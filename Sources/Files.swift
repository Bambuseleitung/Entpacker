import Foundation
import UniformTypeIdentifiers
import SWCompression
import UnrarKit

let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

extension URL: Identifiable { public var id: String { absoluteString } }

enum Kind {
    static let archive: Set<String> = ["zip", "cbz", "7z", "rar", "cbr", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma"]
    // VLC spielt alles, was es kennt; die Liste deckt zusätzlich Endungen ab, die iOS nicht als Medien kennt.
    static let media: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "f4v", "webm", "ogv", "ogm", "ts", "mts", "m2ts", "m2t", "mpg", "mpeg", "mpe",
        "vob", "3gp", "3g2", "rm", "rmvb", "asf", "divx", "xvid", "mxf", "dv", "amv", "nsv", "wtv", "mp3", "m4a", "aac", "flac", "ogg",
        "oga", "opus", "wav", "wma", "ape", "alac", "aiff", "aif", "mka", "mpc", "wv", "tta", "dts", "ac3", "amr",
    ]

    static func isMedia(_ u: URL) -> Bool {
        let ext = u.pathExtension.lowercased()
        return media.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .audiovisualContent) == true
    }
}

func unique(_ url: URL) -> URL {
    var candidate = url, n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        n += 1
    }
    return candidate
}

/// Kopiert Dateien aus „Öffnen mit“ und dem Datei-Dialog in den App-Ordner.
final class Files: ObservableObject {
    @Published var tick = 0

    func receive(_ urls: [URL]) {
        DispatchQueue.global().async {
            for url in urls where !url.path.hasPrefix(docs.path) {
                let scoped = url.startAccessingSecurityScopedResource()
                try? FileManager.default.copyItem(at: url, to: unique(docs.appendingPathComponent(url.lastPathComponent)))
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async { self.tick += 1 }
        }
    }
}

enum Extract {
    struct Unsupported: LocalizedError { var errorDescription: String? { "Format wird nicht unterstützt" } }

    /// Entpackt neben die Datei in einen Ordner gleichen Namens und gibt ihn zurück.
    static func run(_ src: URL) throws -> URL {
        var name = src.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        let dest = unique(src.deletingLastPathComponent().appendingPathComponent(name))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do { try unpack(src, into: dest) } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }

    // shortcut: das ganze Archiv und jeder Eintrag liegen im Speicher (gemappt bzw. pro Eintrag), sehr große 7z-Blöcke können
    // das iPhone überfordern; bei Bedarf auf libarchive mit Streaming umstellen. Passwortgeschützte Archive fehlen.
    private static func unpack(_ src: URL, into dest: URL) throws {
        let ext = src.pathExtension.lowercased()
        if ext == "rar" || ext == "cbr" {
            try URKArchive(path: src.path).extractFiles(to: dest.path, overwrite: true)
            return
        }
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        let payload: Data
        switch ext {
        case "zip", "cbz": return try write(ZipContainer.open(container: data), to: dest)
        case "7z": return try write(SevenZipContainer.open(container: data), to: dest)
        case "tar": return try write(TarContainer.open(container: data), to: dest)
        case "gz", "tgz": payload = try GzipArchive.unarchive(archive: data)
        case "bz2", "tbz", "tbz2": payload = try BZip2.decompress(data: data)
        case "xz", "txz": payload = try XZArchive.unarchive(archive: data)
        case "lzma": payload = try LZMA.decompress(data: data)
        default: throw Unsupported()
        }
        let inner = src.deletingPathExtension().lastPathComponent
        if ["tgz", "tbz", "tbz2", "txz"].contains(ext) || inner.lowercased().hasSuffix(".tar") {
            try write(TarContainer.open(container: payload), to: dest)
        } else {
            try payload.write(to: dest.appendingPathComponent(inner))
        }
    }

    private static func write<E: ContainerEntry>(_ entries: [E], to dest: URL) throws {
        let root = dest.standardizedFileURL.path + "/"
        for e in entries {
            let target = dest.appendingPathComponent(e.info.name).standardizedFileURL
            guard target.path.hasPrefix(root) else { continue } // Zip-Slip: „../“ und absolute Pfade verwerfen
            switch e.info.type {
            case .directory:
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            case .regular:
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (e.data ?? Data()).write(to: target)
            default: continue
            }
        }
    }
}

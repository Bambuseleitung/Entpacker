import Foundation
import UIKit
import UniformTypeIdentifiers
import SWCompression
import UnrarKit
import SSZipArchive
import PLzmaSDK

let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

extension URL: Identifiable { public var id: String { absoluteString } }

enum Kind {
    static let archive: Set<String> = ["zip", "cbz", "7z", "rar", "cbr", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lzma"]
    /// Formate, bei denen ein Passwort möglich ist.
    static let encryptable: Set<String> = ["zip", "cbz", "7z", "rar", "cbr"]
    // VLC spielt alles, was es kennt; die Liste deckt zusätzlich Endungen ab, die iOS nicht als Medien kennt.
    static let media: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "mk3d", "avi", "wmv", "asf", "flv", "f4v", "webm", "ogv", "ogm", "ogx", "ts", "mts", "m2ts", "m2t",
        "trp", "tp", "mpg", "mpeg", "mpe", "m1v", "m2v", "mpv", "mod", "vob", "vro", "evo", "3gp", "3g2", "3gpp", "rm", "rmvb", "divx",
        "xvid", "mxf", "gxf", "dv", "amv", "nsv", "wtv", "ivf", "h264", "h265", "hevc", "264", "265", "y4m", "nut", "bik", "smk", "swf",
        "mp3", "mp2", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus", "wav", "wma", "ape", "alac", "aiff", "aif", "mka", "mpc", "wv",
        "tta", "dts", "ac3", "eac3", "amr", "caf", "spx", "tak",
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

func describe(_ error: Error) -> String {
    if let text = (error as? LocalizedError)?.errorDescription { return text }
    let text = "\(error)"
    // PLzmaSDK liefert mehrzeilige Fehler mit Quelltextstellen; nur die Zeile „What:“ ist für Nutzer brauchbar.
    if let r = text.range(of: "What: ") { return String(text[r.upperBound...].prefix { $0 != "
" }) }
    return text
}

/// Eigener Datei-Dialog über UIKit: SwiftUIs `.fileImporter` öffnet sich nicht, wenn an derselben Ansicht
/// noch andere Dialoge (Vollbild, Hinweis, Vorschau) hängen.
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePicker()
    private var onPick: (([URL]) -> Void)?

    func present(_ onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
        // asCopy: iOS legt die Kopie selbst im tmp-Ordner der App ab, es braucht keinen Sicherheitszugriff.
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        vc.allowsMultipleSelection = true
        vc.delegate = self
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(vc, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick?(urls) }
}

/// Holt Dateien aus „Öffnen mit“ und dem Datei-Dialog in den App-Ordner.
final class Files: ObservableObject {
    @Published var tick = 0
    @Published var error: String?

    func receive(_ urls: [URL]) {
        DispatchQueue.global().async {
            var failures: [String] = []
            for url in urls where !url.path.hasPrefix(docs.path) {
                let dest = unique(docs.appendingPathComponent(url.lastPathComponent))
                let scoped = url.startAccessingSecurityScopedResource()
                do {
                    // Kopien aus tmp/Inbox gehören der App: verschieben spart bei großen Dateien Platz und Zeit.
                    if url.path.contains("/tmp/") || url.path.contains("Inbox/") {
                        try FileManager.default.moveItem(at: url, to: dest)
                    } else {
                        try FileManager.default.copyItem(at: url, to: dest)
                    }
                } catch { failures.append("\(url.lastPathComponent): \(describe(error))") }
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async {
                self.tick += 1
                if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            }
        }
    }
}

enum Extract {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Entpackt neben die Datei in einen Ordner gleichen Namens und gibt ihn zurück.
    static func run(_ src: URL, password: String?, progress: @escaping (Double) -> Void) throws -> URL {
        var name = src.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".tar") { name = String(name.dropLast(4)) }
        let dest = unique(src.deletingLastPathComponent().appendingPathComponent(name))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        do { try unpack(src, into: dest, password: password?.isEmpty == true ? nil : password, progress: progress) } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }

    /// Packt Dateien und Ordner in ein ZIP, optional mit Passwort.
    static func zip(_ urls: [URL], to dest: URL, password: String?) throws {
        let archive = SSZipArchive(path: dest.path)
        guard archive.open() else { throw Failure("ZIP lässt sich nicht anlegen") }
        defer { _ = archive.close() }
        let pw = password?.isEmpty == true ? nil : password
        for u in urls { try add(archive, u, name: u.lastPathComponent, password: pw) }
    }

    private static func add(_ zip: SSZipArchive, _ url: URL, name: String, password: String?) throws {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            _ = zip.writeFolder(atPath: url.path, withFolderName: name, withPassword: password)
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try add(zip, child, name: name + "/" + child.lastPathComponent, password: password)
            }
        } else if !zip.writeFile(atPath: url.path, withFileName: name, withPassword: password) {
            throw Failure("\(url.lastPathComponent) konnte nicht hinzugefügt werden")
        }
    }

    // shortcut: tar/gz/bz2/xz/lzma laufen über SWCompression und liegen im Speicher (Datei gemappt, Einträge einzeln); sehr große
    // Dateien dieser Formate können das iPhone überfordern, dann auf PLzmaSDK (xz/tar) oder libarchive umstellen.
    private static func unpack(_ src: URL, into dest: URL, password: String?, progress: @escaping (Double) -> Void) throws {
        let ext = src.pathExtension.lowercased()
        switch ext {
        case "zip", "cbz":
            try SSZipArchive.unzipFile(atPath: src.path, toDestination: dest.path, overwrite: true, password: password)
        case "rar", "cbr":
            let archive = try URKArchive(path: src.path)
            archive.password = password
            try archive.extractFiles(to: dest.path, overwrite: true)
        case "7z":
            try sevenZip(src, into: dest, password: password, progress: progress)
        default:
            try inMemory(src, ext: ext, into: dest)
        }
    }

    private final class Reporter: DecoderDelegate {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
        func decoder(decoder: PLzmaSDK.Decoder, path: String, progress: Double) { report(progress > 1 ? progress / 100 : progress) }
    }

    /// Streamt von der Platte auf die Platte, auch bei mehreren GB und verschlüsselter Dateiliste.
    private static func sevenZip(_ src: URL, into dest: URL, password: String?, progress: @escaping (Double) -> Void) throws {
        let reporter = Reporter(progress) // der Decoder hält den Beobachter nur schwach
        defer { withExtendedLifetime(reporter) {} }
        let decoder = try PLzmaSDK.Decoder(stream: InStream(path: Path(src.path)), fileType: .sevenZ, delegate: reporter)
        if let password { try decoder.setPassword(password) }
        guard try decoder.open() else { throw Failure("Archiv lässt sich nicht öffnen (Passwort falsch?)") }
        let items = try decoder.items()
        for i in 0..<items.count { // „../“ und absolute Pfade verwerfen (Zip-Slip)
            let path = try items.item(at: i).path().description
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") { throw Failure("Unsicherer Pfad im Archiv: \(path)") }
        }
        guard try decoder.extract(to: Path(dest.path)) else { throw Failure("Entpacken fehlgeschlagen (Passwort falsch?)") }
    }

    private static func inMemory(_ src: URL, ext: String, into dest: URL) throws {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        let payload: Data
        switch ext {
        case "tar": return try write(TarContainer.open(container: data), to: dest)
        case "gz", "tgz": payload = try GzipArchive.unarchive(archive: data)
        case "bz2", "tbz", "tbz2": payload = try BZip2.decompress(data: data)
        case "xz", "txz": payload = try XZArchive.unarchive(archive: data)
        case "lzma": payload = try LZMA.decompress(data: data)
        default: throw Failure("Format wird nicht unterstützt")
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

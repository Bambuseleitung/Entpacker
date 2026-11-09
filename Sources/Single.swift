import Foundation
import SWCompression
import UnrarKit
import PLzmaSDK

/// Merkt Passwörter für die Dauer der App-Sitzung, damit man sie pro Archiv nur einmal eingeben muss.
/// shortcut: nur im Speicher, nach einem Neustart der App wieder leer; dauerhaft ginge es über die Keychain.
enum Passwords {
    private static var store: [String: String] = [:]
    private static let lock = NSLock()

    /// Das eingegebene Passwort gewinnt, sonst das gemerkte.
    static func resolve(_ src: URL, _ typed: String?) -> String? {
        if let typed, !typed.isEmpty { return typed }
        lock.lock(); defer { lock.unlock() }
        return store[src.path]
    }

    static func remember(_ src: URL, _ password: String?) {
        guard let password, !password.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        store[src.path] = password
    }
}

// shortcut: minizip aus dem SSZipArchive-Pod ohne öffentliche Header; die Funktionen sind dort vorhanden und werden hier mit
// ihrer C-Signatur deklariert. Bricht bei einem Pod-Update, dann Version festhalten oder ZIP-Einzeldateien über SWCompression lesen.
@_silgen_name("unzOpen") private func unzOpen(_ path: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
@_silgen_name("unzGoToFirstFile") private func unzGoToFirstFile(_ file: UnsafeMutableRawPointer) -> Int32
@_silgen_name("unzGoToNextFile") private func unzGoToNextFile(_ file: UnsafeMutableRawPointer) -> Int32
@_silgen_name("unzOpenCurrentFilePassword") private func unzOpenCurrentFilePassword(_ file: UnsafeMutableRawPointer, _ password: UnsafePointer<CChar>?) -> Int32
@_silgen_name("unzReadCurrentFile") private func unzReadCurrentFile(_ file: UnsafeMutableRawPointer, _ buffer: UnsafeMutableRawPointer?, _ length: UInt32) -> Int32
@_silgen_name("unzCloseCurrentFile") private func unzCloseCurrentFile(_ file: UnsafeMutableRawPointer) -> Int32
@_silgen_name("unzClose") private func unzClose(_ file: UnsafeMutableRawPointer) -> Int32

extension Extract {
    static let previewRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Preview")

    static func clearPreviews() { try? FileManager.default.removeItem(at: previewRoot) }

    /// Entpackt nur eine Datei des Archivs in einen Zwischenordner (wird beim nächsten Mal und beim App-Start geleert).
    static func single(_ src: URL, entry: ArchiveEntry, password: String?) throws -> URL {
        let pw = Passwords.resolve(src, password)
        clearPreviews()
        let dest = previewRoot.appendingPathComponent(UUID().uuidString)
        let target = dest.appendingPathComponent(entry.path).standardizedFileURL
        // „../“ und absolute Pfade verwerfen (Zip-Slip)
        guard target.path.hasPrefix(dest.standardizedFileURL.path + "/") else { throw Failure("Unsicherer Pfad im Archiv") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch src.pathExtension.lowercased() {
        case "zip", "cbz": try zipSingle(src, index: entry.index, password: pw, to: target)
        case "rar", "cbr": try rarSingle(src, entry: entry, password: pw, to: target)
        case "7z": try sevenZipSingle(src, entry: entry, password: pw, into: dest)
        default: try memorySingle(src, entry: entry, to: target)
        }
        guard FileManager.default.fileExists(atPath: target.path) else { throw Failure("Datei konnte nicht entpackt werden") }
        Passwords.remember(src, pw)
        return target
    }

    private static func zipSingle(_ src: URL, index: Int, password: String?, to target: URL) throws {
        guard let zip = unzOpen(src.path) else { throw Failure("ZIP lässt sich nicht öffnen") }
        defer { _ = unzClose(zip) }
        guard unzGoToFirstFile(zip) == 0 else { throw Failure("ZIP ist leer oder beschädigt") }
        for _ in 0..<index {
            guard unzGoToNextFile(zip) == 0 else { throw Failure("Eintrag nicht gefunden") }
        }
        guard unzOpenCurrentFilePassword(zip, password) == 0 else { throw Failure("Datei lässt sich nicht öffnen (Passwort nötig?)") }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { unzReadCurrentFile(zip, $0.baseAddress, UInt32($0.count)) }
            if n < 0 { _ = unzCloseCurrentFile(zip); throw Failure("Passwort falsch oder Datei beschädigt") }
            if n == 0 { break }
            handle.write(Data(buffer[0..<Int(n)]))
        }
        // Die Prüfsumme wird erst beim Schließen verglichen: ein falsches Passwort fällt hier auf.
        guard unzCloseCurrentFile(zip) == 0 else { throw Failure("Passwort falsch oder Datei beschädigt") }
    }

    private static func rarSingle(_ src: URL, entry: ArchiveEntry, password: String?, to target: URL) throws {
        let archive = try URKArchive(path: src.path)
        archive.password = password
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try archive.extractBufferedData(fromFile: entry.path) { chunk, _ in handle.write(chunk) }
    }

    private static func sevenZipSingle(_ src: URL, entry: ArchiveEntry, password: String?, into dest: URL) throws {
        let decoder = try PLzmaSDK.Decoder(stream: InStream(path: Path(src.path)), fileType: .sevenZ, delegate: nil)
        if let password { try decoder.setPassword(password) }
        guard try decoder.open() else { throw Failure("Archiv lässt sich nicht öffnen (Passwort falsch?)") }
        let wanted = try ItemArray(capacity: 1)
        try wanted.add(item: decoder.items().item(at: Size(entry.index)))
        guard try decoder.extract(items: wanted, to: Path(dest.path), itemsFullPath: true) else {
            throw Failure("Entpacken fehlgeschlagen (Passwort falsch?)")
        }
    }

    /// tar, tgz, gz, bz2, xz, lzma: wie beim Entpacken im Speicher.
    private static func memorySingle(_ src: URL, entry: ArchiveEntry, to target: URL) throws {
        let ext = src.pathExtension.lowercased()
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        let payload: Data
        switch ext {
        case "tar": payload = data
        case "gz", "tgz": payload = try GzipArchive.unarchive(archive: data)
        case "bz2", "tbz", "tbz2": payload = try BZip2.decompress(data: data)
        case "xz", "txz": payload = try XZArchive.unarchive(archive: data)
        case "lzma": payload = try LZMA.decompress(data: data)
        default: throw Failure("Format wird nicht unterstützt")
        }
        let inner = src.deletingPathExtension().lastPathComponent.lowercased()
        let isTar = ext == "tar" || ["tgz", "tbz", "tbz2", "txz"].contains(ext) || inner.hasSuffix(".tar")
        if isTar {
            guard let e = try TarContainer.open(container: payload).first(where: { $0.info.name == entry.path }) else {
                throw Failure("Eintrag nicht gefunden")
            }
            try (e.data ?? Data()).write(to: target)
        } else {
            try payload.write(to: target)
        }
    }
}

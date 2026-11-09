import SwiftUI
import SWCompression
import UnrarKit
import PLzmaSDK

struct ArchiveEntry: Identifiable {
    let path: String
    let size: Int64?
    let isDir: Bool
    var id: String { path }
}

/// Liest die Dateiliste eines Archivs, ohne etwas zu entpacken.
enum Listing {
    static func entries(of src: URL, password: String?) throws -> [ArchiveEntry] {
        let pw = password?.isEmpty == true ? nil : password
        let ext = src.pathExtension.lowercased()
        switch ext {
        case "rar", "cbr":
            let archive = try URKArchive(path: src.path)
            archive.password = pw
            return try archive.listFileInfo().map { ArchiveEntry(path: $0.filename, size: Int64($0.uncompressedSize), isDir: $0.isDirectory) }
        case "7z":
            return try sevenZip(src, password: pw)
        default:
            // shortcut: wie beim Entpacken liegt die Datei gemappt im Speicher; bei gz/bz2/xz wird sie dafür ganz entpackt.
            let data = try Data(contentsOf: src, options: .mappedIfSafe)
            switch ext {
            case "zip", "cbz": return map(try ZipContainer.info(container: data))
            case "tar": return map(try TarContainer.info(container: data))
            case "gz", "tgz": return try inner(GzipArchive.unarchive(archive: data), src, ext)
            case "bz2", "tbz", "tbz2": return try inner(BZip2.decompress(data: data), src, ext)
            case "xz", "txz": return try inner(XZArchive.unarchive(archive: data), src, ext)
            case "lzma": return try inner(LZMA.decompress(data: data), src, ext)
            default: throw Extract.Failure("Format wird nicht unterstützt")
            }
        }
    }

    private static func map<I: ContainerEntryInfo>(_ infos: [I]) -> [ArchiveEntry] {
        infos.map { ArchiveEntry(path: $0.name, size: $0.size.map(Int64.init), isDir: $0.type == .directory) }
    }

    private static func inner(_ payload: Data, _ src: URL, _ ext: String) throws -> [ArchiveEntry] {
        let name = src.deletingPathExtension().lastPathComponent
        if ["tgz", "tbz", "tbz2", "txz"].contains(ext) || name.lowercased().hasSuffix(".tar") {
            return map(try TarContainer.info(container: payload))
        }
        return [ArchiveEntry(path: name, size: Int64(payload.count), isDir: false)]
    }

    private static func sevenZip(_ src: URL, password: String?) throws -> [ArchiveEntry] {
        let decoder = try PLzmaSDK.Decoder(stream: InStream(path: Path(src.path)), fileType: .sevenZ, delegate: nil)
        if let password { try decoder.setPassword(password) }
        guard try decoder.open() else { throw Extract.Failure("Archiv lässt sich nicht öffnen (Passwort nötig oder falsch?)") }
        let items = try decoder.items()
        var out: [ArchiveEntry] = []
        for i in 0..<items.count {
            let item = try items.item(at: i)
            out.append(ArchiveEntry(path: try item.path().description, size: Int64(item.size), isDir: item.isDir))
        }
        return out
    }
}

struct ArchiveView: View {
    let url: URL
    let extractAll: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ArchiveEntry]?
    @State private var error: String?
    @State private var loading = true
    @State private var password = ""
    @State private var query = ""

    private var shown: [ArchiveEntry] {
        guard let entries else { return [] }
        return query.isEmpty ? entries : entries.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    List {
                        Section(summary(entries)) {
                            ForEach(shown) { entry in
                                let parts = entry.path.split(separator: "/")
                                HStack {
                                    Image(systemName: entry.isDir ? "folder.fill" : "doc").frame(width: 24)
                                    Text(parts.last.map(String.init) ?? entry.path).lineLimit(2)
                                    Spacer()
                                    if let size = entry.size, !entry.isDir {
                                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, CGFloat(max(parts.count - 1, 0)) * 14)
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Im Archiv suchen")
                } else if loading {
                    ProgressView("Lese Inhalt …")
                } else {
                    VStack(spacing: 12) {
                        Text(error ?? "").multilineTextAlignment(.center)
                        if Kind.encryptable.contains(url.pathExtension.lowercased()) {
                            SecureField("Passwort", text: $password).textFieldStyle(.roundedBorder)
                            Button("Öffnen") { load(password) }.buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Entpacken") { dismiss(); extractAll() } }
            }
        }
        .onAppear { load(nil) }
    }

    private func summary(_ list: [ArchiveEntry]) -> String {
        let files = list.filter { !$0.isDir }
        let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return "\(files.count) Dateien, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private func load(_ pw: String?) {
        loading = true
        error = nil
        let src = url
        Task.detached {
            do {
                let list = try Listing.entries(of: src, password: pw).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                await MainActor.run { entries = list; loading = false }
            } catch {
                // Verschlüsselte Archive melden beim Öffnen nur einen allgemeinen Fehler; mit Passwortfeld sagt das mehr als der Rohtext.
                let message = Kind.encryptable.contains(src.pathExtension.lowercased())
                    ? ((pw ?? "").isEmpty ? "Das Archiv ist verschlüsselt. Gib das Passwort ein." : "Passwort falsch oder Archiv beschädigt.") + "\n\n" + describe(error)
                    : describe(error)
                await MainActor.run {
                    self.error = message
                    if password.isEmpty { password = clipboardPassword() }
                    loading = false
                }
            }
        }
    }
}

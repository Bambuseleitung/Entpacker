import SwiftUI
import QuickLook
import SWCompression
import UnrarKit
import PLzmaSDK

struct ArchiveEntry: Identifiable {
    let path: String
    let size: Int64?
    let isDir: Bool
    var index = 0 // Stelle im Archiv, so wie das Archiv sie führt (nicht nach dem Sortieren)
    var id: String { path }
}

/// Liest die Dateiliste eines Archivs, ohne etwas zu entpacken.
enum Listing {
    static func entries(of src: URL, password: String?) throws -> [ArchiveEntry] {
        let pw = Passwords.resolve(src, password)
        let list = try read(src, pw)
        Passwords.remember(src, pw)
        return list
    }

    private static func read(_ src: URL, _ pw: String?) throws -> [ArchiveEntry] {
        let ext = src.pathExtension.lowercased()
        switch ext {
        case "rar", "cbr":
            let archive = try URKArchive(path: src.path)
            archive.password = pw
            return try archive.listFileInfo().enumerated().map {
                ArchiveEntry(path: $1.filename, size: Int64($1.uncompressedSize), isDir: $1.isDirectory, index: $0)
            }
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
        infos.enumerated().map { ArchiveEntry(path: $1.name, size: $1.size.map(Int64.init), isDir: $1.type == .directory, index: $0) }
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
            out.append(ArchiveEntry(path: try item.path().description, size: Int64(item.size), isDir: item.isDir, index: Int(i)))
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
    @State private var working = false
    @State private var alert: Hint?
    @State private var retry: ArchiveEntry?   // Datei, die ein Passwort braucht
    @State private var quick: URL?
    @State private var video: URL?

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
                                Button { preview(entry) } label: {
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
                                .tint(.primary)
                                .disabled(entry.isDir)
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
        .quickLookPreview($quick)
        .overlay { if working { ProgressView("Entpacke Datei …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        // Jede Präsentation an eine eigene Ansicht hängen: mehrere Dialoge an derselben Ansicht blockieren sich in SwiftUI gegenseitig.
        .background(Color.clear.fullScreenCover(item: $video) { PlayerScreen(url: $0, playlist: [$0]) })
        .background(Color.clear.alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            if alert?.kind == .password {
                SecureField("Passwort", text: $password)
                Button("Öffnen") { if let entry = retry { preview(entry, password: password) } }
                Button("Abbrechen", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { Text(alert?.text ?? "") })
    }

    /// Entpackt nur diese Datei und öffnet sie: Videos im Player, alles andere in der Vorschau.
    private func preview(_ entry: ArchiveEntry, password: String? = nil) {
        guard !entry.isDir else { return }
        working = true
        let src = url
        Task.detached {
            do {
                let file = try Extract.single(src, entry: entry, password: password)
                await MainActor.run {
                    working = false
                    if Kind.isMedia(file) || !QLPreviewController.canPreview(file as NSURL) { video = file } else { quick = file }
                }
            } catch {
                let message = describe(error)
                await MainActor.run {
                    working = false
                    if Kind.encryptable.contains(src.pathExtension.lowercased()) {
                        retry = entry
                        self.password = clipboardPassword()
                        alert = Hint(title: "Passwort nötig", text: message, kind: .password)
                    } else {
                        alert = Hint(title: "Fehler", text: message)
                    }
                }
            }
        }
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

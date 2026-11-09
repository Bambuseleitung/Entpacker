import SwiftUI
import QuickLook

@main
struct EntpackerApp: App {
    @StateObject private var files = Files()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FolderView(dir: docs).navigationDestination(for: URL.self) { FolderView(dir: $0) }
            }
            .environmentObject(files)
            .onOpenURL { files.receive([$0]) }
        }
    }
}

struct Hint {
    let title: String
    let text: String
    let needsPassword: Bool
}

struct FileRow: Identifiable {
    let url: URL
    let isDir: Bool
    let size: Int64
    var id: URL { url }
}

struct FolderView: View {
    let dir: URL
    @EnvironmentObject private var fs: Files
    @State private var items: [FileRow] = []
    @State private var busy = false
    @State private var progress: Double?
    @State private var alert: Hint?
    @State private var quick: URL?
    @State private var video: URL?
    @State private var retry: URL?        // Archiv, das ein Passwort braucht
    @State private var password = ""

    var body: some View {
        List {
            ForEach(items) { row($0) }
                .onDelete { idx in
                    idx.forEach { try? FileManager.default.removeItem(at: items[$0].url) }
                    load()
                }
        }
        .overlay {
            if items.isEmpty {
                Text("Leer.\nMit + Dateien holen oder in einer anderen App „Öffnen mit Entpacker“ wählen.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
            }
            if busy {
                VStack {
                    if let progress { ProgressView("Entpacke … \(Int(progress * 100)) %", value: progress) } else { ProgressView("Entpacke …") }
                }
                .frame(width: 220).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle(dir == docs ? "Entpacker" : dir.lastPathComponent)
        .toolbar {
            Button { FilePicker.shared.present { fs.receive($0) } } label: { Image(systemName: "plus") }
        }
        .quickLookPreview($quick)
        // Jede Präsentation an eine eigene Ansicht hängen: mehrere Dialoge an derselben Ansicht blockieren sich in SwiftUI gegenseitig.
        .background(Color.clear.fullScreenCover(item: $video) { PlayerScreen(url: $0) })
        .background(Color.clear.alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            if alert?.needsPassword == true {
                SecureField("Passwort", text: $password)
                Button("Entpacken") { if let u = retry { extract(u, password: password) } }
                Button("Abbrechen", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { Text(alert?.text ?? "") })
        .onAppear(perform: load)
        .onChange(of: fs.tick) { _ in load() }
        .onChange(of: fs.error) { if let e = $0 { alert = Hint(title: "Fehler", text: e, needsPassword: false); fs.error = nil } }
    }

    @ViewBuilder private func row(_ it: FileRow) -> some View {
        let name = it.url.lastPathComponent
        if it.isDir {
            NavigationLink(value: it.url) { Label(name, systemImage: "folder.fill") }
        } else {
            let archive = Kind.archive.contains(it.url.pathExtension.lowercased())
            Button { open(it.url) } label: {
                HStack {
                    Image(systemName: archive ? "archivebox.fill" : Kind.isMedia(it.url) ? "play.rectangle.fill" : "doc.fill")
                        .frame(width: 28)
                    VStack(alignment: .leading) {
                        Text(name).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.primary)
            .contextMenu {
                if archive { Button { extract(it.url) } label: { Label("Entpacken", systemImage: "arrow.down.doc") } }
                Button { video = it.url } label: { Label("Im Player öffnen", systemImage: "play.circle") }
                ShareLink(item: it.url)
                Button(role: .destructive) {
                    try? FileManager.default.removeItem(at: it.url)
                    load()
                } label: { Label("Löschen", systemImage: "trash") }
            }
        }
    }

    private func open(_ u: URL) {
        if Kind.archive.contains(u.pathExtension.lowercased()) { extract(u) }
        else if Kind.isMedia(u) { video = u }
        else if QLPreviewController.canPreview(u as NSURL) { quick = u }
        else { video = u } // unbekanntes Format: VLC versucht es trotzdem
    }

    private func extract(_ src: URL, password: String? = nil) {
        busy = true
        progress = nil
        UIApplication.shared.isIdleTimerDisabled = true // sonst sperrt das iPhone mitten im Entpacken
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Extract.run(src, password: password) { p in DispatchQueue.main.async { progress = p } } }
            DispatchQueue.main.async {
                busy = false
                UIApplication.shared.isIdleTimerDisabled = false
                if case .failure(let e) = result {
                    if Kind.encryptable.contains(src.pathExtension.lowercased()) {
                        retry = src
                        self.password = ""
                        alert = Hint(title: "Passwort nötig", text: "\(src.lastPathComponent)\n\(describe(e))\nFalls das Archiv ein Passwort hat, gib es hier ein.", needsPassword: true)
                    } else {
                        alert = Hint(title: "Fehler", text: "\(src.lastPathComponent): \(describe(e))", needsPassword: false)
                    }
                }
                load()
            }
        }
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        items = urls.map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return FileRow(url: $0, isDir: v?.isDirectory == true, size: Int64(v?.fileSize ?? 0))
        }
        .sorted { ($0.isDir ? 0 : 1, $0.url.lastPathComponent.lowercased()) < ($1.isDir ? 0 : 1, $1.url.lastPathComponent.lowercased()) }
    }
}

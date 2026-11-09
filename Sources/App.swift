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

struct Item: Identifiable {
    let url: URL
    let isDir: Bool
    let size: Int64
    var id: URL { url }
}

struct FolderView: View {
    let dir: URL
    @EnvironmentObject private var fs: Files
    @State private var items: [Item] = []
    @State private var busy = false
    @State private var message: String?
    @State private var quick: URL?
    @State private var video: URL?
    @State private var picking = false

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
            if busy { ProgressView("Entpacke …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .navigationTitle(dir == docs ? "Entpacker" : dir.lastPathComponent)
        .toolbar {
            Button { picking = true } label: { Image(systemName: "plus") }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { fs.receive(urls) }
        }
        .quickLookPreview($quick)
        .fullScreenCover(item: $video) { PlayerScreen(url: $0) }
        .alert("Fehler", isPresented: Binding(get: { message != nil }, set: { _ in message = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
        .onAppear(perform: load)
        .onChange(of: fs.tick) { _ in load() }
    }

    @ViewBuilder private func row(_ it: Item) -> some View {
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
        else { quick = u }
    }

    private func extract(_ src: URL) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Extract.run(src) }
            DispatchQueue.main.async {
                busy = false
                if case .failure(let e) = result { message = "\(src.lastPathComponent): \(e.localizedDescription)" }
                load()
            }
        }
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        items = urls.map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return Item(url: $0, isDir: v?.isDirectory == true, size: Int64(v?.fileSize ?? 0))
        }
        .sorted { ($0.isDir ? 0 : 1, $0.url.lastPathComponent.lowercased()) < ($1.isDir ? 0 : 1, $1.url.lastPathComponent.lowercased()) }
    }
}

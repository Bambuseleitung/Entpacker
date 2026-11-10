import SwiftUI

/// Eigener Reiter: nur Videos (und Audio), eigener Ordner „Videos“, Wiedergabeliste über alle Einträge.
struct VideosView: View {
    @EnvironmentObject private var fs: Files
    @State private var items: [FileRow] = []
    @State private var playing: URL?
    @State private var message: String?

    var body: some View {
        List {
            ForEach(items) { item in
                Button { playing = item.url } label: { VideoRow(item: item) }
                    .tint(.primary)
                    .contextMenu {
                        ShareLink(item: item.url)
                        Button(role: .destructive) { remove(item) } label: { Label("Löschen", systemImage: "trash") }
                    }
            }
            .onDelete { idx in idx.forEach { remove(items[$0], reload: false) }; load() }
        }
        .listStyle(.plain)
        .overlay {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle").font(.largeTitle)
                    Text("Noch keine Videos.\nMit + Videos importieren.").multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Videos")
        .toolbar {
            Button { FilePicker.shared.present { fs.receive($0, into: videosDir, onlyVideos: true) } } label: { Image(systemName: "plus") }
        }
        .background(Color.clear.fullScreenCover(item: $playing) { PlayerScreen(url: $0, playlist: items.map(\.url)) })
        .background(Color.clear.alert("Hinweis", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") })
        .onAppear(perform: load)
        .onChange(of: fs.tick) { _ in load() }
        .onChange(of: fs.videoError) { if let e = $0 { message = e; fs.videoError = nil } }
    }

    private func remove(_ item: FileRow, reload: Bool = true) {
        try? FileManager.default.removeItem(at: item.url)
        Thumbs.forget(item.url)
        if reload { load() }
    }

    private func load() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        items = urls.filter(Kind.isMedia).map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return FileRow(url: $0, isDir: false, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }
}

private struct VideoRow: View {
    let item: FileRow
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Color(white: 0.15)
                if let cover { Image(uiImage: cover).resizable().scaledToFill() } else { Image(systemName: "play.fill").foregroundStyle(.secondary) }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent).lineLimit(2)
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { cover = await Thumbs.cover(for: item.url) }
    }
}

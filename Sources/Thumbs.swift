import SwiftUI
import UniformTypeIdentifiers
import MobileVLCKit

/// Holt einzelne Bilder aus einem Video über VLC (klappt auch bei MKV, AVI usw., anders als AVFoundation).
private final class Grab: NSObject, VLCMediaThumbnailerDelegate {
    private var done: ((UIImage?) -> Void)?
    private var thumbnailer: VLCMediaThumbnailer?
    private var me: Grab? // hält sich selbst am Leben, bis VLC antwortet

    func start(_ url: URL, at position: Double, width: Double, _ done: @escaping (UIImage?) -> Void) {
        self.done = done
        me = self
        let t = VLCMediaThumbnailer(media: VLCMedia(url: url), andDelegate: self)
        t.snapshotPosition = .init(position)
        t.thumbnailWidth = .init(width)
        t.thumbnailHeight = .init(width * 9 / 16)
        thumbnailer = t
        t.fetchThumbnail()
        // eigene Zeitgrenze, falls VLC nie antwortet
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.finish(nil) }
    }

    private func finish(_ image: UIImage?) {
        DispatchQueue.main.async {
            guard let done = self.done else { return }
            self.done = nil
            self.thumbnailer = nil
            self.me = nil
            done(image)
        }
    }

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer!) { finish(nil) }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer!, didFinishThumbnail thumbnail: CGImage!) {
        finish(thumbnail.map { UIImage(cgImage: $0) })
    }
}

/// Vorschaubilder für die Zeitleiste (pro Video 30 Stück, grob zuerst) und Titelbilder für die Videoliste.
final class Thumbs: ObservableObject {
    static let count = 30
    @Published private(set) var strip: [Int: UIImage] = [:]
    private var task: Task<Void, Never>?

    /// Startet erst nach 2 s, damit die Wiedergabe nicht zusammen mit dem Dekodieren der Vorschau anläuft.
    func start(_ url: URL) {
        cancel()
        strip = [:]
        guard !Self.isAudio(url) else { return }
        task = Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // 0, 5, 10 … zuerst, dann die Lücken: so gibt es früh eine grobe Vorschau
            let order = (0..<Self.count).sorted { ($0 % 5, $0) < ($1 % 5, $1) }
            for i in order {
                if Task.isCancelled { return }
                if let image = await Self.grab(url, at: (Double(i) + 0.5) / Double(Self.count), width: 240) { strip[i] = image }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Nächstgelegenes fertiges Bild zur Position 0…1.
    func image(at p: Float) -> UIImage? {
        guard !strip.isEmpty else { return nil }
        let target = min(max(Int(p * Float(Self.count)), 0), Self.count - 1)
        for distance in 0..<Self.count {
            if let image = strip[target - distance] ?? strip[target + distance] { return image }
        }
        return nil
    }

    // MARK: Titelbilder

    private static let coverDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers")

    private static func coverFile(_ url: URL) -> URL {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let hash = url.path.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
        return coverDir.appendingPathComponent("\(abs(hash))-\(size).jpg")
    }

    static func cover(for url: URL) async -> UIImage? {
        let file = coverFile(url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        guard !isAudio(url), let image = await grab(url, at: 0.1, width: 320) else { return nil }
        try? FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
        try? image.jpegData(compressionQuality: 0.7)?.write(to: file)
        return image
    }

    static func forget(_ url: URL) { try? FileManager.default.removeItem(at: coverFile(url)) }

    // MARK: Hilfen

    private static let audio: Set<String> = [
        "mp3", "mp2", "m4a", "m4b", "aac", "flac", "ogg", "oga", "opus", "wav", "wma", "ape", "alac", "aiff", "aif", "mka", "mpc", "wv",
        "tta", "dts", "ac3", "eac3", "amr", "caf", "spx", "tak", "mp1", "mpa", "wax", "au", "snd", "mid", "oma",
    ]

    private static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return audio.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .audio) == true
    }

    @MainActor private static func grab(_ url: URL, at position: Double, width: Double) async -> UIImage? {
        await withCheckedContinuation { continuation in
            Grab().start(url, at: position, width: width) { continuation.resume(returning: $0) }
        }
    }
}

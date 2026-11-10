import SwiftUI
import AVFoundation
import MobileVLCKit

struct Track: Identifiable {
    let id: Int32
    let name: String
}

final class Player: ObservableObject {
    let vlc = VLCMediaPlayer()
    let thumbs = Thumbs()
    @Published var position: Float = 0
    @Published var elapsed = "0:00"
    @Published var total = "0:00"
    @Published var playing = true
    @Published var failed = false
    @Published var speed: Float = 1
    @Published var boosting = false
    @Published var toast: String?
    var onEnded: (() -> Void)?
    private var current: URL?
    private var timer: Timer?
    private var didEnd = false
    private var resume: Float?
    private var target: Float = 0
    private var holdUntil = Date.distantPast

    // MARK: Wiedergabe

    func start(_ url: URL, in view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        vlc.drawable = view
        load(url)
        // 0,1 s statt 0,5 s: der Fortschrittspunkt wirkt sonst ruckelig
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Wechselt auf ein anderes Video (nächstes/vorheriges, automatisches Weiterspielen).
    func open(_ url: URL) {
        saveResume()
        load(url)
    }

    private func load(_ url: URL) {
        current = url
        didEnd = false
        failed = false
        position = 0
        resume = Self.savedPosition(url)
        vlc.media = VLCMedia(url: url)
        vlc.play()
        vlc.rate = speed
        thumbs.start(url)
    }

    func stop() {
        saveResume()
        timer?.invalidate()
        thumbs.cancel()
        vlc.stop()
    }

    func toggle() {
        if vlc.isPlaying { vlc.pause() } else { vlc.play() }
    }

    func setSpeed(_ rate: Float) {
        speed = rate
        if !boosting { vlc.rate = rate }
    }

    /// Gedrückt halten: doppelte Geschwindigkeit, loslassen: zurück zur gewählten.
    func boost(_ on: Bool) {
        guard boosting != on else { return }
        boosting = on
        vlc.rate = on ? 2 : speed
        if on { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    func skip(_ seconds: Int32) {
        if seconds > 0 { vlc.jumpForward(seconds) } else { vlc.jumpBackward(-seconds) }
        toast = seconds > 0 ? "+\(seconds) s" : "−\(-seconds) s"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.toast = nil }
    }

    /// Springt an eine Stelle und hält den Fortschrittspunkt dort, bis VLC nachgekommen ist (sonst springt er zurück).
    func seek(to p: Float) {
        target = p
        holdUntil = Date().addingTimeInterval(1)
        position = p
        vlc.position = p
    }

    // MARK: Zeitanzeige

    private var duration: Int { Int(vlc.media?.length.intValue ?? 0) } // Millisekunden

    func label(at p: Float) -> String {
        let s = Int(Double(duration) * Double(p) / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func tick() {
        playing = vlc.isPlaying
        failed = vlc.state == .error
        if vlc.state == .ended, !didEnd {
            didEnd = true
            onEnded?()
        }
        if let r = resume, vlc.isPlaying, duration > 0 {
            resume = nil
            seek(to: r)
        }
        if !(Date() < holdUntil && abs(vlc.position - target) > 0.01) { position = vlc.position }
        elapsed = vlc.time.stringValue ?? "0:00"
        total = vlc.media?.length.stringValue ?? "0:00"
    }

    // MARK: Weiterschauen

    private static func key(_ url: URL) -> String { "pos:" + url.path }
    private static func savedPosition(_ url: URL) -> Float? {
        let p = UserDefaults.standard.float(forKey: key(url))
        return p > 0.02 && p < 0.97 ? p : nil
    }

    private func saveResume() {
        guard let current else { return }
        let p = vlc.position
        if p > 0.02 && p < 0.97 { UserDefaults.standard.set(p, forKey: Self.key(current)) }
        else { UserDefaults.standard.removeObject(forKey: Self.key(current)) }
    }

    // MARK: Spuren

    private func tracks(_ names: [Any]?, _ ids: [Any]?) -> [Track] {
        zip(names ?? [], ids ?? []).compactMap { n, i in
            guard let n = n as? String, let i = (i as? NSNumber)?.int32Value else { return nil }
            return Track(id: i, name: n)
        }
    }

    var audioTracks: [Track] { tracks(vlc.audioTrackNames, vlc.audioTrackIndexes) }
    var subtitleTracks: [Track] { tracks(vlc.videoSubTitlesNames, vlc.videoSubTitlesIndexes) }
}

/// Zeichenfläche für VLC; Gesten: Tippen = Bedienung ein/aus, Doppeltippen links/rechts = ∓10 s, gedrückt halten = doppelte Geschwindigkeit.
private struct Surface: UIViewRepresentable {
    let player: Player
    let url: URL
    let onTap: () -> Void

    final class Coordinator: NSObject {
        let player: Player
        var onTap: () -> Void
        init(_ player: Player, _ onTap: @escaping () -> Void) {
            self.player = player
            self.onTap = onTap
        }

        @objc func tap() { onTap() }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            player.skip(g.location(in: v).x < v.bounds.midX ? -10 : 10)
        }

        @objc func press(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began: player.boost(true)
            case .ended, .cancelled, .failed: player.boost(false)
            default: break
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(player, onTap) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        let c = context.coordinator
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.35
        [single, double, press].forEach(v.addGestureRecognizer)
        DispatchQueue.main.async { player.start(url, in: v) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) { context.coordinator.onTap = onTap }
}

/// Eigene Zeitleiste: der Punkt folgt dem Finger sofort, beim Ziehen erscheint eine Vorschau.
private struct Scrubber<Content: View>: View {
    let progress: Float
    @Binding var dragging: Float?
    let onCommit: (Float) -> Void
    @ViewBuilder let bubble: (Float) -> Content

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let active = dragging != nil
            let value = CGFloat(dragging ?? progress)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(width: w, height: active ? 8 : 4)
                Capsule().fill(Color.white).frame(width: w * value, height: active ? 8 : 4)
                Circle().fill(Color.white).frame(width: active ? 24 : 14, height: active ? 24 : 14)
                    .offset(x: w * value - (active ? 12 : 7))
                if let d = dragging {
                    bubble(d)
                        .offset(x: min(max(w * CGFloat(d) - 85, 0), w - 170), y: -110)
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in dragging = Float(min(max(g.location.x / w, 0), 1)) }
                    .onEnded { g in
                        let p = Float(min(max(g.location.x / w, 0), 1))
                        dragging = nil
                        onCommit(p)
                    }
            )
        }
        .frame(height: 44)
        .animation(.easeOut(duration: 0.12), value: dragging != nil)
    }
}

private struct Bubble: View {
    @ObservedObject var thumbs: Thumbs
    let position: Float
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black
                if let image = thumbs.image(at: position) { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: 170, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label).font(.caption.monospacedDigit().bold())
        }
        .padding(6)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PlayerScreen: View {
    let url: URL
    let playlist: [URL]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p = Player()
    @State private var showUI = true
    @State private var dragging: Float?
    @State private var hide: DispatchWorkItem?
    @State private var current: URL

    init(url: URL, playlist: [URL]) {
        self.url = url
        self.playlist = playlist.contains(url) ? playlist : [url]
        _current = State(initialValue: url)
    }

    private func step(_ delta: Int) {
        guard let i = playlist.firstIndex(of: current), playlist.indices.contains(i + delta) else { return }
        current = playlist[i + delta]
    }

    /// Bedienung nach 3,5 s ausblenden, solange es läuft.
    private func poke() {
        hide?.cancel()
        showUI = true
        let work = DispatchWorkItem { if p.playing && dragging == nil { withAnimation { showUI = false } } }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Surface(player: p, url: url) {
                if showUI { hide?.cancel(); withAnimation { showUI = false } } else { poke() }
            }
            .ignoresSafeArea()
            if p.boosting { badge("2× ▶▶").frame(maxHeight: .infinity, alignment: .top).padding(.top, 60) }
            if let t = p.toast { badge(t) }
            if p.failed { Text("Diese Datei lässt sich nicht abspielen.").foregroundStyle(.white) }
            if showUI { controls.transition(.opacity) }
        }
        .statusBarHidden(!showUI)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            p.onEnded = { step(1) }
            poke()
        }
        .onChange(of: current) { p.open($0) }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            p.stop()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.headline).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title3) }
                Text(current.lastPathComponent).lineLimit(1).font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { r in
                        Button("\(r.formatted()) ×") { p.setSpeed(r); poke() }
                    }
                } label: { Image(systemName: "speedometer").font(.title3) }
                menu("Ton", "speaker.wave.2", p.audioTracks) { p.vlc.currentAudioTrackIndex = $0 }
                menu("Untertitel", "captions.bubble", p.subtitleTracks) { p.vlc.currentVideoSubTitleIndex = $0 }
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: 36) {
                if playlist.count > 1 { Button { step(-1) } label: { Image(systemName: "backward.end.fill").font(.title2) } }
                Button { p.skip(-10); poke() } label: { Image(systemName: "gobackward.10").font(.title) }
                Button { p.toggle(); poke() } label: { Image(systemName: p.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                Button { p.skip(10); poke() } label: { Image(systemName: "goforward.10").font(.title) }
                if playlist.count > 1 { Button { step(1) } label: { Image(systemName: "forward.end.fill").font(.title2) } }
            }
            Spacer()
            VStack(spacing: 0) {
                Scrubber(progress: p.position, dragging: $dragging, onCommit: { p.seek(to: $0); poke() }) { pos in
                    Bubble(thumbs: p.thumbs, position: pos, label: p.label(at: pos))
                }
                HStack {
                    Text(dragging.map { p.label(at: $0) } ?? p.elapsed)
                    Spacer()
                    Text(p.total)
                }
                .font(.caption.monospacedDigit())
            }
            .padding(.horizontal).padding(.bottom, 8).padding(.top, 24)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func menu(_ title: String, _ icon: String, _ tracks: [Track], pick: @escaping (Int32) -> Void) -> some View {
        if !tracks.isEmpty {
            Menu {
                ForEach(tracks) { t in Button(t.name) { pick(t.id); poke() } }
            } label: { Image(systemName: icon).font(.title3) }
                .accessibilityLabel(title)
        }
    }
}

import SwiftUI
import AVFoundation
import MobileVLCKit

struct Track: Identifiable {
    let id: Int32
    let name: String
}

final class Player: ObservableObject {
    let vlc = VLCMediaPlayer()
    @Published var position: Float = 0
    @Published var elapsed = "0:00"
    @Published var total = "0:00"
    @Published var playing = true
    @Published var failed = false
    @Published var speed: Float = 1
    var scrubbing = false
    var onEnded: (() -> Void)?
    private var didEnd = false
    private var timer: Timer?

    func start(_ url: URL, in view: UIView) {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        vlc.drawable = view
        vlc.media = VLCMedia(url: url)
        vlc.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func open(_ url: URL) {
        didEnd = false
        failed = false
        vlc.media = VLCMedia(url: url)
        vlc.play()
        vlc.rate = speed
    }

    func setSpeed(_ rate: Float) {
        speed = rate
        vlc.rate = rate
    }

    func stop() {
        timer?.invalidate()
        vlc.stop()
    }

    func toggle() {
        if vlc.isPlaying { vlc.pause() } else { vlc.play() }
    }

    private func tick() {
        playing = vlc.isPlaying
        failed = vlc.state == .error
        if vlc.state == .ended, !didEnd {
            didEnd = true
            onEnded?()
        }
        if !scrubbing { position = vlc.position }
        elapsed = vlc.time.stringValue ?? "0:00"
        total = vlc.media?.length.stringValue ?? "0:00"
    }

    private func tracks(_ names: [Any]?, _ ids: [Any]?) -> [Track] {
        zip(names ?? [], ids ?? []).compactMap { n, i in
            guard let n = n as? String, let i = (i as? NSNumber)?.int32Value else { return nil }
            return Track(id: i, name: n)
        }
    }

    var audioTracks: [Track] { tracks(vlc.audioTrackNames, vlc.audioTrackIndexes) }
    var subtitleTracks: [Track] { tracks(vlc.videoSubTitlesNames, vlc.videoSubTitlesIndexes) }
}

private struct Surface: UIViewRepresentable {
    let player: Player
    let url: URL

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        DispatchQueue.main.async { player.start(url, in: v) }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {}
}

struct PlayerScreen: View {
    let url: URL
    let playlist: [URL]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p = Player()
    @State private var showUI = true
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Surface(player: p, url: url).ignoresSafeArea().onTapGesture { showUI.toggle() }
            if p.failed { Text("Diese Datei lässt sich nicht abspielen.").foregroundStyle(.white) }
            if showUI { controls }
        }
        .statusBarHidden(!showUI)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            p.onEnded = { step(1) }
        }
        .onChange(of: current) { p.open($0) }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            p.stop()
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 20) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                Text(current.lastPathComponent).lineLimit(1).font(.subheadline)
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { r in Button("\(r.formatted()) ×") { p.setSpeed(r) } }
                } label: { Image(systemName: "speedometer") }
                menu("Ton", "speaker.wave.2", p.audioTracks) { p.vlc.currentAudioTrackIndex = $0 }
                menu("Untertitel", "captions.bubble", p.subtitleTracks) { p.vlc.currentVideoSubTitleIndex = $0 }
            }
            .padding().background(.black.opacity(0.5))
            Spacer()
            VStack {
                Slider(value: Binding(get: { Double(p.position) }, set: { p.position = Float($0) }), in: 0...1) { editing in
                    p.scrubbing = editing
                    if !editing { p.vlc.position = p.position }
                }
                HStack {
                    Text(p.elapsed)
                    Spacer()
                    if playlist.count > 1 { Button { step(-1) } label: { Image(systemName: "backward.end.fill") } }
                    Button { p.vlc.jumpBackward(10) } label: { Image(systemName: "gobackward.10") }
                    Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.title).frame(width: 60) }
                    Button { p.vlc.jumpForward(10) } label: { Image(systemName: "goforward.10") }
                    if playlist.count > 1 { Button { step(1) } label: { Image(systemName: "forward.end.fill") } }
                    Spacer()
                    Text(p.total)
                }
            }
            .padding().background(.black.opacity(0.5))
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder private func menu(_ title: String, _ icon: String, _ tracks: [Track], pick: @escaping (Int32) -> Void) -> some View {
        if !tracks.isEmpty {
            Menu {
                ForEach(tracks) { t in Button(t.name) { pick(t.id) } }
            } label: { Image(systemName: icon) }
                .accessibilityLabel(title)
        }
    }
}

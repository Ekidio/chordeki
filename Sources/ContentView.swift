import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    @State private var dropping = false
    @State private var splash = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 232)
                Rectangle().fill(Theme.line).frame(width: 1)
                Group {
                    if let song = library.selected, song.isReady {
                        SongView(clock: session.player.clock)
                    } else if library.needsEngine {
                        EngineSetupView()
                    } else if let song = library.selected {
                        ProcessingView(song: song)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The control deck runs the full width of the window, under the song list too.
            if library.selected?.isReady == true {
                Rectangle().fill(Theme.line).frame(height: 1)
                ControlDeck(clock: session.player.clock)
                    .padding(12)
                    .background(Theme.panel.opacity(0.5))
            }
        }
        .background(Theme.bg)
        .foregroundColor(Theme.text)
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 120) }
        .overlay(dropping ? DropOverlay() : nil)
        .sheet(isPresented: $session.builderOpen) { ChordBuilderView().environmentObject(session) }
        .overlay { if splash { SplashView { splash = false } } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            loadURLs(providers) { library.add($0) }
            return true
        }
        .onChange(of: library.selectedID) { _, _ in session.open(library.selected) }
        .onChange(of: library.selected?.state) { _, _ in session.open(library.selected) }
        .onChange(of: library.selected?.playablePath) { _, _ in session.open(library.selected) }
        .onAppear {
            session.open(library.selected)
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .preferredColorScheme(.dark)
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { done(box.urls) } }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.08)))
            .overlay(Text("Drop to add songs").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.accent))
            .padding(10)
            .allowsHitTesting(false)
    }
}

struct ToastView: View {
    @ObservedObject var toast = Toast.shared
    var body: some View {
        if let m = toast.message {
            Text(m).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Theme.panel2))
                .overlay(Capsule().strokeBorder(Theme.line))
                .shadow(color: .black.opacity(0.4), radius: 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 0) {
            ChordekiLogo(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14).padding(.top, 16).padding(.bottom, 8)
            Text("CHORDS · BEATS · MIDI")
                .font(.system(size: 9.5, weight: .heavy)).tracking(3.2)
                .foregroundColor(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.songs) { song in
                        SongRow(song: song, selected: song.id == library.selectedID, progress: library.progress[song.id])
                            .onTapGesture { library.selectedID = song.id }
                            .contextMenu {
                                Button("Show in Finder") { library.revealSource(song) }
                                Button("Analyze Again") { library.reanalyze(song.id) }
                                Divider()
                                Button("Remove from List", role: .destructive) { library.remove(song.id) }
                            }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            Button { library.chooseFiles() } label: {
                HStack(spacing: 5) { Image(systemName: "plus"); Text("ADD SONG") }
                    .font(.system(size: 11, weight: .heavy))
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
            }
            .buttonStyle(.plain)
            .help("Add songs (⌘O), or drop them on the window")
            .foregroundColor(Theme.text)
            .padding(12)
        }
        .background(Theme.panel)
    }
}

struct SongRow: View {
    let song: Song
    let selected: Bool
    let progress: (Double, String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(song.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            switch song.state {
            case .ready:
                if let a = song.analysis {
                    HStack(spacing: 6) {
                        Tag(text: formatBPM(a.tempo) + " BPM", color: Theme.accent)
                        Tag(text: a.keyLabel, color: Theme.green)
                        Spacer()
                        Text(formatTime(a.duration, hundredths: false)).font(Theme.mono(10)).foregroundColor(Theme.dim)
                    }
                }
            case .queued:
                Text("Queued…").font(.system(size: 10.5)).foregroundColor(Theme.dim)
            case .analyzing:
                VStack(alignment: .leading, spacing: 4) {
                    Text(progress?.1 ?? "Analyzing…").font(.system(size: 10.5)).foregroundColor(Theme.accent).lineLimit(1)
                    BandProgress(fraction: progress?.0 ?? 0)
                }
            case .failed:
                Text(song.error ?? "Error").font(.system(size: 10.5)).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.panel2 : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.white.opacity(0.08) : .clear))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Empty and processing states

struct EmptyStateView: View {
    @EnvironmentObject var library: Library
    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 4).fill(Theme.bands[i]).frame(width: 14, height: CGFloat([46, 70, 34, 58][i]))
                }
            }
            Text("Drop songs here").font(.system(size: 22, weight: .bold))
            Text("MP3, WAV, AIFF, M4A, FLAC or WEBM. CHORDEKI finds the beats,\nthe bars, the key and the chords, and turns them into MIDI.")
                .multilineTextAlignment(.center).font(.system(size: 13)).foregroundColor(Theme.dim)
            Button("Choose Songs…") { library.chooseFiles() }
                .buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
            Text("⌘O").font(Theme.mono(10.5)).foregroundColor(Theme.dim)
        }
    }
}

struct ProcessingView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var session: Session
    let song: Song

    var body: some View {
        VStack(spacing: 16) {
            Text(song.title).font(.system(size: 20, weight: .bold))
            switch song.state {
            case .failed:
                Text(song.error ?? "The analysis failed.").font(.system(size: 12)).foregroundColor(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                Button("Try Again") { library.reanalyze(song.id) }
                    .buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
            default:
                let p = library.progress[song.id]
                Text((p?.1 ?? "Waiting for its turn").uppercased())
                    .font(.system(size: 11, weight: .heavy)).tracking(1.5).foregroundColor(Theme.accent)
                BandProgress(fraction: p?.0 ?? 0, height: 6).frame(width: 360)
                Text("Listening for beats, bars and chords. About 15 seconds a song – enjoy the music meanwhile.")
                    .font(.system(size: 11.5)).foregroundColor(Theme.dim)
            }
            if session.song?.id == song.id {
                ListenWhileWaiting(player: session.player, clock: session.player.clock)
                    .frame(maxWidth: 720)
                    .padding(.top, 18)
            }
        }
        .padding(40)
    }
}

/// While a song is analyzed: play / pause, time and the waveform with the playhead (click to jump).
private struct ListenWhileWaiting: View {
    @ObservedObject var player: ChordPlayer
    let clock: PlayClock

    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.black)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(player.isPlaying ? Theme.loop : Theme.text))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!player.canPlay)
            .modifier(DisabledDim())
            .help(player.canPlay ? "Play / pause (space)" : "Getting the audio ready…")
            VStack(alignment: .leading, spacing: 6) {
                WaitingTime(clock: clock, duration: player.duration)
                WaitingWave(peaks: player.peaks, clock: clock, duration: player.duration) { player.seek($0) }
                    .frame(height: 44)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

private struct WaitingTime: View {
    @ObservedObject var clock: PlayClock
    let duration: Double
    var body: some View {
        HStack {
            Text("LISTEN WHILE IT ANALYZES").font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(Theme.dim)
            Spacer()
            Text("\(formatTime(clock.position, hundredths: false)) / \(formatTime(duration, hundredths: false))")
                .font(Theme.mono(11, .semibold)).foregroundColor(Theme.text)
        }
    }
}

private struct WaitingWave: View {
    let peaks: [Float]
    @ObservedObject var clock: PlayClock
    let duration: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let d = max(duration, 0.001)
            let played = CGFloat(clock.position / d) * w
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    guard !peaks.isEmpty else { return }
                    let n = peaks.count
                    var past = Path(), future = Path()
                    for (i, v) in peaks.enumerated() {
                        let x = CGFloat(i) / CGFloat(n) * size.width
                        let a = CGFloat(v) * size.height / 2 * 0.95
                        let r = CGRect(x: x, y: size.height / 2 - a, width: max(0.6, size.width / CGFloat(n)), height: max(0.5, a * 2))
                        if x < played { past.addRect(r) } else { future.addRect(r) }
                    }
                    ctx.fill(future, with: .color(Theme.mix.opacity(0.35)))
                    ctx.fill(past, with: .linearGradient(Gradient(colors: Theme.bands),
                                                         startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                }
                Rectangle().fill(Color.white).frame(width: 2, height: h)
                    .shadow(color: .white.opacity(0.6), radius: 3)
                    .offset(x: played - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(max(0, min(1, v.location.x / w)) * d) })
        }
    }
}

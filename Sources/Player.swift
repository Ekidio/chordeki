import Foundation
import AVFoundation

/// The playhead position, separate so that only the views that follow it redraw 60 times a second.
final class PlayClock: ObservableObject {
    @Published var position: Double = 0
}

/// Plays the song through AVAudioEngine, with a metronome click on the beat grid.
/// The reported position is what you hear: the output latency is taken off.
@MainActor
final class ChordPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var peaks: [Float] = []
    @Published var clickOn = false { didSet { if isPlaying { restart() } } }
    /// Piano plays the chords along with the song, to check them by ear.
    @Published var pianoOn = UserDefaults.standard.object(forKey: "pianoOn") as? Bool ?? true {
        didSet {
            if !pianoOn { pianoStop() }
            UserDefaults.standard.set(pianoOn, forKey: "pianoOn")
        }
    }
    /// ORIGINAL ↔ PIANO balance: 0 = only the song, 1 = only the piano, 0.5 = both at full level.
    @Published var mix: Float = UserDefaults.standard.object(forKey: "mix") as? Float ?? 0.5 {
        didSet { applyMix(); UserDefaults.standard.set(mix, forKey: "mix") }
    }
    let clock = PlayClock()
    /// The chords for the piano: start time and MIDI notes (set by the session, transposed as shown).
    var pianoTrack: [(t: Double, notes: [UInt8])] = [] { didSet { pianoIndex = -2 } }

    var position: Double { clock.position }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let clickNode = AVAudioPlayerNode()
    private let clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var clickHigh = Self.clickBuffer(format: clickFormat, freq: 2_000)
    private lazy var clickLow = Self.clickBuffer(format: clickFormat, freq: 1_200)
    private var file: AVAudioFile?
    private var loadedPath: String?
    private var beats: [(t: Double, down: Bool)] = []
    private var startPos = 0.0
    private var timer: Timer?
    private let piano = AVAudioUnitSampler()
    private let guitar = AVAudioUnitSampler()
    /// Shifts the song's pitch, tempo kept. Only in the chain while transposed (0 = the song as it is).
    private let shifter = AVAudioUnitTimePitch()
    private var songFormat: AVAudioFormat?
    private var positionBeforeShift = 0.0

    /// The song's audio, transposed this many semitones (tempo kept).
    var audioShift = 0 {
        willSet { positionBeforeShift = currentPosition() }   // measured with the old chain's latency
        didSet {
            guard audioShift != oldValue else { return }
            let wasPlaying = isPlaying
            let pos = positionBeforeShift
            stop()
            connectSong()
            clock.position = pos
            if wasPlaying { play() }
        }
    }

    /// How late the shifted audio comes out (seconds); 0 when not shifted.
    private var shiftLatency: Double { audioShift == 0 ? 0 : max(0, shifter.latency) }

    /// The song → (pitch shifter, only when transposed) → mixer.
    private func connectSong() {
        guard let fmt = songFormat else { return }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(shifter)
        if audioShift == 0 {
            engine.connect(node, to: engine.mainMixerNode, format: fmt)
        } else {
            shifter.pitch = Float(audioShift * 100)
            shifter.rate = 1
            shifter.overlap = 32                                               // the finest (cleanest) setting
            engine.connect(node, to: shifter, format: fmt)
            engine.connect(shifter, to: engine.mainMixerNode, format: fmt)
        }
    }
    private var pianoIndex = -2
    private var sounding: [UInt8] = []
    private var soundingOn: AVAudioUnitSampler?
    private var strum: [DispatchWorkItem] = []
    private var auditionEnd: Task<Void, Never>?

    /// The instrument chords are heard on.
    enum Sound { case piano, guitar }
    /// The play-along instrument (set by the session with `pianoTrack`).
    var trackSound: Sound = .piano

    init() {
        engine.attach(node)
        engine.attach(clickNode)
        engine.attach(piano)
        engine.attach(guitar)
        engine.attach(shifter)
        engine.connect(clickNode, to: engine.mainMixerNode, format: clickFormat)
        engine.connect(piano, to: engine.mainMixerNode, format: nil)
        engine.connect(guitar, to: engine.mainMixerNode, format: nil)
        // The General MIDI piano and nylon-string acoustic guitar that come with macOS.
        let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        try? piano.loadSoundBankInstrument(at: bank, program: 0,
                                           bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        try? guitar.loadSoundBankInstrument(at: bank, program: 24,                 // Nylon-str. Gt: warm, clearly acoustic
                                            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        applyMix()
    }

    private func applyMix() {
        node.volume = min(1, 2 * (1 - mix))
        piano.volume = min(1, 2 * mix)
        guitar.volume = min(1, 2 * mix)
    }

    /// Starts a chord: at once on the piano, strummed low to high on the guitar.
    private func strike(_ notes: [UInt8], on sound: Sound, velocity: UInt8) {
        let sampler = sound == .guitar ? guitar : piano
        soundingOn = sampler
        sounding = notes
        if sound == .piano {
            for n in notes { sampler.startNote(n, withVelocity: velocity, onChannel: 0) }
            return
        }
        for (k, n) in notes.sorted().enumerated() {
            let item = DispatchWorkItem { sampler.startNote(n, withVelocity: velocity, onChannel: 0) }
            strum.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.022 * Double(k), execute: item)
        }
    }

    // MARK: Piano

    /// Plays one chord for a moment, on the piano or (strummed) on the guitar.
    func audition(_ notes: [UInt8], sound: Sound = .piano) {
        guard !notes.isEmpty else { return }
        do { if !engine.isRunning { try engine.start() } } catch { return }
        pianoStop()
        strike(notes, on: sound, velocity: 92)
        auditionEnd?.cancel()
        auditionEnd = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.pianoStop()
        }
    }

    private func pianoStop() {
        strum.forEach { $0.cancel() }
        strum = []
        for n in sounding { soundingOn?.stopNote(n, onChannel: 0) }
        sounding = []
    }

    /// While playing: change the piano chord when the song reaches the next one.
    private func pianoFollow(_ t: Double) {
        guard pianoOn, !pianoTrack.isEmpty else { return }
        var i = -1
        var lo = 0, hi = pianoTrack.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if pianoTrack[mid].t <= t + 0.005 { i = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard i != pianoIndex else { return }
        pianoIndex = i
        auditionEnd?.cancel()
        pianoStop()
        guard i >= 0 else { return }
        strike(pianoTrack[i].notes, on: trackSound, velocity: 78)
    }

    /// Loads a song's audio. It plays before the analysis is there (no beats yet); when the analysis
    /// arrives for the same audio, playback simply goes on with the beats added.
    func load(_ song: Song?) {
        guard let song else { unload(); return }
        let a = song.analysis
        beats = a?.beats.map { ($0.t, $0.pos == 0) } ?? []
        let path = song.audioURL.path
        guard path != loadedPath || file == nil else { return }
        stop()
        loadedPath = path
        peaks = []
        clock.position = 0
        do {
            let f = try AVAudioFile(forReading: song.audioURL)
            file = f
            songFormat = f.processingFormat
            connectSong()
            duration = Double(f.length) / f.processingFormat.sampleRate
        } catch {
            // Not playable (yet): e.g. a WEBM before the engine has written its WAV.
            file = nil
            loadedPath = nil
            duration = a?.duration ?? 0
            return
        }
        let url = song.audioURL
        Task.detached(priority: .userInitiated) {
            let p = Self.computePeaks(url, bins: 2400)
            await MainActor.run { if self.loadedPath == path { self.peaks = p } }
        }
    }

    private func unload() {
        stop()
        loadedPath = nil
        file = nil
        peaks = []
        duration = 0
        clock.position = 0
    }

    // MARK: Transport

    var canPlay: Bool { file != nil }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let file, !isPlaying else { return }
        if clock.position >= duration - 0.05 { clock.position = 0 }
        do { if !engine.isRunning { try engine.start() } } catch { return }
        startPos = clock.position
        let sr = file.processingFormat.sampleRate
        let from = AVAudioFramePosition(startPos * sr)
        guard from < file.length else { return }
        node.scheduleSegment(file, startingFrame: from, frameCount: AVAudioFrameCount(file.length - from), at: nil)
        if clickOn {
            let csr = clickFormat.sampleRate
            for b in beats where b.t >= startPos - 0.001 {
                // the shifted audio comes out a little later: the clicks wait for it
                let at = AVAudioTime(sampleTime: AVAudioFramePosition((b.t - startPos + shiftLatency) * csr), atRate: csr)
                clickNode.scheduleBuffer(b.down ? clickHigh : clickLow, at: at)
            }
        }
        // Both start on the same host time, so the click sits exactly on the music.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        node.play(at: start)
        clickNode.play(at: start)
        isPlaying = true
        pianoIndex = -2
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        guard isPlaying else { return }
        let p = currentPosition()
        stop()
        clock.position = p
    }

    func seek(_ t: Double) {
        let wasPlaying = isPlaying
        stop()
        clock.position = max(0, min(duration, t))
        if wasPlaying { play() }
    }

    private func restart() { seek(currentPosition()) }

    private func stop() {
        timer?.invalidate()
        timer = nil
        node.stop()
        clickNode.stop()
        isPlaying = false
        if pianoIndex != -2 { pianoStop(); pianoIndex = -2 }
    }

    private func tick() {
        // The piano starts its notes now, so it follows what is being rendered now (no latency taken off).
        pianoFollow(currentPosition(compensated: false))
        let p = currentPosition()
        if p >= duration {
            stop()
            clock.position = duration
            return
        }
        clock.position = p
    }

    /// Where the sound you hear right now is in the song.
    private func currentPosition(compensated: Bool = true) -> Double {
        guard isPlaying, let nodeTime = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nodeTime) else {
            return clock.position
        }
        let latency = (compensated ? engine.outputNode.presentationLatency : 0) + shiftLatency
        return max(startPos, startPos + Double(pt.sampleTime) / pt.sampleRate - latency)
    }

    // MARK: Sound helpers

    private static func clickBuffer(format: AVAudioFormat, freq: Double) -> AVAudioPCMBuffer {
        let n = AVAudioFrameCount(format.sampleRate * 0.03)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        buf.frameLength = n
        let d = buf.floatChannelData![0]
        for i in 0..<Int(n) {
            let t = Double(i) / format.sampleRate
            d[i] = Float(sin(2 * .pi * freq * t) * exp(-t * 180) * 0.6)
        }
        return buf
    }

    /// Peak level per bin across the file (0...1), for the overview waveform.
    nonisolated static func computePeaks(_ url: URL, bins: Int) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return [] }
        let format = f.processingFormat
        let per = max(1, Int(f.length) / bins)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(per * 64)) else { return [] }
        var out: [Float] = []
        out.reserveCapacity(bins + 1)
        var current: Float = 0
        var count = 0
        while (try? f.read(into: buf)) != nil, buf.frameLength > 0 {
            let chans = Int(format.channelCount)
            for i in 0..<Int(buf.frameLength) {
                var m: Float = 0
                for c in 0..<chans { m = max(m, abs(buf.floatChannelData![c][i])) }
                current = max(current, m)
                count += 1
                if count == per { out.append(current); current = 0; count = 0 }
            }
        }
        if count > 0 { out.append(current) }
        let top = out.max() ?? 1
        return top > 0 ? out.map { $0 / top } : out
    }
}

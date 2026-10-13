import Foundation

/// What the engine (chords.py) finds in a song.
struct Analysis: Codable, Equatable {
    struct Key: Codable, Equatable {
        var root: Int
        var mode: String          // "major" / "minor"
    }
    struct Beat: Codable, Equatable {
        var t: Double             // seconds
        var pos: Int              // place in the bar, 0 = the 1
        var root: Int?            // nil = no chord
        var base: String          // "" or "m": the plain triad
        var quality: String       // "", "m", "7", "maj7", "m7", "sus2", ...
        var conf: Double?         // 0…1: how sure the engine is of this beat's chord
        var restart: Bool?        // set by hand: the same chord is struck again here (a new chord in the grid and MIDI)
    }
    var duration: Double
    var tempo: Double
    var meter: Int
    var key: Key
    var beats: [Beat]
    /// For every bar, the other bars that are the same music (by sound).
    var barTwins: [[Int]]?

    enum CodingKeys: String, CodingKey {
        case duration, tempo, meter, key, beats
        case barTwins = "bar_twins"
    }

    /// A chord run is unsure when its weakest beat is below `unsureWeakest` or its average below `unsureAverage`
    /// (share of the evidence the engine had for it). About one chord in eight on real songs.
    static let unsureWeakest = 0.3
    static let unsureAverage = 0.45
}

/// One chord as shown: root + quality, already transposed.
struct Chord: Hashable {
    var root: Int?
    var quality: String

    static let none = Chord(root: nil, quality: "")
}

/// A run of beats holding one chord.
struct ChordSpan: Identifiable, Hashable {
    var id: Int { firstBeat }
    var chord: Chord
    var firstBeat: Int
    var lastBeat: Int
    var start: Double
    var end: Double
}

/// How chords are named on screen: transposition, simple/extended, sharps or flats.
struct ChordStyle: Equatable {
    var transpose = 0
    var simple = false

    static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flats = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    private static let flatMajorKeys: Set<Int> = [5, 10, 3, 8, 1]      // F Bb Eb Ab Db
    private static let flatMinorKeys: Set<Int> = [2, 7, 0, 5, 10, 3]   // Dm Gm Cm Fm Bbm Ebm

    func chord(_ b: Analysis.Beat) -> Chord {
        guard let r = b.root else { return .none }
        return Chord(root: (r + transpose + 120) % 12, quality: simple ? b.base : b.quality)
    }

    func usesFlats(_ key: Analysis.Key) -> Bool {
        let r = (key.root + transpose + 120) % 12
        return key.mode == "major" ? Self.flatMajorKeys.contains(r) : Self.flatMinorKeys.contains(r)
    }

    func name(_ c: Chord, key: Analysis.Key) -> String {
        guard let r = c.root else { return "N.C." }
        return (usesFlats(key) ? Self.flats : Self.sharps)[r] + c.quality
    }

    func keyName(_ key: Analysis.Key) -> String {
        let r = (key.root + transpose + 120) % 12
        return (usesFlats(key) ? Self.flats : Self.sharps)[r] + (key.mode == "major" ? "" : "m")
    }
}

extension Analysis {
    /// Runs of equal chords, as named with `style`.
    func spans(_ style: ChordStyle) -> [ChordSpan] {
        var out: [ChordSpan] = []
        for (i, b) in beats.enumerated() {
            let c = style.chord(b)
            let end = i + 1 < beats.count ? beats[i + 1].t : duration
            if var last = out.last, last.chord == c, b.restart != true {
                last.lastBeat = i
                last.end = end
                out[out.count - 1] = last
            } else {
                out.append(ChordSpan(chord: c, firstBeat: i, lastBeat: i, start: b.t, end: end))
            }
        }
        return out
    }

    /// Bars per row in the chord grid.
    static let barsPerRow = 4

    /// Where each beat sits: (bar index, place in that bar's beat list).
    var beatLocations: [(bar: Int, slot: Int)] {
        var out = [(bar: Int, slot: Int)](repeating: (0, 0), count: beats.count)
        for (bi, bar) in bars.enumerated() { for (k, b) in bar.enumerated() { out[b] = (bi, k) } }
        return out
    }

    /// The same beat in every bar that is the same music: target beat → source beat.
    func twinBeats(of range: ClosedRange<Int>) -> [Int: Int] {
        guard let twins = barTwins else { return [:] }
        let bars = self.bars
        let loc = beatLocations
        var out: [Int: Int] = [:]
        for i in range where beats.indices.contains(i) {
            let (bi, k) = loc[i]
            guard twins.indices.contains(bi) else { continue }
            for tb in twins[bi] where bars.indices.contains(tb) && bars[tb].count == bars[bi].count {
                let t = bars[tb][k]
                if !range.contains(t) { out[t] = i }
            }
        }
        return out
    }

    /// Beats that show a chord name: every chord change, and the first beat of every grid row
    /// (a chord going on into a new row is named there too). The piano strikes on these, ← / → stop on them.
    func labelBeats(_ style: ChordStyle) -> [Int] {
        var marks = Set(spans(style).map(\.firstBeat))
        for (k, bar) in bars.enumerated() where k % Self.barsPerRow == 0 {
            if let first = bar.first { marks.insert(first) }
        }
        return marks.sorted()
    }

    /// The beat playing at time `t` (-1 before the first beat).
    func beatIndex(at t: Double) -> Int {
        var lo = 0, hi = beats.count - 1
        guard hi >= 0, t >= beats[0].t else { return -1 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if beats[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Bars as lists of beat indices; the first bar may be a pickup (shorter, padded at the front).
    var bars: [[Int]] {
        var out: [[Int]] = []
        for (i, b) in beats.enumerated() {
            if b.pos == 0 || out.isEmpty { out.append([i]) } else { out[out.count - 1].append(i) }
        }
        return out
    }

    /// Bar number (1 = first full bar) and beat in bar (1-based) at time `t`.
    func barBeat(at t: Double) -> (bar: Int, beat: Int)? {
        let i = beatIndex(at: t)
        guard i >= 0 else { return nil }
        let pickup = beats.first.map { $0.pos != 0 } ?? false
        var bar = pickup ? 0 : 1
        if i > 0 { for j in 1...i where beats[j].pos == 0 { bar += 1 } }
        return (bar, beats[i].pos + 1)
    }

    var keyLabel: String { ChordStyle().keyName(key) }
}

/// A chord the user set by hand on one beat (untransposed, as the engine would name it).
struct ChordEdit: Codable, Equatable {
    var root: Int?
    var quality: String
    /// Strike the chord again on this beat, even if the one before is the same.
    var restart: Bool? = nil

    /// The plain triad of a chord type, for SIMPLE view.
    static func base(of quality: String) -> String {
        ["m", "m7", "dim", "m7b5"].contains(quality) ? "m" : ""
    }
}

/// Which notes sound for a chord: on the piano and in the MIDI export.
enum ChordNotes {
    static let intervals: [String: [Int]] = [
        "": [0, 4, 7], "m": [0, 3, 7], "7": [0, 4, 7, 10], "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10],
        "sus2": [0, 2, 7], "sus4": [0, 5, 7], "add9": [0, 2, 4, 7], "dim": [0, 3, 6], "m7b5": [0, 3, 6, 10], "aug": [0, 4, 8],
    ]
    static let qualities = ["", "m", "7", "maj7", "m7", "sus2", "sus4", "add9", "dim", "m7b5", "aug"]

    /// Chord tones with the root between F3 and E4.
    static func upper(_ c: Chord) -> [UInt8] {
        guard let r = c.root else { return [] }
        let base = 53 + (r - 5 + 12) % 12
        return (intervals[c.quality] ?? [0, 4, 7]).map { UInt8(base + $0) }
    }

    /// The root in the bass, C2…B2.
    static func bass(_ c: Chord) -> UInt8? { c.root.map { UInt8(36 + $0) } }

    static func all(_ c: Chord) -> [UInt8] { (bass(c).map { [$0] } ?? []) + upper(c) }
}

/// A song in the list.
struct Song: Codable, Identifiable, Equatable {
    enum State: String, Codable { case queued, analyzing, ready, failed }

    var id = UUID()
    var title: String
    var sourcePath: String
    /// A WAV the engine wrote when macOS cannot play the original (e.g. WEBM).
    var playablePath: String?
    var state: State = .queued
    var analysis: Analysis?
    var error: String?
    /// Hand-set chords, by beat index.
    var edits: [Int: ChordEdit]?
    /// Beats the user listened to and found right (unsure no more).
    var checked: Set<Int>?

    var isReady: Bool { state == .ready && analysis != nil }

    /// The analysis with the hand-set chords in place.
    var effective: Analysis? {
        guard var a = analysis else { return nil }
        for (i, e) in edits ?? [:] where a.beats.indices.contains(i) {
            a.beats[i].root = e.root
            a.beats[i].quality = e.quality
            a.beats[i].base = ChordEdit.base(of: e.quality)
            a.beats[i].restart = e.restart
        }
        return a
    }
    var audioURL: URL { URL(fileURLWithPath: playablePath ?? sourcePath) }
}

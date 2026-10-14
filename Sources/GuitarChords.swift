import SwiftUI

/// A guitar voicing: frets low E → high e (-1 = muted, 0 = open) and an optional barre fret.
struct Voicing: Equatable {
    var frets: [Int]
    var barre: Int?
}

enum GuitarChords {
    private static let open: [String: String] = [
        "C": "x32010", "C7": "x32310", "Cmaj7": "x32000", "Cadd9": "x32030", "Csus4": "x33011", "Csus2": "x30013",
        "D": "xx0232", "Dm": "xx0231", "D7": "xx0212", "Dmaj7": "xx0222", "Dm7": "xx0211", "Dsus2": "xx0230", "Dsus4": "xx0233",
        "E": "022100", "Em": "022000", "E7": "020100", "Emaj7": "021100", "Em7": "022030", "Esus4": "022200",
        "F": "133211", "Fmaj7": "xx3210",
        "G": "320003", "G7": "320001", "Gmaj7": "320002", "Gsus4": "330013", "Gsus2": "300233", "Gadd9": "320203",
        "A": "x02220", "Am": "x02210", "A7": "x02020", "Amaj7": "x02120", "Am7": "x02010", "Asus2": "x02200", "Asus4": "x02230",
        "B7": "x21202",
    ]
    /// Movable shapes relative to the barre fret: E-form (root on the low E), A-form (root on A).
    private static let eForm: [String: [Int]] = [
        "": [0, 2, 2, 1, 0, 0], "m": [0, 2, 2, 0, 0, 0], "7": [0, 2, 0, 1, 0, 0], "maj7": [0, -1, 1, 1, 0, -1],
        "m7": [0, 2, 0, 0, 0, 0], "sus4": [0, 2, 2, 2, 0, 0], "sus2": [0, 2, 4, 4, 0, 0], "add9": [0, 2, 2, 1, 0, 2],
        "dim": [0, 1, 2, 0, -1, -1], "aug": [0, 3, 2, 1, 1, 0],
    ]
    private static let aForm: [String: [Int]] = [
        "": [-1, 0, 2, 2, 2, 0], "m": [-1, 0, 2, 2, 1, 0], "7": [-1, 0, 2, 0, 2, 0], "maj7": [-1, 0, 2, 1, 2, 0],
        "m7": [-1, 0, 2, 0, 1, 0], "sus4": [-1, 0, 2, 2, 3, 0], "sus2": [-1, 0, 2, 2, 0, 0], "add9": [-1, 0, 2, 4, 2, 0],
        "dim": [-1, 0, 1, 2, 1, -1], "m7b5": [-1, 0, 1, 0, 1, -1], "aug": [-1, 0, 3, 2, 2, 1],
    ]

    /// The notes a guitar plays for a chord: its shape (open strings E2 A2 D3 G3 B3 E4 + frets),
    /// a hand-built chord's own notes, or the standard voicing when there is no shape.
    static func notes(_ c: Chord) -> [UInt8] {
        if let n = c.notes, !n.isEmpty { return n.sorted().map { UInt8(max(21, min(108, $0))) } }
        guard let v = voicing(c) else { return ChordNotes.all(c) }
        let open = [40, 45, 50, 55, 59, 64]
        var shape = v.frets.enumerated().compactMap { s, f in f < 0 ? nil : UInt8(open[s] + f) }
        // An inversion: its bass note at the bottom (E2…D#3), the shape's notes above it
        if let b = c.bass, b != c.root {
            let low = UInt8(40 + (b - 4 + 12) % 12)
            shape = [low] + shape.filter { $0 > low }
        }
        return shape
    }

    /// Fingerings the user picked for this song, by chord key (see `key(_:)`). Set by the session.
    nonisolated(unsafe) static var chosen: [String: [Int]] = [:]

    /// A chord's identity for remembering its fingering: root, type and bass (not how it is named).
    static func key(_ c: Chord) -> String { ChordNotes.key(c) }

    /// The fingering shown and played: the one picked for this song, or the standard shape.
    static func voicing(_ chord: Chord) -> Voicing? {
        if let f = chosen[key(chord)] { return Voicing(frets: f, barre: barreFret(f)) }
        return standardVoicing(chord)
    }

    /// The barre fret of a shape: when more than four strings are fretted, the lowest fret is held by one finger.
    static func barreFret(_ frets: [Int]) -> Int? {
        let fretted = frets.filter { $0 > 0 }
        guard fretted.count > 4, let low = fretted.min(), frets.filter({ $0 == low }).count >= 2 else { return nil }
        return low
    }

    private nonisolated(unsafe) static var cache: [String: [Voicing]] = [:]

    /// Playable fingerings of a chord, the standard shape first, then up the neck (at most 6).
    /// Playable: at most 4 frets wide, at most 4 fingers (a barre counts as one), at least 4 strings,
    /// muted strings only at the edges, the bass (root, or the slash note) lowest, and every chord
    /// tone in – only the 5th may be left out of a chord of four or more notes.
    static func voicings(_ chord: Chord) -> [Voicing] {
        guard let root = chord.root else { return [] }
        let k = key(chord)
        if let c = cache[k] { return c }
        let ivs = ChordNotes.intervals[chord.quality] ?? ChordNotes.recognizeIntervals[chord.quality] ?? [0, 4, 7]
        let tones = Set(ivs.map { (root + $0) % 12 })
        let needed = ivs.count >= 4 ? tones.subtracting([(root + 7) % 12]) : tones
        let bass = chord.bass ?? root
        let open = [40, 45, 50, 55, 59, 64]

        var found: [(frets: [Int], score: Double)] = []
        for pos in 0...12 {
            // Frets this window offers on each string: muted, open (low positions), or a chord tone
            let options: [[Int]] = open.map { o in
                var opts = [-1]
                if pos <= 3, tones.contains(o % 12) { opts.append(0) }
                for f in max(1, pos)...(max(1, pos) + 3) where tones.contains((o + f) % 12) { opts.append(f) }
                return opts
            }
            var frets = [Int](repeating: -1, count: 6)
            func walk(_ s: Int) {
                if s == 6 {
                    if let sc = score(frets, open: open, needed: needed, bass: bass, pos: pos) { found.append((frets, sc)) }
                    return
                }
                for f in options[s] { frets[s] = f; walk(s + 1) }
            }
            walk(0)
        }
        // The best per neck position, then the most different ones
        var picked: [[Int]] = []
        // The standard shape first – unless a slash chord needs another bass than its lowest note
        if let std = standardVoicing(chord), let low = std.frets.indices.first(where: { std.frets[$0] >= 0 }),
           (open[low] + std.frets[low]) % 12 == bass {
            picked.append(std.frets)
        }
        for cand in found.sorted(by: { $0.score < $1.score }) where picked.count < 6 {
            let low = cand.frets.filter { $0 > 0 }.min() ?? 0
            let clash = picked.contains { p in
                p == cand.frets || abs((p.filter { $0 > 0 }.min() ?? 0) - low) < 2
            }
            if !clash { picked.append(cand.frets) }
        }
        let out = picked.map { Voicing(frets: $0, barre: barreFret($0)) }
            .sorted { ($0.frets.filter { $0 > 0 }.min() ?? 0) < ($1.frets.filter { $0 > 0 }.min() ?? 0) }
        cache[k] = out
        return out
    }

    /// nil when not playable; lower is better.
    private static func score(_ f: [Int], open: [Int], needed: Set<Int>, bass: Int, pos: Int) -> Double? {
        let sounding = f.indices.filter { f[$0] >= 0 }
        guard sounding.count >= 4 else { return nil }
        // Mutes only at the low end, plus possibly the top string
        guard let first = sounding.first, let last = sounding.last else { return nil }
        if (first...last).contains(where: { f[$0] < 0 }) { return nil }
        if last < 4 { return nil }
        // Bass lowest, all needed tones present
        guard (open[first] + f[first]) % 12 == bass else { return nil }
        let pcs = Set(sounding.map { (open[$0] + f[$0]) % 12 })
        guard needed.isSubset(of: pcs) else { return nil }
        let fretted = f.filter { $0 > 0 }
        if let lo = fretted.min(), let hi = fretted.max(), hi - lo > 3 { return nil }
        // Fingers: one for the barre (lowest fret, when more than four strings are fretted), one per other note
        var fingers = fretted.count
        if fretted.count > 4, let lo = fretted.min() {
            fingers = fretted.filter { $0 != lo }.count + 1
            // a barre must lie flat: no open string above the barre's first string
            let from = f.firstIndex(of: lo)!
            if f[from...].contains(0) { return nil }
        }
        guard fingers <= 4 else { return nil }
        return Double(fingers) * 1.0 + Double(fretted.min() ?? 0) * 0.15 - Double(sounding.count) * 0.6
    }

    /// The standard shape: an open chord, or the nearest E- or A-form barre.
    static func standardVoicing(_ chord: Chord) -> Voicing? {
        guard let root = chord.root else { return nil }
        if let s = open[ChordStyle.sharps[root] + chord.quality] {
            let frets = s.map { $0 == "x" ? -1 : Int(String($0))! }
            return Voicing(frets: frets, barre: s == "133211" ? 1 : nil)
        }
        var options: [(shape: [Int], fret: Int)] = []
        if let s = eForm[chord.quality] { options.append((s, (root - 4 + 12) % 12)) }
        if let s = aForm[chord.quality] { options.append((s, (root - 9 + 12) % 12)) }
        guard let best = options.min(by: { $0.fret < $1.fret }) else { return nil }
        return Voicing(frets: best.shape.map { $0 < 0 ? -1 : $0 + best.fret }, barre: best.fret > 0 ? best.fret : nil)
    }
}

/// A chord box: 6 strings, 5 frets, dots, barre, open/muted marks.
struct ChordDiagram: View {
    let voicing: Voicing?
    var color: Color = Theme.text

    var body: some View {
        Canvas { ctx, size in
            guard let v = voicing else { return }
            let played = v.frets.filter { $0 > 0 }
            let maxF = played.max() ?? 0
            let start = maxF <= 4 ? 1 : (played.min() ?? 1)
            let nFrets = 5
            let left = size.width * 0.2, right = size.width * 0.06
            let top = size.height * 0.18, bottom = size.height * 0.03
            let sw = (size.width - left - right) / 5
            let fh = (size.height - top - bottom) / CGFloat(nFrets)
            let x = { (s: Int) in left + CGFloat(s) * sw }
            let dot = min(sw, fh) * 0.34

            if start == 1 {
                ctx.fill(Path(CGRect(x: x(0) - 1, y: top - 3, width: sw * 5 + 2, height: 3)), with: .color(color))
            } else {
                let label = ctx.resolve(Text("\(start)").font(Theme.mono(max(8, fh * 0.5), .bold)).foregroundColor(Theme.dim))
                ctx.draw(label, at: CGPoint(x: left - sw * 0.55, y: top + fh * 0.5), anchor: .trailing)
            }
            var grid = Path()
            for i in 0...nFrets {
                grid.move(to: CGPoint(x: x(0), y: top + CGFloat(i) * fh))
                grid.addLine(to: CGPoint(x: x(5), y: top + CGFloat(i) * fh))
            }
            for s in 0..<6 {
                grid.move(to: CGPoint(x: x(s), y: top))
                grid.addLine(to: CGPoint(x: x(s), y: top + CGFloat(nFrets) * fh))
            }
            ctx.stroke(grid, with: .color(color.opacity(0.45)), lineWidth: 1)

            if let b = v.barre {
                let strings = v.frets.indices.filter { v.frets[$0] == b }
                if let s0 = strings.first, let s1 = strings.last, s1 > s0 {
                    let cy = top + (CGFloat(b - start) + 0.5) * fh
                    let r = CGRect(x: x(s0) - dot, y: cy - dot, width: x(s1) - x(s0) + dot * 2, height: dot * 2)
                    ctx.fill(Path(roundedRect: r, cornerRadius: dot), with: .color(color))
                }
            }
            let markY = top * 0.45
            let m = top * 0.22
            for (s, f) in v.frets.enumerated() {
                if f < 0 {
                    var p = Path()
                    p.move(to: CGPoint(x: x(s) - m, y: markY - m)); p.addLine(to: CGPoint(x: x(s) + m, y: markY + m))
                    p.move(to: CGPoint(x: x(s) + m, y: markY - m)); p.addLine(to: CGPoint(x: x(s) - m, y: markY + m))
                    ctx.stroke(p, with: .color(color.opacity(0.8)), lineWidth: 1.4)
                } else if f == 0 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: x(s) - m, y: markY - m, width: m * 2, height: m * 2)),
                               with: .color(color.opacity(0.8)), lineWidth: 1.4)
                } else if f != v.barre {
                    let cy = top + (CGFloat(f - start) + 0.5) * fh
                    ctx.fill(Path(ellipseIn: CGRect(x: x(s) - dot, y: cy - dot, width: dot * 2, height: dot * 2)), with: .color(color))
                }
            }
        }
    }
}

/// A small keyboard (two octaves from C) with the chord's notes lit; a dot marks the root.
/// `paper`: drawn for print (white page, notes in grey).
struct PianoChord: View {
    let chord: Chord
    var ink: Color = Theme.text
    var paper = false

    private static let whitePCs = [0, 2, 4, 5, 7, 9, 11]
    private static let blackAfterWhite: [Int: Int] = [0: 1, 1: 3, 3: 6, 4: 8, 5: 10]   // white index in octave → black pc

    var body: some View {
        Canvas { ctx, size in
            let lit: Set<Int>
            if let r = chord.root, let notes = chord.notes ?? ChordNotes.chosenPiano[ChordNotes.key(chord)], let low = notes.min() {
                // A chord built by hand: its own voicing, from the bass up (folded into two octaves)
                let start = ((low % 12) + 12) % 12          // the lowest note where it really is
                lit = Set(notes.map { n -> Int in
                    var k = start + (n - low)
                    while k > 23 { k -= 12 }
                    return k
                })
            } else if let r = chord.root {
                var tones = Set((ChordNotes.intervals[chord.quality] ?? ChordNotes.recognizeIntervals[chord.quality] ?? [0, 4, 7]).map { r + $0 })
                if let b = chord.bass, b != r { tones.insert(b) }       // the inversion's bass key lit too
                lit = tones
            } else {
                lit = []
            }
            let root: Int? = {
                guard let r = chord.root else { return nil }
                if let notes = chord.notes ?? ChordNotes.chosenPiano[ChordNotes.key(chord)], let low = notes.min() {
                    // the root's place in the hand-built (or picked) voicing
                    let start = ((low % 12) + 12) % 12          // the lowest note where it really is
                    return notes.map { start + ($0 - low) }.map { var k = $0; while k > 23 { k -= 12 }; return k }
                        .first { ($0 % 12) == r }
                }
                return r
            }()
            let litColor = paper ? Color(white: 0.55) : Theme.chordColor(chord.root)
            let rootColor = paper ? Color(white: 0.2) : Theme.chordColor(chord.root)
            let ww = size.width / 14, wh = size.height
            let bw = ww * 0.62, bh = wh * 0.6
            let line = paper ? ink.opacity(0.6) : Color.black.opacity(0.55)

            // White keys
            for k in 0..<14 {
                let note = (k / 7) * 12 + Self.whitePCs[k % 7]
                let r = CGRect(x: CGFloat(k) * ww, y: 0, width: ww, height: wh)
                let on = lit.contains(note)
                ctx.fill(Path(roundedRect: r.insetBy(dx: 0.4, dy: 0), cornerRadius: 1.5),
                         with: .color(on ? (note == root ? rootColor : litColor) : (paper ? .white : Color(white: 0.92))))
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.4, dy: 0), cornerRadius: 1.5), with: .color(line), lineWidth: 0.6)
                if on && note == root {
                    let d = min(ww * 0.42, 5)
                    ctx.fill(Path(ellipseIn: CGRect(x: r.midX - d / 2, y: wh - d - 2.5, width: d, height: d)),
                             with: .color(paper ? .white : .black.opacity(0.75)))
                }
            }
            // Black keys
            for k in 0..<14 {
                guard let pc = Self.blackAfterWhite[k % 7] else { continue }
                let note = (k / 7) * 12 + pc
                let r = CGRect(x: CGFloat(k + 1) * ww - bw / 2, y: 0, width: bw, height: bh)
                let on = lit.contains(note)
                ctx.fill(Path(roundedRect: r, cornerRadius: 1.2),
                         with: .color(on ? (note == root ? rootColor : litColor) : (paper ? ink : Color(white: 0.08))))
                if on && note == root {
                    let d = min(bw * 0.55, 4.5)
                    ctx.fill(Path(ellipseIn: CGRect(x: r.midX - d / 2, y: bh - d - 2, width: d, height: d)),
                             with: .color(paper ? .white : .black.opacity(0.75)))
                }
            }
        }
    }
}

/// Guitar shape or piano keys, as chosen under the grid (GUITAR / PIANO).
struct ChordPicture: View {
    let chord: Chord
    var color: Color = Theme.text
    @AppStorage("diagramStyle") private var diagramStyle = "piano"

    var body: some View {
        if diagramStyle == "piano" {
            PianoChord(chord: chord, ink: color)
                .aspectRatio(14 / 5.2, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChordDiagram(voicing: GuitarChords.voicing(chord), color: color)
        }
    }
}

import Foundation

/// Writes the chords as a Standard MIDI File: a conductor track (tempo, meter, chord-name markers),
/// a piano chord track and a bass track.
enum MidiWriter {
    enum Timing { case synced, grid }

    static let ppq = 480

    /// `sections` become cue markers ("VERSE 1", "CHORUS 1"…) on their first bar.
    static func data(_ a: Analysis, style: ChordStyle, timing: Timing, sections: [SectionMark] = []) -> Data {
        let beats = a.beats
        guard !beats.isEmpty else { return Data() }
        let durations = beats.indices.map { i in (i + 1 < beats.count ? beats[i + 1].t : a.duration) - beats[i].t }
        let medianBeat = durations.sorted()[durations.count / 2]

        var conductor: [(Int, [UInt8])] = []
        var chords: [(Int, [UInt8])] = []
        var bass: [(Int, [UInt8])] = []
        let tickOfBeat: (Int) -> Int
        let endTick: Int

        switch timing {
        case .grid:
            let bpm = a.tempo.rounded()
            conductor.append((0, tempoEvent(60 / bpm)))
            let spb = 60 / bpm
            tickOfBeat = { i in Int((beats[i].t / spb * Double(ppq)).rounded()) }
            endTick = Int((a.duration / spb * Double(ppq)).rounded())
        case .synced:
            // Count-in beats before the first beat, chosen so the 1 lands on a bar line.
            let t0 = beats[0].t
            var nPick = 0
            if t0 > 0.05 {
                nPick = max(1, Int((t0 / medianBeat).rounded()))
                while nPick % a.meter != beats[0].pos % a.meter { nPick += 1 }
                conductor.append((0, tempoEvent(t0 / Double(nPick))))
            }
            for (i, d) in durations.enumerated() {
                conductor.append(((nPick + i) * ppq, tempoEvent(max(0.05, d))))
            }
            tickOfBeat = { i in (nPick + i) * ppq }
            endTick = (nPick + beats.count) * ppq
        }

        conductor.append((0, [0xFF, 0x58, 0x04, UInt8(a.meter), 2, 24, 8]))     // time signature meter/4
        conductor.append((0, meta(0x03, "CHORDEKI")))

        for span in a.spans(style) {
            guard span.chord.root != nil else { continue }
            let on = tickOfBeat(span.firstBeat)
            let off = span.lastBeat + 1 < beats.count ? tickOfBeat(span.lastBeat + 1) : endTick
            guard off > on else { continue }
            conductor.append((on, meta(0x06, style.name(span.chord, key: a.key))))
            for n in ChordNotes.upper(span.chord) {
                chords.append((on, [0x90, n, 80]))
                chords.append((off, [0x80, n, 0]))
            }
            if let b = ChordNotes.bass(span.chord) {
                bass.append((on, [0x91, b, 95]))
                bass.append((off, [0x81, b, 0]))
            }
        }

        let bars = a.bars
        let marks = sections.filter { bars.indices.contains($0.bar) }.sorted { $0.bar < $1.bar }
        for (m, title) in zip(marks, SectionKind.titles(marks)) {
            conductor.append((tickOfBeat(bars[m.bar][0]), meta(0x07, title)))      // cue point
        }

        chords.insert((0, [0xC0, 0]), at: 0)                                  // piano
        chords.insert((0, meta(0x03, "Chords")), at: 0)
        bass.insert((0, [0xC1, 33]), at: 0)                                   // fingered bass
        bass.insert((0, meta(0x03, "Bass")), at: 0)

        var out = Data("MThd".utf8)
        out += be32(6) + be16(1) + be16(3) + be16(UInt16(ppq))
        for events in [conductor, chords, bass] {
            out += track(events, endTick: endTick)
        }
        return out
    }

    // MARK: Encoding

    private static func tempoEvent(_ secondsPerBeat: Double) -> [UInt8] {
        let us = UInt32(max(1, min(0xFFFFFF, (secondsPerBeat * 1_000_000).rounded())))
        return [0xFF, 0x51, 0x03, UInt8(us >> 16 & 0xFF), UInt8(us >> 8 & 0xFF), UInt8(us & 0xFF)]
    }

    private static func meta(_ type: UInt8, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [0xFF, type] + vlq(bytes.count) + bytes
    }

    private static func track(_ events: [(Int, [UInt8])], endTick: Int) -> Data {
        // Note-offs before note-ons at the same tick; stable otherwise.
        let sorted = events.enumerated().sorted { a, b in
            if a.element.0 != b.element.0 { return a.element.0 < b.element.0 }
            let aOff = a.element.1.first.map { $0 & 0xF0 == 0x80 } ?? false
            let bOff = b.element.1.first.map { $0 & 0xF0 == 0x80 } ?? false
            if aOff != bOff { return aOff }
            return a.offset < b.offset
        }.map(\.element)
        var body: [UInt8] = []
        var last = 0
        for (tick, msg) in sorted {
            body += vlq(tick - last) + msg
            last = tick
        }
        body += vlq(max(0, endTick - last)) + [0xFF, 0x2F, 0x00]
        return Data("MTrk".utf8) + be32(UInt32(body.count)) + Data(body)
    }

    private static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }

    private static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
}

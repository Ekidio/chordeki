import SwiftUI

/// Build a chord by ear on a big piano and put it on the selected beats.
/// Click keys to add or remove notes (each one sounds); the type buttons build a chord on the lowest note.
struct ChordBuilderView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [Int] = []

    static let low = 48          // C3
    static let high = 83         // B5

    private static let types: [(String, String)] = [
        ("", "MAJ"), ("m", "MIN"), ("7", "7"), ("maj7", "MAJ7"), ("m7", "M7"), ("6", "6"), ("m6", "M6"),
        ("9", "9"), ("add9", "ADD9"), ("sus2", "SUS2"), ("sus4", "SUS4"), ("7sus4", "7SUS4"),
        ("dim", "DIM"), ("dim7", "DIM7"), ("m7b5", "M7♭5"), ("aug", "AUG"),
    ]

    var body: some View {
        let chord = ChordNotes.recognize(notes)
        let key = session.analysis?.key ?? Analysis.Key(root: 0, mode: "major")
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("BUILD A CHORD").font(.system(size: 11, weight: .heavy)).tracking(1.4).foregroundColor(Theme.accent)
                if let label = session.selectionLabel() {
                    Text("for " + label.lowercased()).font(Theme.mono(11, .semibold)).foregroundColor(Theme.dim)
                }
                Spacer()
                Text("Click keys to add or remove notes · each one sounds")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
            }

            HStack(alignment: .center, spacing: 18) {
                Text(notes.isEmpty ? "–" : session.style.name(chord, key: key))
                    .font(.system(size: 46, weight: .black).italic())
                    .foregroundColor(notes.isEmpty ? Theme.dim : Theme.chordColor(chord.root))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(minWidth: 220, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("NOTES").font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(Theme.dim)
                    Text(notes.isEmpty ? "none yet" : notes.sorted().map(Self.noteName).joined(separator: "  "))
                        .font(Theme.mono(13, .semibold)).foregroundColor(Theme.text)
                    if chord.quality == "(custom)" {
                        Text("Not a named chord – it plays exactly as built.")
                            .font(.system(size: 10.5)).foregroundColor(Theme.orange)
                    }
                }
                Spacer()
            }

            BigKeyboard(notes: notes, color: Theme.chordColor(chord.root)) { n in
                if let i = notes.firstIndex(of: n) { notes.remove(at: i) } else { notes.append(n) }
                session.playNote(n)
            }
            .frame(height: 170)

            // Chord types on the lowest note (or C4)
            VStack(alignment: .leading, spacing: 6) {
                Text("CHORD TYPE ON THE LOWEST NOTE").font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(Theme.dim)
                HStack(spacing: 4) {
                    ForEach(Self.types, id: \.0) { q, title in
                        Button(title) { applyType(q) }
                            .buttonStyle(PillButtonStyle(color: Theme.accent, small: true))
                    }
                }
                HStack(spacing: 4) {
                    Button { invert() } label: { HStack(spacing: 3) { Image(systemName: "arrow.up.and.down"); Text("INVERT") } }
                        .buttonStyle(PillButtonStyle(small: true)).disabled(notes.count < 2).modifier(DisabledDim())
                        .help("The lowest note goes up an octave")
                    Button { shift(-12) } label: { Text("OCT −") }
                        .buttonStyle(PillButtonStyle(small: true)).disabled(notes.isEmpty).modifier(DisabledDim())
                    Button { shift(12) } label: { Text("OCT +") }
                        .buttonStyle(PillButtonStyle(small: true)).disabled(notes.isEmpty).modifier(DisabledDim())
                    Button("CLEAR") { notes = [] }
                        .buttonStyle(PillButtonStyle(small: true)).disabled(notes.isEmpty).modifier(DisabledDim())
                }
            }

            HStack(spacing: 8) {
                Button { session.player.audition(notes.map { UInt8($0) }) } label: {
                    HStack(spacing: 5) { Image(systemName: "pianokeys"); Text("PLAY") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.violet, filled: true))
                .keyboardShortcut(.space, modifiers: [])
                .disabled(notes.isEmpty)
                .help("Hear the chord (space)")
                Spacer()
                Button("CANCEL") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { putIn(chord) } label: {
                    HStack(spacing: 5) { Image(systemName: "checkmark"); Text("PUT IN") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.green, filled: true))
                .keyboardShortcut(.defaultAction)
                .disabled(notes.isEmpty)
                .help("Put this chord on the selected beats (↩)")
            }
        }
        .padding(22)
        .frame(width: 920)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear { notes = Self.startNotes(session.builderStart) }
    }

    // MARK: Actions

    private func putIn(_ chord: Chord) {
        guard !notes.isEmpty else { return }
        session.setChord(chord)
        dismiss()
    }

    private func applyType(_ q: String) {
        let root = notes.min() ?? 60
        let ivs = ChordNotes.recognizeIntervals[q] ?? [0, 4, 7]
        notes = ivs.map { root + $0 }.filter { $0 <= Self.high + 12 }
        session.player.audition(notes.map { UInt8($0) })
    }

    private func invert() {
        guard let low = notes.min(), let i = notes.firstIndex(of: low) else { return }
        notes[i] = low + 12
        session.player.audition(notes.map { UInt8($0) })
    }

    private func shift(_ d: Int) {
        let moved = notes.map { $0 + d }
        guard let lo = moved.min(), let hi = moved.max(), lo >= Self.low - 12, hi <= Self.high + 12 else { return }
        notes = moved
        session.player.audition(notes.map { UInt8($0) })
    }

    /// The selection's chord as notes on the keyboard: its voicing, with a different bass note below it.
    static func startNotes(_ c: Chord) -> [Int] {
        guard c.root != nil else { return [] }
        if let n = c.notes, !n.isEmpty { return n }
        var upper = ChordNotes.upper(c).map(Int.init)
        if let b = c.bass, b != c.root, let lo = upper.min() {
            var bassNote = lo - ((lo - b) % 12 + 12) % 12
            if bassNote == lo { bassNote -= 12 }
            upper.insert(bassNote, at: 0)
        }
        return upper
    }

    static func noteName(_ n: Int) -> String {
        ChordStyle.sharps[((n % 12) + 12) % 12] + "\(n / 12 - 1)"
    }
}

/// Three octaves of piano keys (C3–B5) to click.
private struct BigKeyboard: View {
    let notes: [Int]
    let color: Color
    let toggle: (Int) -> Void

    private static let whitePCs = [0, 2, 4, 5, 7, 9, 11]

    var body: some View {
        GeometryReader { g in
            let whites = (ChordBuilderView.low...ChordBuilderView.high).filter { Self.whitePCs.contains($0 % 12) }
            let ww = g.size.width / CGFloat(whites.count)
            let bw = ww * 0.6, bh = g.size.height * 0.62
            let lowest = notes.min()
            ZStack(alignment: .topLeading) {
                ForEach(Array(whites.enumerated()), id: \.element) { k, n in
                    let on = notes.contains(n)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(on ? color : Color(white: 0.93))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.black.opacity(0.5), lineWidth: 0.8))
                        if n % 12 == 0 {
                            Text("C\(n / 12 - 1)").font(Theme.mono(9, .bold)).foregroundColor(.black.opacity(0.45)).padding(.bottom, 6)
                        }
                        if on && n == lowest {
                            Circle().fill(Color.black.opacity(0.7)).frame(width: 8, height: 8).padding(.bottom, 22)
                        }
                    }
                    .frame(width: ww - 1, height: g.size.height)
                    .offset(x: CGFloat(k) * ww)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(n) }
                }
                ForEach(Array(whites.enumerated()), id: \.element) { k, n in
                    if [0, 2, 5, 7, 9].contains(n % 12), n + 1 <= ChordBuilderView.high {
                        let b = n + 1
                        let on = notes.contains(b)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(on ? color : Color(white: 0.09))
                            .overlay(alignment: .bottom) {
                                if on && b == lowest { Circle().fill(Color.black.opacity(0.7)).frame(width: 7, height: 7).padding(.bottom, 8) }
                            }
                            .frame(width: bw, height: bh)
                            .offset(x: CGFloat(k + 1) * ww - bw / 2)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(b) }
                    }
                }
            }
        }
    }
}

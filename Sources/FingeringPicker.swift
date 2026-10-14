import SwiftUI

/// SHAPES: pick how a chord is played, for the instrument shown under the grid.
/// GUITAR: every playable fingering, from the open position up the neck.
/// PIANO: root position, every inversion and an open voicing.
/// Click one to hear it and use it in this song – the pictures, NOW / NEXT, the PDF, the sound
/// (and on the piano the MIDI chord track) follow.
struct FingeringPicker: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @AppStorage("diagramStyle") private var diagramStyle = "piano"
    let chord: Chord

    var body: some View {
        let piano = diagramStyle != "guitar"
        let key = session.analysis?.key ?? Analysis.Key(root: 0, mode: "major")
        let name = session.style.name(chord, key: key)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(piano ? "PIANO VOICINGS" : "GUITAR FINGERINGS").font(.system(size: 11, weight: .heavy)).tracking(1.4).foregroundColor(Theme.accent)
                Text(name).font(.system(size: 30, weight: .black).italic()).foregroundColor(Theme.chordColor(chord.root))
                Spacer()
                Text("Click one to hear it and use it in this song")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
            }
            if piano { pianoGrid } else { guitarGrid }
            HStack {
                Button(piano ? "STANDARD VOICING" : "STANDARD SHAPE") {
                    piano ? session.choosePianoVoicing(chord, nil) : session.chooseFingering(chord, nil)
                }
                .buttonStyle(PillButtonStyle())
                .help("Back to the usual one")
                Spacer()
                Button("DONE") { dismiss() }
                    .buttonStyle(PillButtonStyle(color: Theme.green, filled: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: piano ? 760 : 640)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: Guitar

    @ViewBuilder private var guitarGrid: some View {
        let shapes = GuitarChords.voicings(chord)
        let current = GuitarChords.voicing(chord)
        if shapes.isEmpty {
            Text("No guitar shape found for this chord.").font(.system(size: 12)).foregroundColor(Theme.orange)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(shapes.indices, id: \.self) { i in
                    let v = shapes[i]
                    let on = current?.frets == v.frets
                    card(on: on, label: Self.position(v), detail: v.frets.map { $0 < 0 ? "x" : String($0) }.joined(separator: " ")) {
                        ChordDiagram(voicing: v, color: on ? .black : Theme.text).frame(width: 120, height: 146)
                    }
                    .onTapGesture { session.chooseFingering(chord, v.frets) }
                }
            }
        }
    }

    /// "OPEN" or "FRET 7": where on the neck the shape sits.
    static func position(_ v: Voicing) -> String {
        let fretted = v.frets.filter { $0 > 0 }
        guard let low = fretted.min() else { return "OPEN" }
        return (v.frets.contains(0) && low <= 3) || (fretted.max() ?? 0) <= 4 ? "OPEN" : "FRET \(low)"
    }

    // MARK: Piano

    @ViewBuilder private var pianoGrid: some View {
        let voicings = ChordNotes.pianoVoicings(chord)
        let current = ChordNotes.upper(chord).map(Int.init)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(voicings.indices, id: \.self) { i in
                let v = voicings[i]
                let on = current == v.notes.sorted()
                card(on: on, label: v.label, detail: v.notes.sorted().map(ChordBuilderView.noteName).joined(separator: " ")) {
                    PianoChord(chord: Chord(root: chord.root, quality: chord.quality, bass: chord.bass, notes: v.notes),
                               ink: on ? .black : Theme.text)
                        .frame(width: 200, height: 74)
                }
                .onTapGesture { session.choosePianoVoicing(chord, v.notes) }
            }
        }
    }

    // MARK: Card

    private func card<Picture: View>(on: Bool, label: String, detail: String, @ViewBuilder picture: () -> Picture) -> some View {
        VStack(spacing: 8) {
            picture()
            Text(label).font(.system(size: 11, weight: .heavy)).tracking(1)
                .foregroundColor(on ? .black : Theme.dim)
            Text(detail).font(Theme.mono(10.5, .semibold)).foregroundColor(on ? .black.opacity(0.7) : Theme.dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Theme.loop : Theme.panel2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? .clear : Theme.line))
        .contentShape(Rectangle())
        .help("Hear it and use it in this song")
    }
}

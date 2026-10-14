import SwiftUI

/// Build a chord by ear on a big piano and put it on the selected beats.
/// It starts empty: click the notes one by one; after every click all the notes so far sound together.
struct ChordBuilderView: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var notes: [Int] = []

    static let low = 48          // C3
    static let high = 83         // B5

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
                Text("Click the notes one by one · all of them sound together · click again to take one out")
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
                if !notes.isEmpty { session.playNotes(notes) }            // the whole chord so far
            }
            .frame(height: 170)

            HStack(spacing: 8) {
                Button("CLEAR") { notes = [] }
                    .buttonStyle(PillButtonStyle())
                    .disabled(notes.isEmpty).modifier(DisabledDim())
                Button { session.playNotes(notes) } label: {
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
        .onAppear { notes = [] }
    }

    // MARK: Actions

    private func putIn(_ chord: Chord) {
        guard !notes.isEmpty else { return }
        session.setChord(chord)
        dismiss()
    }

    static func noteName(_ n: Int) -> String {
        ChordStyle.sharps[((n % 12) + 12) % 12] + "\(n / 12 - 1)"
    }
}

/// Three octaves of piano keys (C3–B5) to click.
/// The keys are only drawn; one tap area over the whole keyboard works out which key was hit
/// (black keys first, they sit on top).
private struct BigKeyboard: View {
    let notes: [Int]
    let color: Color
    let toggle: (Int) -> Void

    private static let whitePCs = [0, 2, 4, 5, 7, 9, 11]
    private static var whites: [Int] {
        (ChordBuilderView.low...ChordBuilderView.high).filter { whitePCs.contains($0 % 12) }
    }

    var body: some View {
        GeometryReader { g in
            let whites = Self.whites
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
                    }
                }
            }
            .allowsHitTesting(false)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        if let n = Self.key(at: tap.location, ww: ww, bw: bw, bh: bh, whites: whites) { toggle(n) }
                    })
            }
        }
    }

    /// The key under a point: a black key if the point is on one, otherwise the white key below it.
    static func key(at p: CGPoint, ww: CGFloat, bw: CGFloat, bh: CGFloat, whites: [Int]) -> Int? {
        let k = Int(p.x / ww)
        guard whites.indices.contains(k) else { return nil }
        if p.y <= bh {
            // the black key right of this white key, or left of it
            let n = whites[k]
            let rightEdge = CGFloat(k + 1) * ww
            if [0, 2, 5, 7, 9].contains(n % 12), n + 1 <= ChordBuilderView.high, p.x >= rightEdge - bw / 2 { return n + 1 }
            if k > 0 {
                let prev = whites[k - 1]
                let leftEdge = CGFloat(k) * ww
                if [0, 2, 5, 7, 9].contains(prev % 12), p.x <= leftEdge + bw / 2 { return prev + 1 }
            }
        }
        return whites[k]
    }
}

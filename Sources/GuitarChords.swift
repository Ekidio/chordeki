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

    static func voicing(_ chord: Chord) -> Voicing? {
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

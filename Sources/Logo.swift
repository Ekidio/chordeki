import SwiftUI

/// The CHORDEKI logo: "CHORD" in bold italic and the skewed EKI badge of the family,
/// its four colour bands carrying little piano keys.
struct ChordekiLogo: View {
    var height: CGFloat = 30

    var body: some View {
        Canvas { ctx, size in
            ChordekiLogo.draw(ctx, CGRect(origin: .zero, size: size))
        }
        .frame(width: height * 4.1, height: height)
    }

    /// Draws the logo into `rect` (aspect ~4.1 : 1).
    static func draw(_ ctx: GraphicsContext, _ rect: CGRect) {
        let h = rect.height
        let skew = CGAffineTransform(a: 1, b: 0, c: -0.25, d: 1, tx: 0, ty: 0)
        let word = ctx.resolve(Text("CHORD").font(.system(size: h * 0.92, weight: .black).italic()).foregroundColor(.white))
        let wordW = word.measure(in: CGSize(width: 10_000, height: 10_000)).width
        let gap = h * 0.16
        let bw = h * 1.62, bh = h * 0.86
        let total = wordW + gap + bw + bh * 0.25 + h * 0.1
        let k = min(1, rect.width / total)
        var g = ctx
        g.translateBy(x: rect.minX, y: rect.midY)
        g.scaleBy(x: k, y: k)

        g.draw(word, at: CGPoint(x: 0, y: h * 0.02), anchor: .leading)

        let bx = wordW + gap, by = -bh / 2
        g.drawLayer { g in
            var sh = g
            sh.translateBy(x: bx + bh / 2 * 0.25 + h * 0.07, y: by + h * 0.07)
            sh.concatenate(skew)
            sh.fill(Path(CGRect(x: 0, y: 0, width: bw, height: bh)), with: .color(.white))
            for i in 0..<4 {
                var b = g
                b.translateBy(x: bx + bh / 2 * 0.25, y: by + CGFloat(i) * bh / 4)
                b.concatenate(skew)
                let band = CGRect(x: 0, y: 0, width: bw, height: bh / 4 + 0.4)
                b.fill(Path(band), with: .color(Theme.bands[i]))
                b.clip(to: Path(band))
                // Piano keys: black keys in the 2 + 3 pattern of an octave
                let keyW = bw / 14
                var keys = Path()
                for j in 0..<14 where [0, 1, 3, 4, 5].contains(j % 7) {
                    keys.addRect(CGRect(x: (CGFloat(j) + 0.68) * keyW, y: 0, width: keyW * 0.6, height: bh / 4 * 0.62))
                }
                b.fill(keys, with: .color(.black.opacity(0.22)))
            }
            var e = g
            e.blendMode = .destinationOut
            e.translateBy(x: bx + bw / 2 + h * 0.06, y: h * 0.02)
            e.draw(Text("EKI").font(.system(size: h * 0.8, weight: .black).italic()).foregroundColor(.white), at: .zero, anchor: .center)
        }
    }
}

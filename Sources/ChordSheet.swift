import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A printable chord sheet (PDF, A4): title and facts, every guitar shape, then the bars in rows of four,
/// exactly as the grid shows them (SIMPLE / EXTENDED, transposed, with the hand fixes).
enum ChordSheet {
    static let page = CGSize(width: 595, height: 842)       // A4 in points
    static let margin: CGFloat = 36
    static let rowHeight: CGFloat = 46
    static let sectionHeader: CGFloat = 18
    /// Title, facts and every chord picture (10 a row).
    static func firstPageHeader(chords: Int, piano: Bool) -> CGFloat {
        let rows = max(1, (chords + 9) / 10)
        return 78 + CGFloat(rows) * (piano ? 50 : 70)
    }
    static let otherPageHeader: CGFloat = 40

    @MainActor
    static func export(song: Song, analysis a: Analysis, style: ChordStyle, sections: [SectionMark]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let t = style.transpose == 0 ? "" : String(format: " (%+d)", style.transpose)
        panel.nameFieldStringValue = "\(song.title) - chord sheet\(t).pdf"
        panel.directoryURL = URL(fileURLWithPath: song.sourcePath).deletingLastPathComponent()
        panel.message = "A printable chord sheet: guitar shapes and the bars, as shown in CHORDEKI."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(to: url, title: song.title, analysis: a, style: style, sections: sections)
            Toast.shared.show("PDF saved: \(url.lastPathComponent)")
            NSWorkspace.shared.open(url)
        } catch {
            Toast.shared.show("Could not save: \(error.localizedDescription)")
        }
    }

    @MainActor
    static func write(to url: URL, title: String, analysis a: Analysis, style: ChordStyle, sections: [SectionMark]) throws {
        let bars = a.bars
        let rows = a.gridRows(sections)
        let titles = SectionKind.titles(sections.filter { bars.indices.contains($0.bar) })
        let piano = UserDefaults.standard.string(forKey: "diagramStyle") == "piano"
        // Fill pages row by row; a row that starts a section is taller (its title).
        let usable = page.height - 2 * margin - 24             // footer
        var pages: [[GridRow]] = [[]]
        let headerHeight = firstPageHeader(chords: songChords(a, style).count, piano: piano)
        var room = usable - headerHeight
        for row in rows {
            let h = rowHeight + (row.sectionStart ? sectionHeader : 0)
            if h > room {
                pages.append([])
                room = usable - otherPageHeader
            }
            pages[pages.count - 1].append(row)
            room -= h
        }

        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: title,
                                                                  kCGPDFContextCreator as String: "CHORDEKI"] as CFDictionary)
        else { throw EngineError("Could not create the PDF file.") }
        let chords = a.beats.map { style.chord($0) }
        let pickup = (a.beats.first?.pos ?? 0) != 0
        for (p, rowsOnPage) in pages.enumerated() {
            let view = SheetPage(title: title, analysis: a, style: style, chords: chords, bars: bars, pickup: pickup,
                                 rows: rowsOnPage, titles: titles, piano: piano, headerHeight: headerHeight,
                                 first: p == 0, pageNumber: p + 1, pageCount: pages.count)
                .frame(width: page.width, height: page.height)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(page)
            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

private struct SheetPage: View {
    let title: String
    let analysis: Analysis
    let style: ChordStyle
    let chords: [Chord]
    let bars: [[Int]]
    let pickup: Bool
    let rows: [GridRow]
    let titles: [String]
    let piano: Bool
    let headerHeight: CGFloat
    let first: Bool
    let pageNumber: Int
    let pageCount: Int

    private let ink = Color(white: 0.08)
    private let soft = Color(white: 0.45)
    private let rule = Color(white: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if first { header } else {
                Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(soft)
                    .frame(height: ChordSheet.otherPageHeader, alignment: .topLeading)
            }
            ForEach(rows.indices, id: \.self) { r in
                if rows[r].sectionStart, let k = rows[r].section, titles.indices.contains(k) {
                    Text(titles[k]).font(.system(size: 9, weight: .heavy)).tracking(1.2)
                        .foregroundColor(Theme.sectionColor(String(titles[k].split(separator: " ").first ?? "")).opacity(0.95))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12)))
                        .frame(height: ChordSheet.sectionHeader, alignment: .bottomLeading)
                }
                row(rows[r].bars)
            }
            Spacer(minLength: 0)
            HStack {
                Text("CHORDEKI").font(.system(size: 8, weight: .black).italic()).foregroundColor(soft)
                Text("· chords · beats · midi").font(.system(size: 8)).foregroundColor(soft)
                Spacer()
                Text("\(pageNumber) / \(pageCount)").font(.system(size: 8, design: .monospaced)).foregroundColor(soft)
            }
        }
        .padding(ChordSheet.margin)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .heavy)).foregroundColor(ink).lineLimit(2)
            HStack(spacing: 14) {
                fact("KEY", style.keyName(analysis.key))
                fact("BPM", formatBPM(analysis.tempo))
                fact("METER", "\(analysis.meter)/4")
                fact("BARS", "\(analysis.bars.count)")
                if style.transpose != 0 { fact("TRANSPOSED", String(format: "%+d", style.transpose)) }
                fact("CHORDS", style.simple ? "simple" : "extended")
            }
            let used = songChords(analysis, style)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 7), count: 10), alignment: .leading, spacing: 4) {
                ForEach(used, id: \.self) { c in
                    VStack(spacing: 1) {
                        Text(style.name(c, key: analysis.key)).font(.system(size: 9, weight: .heavy)).foregroundColor(ink)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if piano {
                            PianoChord(chord: c, ink: ink, paper: true).frame(width: 46, height: 30).padding(.vertical, 9)
                        } else {
                            ChordDiagram(voicing: GuitarChords.voicing(c), color: ink).frame(width: 40, height: 48)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .frame(height: headerHeight, alignment: .topLeading)
        .clipped()
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 7.5, weight: .heavy)).foregroundColor(soft)
            Text(value).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(ink)
        }
    }

    private func row(_ barIndices: [Int]) -> some View {
        HStack(spacing: 0) {
            ForEach(barIndices, id: \.self) { bi in bar(bi, rowStart: bi == barIndices.first) }
            if barIndices.count < Analysis.barsPerRow {
                ForEach(0..<(Analysis.barsPerRow - barIndices.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
            Rectangle().fill(ink).frame(width: 1, height: 26).offset(y: 6)
        }
        .frame(height: ChordSheet.rowHeight)
    }

    private func bar(_ bi: Int, rowStart: Bool) -> some View {
        let beats = bars[bi]
        let padding = max(0, analysis.meter - beats.count)
        let number = bi + (pickup ? 0 : 1)
        return VStack(alignment: .leading, spacing: 2) {
            Text(number == 0 ? "pickup" : "\(number)").font(.system(size: 7, design: .monospaced)).foregroundColor(soft)
                .padding(.leading, 3)
            HStack(spacing: 0) {
                Rectangle().fill(ink).frame(width: 1, height: 26)
                ForEach(0..<padding, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 26) }
                ForEach(Array(beats.enumerated()), id: \.element) { j, b in
                    let c = chords[b]
                    let changed = b == 0 || chords[b - 1] != c || analysis.beats[b].restart == true
                    let show = changed || (rowStart && j == 0)
                    ZStack(alignment: .leading) {
                        if show {
                            Text(style.name(c, key: analysis.key))
                                .font(.system(size: style.name(c, key: analysis.key).count > 4 ? 10 : 12.5, weight: .bold))
                                .foregroundColor(c.root == nil ? soft : ink)
                                .fixedSize()
                                .padding(.leading, 4)
                                .frame(width: 0, alignment: .leading)
                        } else {
                            Text("·").font(.system(size: 11)).foregroundColor(rule).padding(.leading, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 26, alignment: .leading)
                    .zIndex(show ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

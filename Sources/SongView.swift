import SwiftUI
import AppKit

struct SongView: View {
    @EnvironmentObject var session: Session
    let clock: PlayClock     // not observed here: only the playhead follows it

    var body: some View {
        if let a = session.analysis {
            let spans = a.spans(session.style)
            VStack(spacing: 0) {
                HeaderBar(analysis: a)
                OverviewStrip(analysis: a, spans: spans, peaks: session.player.peaks, clock: clock)
                    .frame(height: 46)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                HStack(alignment: .top, spacing: 12) {
                    NowPanel(analysis: a, spans: spans)
                        .frame(width: 290)
                    VStack(spacing: 10) {
                        ChordGrid(analysis: a)
                        DiagramStrip(analysis: a, spans: spans)
                            .frame(height: 128)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var session: Session
    let analysis: Analysis

    var body: some View {
        let style = session.style
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.song?.title ?? "").font(.system(size: 19, weight: .bold)).lineLimit(1)
                HStack(spacing: 10) {
                    Stat(label: "BPM", value: formatBPM(analysis.tempo), color: Theme.accent)
                    Stat(label: "KEY", value: style.keyName(analysis.key), color: Theme.green)
                    Stat(label: "METER", value: "\(analysis.meter)/4", color: Theme.violet)
                    Stat(label: "BARS", value: "\(analysis.bars.count)", color: Theme.dim)
                    Stat(label: "CHORDS", value: "\(Set(analysis.spans(style).compactMap { $0.chord.root == nil ? nil : $0.chord }).count)", color: Theme.dim)
                    Stat(label: "TIME", value: formatTime(analysis.duration, hundredths: false), color: Theme.dim)
                    if style.transpose != 0 {
                        Stat(label: "TRANSPOSED", value: String(format: "%+d", style.transpose), color: Theme.loop)
                    }
                }
            }
            Spacer()
            ModeSwitch()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

/// SIMPLE / EXTENDED, in the style of STEMEKI's EDIT / EXPORT switch.
struct ModeSwitch: View {
    @EnvironmentObject var session: Session

    var body: some View {
        HStack(spacing: 2) {
            side("SIMPLE", icon: "circle.grid.2x1", on: session.style.simple) { session.style.simple = true }
                .help("Plain major and minor chords")
            side("EXTENDED", icon: "circle.grid.3x3", on: !session.style.simple) { session.style.simple = false }
                .help("7ths, maj7, sus, add9, dim…")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func side(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon); Text(title) }
                .font(.system(size: 12, weight: .heavy)).tracking(1)
                .foregroundColor(on ? .white : Theme.dim)
                .padding(.horizontal, 16).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.active : .clear))
                .shadow(color: on ? Theme.active.opacity(0.55) : .clear, radius: 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overview

/// The whole song: chord ribbon, waveform, bar ticks and the playhead. Click or drag to seek.
struct OverviewStrip: View {
    @EnvironmentObject var session: Session
    let analysis: Analysis
    let spans: [ChordSpan]
    let peaks: [Float]
    let clock: PlayClock

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let d = max(analysis.duration, 0.001)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Chord ribbon along the bottom
                    for s in spans where s.chord.root != nil {
                        let r = CGRect(x: s.start / d * w, y: h - 7, width: max(1, (s.end - s.start) / d * w - 1), height: 7)
                        ctx.fill(Path(r), with: .color(Theme.chordColor(s.chord.root).opacity(0.9)))
                    }
                    // Waveform
                    if !peaks.isEmpty {
                        var p = Path()
                        let mid = (h - 9) / 2
                        let n = peaks.count
                        for (i, v) in peaks.enumerated() {
                            let x = CGFloat(i) / CGFloat(n) * w
                            let a = CGFloat(v) * mid * 0.95
                            p.addRect(CGRect(x: x, y: mid - a, width: max(0.6, w / CGFloat(n)), height: max(0.5, a * 2)))
                        }
                        ctx.fill(p, with: .color(Theme.mix.opacity(0.55)))
                    }
                }
                // Unsure chords: little orange flags above the ribbon
                Canvas { ctx, size in
                    for sp in session.unsureSpans {
                        let x = sp.start / d * size.width
                        ctx.fill(Path(CGRect(x: x, y: size.height - 12, width: max(2, (sp.end - sp.start) / d * size.width), height: 3)),
                                 with: .color(Theme.orange))
                    }
                }
                .allowsHitTesting(false)
                PlayheadLine(clock: clock, duration: d, height: h)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                session.seek(max(0, min(1, v.location.x / w)) * d)
            })
        }
    }
}

extension Theme {
    static let mix = Color(red: 0.74, green: 0.78, blue: 0.92)
}

private struct PlayheadLine: View {
    @ObservedObject var clock: PlayClock
    let duration: Double
    let height: CGFloat
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(Color.white)
                .frame(width: 2, height: height)
                .shadow(color: .white.opacity(0.6), radius: 3)
                .offset(x: CGFloat(clock.position / duration) * g.size.width - 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Now playing

struct NowPanel: View {
    @EnvironmentObject var session: Session
    let analysis: Analysis
    let spans: [ChordSpan]

    var body: some View {
        let i = session.currentBeat
        let idx = spans.lastIndex { $0.firstBeat <= max(i, 0) } ?? 0
        let cur: ChordSpan? = i >= 0 ? spans[safe: idx] : nil
        // The next real chord (gaps without a chord are skipped).
        let next: ChordSpan? = spans[(i >= 0 ? idx + 1 : 0)...].first { $0.chord.root != nil && $0.firstBeat > i }
        let style = session.style
        VStack(alignment: .leading, spacing: 14) {
            let curChord = cur?.chord ?? .none
            HStack {
                Text("NOW").font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(Theme.accent)
                Spacer()
                Button { session.hear(curChord) } label: {
                    HStack(spacing: 4) { Image(systemName: "pianokeys"); Text("HEAR") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.accent, small: true))
                .disabled(curChord.root == nil)
                .modifier(DisabledDim())
                .help("Play this chord on the piano (P)")
            }
            HStack(alignment: .center, spacing: 14) {
                Text(cur == nil ? "–" : style.name(curChord, key: analysis.key))
                    .font(.system(size: 52, weight: .black).italic())
                    .foregroundColor(cur == nil ? Theme.dim : Theme.chordColor(curChord.root))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ChordDiagram(voicing: GuitarChords.voicing(curChord))
                    .frame(width: 92, height: 112)
                    .contentShape(Rectangle())
                    .onTapGesture { session.hear(curChord) }
            }
            BeatDots(analysis: analysis, beat: i)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT").font(.system(size: 9.5, weight: .heavy)).tracking(1.2).foregroundColor(Theme.dim)
                    Text(next.map { style.name($0.chord, key: analysis.key) } ?? "–")
                        .font(.system(size: 28, weight: .heavy).italic())
                        .foregroundColor(next.map { Theme.chordColor($0.chord.root) } ?? Theme.dim)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    if let next, i >= 0 {
                        let beatsAway = next.firstBeat - i
                        Text("in \(beatsAway) beat\(beatsAway == 1 ? "" : "s")")
                            .font(Theme.mono(10.5)).foregroundColor(Theme.dim)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ChordDiagram(voicing: next.flatMap { GuitarChords.voicing($0.chord) }, color: Theme.dim)
                    .frame(width: 62, height: 76)
                    .contentShape(Rectangle())
                    .onTapGesture { if let next { session.hear(next.chord) } }
                    .help("Hear it on the piano")
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

/// The beats of the current bar; the one playing lights up, the 1 in yellow.
struct BeatDots: View {
    let analysis: Analysis
    let beat: Int
    var body: some View {
        let pos = beat >= 0 ? analysis.beats[beat].pos : -1
        HStack(spacing: 8) {
            ForEach(0..<analysis.meter, id: \.self) { k in
                let on = k == pos
                RoundedRectangle(cornerRadius: 3)
                    .fill(on ? (k == 0 ? Theme.loop : Theme.accent) : Theme.panel2)
                    .frame(height: 10)
                    .shadow(color: on ? (k == 0 ? Theme.loop : Theme.accent).opacity(0.7) : .clear, radius: 6)
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Chord grid

/// Bars in rows of four, a cell per beat; the chord name where it changes. Click a cell to jump there.
struct ChordGrid: View {
    @EnvironmentObject var session: Session
    let analysis: Analysis

    private let barsPerRow = Analysis.barsPerRow

    var body: some View {
        let bars = analysis.bars
        let rows = stride(from: 0, to: bars.count, by: barsPerRow).map { Array(bars[$0..<min($0 + barsPerRow, bars.count)]) }
        let pickup = (analysis.beats.first?.pos ?? 0) != 0
        let current = session.currentBeat
        let currentRow = rows.firstIndex { $0.contains { $0.contains(current) } } ?? 0
        let style = session.style
        let chords = analysis.beats.map { style.chord($0) }
        let unsure = unsureMap(session.unsureSpans)
        let twins = session.twinsOfSelection

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 6) {
                            ForEach(rows[r].indices, id: \.self) { k in
                                let barIndex = r * barsPerRow + k
                                BarView(number: barIndex + (pickup ? 0 : 1), beats: rows[r][k], meter: analysis.meter,
                                        chords: chords, analysis: analysis, current: current, rowStart: k == 0,
                                        unsure: unsure, twins: twins)
                            }
                            if rows[r].count < barsPerRow {
                                ForEach(0..<(barsPerRow - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                            }
                        }
                        .id(r)
                    }
                }
                .padding(10)
            }
            .onChange(of: currentRow) { _, row in
                guard session.follow, session.player.isPlaying else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(row, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .overlay(alignment: .bottom) { OfferBar().padding(10) }
    }
}

/// Beat → is it the first beat of its unsure run (beats of sure chords are missing).
private func unsureMap(_ spans: [ChordSpan]) -> [Int: Bool] {
    var out: [Int: Bool] = [:]
    for sp in spans { for b in sp.firstBeat...sp.lastBeat { out[b] = b == sp.firstBeat } }
    return out
}

/// After a fix: "the same music in 3 more places — apply there?"
private struct OfferBar: View {
    @EnvironmentObject var session: Session
    var body: some View {
        if let o = session.offer {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square").foregroundColor(Theme.violet)
                Text("\(o.chordName) · the same music is in \(o.places) more bar\(o.places == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .semibold))
                Button("APPLY THERE  (A)") { session.applyOffer() }
                    .buttonStyle(PillButtonStyle(color: Theme.violet, filled: true, small: true))
                Button { session.dismissOffer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PillButtonStyle(small: true))
                    .help("No thanks")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.panel2))
            .overlay(Capsule().strokeBorder(Theme.violet.opacity(0.6)))
            .shadow(color: .black.opacity(0.5), radius: 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct BarView: View {
    @EnvironmentObject var session: Session
    let number: Int
    let beats: [Int]
    let meter: Int
    let chords: [Chord]
    let analysis: Analysis
    let current: Int
    let rowStart: Bool
    let unsure: [Int: Bool]
    let twins: Set<Int>

    var body: some View {
        let padding = max(0, meter - beats.count)       // a pickup bar is padded at the front
        VStack(alignment: .leading, spacing: 3) {
            Text(number == 0 ? "PICKUP" : "\(number)")
                .font(Theme.mono(9, .semibold)).foregroundColor(Theme.dim.opacity(0.8))
                .padding(.leading, 2)
            HStack(spacing: 2) {
                ForEach(0..<padding, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 5).fill(Theme.bg.opacity(0.5)).frame(height: 46)
                }
                ForEach(Array(beats.enumerated()), id: \.element) { j, b in
                    let c = chords[b]
                    let changed = b == 0 || chords[b - 1] != c || analysis.beats[b].restart == true
                    let showName = changed || (rowStart && j == 0)
                    BeatCell(name: showName ? session.style.name(c, key: analysis.key) : nil,
                             dimName: false, color: Theme.chordColor(c.root), on: b == current,
                             selected: session.selection?.contains(b) == true, edited: session.isEdited(b),
                             unsure: unsure[b], twin: twins.contains(b))
                        .onTapGesture { session.click(beat: b, extend: NSEvent.modifierFlags.contains(.shift)) }
                        .contextMenu { ChordMenu(beat: b) }
                        .zIndex(showName ? 1 : 0)   // a long name stays above the next beat, even when it lights up
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BeatCell: View {
    let name: String?
    let dimName: Bool
    let color: Color
    let on: Bool
    let selected: Bool
    let edited: Bool
    /// nil: sure; false: inside an unsure run; true: the first beat of one (gets the "?").
    var unsure: Bool? = nil
    var twin = false

    var body: some View {
        // The name is an overlay, so it never widens its cell; a long name runs into the next (empty) beat.
        RoundedRectangle(cornerRadius: 5)
            .fill(on ? Theme.loop : (selected ? Theme.accent.opacity(0.16) : Theme.panel2))
            .shadow(color: on ? Theme.loop.opacity(0.6) : .clear, radius: 8)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5))
            .overlay {
                if !selected, unsure != nil {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.orange.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                } else if !selected, twin {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.violet.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if unsure == true {
                    Text("?").font(.system(size: 10, weight: .black)).foregroundColor(.black)
                        .frame(width: 14, height: 14).background(Circle().fill(Theme.orange)).padding(4)
                        .help("The engine is not sure of this chord. Listen (P), fix it, or O if it sounds right.")
                }
            }
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if name != nil && !dimName {
                    Rectangle().fill(color).frame(width: 3).padding(.vertical, 6).padding(.leading, 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if edited {
                    Circle().fill(Theme.violet).frame(width: 6, height: 6).padding(5)
                        .help("Set by hand (ORIGINAL puts back what was detected)")
                }
            }
            .overlay(alignment: .leading) {
                if let name {
                    Text(name)
                        .font(.system(size: name.count > 4 ? 13.5 : 17, weight: dimName ? .semibold : .heavy))
                        .foregroundColor(on ? .black : (dimName ? Theme.dim : Theme.text))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 10)
                        .frame(width: 0, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Right-click menu of a beat: hear it, copy / paste, pick a chord, undo the fix.
struct ChordMenu: View {
    @EnvironmentObject var session: Session
    let beat: Int

    var body: some View {
        if let a = session.analysis {
            let style = session.style
            let shown = style.chord(a.beats[beat])
            let used = songChords(a, style)
            Button("Hear \(style.name(shown, key: a.key)) on Piano  (P)") { session.hear(shown) }
            Divider()
            Button("Copy  (⌘C)") { session.ensureSelected(beat); session.copy() }
            Button(session.clipboard.count > 1 ? "Paste \(session.clipboard.count) Beats  (⌘V)" : "Paste  (⌘V)") {
                session.ensureSelected(beat); session.paste()
            }
            .disabled(session.clipboard.isEmpty)
            Divider()
            Menu("Chords of This Song") {
                ForEach(used, id: \.self) { c in
                    Button(style.name(c, key: a.key)) { session.ensureSelected(beat); session.setChord(c) }
                }
            }
            Menu("Any Chord") {
                ForEach(0..<12, id: \.self) { r in
                    Menu(style.name(Chord(root: r, quality: ""), key: a.key)) {
                        ForEach(ChordNotes.qualities, id: \.self) { q in
                            let c = Chord(root: r, quality: q)
                            Button(style.name(c, key: a.key)) { session.ensureSelected(beat); session.setChord(c) }
                        }
                    }
                }
            }
            Button("No Chord (N.C.)") { session.ensureSelected(beat); session.setChord(.none) }
            Button("Strike \(style.name(shown, key: a.key)) Again Here  (splits the held chord, also in MIDI)") {
                session.strikeAgain(beat)
            }
            .disabled(shown.root == nil || beat == 0 || a.beats[beat].restart == true
                      || style.chord(a.beats[max(0, beat - 1)]) != shown)
            Divider()
            Button("Remove Chord – the One Before Goes On  (⌫)") { session.ensureSelected(beat); session.deleteChord() }
            Button("Back to Detected") { session.ensureSelected(beat); session.revertSelection() }
                .disabled(!(session.selection ?? beat...beat).contains { session.isEdited($0) } && !session.isEdited(beat))
        }
    }
}

/// The song's chords in order of appearance.
func songChords(_ a: Analysis, _ style: ChordStyle) -> [Chord] {
    var seen: [Chord] = []
    for s in a.spans(style) where s.chord.root != nil && !seen.contains(s.chord) { seen.append(s.chord) }
    return seen
}

// MARK: - Diagram strip

/// Every chord of the song with its guitar shape. Click: hear it on the piano.
/// With beats selected it is the palette: click puts that chord on them.
struct DiagramStrip: View {
    @EnvironmentObject var session: Session
    let analysis: Analysis
    let spans: [ChordSpan]

    var body: some View {
        let seen = songChords(analysis, session.style)
        let i = session.currentBeat
        let current: Chord? = i >= 0 ? session.style.chord(analysis.beats[i]) : nil
        let picking = session.selection != nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if picking, let label = session.selectionLabel() {
                    Text("CLICK A CHORD TO PUT IT ON \(label)")
                        .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundColor(Theme.accent)
                    Spacer()
                    Button("CLEAR SELECTION") { session.clearSelection() }
                        .buttonStyle(PillButtonStyle(small: true))
                        .help("Esc")
                } else {
                    Text("CHORDS IN THIS SONG · CLICK TO HEAR ON PIANO")
                        .font(.system(size: 9.5, weight: .heavy)).tracking(1).foregroundColor(Theme.dim)
                    Spacer()
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(seen, id: \.self) { c in
                        let on = c == current
                        VStack(spacing: 4) {
                            Text(session.style.name(c, key: analysis.key))
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(on ? .black : Theme.chordColor(c.root))
                                .lineLimit(1)
                            ChordDiagram(voicing: GuitarChords.voicing(c), color: on ? .black : Theme.text)
                                .frame(width: 54, height: 64)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.loop : Theme.panel2))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picking ? Theme.accent.opacity(0.5) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { picking ? session.setChord(c) : session.hear(c) }
                        .help(picking ? "Put \(session.style.name(c, key: analysis.key)) on the selected beats"
                                      : "Hear \(session.style.name(c, key: analysis.key)) on the piano")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picking ? Theme.accent.opacity(0.6) : Theme.line))
    }
}

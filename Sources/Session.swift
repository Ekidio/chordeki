import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// The open song: playback, the beat under the playhead, how chords are shown, hand fixes, export.
@MainActor
final class Session: ObservableObject {
    static weak var current: Session?

    let player = ChordPlayer()
    @Published var style = ChordStyle(numerals: ChordStyle.Numerals(rawValue: UserDefaults.standard.string(forKey: "numerals") ?? "") ?? .letters,
                                      showBass: UserDefaults.standard.bool(forKey: "showBass")) {
        didSet {
            refreshPiano()
            if style.transpose != oldValue.transpose { applyAudioShift() }
            if style.numerals != oldValue.numerals { UserDefaults.standard.set(style.numerals.rawValue, forKey: "numerals") }
            if style.showBass != oldValue.showBass { UserDefaults.standard.set(style.showBass, forKey: "showBass") }
        }
    }
    /// Transposing moves the song's audio too (tempo kept). Off: only the chords move.
    @Published var audioTranspose = UserDefaults.standard.object(forKey: "audioTranspose") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(audioTranspose, forKey: "audioTranspose")
            applyAudioShift()
        }
    }

    private func applyAudioShift() { player.audioShift = audioTranspose ? style.transpose : 0 }

    /// MIDI export: the chord track follows the recording's accompaniment rhythm (off: held chords).
    @Published var midiRhythm = UserDefaults.standard.bool(forKey: "midiRhythm") {
        didSet { UserDefaults.standard.set(midiRhythm, forKey: "midiRhythm") }
    }
    @Published var follow = true
    /// The beat under the playhead (-1 before the first beat). Changes a few times a second, not 60.
    @Published private(set) var currentBeat = -1
    @Published private(set) var song: Song?
    /// Selected beats (for copy / paste / setting a chord).
    @Published private(set) var selection: ClosedRange<Int>?
    @Published private(set) var clipboard: [ChordEdit] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// After a fix: the same place in the other parts that sound the same, ready to take the fix too.
    @Published private(set) var offer: Offer?

    struct Offer: Equatable {
        var edits: [Int: ChordEdit] = [:]
        /// A section offer: these bars start the same kind of section.
        var sectionBars: [Int] = []
        var sectionKind: String?
        var places: Int
        var label: String
    }

    /// What undo / redo restore: the hand-set chords and sections together.
    private struct Snapshot: Equatable {
        var edits: [Int: ChordEdit]
        var sections: [SectionMark]?
    }

    private var anchor: Int?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var bag = Set<AnyCancellable>()

    init() {
        Session.current = self
        player.clock.$position
            .sink { [weak self] t in
                guard let self, let a = self.analysis else { return }
                let i = a.beatIndex(at: t)
                if i != self.currentBeat { self.currentBeat = i }
            }
            .store(in: &bag)
        // Re-publish the player's changes (play state, peaks, toggles) to views that watch the session.
        player.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    func open(_ song: Song?) {
        let same = song?.id == self.song?.id
        // Any song with audio: it plays while the analysis runs.
        self.song = song
        if !same {
            style.transpose = 0
            selection = nil
            anchor = nil
            offer = nil
            undoStack = []
            redoStack = []
            updateUndoFlags()
        }
        GuitarChords.chosen = self.song?.voicings ?? [:]
        ChordNotes.chosenPiano = self.song?.pianoVoicings ?? [:]
        player.load(self.song)
        refreshPiano()
        currentBeat = analysis?.beatIndex(at: player.position) ?? -1
        // A song just opened starts playing at once, the analysis goes on behind it.
        if let id = song?.id, Library.shared.autoplay == id, player.canPlay {
            Library.shared.autoplay = nil
            if !player.isPlaying { player.play() }
        }
    }

    /// The analysis with the hand-set chords in place: what is shown, played and exported.
    var analysis: Analysis? { song?.effective }

    func isEdited(_ beat: Int) -> Bool { song?.edits?[beat] != nil }

    /// The song's sections (set by hand, or the engine's suggestion).
    var sections: [SectionMark] { song?.effectiveSections ?? [] }

    // MARK: Unsure chords

    /// Chord runs the engine was not sure of, not yet fixed or checked by ear.
    var unsureSpans: [ChordSpan] {
        guard let a = analysis else { return [] }
        let edits = song?.edits ?? [:]
        let checked = song?.checked ?? []
        return a.spans(style).filter { s in
            guard s.chord.root != nil else { return false }
            let range = s.firstBeat...s.lastBeat
            if range.contains(where: { edits[$0] != nil || checked.contains($0) }) { return false }
            let confs = range.compactMap { a.beats[$0].conf }
            guard !confs.isEmpty else { return false }
            return (confs.min() ?? 1) < Analysis.unsureWeakest
                || confs.reduce(0, +) / Double(confs.count) < Analysis.unsureAverage
        }
    }

    /// U / ⇧U: to the next (previous) unsure chord: select it, go there, hear it.
    func stepUnsure(_ delta: Int) {
        let list = unsureSpans
        guard !list.isEmpty else { Toast.shared.show("No unsure chords left"); return }
        let here = selection?.lowerBound ?? max(0, currentBeat)
        let target: ChordSpan?
        if delta > 0 {
            target = list.first { $0.firstBeat > here } ?? list.first
        } else {
            target = list.last { $0.firstBeat < here } ?? list.last
        }
        guard let span = target else { return }
        anchor = span.firstBeat
        selection = span.firstBeat...span.lastBeat
        offer = nil
        player.seek(span.start)
        hear(span.chord)
    }

    /// O: the selected chord sounds right; it is unsure no more. Then on to the next unsure one.
    func markChecked() {
        guard let r = selection, let id = song?.id else { return }
        var checked = song?.checked ?? []
        for i in r { checked.insert(i) }
        Library.shared.setChecked(id, checked)
        song = Library.shared.songs.first { $0.id == id }
        Toast.shared.show("Checked ✓")
        if !unsureSpans.isEmpty { stepUnsure(1) }
    }

    /// The beats that are the same music as the selection (for a hint in the grid).
    var twinsOfSelection: Set<Int> {
        guard let r = selection, let a = analysis, r.count <= 64 else { return [] }
        return Set(a.twinBeats(of: r).keys)
    }

    /// Offers the fix just made on `range` for every place that is the same music.
    private func proposeTwins(_ range: ClosedRange<Int>) {
        guard let a = analysis else { offer = nil; return }
        var edits: [Int: ChordEdit] = [:]
        var bars = Set<Int>()
        let loc = a.beatLocations
        for (t, src) in a.twinBeats(of: range) {
            let want = edit(of: a.beats[src], restart: a.beats[src].restart)
            if a.beats[t].root != want.root || a.beats[t].quality != want.quality
                || a.beats[t].bass != want.bass || a.beats[t].notes != want.notes
                || (want.restart == true && a.beats[t].restart != true) {
                edits[t] = want
                bars.insert(loc[t].bar)
            }
        }
        guard !edits.isEmpty else { offer = nil; return }
        let name = style.name(style.chord(a.beats[range.lowerBound]), key: a.key)
        offer = Offer(edits: edits, places: bars.count, label: "\(name) · the same music is in \(bars.count) more bar\(bars.count == 1 ? "" : "s")")
    }

    /// A: put the fix (chords or sections) on the other places too.
    func applyOffer() {
        guard let o = offer else { return }
        if let kind = o.sectionKind {
            changeSections { marks in
                for b in o.sectionBars {
                    marks.removeAll { $0.bar == b }
                    marks.append(SectionMark(bar: b, kind: kind))
                }
            }
            Toast.shared.show("\(kind) marked in \(o.places) more place\(o.places == 1 ? "" : "s")")
        } else {
            change { edits in for (i, e) in o.edits { edits[i] = e } }
            Toast.shared.show("Fixed in \(o.places) more bar\(o.places == 1 ? "" : "s")")
        }
        offer = nil
    }

    // MARK: Sections

    /// A section of `kind` starts at the bar of `beat`. Offers the same for every place that is the same music.
    func setSection(_ kind: String, atBeat beat: Int) {
        guard let a = analysis, a.beats.indices.contains(beat) else { return }
        let bar = a.beatLocations[beat].bar
        changeSections { marks in
            marks.removeAll { $0.bar == bar }
            marks.append(SectionMark(bar: bar, kind: kind))
        }
        // The same music elsewhere: bars whose next four bars repeat this bar's next four.
        guard let twins = a.barTwins else { offer = nil; return }
        let n = a.bars.count
        let span = min(4, n - bar)
        var starts: [Int] = []
        for cand in (twins.indices.contains(bar) ? twins[bar] : []) where cand != bar {
            let ok = (0..<span).allSatisfy { t in
                bar + t < twins.count && twins[bar + t].contains(cand + t)
            }
            let taken = sections.contains { $0.bar == cand && $0.kind == kind }
            if ok && !taken && !starts.contains(where: { abs($0 - cand) < 4 }) { starts.append(cand) }
        }
        offer = starts.isEmpty ? nil : Offer(sectionBars: starts, sectionKind: kind, places: starts.count,
                                             label: "\(kind) · the same music starts at \(starts.count) more place\(starts.count == 1 ? "" : "s")")
    }

    /// No section starts at the bar of `beat` any more (it joins the section before).
    func removeSection(atBeat beat: Int) {
        guard let a = analysis, a.beats.indices.contains(beat) else { return }
        let bar = a.beatLocations[beat].bar
        changeSections { $0.removeAll { $0.bar == bar } }
    }

    func sectionAt(beat: Int) -> SectionMark? {
        guard let a = analysis, a.beats.indices.contains(beat) else { return nil }
        let bar = a.beatLocations[beat].bar
        return sections.first { $0.bar == bar }
    }

    /// Back to the engine's suggestion.
    func resetSections() { storeChange(Snapshot(edits: song?.edits ?? [:], sections: nil)) }

    func clearSections() { changeSections { $0 = [] } }

    private func changeSections(_ body: (inout [SectionMark]) -> Void) {
        var marks = sections
        body(&marks)
        storeChange(Snapshot(edits: song?.edits ?? [:], sections: marks.sorted { $0.bar < $1.bar }))
    }

    func dismissOffer() { offer = nil }

    /// The instrument chords are heard on: piano (the default, PIANO view), or guitar when GUITAR is chosen.
    var sound: ChordPlayer.Sound { UserDefaults.standard.string(forKey: "diagramStyle") == "guitar" ? .guitar : .piano }

    /// The notes of a chord on the current instrument (the guitar plays its shape).
    func soundNotes(_ c: Chord) -> [UInt8] { sound == .guitar ? GuitarChords.notes(c) : ChordNotes.all(c) }

    /// GUITAR / PIANO was switched: the play-along changes instrument too.
    func soundChanged() { refreshPiano() }

    private func refreshPiano() {
        guard let a = analysis else { player.pianoTrack = []; return }
        player.trackSound = sound
        player.pianoTrack = a.labelBeats(style, sections: sections).map { (a.beats[$0].t, soundNotes(style.chord(a.beats[$0]))) }
    }

    // MARK: Navigation

    func seek(_ t: Double) { player.seek(t) }

    func seekBeat(_ i: Int) {
        guard let a = analysis, a.beats.indices.contains(i) else { return }
        player.seek(a.beats[i].t)
    }

    /// Jumps a bar back or forward from the playhead.
    func jumpBar(_ delta: Int) {
        guard let a = analysis else { return }
        let starts = a.beats.indices.filter { a.beats[$0].pos == 0 }.map { a.beats[$0].t }
        guard !starts.isEmpty else { return }
        let t = player.position
        let here = starts.lastIndex { $0 <= t + 0.05 } ?? -1
        // Back: to the start of this bar first, unless we are right on it.
        var target = here + delta
        if delta < 0, here >= 0, t - starts[here] > 0.4 { target = here }
        player.seek(starts[max(0, min(starts.count - 1, target))])
    }

    func goToStart() { player.seek(0) }

    // MARK: Selection

    /// Click: select this beat (and play from it when paused it just moves there). Shift-click: extend.
    func click(beat i: Int, extend: Bool) {
        offer = nil
        if extend, let a = anchor {
            selection = min(a, i)...max(a, i)
        } else {
            anchor = i
            selection = i...i
            seekBeat(i)
            if let a = analysis, a.beats.indices.contains(i) { hear(style.chord(a.beats[i])) }
        }
    }

    /// For the right-click menu: act on the selection if the beat is in it, otherwise on that beat.
    func ensureSelected(_ i: Int) {
        if selection?.contains(i) != true {
            anchor = i
            selection = i...i
        }
    }

    func clearSelection() {
        selection = nil
        anchor = nil
        offer = nil
    }

    /// "Bar 5 · 1 – bar 6 · 4"
    func selectionLabel() -> String? {
        guard let r = selection, let a = analysis else { return nil }
        func label(_ i: Int) -> String {
            guard let p = a.barBeat(at: a.beats[i].t) else { return "–" }
            return p.bar == 0 ? "pickup · \(p.beat)" : "\(p.bar) · \(p.beat)"
        }
        return r.count == 1 ? "BAR " + label(r.lowerBound) : "BAR " + label(r.lowerBound) + " – " + label(r.upperBound)
    }

    // MARK: Hearing chords

    /// Plays a chord (as shown) on the piano.
    func hear(_ c: Chord) { player.audition(soundNotes(c), sound: sound) }

    /// P: the chord of the selection, or the one under the playhead.
    func hearCurrent() {
        guard let a = analysis else { return }
        let i = selection?.lowerBound ?? max(0, currentBeat)
        guard a.beats.indices.contains(i) else { return }
        hear(style.chord(a.beats[i]))
    }

    // MARK: Fixing chords

    /// What the engine would call the chord shown as `c` (transposition taken off).
    private func raw(_ c: Chord) -> ChordEdit {
        ChordEdit(root: c.root.map { ($0 - style.transpose + 120) % 12 }, quality: c.quality,
                  bass: c.bass.map { ($0 - style.transpose + 120) % 12 },
                  notes: c.notes.map { $0.map { $0 - style.transpose } })
    }

    /// A beat's chord as an edit, everything included.
    private func edit(of b: Analysis.Beat, restart: Bool? = nil) -> ChordEdit {
        ChordEdit(root: b.root, quality: b.quality, restart: restart, bass: b.bass, notes: b.notes)
    }

    // MARK: Chord builder

    /// The piano chord builder is open (for the selection).
    @Published var builderOpen = false

    // MARK: Guitar fingerings

    /// The chord whose fingerings are shown in the picker (nil: closed).
    @Published var fingeringChord: Chord?

    func openFingerings(_ c: Chord) {
        guard c.root != nil else { return }
        fingeringChord = c
    }

    /// Use this piano voicing for the chord everywhere in this song – sound, MIDI, pictures (and hear it).
    func choosePianoVoicing(_ c: Chord, _ notes: [Int]?) {
        guard let id = song?.id else { return }
        var v = song?.pianoVoicings ?? [:]
        v[ChordNotes.key(c)] = notes
        Library.shared.setPianoVoicings(id, v)
        song = Library.shared.songs.first { $0.id == id }
        ChordNotes.chosenPiano = song?.pianoVoicings ?? [:]
        refreshPiano()
        objectWillChange.send()
        player.audition(ChordNotes.all(c), sound: .piano)
    }

    /// Use this fingering for the chord everywhere in this song (and hear it).
    func chooseFingering(_ c: Chord, _ frets: [Int]?) {
        guard let id = song?.id else { return }
        var v = song?.voicings ?? [:]
        v[GuitarChords.key(c)] = frets
        Library.shared.setVoicings(id, v)
        song = Library.shared.songs.first { $0.id == id }
        GuitarChords.chosen = song?.voicings ?? [:]
        refreshPiano()
        objectWillChange.send()
        player.audition(GuitarChords.notes(c), sound: .guitar)
    }

    func openBuilder(_ beat: Int? = nil) {
        if let beat { ensureSelected(beat) }
        guard selection != nil else { Toast.shared.show("Select a beat first"); return }
        builderOpen = true
    }

    /// The chord builder is a keyboard: it always sounds on the piano.
    func playNotes(_ notes: [Int]) { player.audition(notes.sorted().map { UInt8(max(21, min(108, $0))) }, sound: .piano) }

    /// Puts a chord (as shown) on every selected beat.
    func setChord(_ c: Chord) {
        guard let r = selection, let a = analysis else { return }
        let e = raw(c)
        // The same chord as the one going on before: strike it again here (a new chord, also in the MIDI).
        let again = r.lowerBound > 0 && c.root != nil && style.chord(a.beats[r.lowerBound - 1]) == c
        change { edits in
            for i in r { edits[i] = e }
            if again { edits[r.lowerBound]?.restart = true }
        }
        hear(c)
        proposeTwins(r)
    }

    /// Strike the chord going on again on this beat: it becomes a new chord in the grid, on the piano and in the MIDI.
    func strikeAgain(_ i: Int) {
        guard let a = analysis, a.beats.indices.contains(i), a.beats[i].root != nil else { return }
        anchor = i
        selection = i...i
        change { $0[i] = edit(of: a.beats[i], restart: true) }
        hear(style.chord(a.beats[i]))
        proposeTwins(i...i)
    }

    func copy() {
        guard let r = selection, let a = analysis else { return }
        clipboard = r.map { edit(of: a.beats[$0], restart: a.beats[$0].restart) }
        Toast.shared.show(clipboard.count == 1 ? "Copied 1 beat" : "Copied \(clipboard.count) beats")
    }

    /// One copied chord fills the whole selection; a copied passage is laid down from the selection's start.
    func paste() {
        guard let r = selection, !clipboard.isEmpty, let a = analysis else { return }
        let clip = clipboard
        change { edits in
            if clip.count == 1 {
                for i in r { edits[i] = clip[0] }
            } else {
                for (k, e) in clip.enumerated() where r.lowerBound + k < a.beats.count { edits[r.lowerBound + k] = e }
            }
        }
        if clip.count > 1 { selection = r.lowerBound...min(a.beats.count - 1, r.lowerBound + clip.count - 1) }
        Toast.shared.show(clip.count == 1 ? "Pasted" : "Pasted \(clip.count) beats")
        if let sel = selection { proposeTwins(sel) }
    }

    /// ⌫: removes the chord on the selected beats; the chord before them simply goes on.
    func deleteChord() {
        guard let r = selection, let a = analysis else { return }
        let prev = r.lowerBound > 0 ? a.beats[r.lowerBound - 1] : nil
        let fill = prev.map { edit(of: $0) } ?? ChordEdit(root: nil, quality: "")
        change { edits in for i in r { edits[i] = fill } }
        let name = prev.map { style.name(style.chord($0), key: a.key) } ?? "N.C."
        Toast.shared.show("Chord removed: \(name) goes on")
        proposeTwins(r)
    }

    /// PIANO mode ← / →: step from chord to chord (every name in the grid), select it, go there and hear it.
    func stepChord(_ delta: Int) {
        guard let a = analysis else { return }
        let marks = a.labelBeats(style, sections: sections).filter { style.chord(a.beats[$0]).root != nil }
        guard !marks.isEmpty else { return }
        // From the playhead while playing, otherwise from the selection.
        let here = player.isPlaying ? max(0, currentBeat) : (selection?.lowerBound ?? max(0, currentBeat))
        let k = (marks.lastIndex { $0 <= here } ?? -1) + delta
        guard marks.indices.contains(k) else { return }
        let first = marks[k]
        let all = a.labelBeats(style, sections: sections)
        let last = (all.first { $0 > first } ?? a.beats.count) - 1
        anchor = first
        selection = first...last
        offer = nil
        player.seek(a.beats[first].t)
        hear(style.chord(a.beats[first]))
    }

    /// Back to what the engine found, on the selected beats.
    func revertSelection() {
        guard let r = selection else { return }
        change { edits in for i in r { edits[i] = nil } }
    }

    func revertAll() {
        guard !(song?.edits ?? [:]).isEmpty else { return }
        change { $0 = [:] }
        Toast.shared.show("All chords back as detected")
    }

    private var snapshot: Snapshot { Snapshot(edits: song?.edits ?? [:], sections: song?.sections) }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        store(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        store(next)
    }

    private func change(_ body: (inout [Int: ChordEdit]) -> Void) {
        guard let song, let detected = song.analysis else { return }
        var edits = song.edits ?? [:]
        body(&edits)
        // An edit equal to what was detected is no edit.
        for (i, e) in edits where detected.beats.indices.contains(i)
            && detected.beats[i].root == e.root && detected.beats[i].quality == e.quality && e.restart != true
            && e.bass == nil && e.notes == nil {
            edits[i] = nil
        }
        storeChange(Snapshot(edits: edits, sections: song.sections))
    }

    /// Records an undo step and stores the new state.
    private func storeChange(_ next: Snapshot) {
        let before = snapshot
        guard next != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        store(next)
    }

    private func store(_ s: Snapshot) {
        guard let id = song?.id else { return }
        Library.shared.setEdits(id, s.edits)
        Library.shared.setSections(id, s.sections)
        song = Library.shared.songs.first { $0.id == id }
        refreshPiano()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Export

    func exportPDF() {
        guard let song, let a = analysis else { return }
        ChordSheet.export(song: song, analysis: a, style: style, sections: sections)
    }

    func exportMIDI(_ timing: MidiWriter.Timing) {
        guard let song, let a = analysis else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        let suffix = (timing == .synced ? "chords" : "chords \(formatBPM(a.tempo.rounded())) BPM") + (midiRhythm ? " rhythm" : "")
        let t = style.transpose == 0 ? "" : String(format: " (%+d)", style.transpose)
        panel.nameFieldStringValue = "\(song.title) - \(suffix)\(t).mid"
        panel.directoryURL = URL(fileURLWithPath: song.sourcePath).deletingLastPathComponent()
        panel.message = timing == .synced
            ? "MIDI that lines up with the original recording (tempo follows the song)."
            : "MIDI on a steady \(formatBPM(a.tempo.rounded())) BPM grid."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MidiWriter.data(a, style: style, timing: timing, sections: sections, rhythm: midiRhythm).write(to: url)
            Toast.shared.show("MIDI saved: \(url.lastPathComponent)")
        } catch {
            Toast.shared.show("Could not save: \(error.localizedDescription)")
        }
    }
}

/// A short message at the bottom of the window.
@MainActor
final class Toast: ObservableObject {
    static let shared = Toast()
    @Published private(set) var message: String?
    private var hide: Task<Void, Never>?

    func show(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { message = text }
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { withAnimation(.easeIn(duration: 0.3)) { message = nil } }
        }
    }
}

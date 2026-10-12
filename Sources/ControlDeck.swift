import SwiftUI

/// Bottom deck: chord display, transport and export, side by side (as in STEMEKI).
struct ControlDeck: View {
    let clock: PlayClock

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChordsCard().frame(maxWidth: .infinity)
            EditCard().frame(maxWidth: .infinity)
            TransportCard(clock: clock).fixedSize(horizontal: true, vertical: false)
            ExportCard().frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Chords

struct ChordsCard: View {
    @EnvironmentObject var session: Session

    var body: some View {
        Card(title: "CHORDS", accent: Theme.accent) {
            HStack(spacing: 4) {
                Button("SIMPLE") { session.style.simple = true }
                    .buttonStyle(PillButtonStyle(color: Theme.accent, active: session.style.simple))
                    .help("Plain major and minor chords")
                Button("EXTENDED") { session.style.simple = false }
                    .buttonStyle(PillButtonStyle(color: Theme.accent, active: !session.style.simple))
                    .help("7ths, maj7, sus, add9, dim…")
            }
            HStack(spacing: 4) {
                Text("TRANSPOSE").font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundColor(Theme.dim)
                Button { session.style.transpose = max(-11, session.style.transpose - 1) } label: { Image(systemName: "minus") }
                    .buttonStyle(PillButtonStyle(small: true))
                    .help("Transpose down a semitone")
                Text(session.style.transpose == 0 ? "0" : String(format: "%+d", session.style.transpose))
                    .font(Theme.mono(12, .bold))
                    .foregroundColor(session.style.transpose == 0 ? Theme.text : Theme.loop)
                    .frame(minWidth: 28)
                Button { session.style.transpose = min(11, session.style.transpose + 1) } label: { Image(systemName: "plus") }
                    .buttonStyle(PillButtonStyle(small: true))
                    .help("Transpose up a semitone")
                Button("0") { session.style.transpose = 0 }
                    .buttonStyle(PillButtonStyle(small: true))
                    .disabled(session.style.transpose == 0)
                    .modifier(DisabledDim())
                    .help("Original key")
            }
        }
    }
}

// MARK: Edit

/// Fixing chords by hand: copy a good passage, paste it where the same chords were missed.
struct EditCard: View {
    @EnvironmentObject var session: Session

    var body: some View {
        let has = session.selection != nil
        Card(title: "FIX CHORDS", accent: Theme.violet) {
            Text(session.selectionLabel() ?? "Click a beat · shift-click for more")
                .font(Theme.mono(10.5, .bold))
                .foregroundColor(has ? Theme.accent : Theme.dim)
                .lineLimit(1)
            HStack(spacing: 4) {
                Button("COPY") { session.copy() }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(!has).modifier(DisabledDim())
                    .help("Copy the selected beats (⌘C)")
                Button(session.clipboard.count > 1 ? "PASTE \(session.clipboard.count)" : "PASTE") { session.paste() }
                    .buttonStyle(PillButtonStyle(color: Theme.violet, small: true))
                    .disabled(!has || session.clipboard.isEmpty).modifier(DisabledDim())
                    .help("One copied chord fills the selection; a copied passage is laid down from its start (⌘V)")
                Button { session.deleteChord() } label: { Image(systemName: "delete.left") }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(!has).modifier(DisabledDim())
                    .help("Remove the chord: the one before goes on (⌫)")
                Button("ORIGINAL") { session.revertSelection() }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(!has).modifier(DisabledDim())
                    .help("Back to what was detected")
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(!session.canUndo).modifier(DisabledDim())
                    .help("Undo (⌘Z)")
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(!session.canRedo).modifier(DisabledDim())
                    .help("Redo (⇧⌘Z)")
            }
            let unsure = session.unsureSpans.count
            HStack(spacing: 4) {
                Text(unsure == 0 ? "ALL CHECKED" : "UNSURE \(unsure)")
                    .font(Theme.mono(10.5, .bold))
                    .foregroundColor(unsure == 0 ? Theme.green : Theme.orange)
                    .frame(minWidth: 84, alignment: .leading)
                Button { session.stepUnsure(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(unsure == 0).modifier(DisabledDim())
                    .help("Previous unsure chord (⇧U)")
                Button { session.stepUnsure(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(PillButtonStyle(small: true)).disabled(unsure == 0).modifier(DisabledDim())
                    .help("Next unsure chord (U): it is selected and played on the piano")
                Button { session.markChecked() } label: { HStack(spacing: 3) { Image(systemName: "checkmark"); Text("SOUNDS RIGHT") } }
                    .buttonStyle(PillButtonStyle(color: Theme.green, small: true)).disabled(!has).modifier(DisabledDim())
                    .help("The selected chord is right: unsure no more, on to the next (O)")
            }
        }
    }
}

// MARK: Transport

struct TransportCard: View {
    @EnvironmentObject var session: Session
    let clock: PlayClock

    var body: some View {
        let player = session.player
        Card(title: "TRANSPORT") {
            HStack(spacing: 10) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(player.isPlaying ? Theme.loop : Theme.text))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")
                VStack(alignment: .leading, spacing: 3) {
                    TimeReadout(clock: clock, analysis: session.analysis)
                    HStack(spacing: 4) {
                        Button { session.goToStart() } label: { Image(systemName: "backward.end.fill") }
                            .buttonStyle(PillButtonStyle(small: true))
                            .help("Back to the start (Enter). ← / → jump a bar.")
                        Button { session.follow.toggle() } label: { Text("FOLLOW") }
                            .buttonStyle(PillButtonStyle(color: Theme.accent, active: session.follow, small: true))
                            .help("The chord grid scrolls along with the song")
                        Button { player.clickOn.toggle() } label: {
                            HStack(spacing: 3) { Image(systemName: "metronome.fill"); Text("CLICK") }
                        }
                        .buttonStyle(PillButtonStyle(color: Theme.loop, active: player.clickOn, small: true))
                        .keyboardShortcut("k", modifiers: [])
                        .help("Metronome on the detected beats, higher on the 1 (K): hear if the grid sits right")
                        Button { player.pianoOn.toggle() } label: {
                            HStack(spacing: 3) { Image(systemName: "pianokeys"); Text("PIANO") }
                        }
                        .buttonStyle(PillButtonStyle(color: Theme.violet, active: player.pianoOn, small: true))
                        .keyboardShortcut("j", modifiers: [])
                        .help("PIANO (J): the piano plays the chords along with the song, and ← / → step from chord to chord and play it.")
                    }
                    MixSlider(player: player)
                }
            }
        }
    }
}

private struct TimeReadout: View {
    @ObservedObject var clock: PlayClock
    let analysis: Analysis?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatTime(clock.position)).font(Theme.mono(16, .semibold)).fixedSize()
            if let p = analysis?.barBeat(at: clock.position) {
                Text(p.bar == 0 ? "PICKUP · \(p.beat)" : "BAR \(p.bar) · \(p.beat)")
                    .font(Theme.mono(10.5, .bold)).foregroundColor(Theme.accent).fixedSize()
            } else {
                Text("BAR – · –").font(Theme.mono(10.5, .bold)).foregroundColor(Theme.dim).fixedSize()
            }
        }
    }
}

// MARK: Export

struct ExportCard: View {
    @EnvironmentObject var session: Session

    var body: some View {
        Card(title: "EXPORT", accent: Theme.green) {
            HStack(spacing: 4) {
                Button { session.exportMIDI(.synced) } label: {
                    HStack(spacing: 4) { Image(systemName: "waveform.path"); Text("SYNCED") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.green, filled: true))
                .help("Tempo map follows the song: lines up with the original recording in any DAW (⌘E)")
                Button { session.exportMIDI(.grid) } label: {
                    HStack(spacing: 4) { Image(systemName: "metronome"); Text("GRID \(formatBPM((session.analysis?.tempo ?? 120).rounded())) BPM") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.green, filled: true))
                .help("A steady tempo, rounded to a whole BPM (⇧⌘E)")
                Button { session.exportPDF() } label: {
                    HStack(spacing: 4) { Image(systemName: "doc.richtext"); Text("PDF") }
                }
                .buttonStyle(PillButtonStyle(color: Theme.accent, filled: true))
                .help("A printable chord sheet: guitar shapes and the bars, as shown (⌘P)")
            }
            Text("MIDI: chords + bass + chord names as markers · \(session.style.simple ? "simple" : "extended")\(session.style.transpose == 0 ? "" : String(format: " · %+d", session.style.transpose))")
                .font(.system(size: 10)).foregroundColor(Theme.dim)
        }
    }
}

/// ORIGINAL ↔ PIANO: the balance between the song and the piano. Double-click: back to the middle.
private struct MixSlider: View {
    @ObservedObject var player: ChordPlayer

    var body: some View {
        HStack(spacing: 6) {
            Text("MIX").font(.system(size: 9.5, weight: .heavy)).tracking(0.8).foregroundColor(Theme.dim)
            Text("ORIGINAL").font(.system(size: 9, weight: .heavy))
                .foregroundColor(player.mix < 0.95 ? Theme.text : Theme.dim)
            Slider(value: Binding(get: { Double(player.mix) }, set: { player.mix = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .tint(Theme.violet)
                .frame(width: 130)
                .onTapGesture(count: 2) { player.mix = 0.5 }
            Text("PIANO").font(.system(size: 9, weight: .heavy))
                .foregroundColor(player.mix > 0.05 ? Theme.violet : Theme.dim)
        }
        .help("Balance of the song and the piano. Middle: both at full level. Double-click: back to the middle.")
    }
}

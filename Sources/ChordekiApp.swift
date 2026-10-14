import SwiftUI
import AppKit

@main
struct ChordekiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library.shared
    @StateObject private var session = Session()
    @StateObject private var updater = Updater.shared

    var body: some Scene {
        Window("CHORDEKI", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(session)
                .frame(minWidth: 1180, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Songs…") { library.chooseFiles() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export MIDI (synced to the song)…") { session.exportMIDI(.synced) }
                    .keyboardShortcut("e")
                    .disabled(library.selected?.isReady != true)
                Button("Export MIDI (steady tempo)…") { session.exportMIDI(.grid) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(library.selected?.isReady != true)
                Divider()
                Button("Export Chord Sheet (PDF)…") { session.exportPDF() }
                    .keyboardShortcut("p")
                    .disabled(library.selected?.isReady != true)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Chord Change") { session.undo() }
                    .keyboardShortcut("z")
                    .disabled(!session.canUndo)
                Button("Redo Chord Change") { session.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!session.canRedo)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Chords") { session.copy() }
                    .keyboardShortcut("c")
                    .disabled(session.selection == nil)
                Button("Paste Chords") { session.paste() }
                    .keyboardShortcut("v")
                    .disabled(session.selection == nil || session.clipboard.isEmpty)
                Divider()
                Button("Remove Chord (the one before goes on)") { session.deleteChord() }
                    .disabled(session.selection == nil)
                Button("Back to Detected Chords") { session.revertSelection() }
                    .disabled(session.selection == nil)
                Button("All Chords Back to Detected") { session.revertAll() }
                    .disabled((session.song?.edits ?? [:]).isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Not while typing, and not in a sheet (the chord builder has its own keys).
            guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  NSApp.keyWindow?.isSheet != true else { return e }
            let act: (@MainActor (Session) -> Void)?
            switch e.keyCode {
            // ← / →: with PIANO on, chord by chord (heard on the piano); otherwise a bar back / forward
            case 123: act = { $0.player.pianoOn ? $0.stepChord(-1) : $0.jumpBar(-1) }
            case 124: act = { $0.player.pianoOn ? $0.stepChord(1) : $0.jumpBar(1) }
            case 36, 76: act = { $0.goToStart() }         // Enter: to the very start
            case 35: act = { $0.hearCurrent() }           // P: hear the chord on the piano
            case 53: act = { $0.clearSelection() }        // Esc
            case 51, 117: act = { $0.deleteChord() }      // ⌫ / ⌦: remove the chord, the one before goes on
            case 32: act = e.modifierFlags.contains(.shift) ? { $0.stepUnsure(-1) } : { $0.stepUnsure(1) }  // U / ⇧U
            case 31: act = { $0.markChecked() }           // O: sounds right
            case 0: act = { $0.applyOffer() }             // A: apply the fix to the same music elsewhere
            case 11: act = { $0.openBuilder() }           // B: build a chord on the piano for the selection
            default: act = nil
            }
            guard let act else { return e }
            MainActor.assumeIsolated { if let s = Session.current { act(s) } }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Library.shared.add(urls) }
    }
}

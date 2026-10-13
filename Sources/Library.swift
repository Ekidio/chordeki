import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// The song list: added files, their analysis, kept between launches.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var songs: [Song] = []
    @Published var selectedID: UUID?
    @Published var progress: [UUID: (Double, String)] = [:]
    @Published var needsEngine = !Engine.isInstalled
    /// A song just opened by the user: it starts playing as soon as its audio can be played.
    @Published var autoplay: UUID?

    private var running = false

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CHORDEKI")
    }
    private static var indexURL: URL { supportDir.appendingPathComponent("library.json") }
    static func songDir(_ id: UUID) -> URL { supportDir.appendingPathComponent("Songs/\(id.uuidString)") }

    var selected: Song? { songs.first { $0.id == selectedID } }

    init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([Song].self, from: data) {
            // Songs caught mid-analysis by a quit start again.
            songs = saved.map { var s = $0; if s.state == .analyzing { s.state = .queued }; return s }
            // Songs analyzed by an older engine get the new findings (unsure chords, repeats); hand fixes stay.
            for i in songs.indices where songs[i].state == .ready && songs[i].analysis?.barTwins == nil {
                songs[i].state = .queued
            }
        }
        selectedID = songs.first?.id
        runQueue()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(songs) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    // MARK: Adding

    static let audioExtensions: Set<String> = ["mp3", "wav", "aif", "aiff", "m4a", "aac", "flac", "ogg", "opus", "webm", "caf", "mp4", "mka"]

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.audioExtensions.compactMap { UTType(filenameExtension: $0) } + [.audio]
        panel.message = "Choose songs for CHORDEKI"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        var firstNew: UUID?
        for url in urls where Self.audioExtensions.contains(url.pathExtension.lowercased()) {
            if let existing = songs.first(where: { $0.sourcePath == url.path }) {
                firstNew = firstNew ?? existing.id
                continue
            }
            let title = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
            let song = Song(title: title, sourcePath: url.path)
            songs.append(song)
            firstNew = firstNew ?? song.id
        }
        if let firstNew {
            selectedID = firstNew
            autoplay = firstNew
        }
        save()
        runQueue()
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.songDir(id))
        songs.removeAll { $0.id == id }
        if selectedID == id { selectedID = songs.first?.id }
        save()
    }

    func reanalyze(_ id: UUID) {
        // New beats: hand-set chords would land in the wrong places.
        update(id) { $0.state = .queued; $0.error = nil; $0.edits = nil; $0.checked = nil }
        runQueue()
    }

    func setEdits(_ id: UUID, _ edits: [Int: ChordEdit]) {
        update(id) { $0.edits = edits.isEmpty ? nil : edits }
    }

    func setChecked(_ id: UUID, _ checked: Set<Int>) {
        update(id) { $0.checked = checked.isEmpty ? nil : checked }
    }

    func revealSource(_ song: Song) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: song.sourcePath)])
    }

    private func update(_ id: UUID, _ change: (inout Song) -> Void) {
        guard let i = songs.firstIndex(where: { $0.id == id }) else { return }
        change(&songs[i])
        save()
    }

    // MARK: Engine

    func installEngine() {
        EngineInstaller.shared.start { [weak self] in
            self?.needsEngine = false
            self?.runQueue()
        }
    }

    // MARK: Analysis queue (one song at a time)

    private func runQueue() {
        guard !running, !needsEngine, let next = songs.first(where: { $0.state == .queued }) else { return }
        running = true
        Task {
            await analyze(next)
            running = false
            runQueue()
        }
    }

    private func analyze(_ song: Song) async {
        let id = song.id
        update(id) { $0.state = .analyzing }
        progress[id] = (0, "Starting the engine")
        defer { progress[id] = nil }

        guard FileManager.default.fileExists(atPath: song.sourcePath) else {
            update(id) { $0.state = .failed; $0.error = "The file is gone: \(song.sourcePath)" }
            return
        }
        guard let script = Engine.script else {
            update(id) { $0.state = .failed; $0.error = "Missing chords.py in the app." }
            return
        }
        // macOS plays most formats itself; others (WEBM, OGG…) get a WAV from the engine.
        var args = [script.path, song.sourcePath]
        var wav: URL?
        if (try? AVAudioFile(forReading: URL(fileURLWithPath: song.sourcePath))) == nil {
            let dir = Self.songDir(id)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            wav = dir.appendingPathComponent("audio.wav")
            args += ["--wav", wav!.path]
        }

        var result: Analysis?
        var failure: String?
        do {
            try await Engine.run(Engine.python.path, args, env: ["TORCH_HOME": Engine.torchHome.path]) { [weak self] line in
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                if let p = obj["progress"] as? Double {
                    self?.progress[id] = (p, obj["step"] as? String ?? "")
                } else if let w = obj["wav"] as? String {
                    // The playable WAV is there before the analysis: the song can be heard already.
                    self?.update(id) { $0.playablePath = w }
                } else if let r = obj["result"], let rd = try? JSONSerialization.data(withJSONObject: r) {
                    do { result = try JSONDecoder().decode(Analysis.self, from: rd) }
                    catch { failure = "Unreadable engine result: \(error.localizedDescription)" }
                } else if let e = obj["error"] as? String {
                    failure = e
                }
            }
        } catch {
            failure = failure ?? error.localizedDescription
        }

        if let result {
            update(id) {
                // Hand fixes stay when the beats are the same (a fresh analysis of the same file).
                if $0.analysis?.beats.count != result.beats.count { $0.edits = nil; $0.checked = nil }
                $0.analysis = result
                $0.playablePath = wav?.path
                $0.state = .ready
                $0.error = nil
            }
        } else {
            update(id) { $0.state = .failed; $0.error = failure ?? "The analysis failed." }
        }
    }
}

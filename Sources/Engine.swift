import Foundation
import CryptoKit
import SwiftUI

/// CHORDEKI's own analysis engine: a private Python with the beat model (Beat This!) and librosa,
/// set up by one click in ~/Library/Application Support/CHORDEKI/Engine. Same recipe as STEMEKI's.
enum Engine {
    static let pythonURL = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20250317/cpython-3.10.16+20250317-aarch64-apple-darwin-install_only.tar.gz")!
    static let pythonSHA256 = "e99f8457d9c79592c036489c5cfa78df76e4762d170665e499833e045d82608f"
    /// The beat / downbeat model (Beat This!, JKU Linz, MIT), where its own loader looks for it.
    static let beatModelURL = URL(string: "https://cloud.cp.jku.at/public.php/dav/files/7ik4RrBKTS273gp/final0.ckpt")!
    static let beatModelFile = "beat_this-final0.ckpt"
    static let beatModelSHA256 = "8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"
    /// Native packages must come as ready-made wheels: no compiler on the user's Mac.
    static let binaryOnly = "torch,torchaudio,numpy,scipy,numba,llvmlite,soundfile,scikit-learn,soxr,msgpack,cffi,av"

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CHORDEKI/Engine")
    }
    static var python: URL { dir.appendingPathComponent("python/bin/python3") }
    static var torchHome: URL { dir.appendingPathComponent("torch") }
    static var beatModel: URL { torchHome.appendingPathComponent("hub/checkpoints").appendingPathComponent(beatModelFile) }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: beatModel.path)
    }

    static var script: URL? { Bundle.main.url(forResource: "chords", withExtension: "py") }

    /// Runs a tool; stdout lines go to `onLine`, a failure throws with the end of its output.
    @discardableResult
    static func run(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                    onLine: (@MainActor (String) -> Void)? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PYTHONUNBUFFERED"] = "1"
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let log = LogBuffer()
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                for line in log.appendOut(data) {
                    if let onLine { DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } } }
                }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                log.appendErr(data)
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let rest = log.appendOut(out.fileHandleForReading.readDataToEndOfFile()) + log.flushOut()
                log.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                if let onLine, !rest.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { rest.forEach(onLine) } }
                }
                // Let the last lines reach the main actor before we report back.
                DispatchQueue.main.async {
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: 0)
                    } else {
                        let tail = log.errText.split(separator: "\n").suffix(3).joined(separator: "\n")
                        cont.resume(throwing: EngineError(tail.isEmpty ? "\(tool) failed" : tail))
                    }
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

/// Collects a process's output and splits stdout into lines.
private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var err = Data()

    func appendOut(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    func flushOut() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let s = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [s]
    }

    func appendErr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        err.append(data)
        if err.count > 200_000 { err = err.suffix(100_000) }
    }

    var errText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: err, as: UTF8.self)
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Downloads and sets up the engine, step by step, with progress for the setup screen.
@MainActor
final class EngineInstaller: ObservableObject {
    static let shared = EngineInstaller()

    enum Phase: Equatable { case idle, working, failed(String), done }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step = ""
    @Published private(set) var detail = ""
    @Published private(set) var fraction = 0.0

    func start(onDone: @escaping @MainActor () -> Void) {
        guard phase != .working else { return }
        phase = .working
        fraction = 0
        Task {
            do {
                try await install()
                phase = .done
                onDone()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func install() async throws {
        let fm = FileManager.default
        let work = Engine.dir.deletingLastPathComponent().appendingPathComponent("Engine.partial")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        if let free = try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 2_000_000_000 {
            throw EngineError("Not enough free disk space: the engine needs about 2 GB while installing.")
        }

        // 1. Python.
        step = "STEP 1 / 4 · Downloading Python"
        let archive = work.appendingPathComponent("python.tar.gz")
        try await Downloader.fetch(Engine.pythonURL, to: archive) { [weak self] f, got, total in
            self?.fraction = 0.08 * f
            self?.detail = Self.megabytes(got, total)
        }
        guard try Self.sha256(archive) == Engine.pythonSHA256 else {
            throw EngineError("The Python download is damaged (checksum mismatch). Please try again.")
        }
        detail = "Unpacking…"
        try await Engine.run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path])
        try? fm.removeItem(at: archive)
        _ = try? await Engine.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", work.path])
        let python = work.appendingPathComponent("python/bin/python3")

        // 2. The beat finder, librosa and friends, the exact versions CHORDEKI is tested with.
        step = "STEP 2 / 4 · Installing the AI"
        fraction = 0.1
        guard let requirements = Bundle.main.url(forResource: "engine-requirements", withExtension: "txt") else {
            throw EngineError("Missing engine-requirements.txt in the app.")
        }
        let total = Double((try? String(contentsOf: requirements, encoding: .utf8))?
            .split(separator: "\n").filter { $0.contains("==") }.count ?? 40)
        var collected = 0.0
        try await Engine.run(python.path, ["-m", "pip", "install", "--no-cache-dir", "--prefer-binary",
                                           "--only-binary=\(Engine.binaryOnly)", "--disable-pip-version-check",
                                           "--no-warn-script-location", "-r", requirements.path],
                             env: ["PIP_NO_INPUT": "1"]) { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("Collecting ") {
                collected += 1
                self.detail = String(line.dropFirst(11)).components(separatedBy: " ").first ?? ""
                self.fraction = 0.1 + 0.6 * min(1, collected / total)
            } else if line.hasPrefix("Installing collected packages") {
                self.detail = "Putting it all together…"
                self.fraction = 0.72
            }
        }

        // 3. The beat model.
        let checkpoints = work.appendingPathComponent("torch/hub/checkpoints")
        try fm.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        let beatModel = checkpoints.appendingPathComponent(Engine.beatModelFile)
        step = "STEP 3 / 4 · Downloading the beat model"
        try await Downloader.fetch(Engine.beatModelURL, to: beatModel) { [weak self] f, got, total in
            self?.fraction = 0.74 + 0.16 * f
            self?.detail = Self.megabytes(got, total)
        }
        guard try Self.sha256(beatModel) == Engine.beatModelSHA256 else {
            try? fm.removeItem(at: beatModel)
            throw EngineError("The beat model download is damaged (checksum mismatch). Please try again.")
        }

        // 4. Does it all load?
        step = "STEP 4 / 4 · Testing the engine"
        detail = "Loading the AI once…"
        fraction = 0.93
        try await Engine.run(python.path, ["-c", "import librosa, soundfile, soxr, av, torch, beat_this; "
                                           + "from beat_this.inference import load_checkpoint; load_checkpoint('final0')"],
                             env: ["TORCH_HOME": work.appendingPathComponent("torch").path])

        try? fm.removeItem(at: Engine.dir)
        try fm.moveItem(at: work, to: Engine.dir)
        fraction = 1
        detail = "Ready"
    }

    nonisolated static func megabytes(_ got: Int64, _ total: Int64) -> String {
        let g = Double(got) / 1_000_000
        return total > 0 ? String(format: "%.0f of %.0f MB", g, Double(total) / 1_000_000) : String(format: "%.0f MB", g)
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A file download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let progress: @MainActor (Double, Int64, Int64) -> Void
    private var cont: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast

    private init(dest: URL, progress: @escaping @MainActor (Double, Int64, Int64) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    static func fetch(_ url: URL, to dest: URL,
                      progress: @escaping @MainActor (Double, Int64, Int64) -> Void) async throws {
        let d = Downloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.cont = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten got: Int64, totalBytesExpectedToWrite total: Int64) {
        guard Date().timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = Date()
        let f = total > 0 ? Double(got) / Double(total) : 0
        let progress = progress
        DispatchQueue.main.async { MainActor.assumeIsolated { progress(f, got, total) } }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            cont?.resume(throwing: EngineError("Download failed (HTTP \(http.statusCode))."))
            cont = nil
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            cont?.resume()
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            cont?.resume(throwing: EngineError("Download failed: \(error.localizedDescription) Check the internet connection and try again."))
            cont = nil
        }
    }
}

// MARK: - Setup screen

/// Shown instead of the song area until the engine is there.
struct EngineSetupView: View {
    @EnvironmentObject var library: Library
    @ObservedObject var installer = EngineInstaller.shared

    var body: some View {
        VStack(spacing: 18) {
            ChordekiLogo(height: 44)
            Text("ONE-TIME SETUP").font(.system(size: 11, weight: .heavy)).tracking(3).foregroundColor(Theme.dim)
            Text("CHORDEKI needs its AI engine to hear beats and chords.")
                .font(.system(size: 15, weight: .semibold))
            Text("One click installs everything: no Terminal, no Python knowledge needed.\nAbout 300 MB download. It runs on your Mac, your music never leaves it.")
                .font(.system(size: 12)).foregroundColor(Theme.dim)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

            switch installer.phase {
            case .working:
                VStack(alignment: .leading, spacing: 8) {
                    Text(installer.step).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundColor(Theme.accent)
                    BandProgress(fraction: installer.fraction, height: 6)
                    HStack {
                        Text(installer.detail).font(Theme.mono(10.5)).foregroundColor(Theme.dim).lineLimit(1)
                        Spacer()
                        Text("\(Int(installer.fraction * 100))%").font(Theme.mono(10.5)).foregroundColor(Theme.dim)
                    }
                    Text("This takes a few minutes. You can already add songs, they wait in the list.")
                        .font(.system(size: 10.5)).foregroundColor(Theme.dim)
                }
                .frame(width: 420)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).font(.system(size: 11)).foregroundColor(.orange)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    installButton("TRY AGAIN")
                }
                .frame(width: 420)
            case .idle, .done:
                installButton("INSTALL ENGINE")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func installButton(_ title: String) -> some View {
        Button { library.installEngine() } label: {
            HStack(spacing: 8) { Image(systemName: "arrow.down.circle.fill"); Text(title) }
                .font(.system(size: 13, weight: .heavy)).tracking(1)
                .foregroundColor(.white)
                .padding(.horizontal, 22).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.active))
                .shadow(color: Theme.active.opacity(0.6), radius: 10)
        }
        .buttonStyle(.plain)
    }
}

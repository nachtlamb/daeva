import AppKit
import Foundation
import Observation

struct SetupStep: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let ok: Bool
    let detail: String
    let can_run: Bool
    let open: String?
}

struct LaunchSettings: Codable, Equatable {
    var metal_hud = false
    var msync = false
    var cpuid_fix = true
    var loaddll = false
    var discord = true
}

private struct Status: Decodable {
    let steps: [SetupStep]
    let running: Bool
    let settings: LaunchSettings
    let art: [String: String]
}

private struct Line: Decodable {
    let progress: String?
    let error: String?
    let done: String?
}

enum PlayState: Equatable {
    case checking, needsSetup, ready, launching, playing
}

/// Talks to daeva-engine (the Python backend shipped inside the app) over JSON.
@MainActor @Observable
final class Backend {
    static let appID = "3393110"

    var steps: [SetupStep] = []
    var settings = LaunchSettings()
    var running = false
    var launching = false
    var busyStep: String?
    var progress: String?
    var lastError: String?
    var hero: NSImage?
    var logo: NSImage?
    var news: [NewsItem] = []

    private var artLoaded = false
    private var launchStarted: Date?
    private var runningSince: Date?
    private let presence = DiscordPresence()

    var state: PlayState {
        if steps.isEmpty { return .checking }
        if running { return .playing }
        if launching { return .launching }
        return steps.allSatisfy(\.ok) ? .ready : .needsSetup
    }

    var pending: [SetupStep] { steps.filter { !$0.ok } }

    // MARK: locating the backend

    private struct Runtime { let python: URL; let script: URL }

    private static let runtime: Runtime = {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let py = res.appending(path: "python/bin/python3")
            let script = res.appending(path: "daeva/bin/daeva-engine")
            if fm.isExecutableFile(atPath: py.path), fm.fileExists(atPath: script.path) {
                return Runtime(python: py, script: script)
            }
        }
        // dev checkout: gui/Sources/Daeva/Backend.swift -> repo root
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let py = candidates.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        return Runtime(python: URL(fileURLWithPath: py), script: repo.appending(path: "bin/daeva-engine"))
    }()

    private nonisolated static func call(_ args: [String], onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        let rt = await runtime
        let p = Process()
        p.executableURL = rt.python
        p.arguments = ["-I", rt.script.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        do {
            for try await line in out.fileHandleForReading.bytes.lines { onLine(line) }
        } catch {}
        p.waitUntilExit()
        return p.terminationStatus
    }

    private nonisolated static func json<T: Decodable>(_ args: [String], as: T.Type) async -> T? {
        let box = LineBox()
        _ = await call(args) { box.append($0) }
        guard let data = box.text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: actions

    func refresh() async {
        guard let s = await Self.json(["status"], as: Status.self) else {
            lastError = "Couldn't reach the Daeva engine."
            return
        }
        steps = s.steps
        settings = s.settings
        if s.running != running || (s.running && runningSince == nil) {
            runningSince = s.running ? Date() : nil
            await updatePresence()
        }
        running = s.running
        if running { launching = false }
        if launching, let t = launchStarted, Date().timeIntervalSince(t) > 90 { launching = false }
        if !artLoaded {
            artLoaded = true
            hero = s.art["hero"].flatMap(NSImage.init(contentsOfFile:))
            logo = s.art["logo"].flatMap(NSImage.init(contentsOfFile:))
        }
    }

    func loadNews() async {
        news = await News.fetch(appID: Self.appID)
    }

    private func updatePresence() async {
        if settings.discord, let since = runningSince {
            await presence.set(startedAt: since)
        } else {
            await presence.clear()
        }
    }

    func run(step: String, dmg: URL? = nil) async {
        busyStep = step
        lastError = nil
        var args = ["step", step]
        if let dmg { args += ["--dmg", dmg.path] }
        let sink = ProgressSink()
        let rc = await Self.call(args) { line in
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONDecoder().decode(Line.self, from: data) else { return }
            Task { @MainActor in sink.handle(msg, backend: self) }
        }
        if rc != 0, lastError == nil { lastError = "Step “\(step)” failed." }
        busyStep = nil
        progress = nil
        await refresh()
    }

    func setUp() async {
        for step in steps where !step.ok && step.can_run && step.id != "gptk" {
            await run(step: step.id)
            if lastError != nil { break }
        }
    }

    func update(_ s: LaunchSettings) async {
        settings = s
        let flags = [("metal_hud", s.metal_hud), ("msync", s.msync), ("cpuid_fix", s.cpuid_fix),
                     ("loaddll", s.loaddll), ("discord", s.discord)]
        _ = await Self.json(["settings"] + flags.flatMap { ["--set", "\($0.0)=\($0.1 ? "on" : "off")"] },
                            as: [String: LaunchSettings].self)
        await updatePresence()
    }

    func play() {
        launching = true
        launchStarted = Date()
        open("steam://rungameid/\(Self.appID)")
    }

    func stop() async {
        _ = await Self.call(["recover"]) { _ in }
        launching = false
        await refresh()
    }

    func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static let logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Daeva/logs")

    func latestLog() -> String {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.logsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.lastPathComponent.hasPrefix("aion2-") }
            .max { ($0.modDate ?? .distantPast) < ($1.modDate ?? .distantPast) }
        var text = (try? String(contentsOf: Self.logsDir.appending(path: "steam-run.log"), encoding: .utf8)) ?? ""
        if let newest, let game = try? String(contentsOf: newest, encoding: .utf8) {
            text += "\n── \(newest.lastPathComponent) ──\n" + game
        }
        return String(text.suffix(60_000))
    }
}

@MainActor
private final class ProgressSink {
    func handle(_ msg: Line, backend: Backend) {
        if let p = msg.progress { backend.progress = p }
        if let e = msg.error { backend.lastError = e }
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.withLock { lines.append(s) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

private extension URL {
    var modDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}

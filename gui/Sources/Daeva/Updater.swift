import AppKit
import CryptoKit
import Foundation
import Observation

/// Checks GitHub Releases for a newer Daeva and installs it in place.
///
/// The DMG is verified against the sha256 digest GitHub publishes for the asset and the
/// new bundle must carry the same identifier and pass codesign before it replaces this one.
@MainActor @Observable
final class Updater {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
    }

    enum Phase: Equatable { case idle, downloading(Double), installing, failed(String) }

    static let repo = Bundle.main.object(forInfoDictionaryKey: "DaevaUpdateRepo") as? String ?? ""
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var available: Release?
    var phase: Phase = .idle

    func check() async {
        guard !Self.repo.isEmpty, Bundle.main.bundleURL.pathExtension == "app",
              let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: data),
              rel.dmg != nil, Self.isNewer(rel.version, than: Self.current) else { return }
        available = rel
    }

    func install() async {
        guard let rel = available, let asset = rel.dmg else { return }
        do {
            phase = .downloading(0)
            let dmg = try await download(asset)
            phase = .installing
            let staged = try stage(dmg)
            try relaunch(replacingWith: staged)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: steps

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func download(_ asset: Release.Asset) async throws -> URL {
        let (bytes, resp) = try await URLSession.shared.bytes(from: asset.browser_download_url)
        let total = Double(resp.expectedContentLength)
        let dst = FileManager.default.temporaryDirectory.appending(path: "Daeva-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        var hash = SHA256()
        var buf = Data(capacity: 1 << 20)
        var done = 0.0
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 20 {
                hash.update(data: buf); try out.write(contentsOf: buf)
                done += Double(buf.count); buf.removeAll(keepingCapacity: true)
                if total > 0 { phase = .downloading(done / total) }
            }
        }
        hash.update(data: buf); try out.write(contentsOf: buf)
        let got = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard let want = asset.digest?.replacingOccurrences(of: "sha256:", with: ""), want == got else {
            throw Failure("The update didn't match its published checksum.")
        }
        return dst
    }

    /// Mounts the DMG, copies Daeva.app next to the running app and checks it.
    private func stage(_ dmg: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appending(path: "Daeva-mnt-\(UUID().uuidString)")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            try? FileManager.default.removeItem(at: dmg)
        }
        let src = mount.appending(path: "Daeva.app")
        let staged = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: ".Daeva-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [src.path, staged.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", staged.path])
        let id = Bundle(url: staged)?.bundleIdentifier
        guard id == Bundle.main.bundleIdentifier else {
            try? FileManager.default.removeItem(at: staged)
            throw Failure("The update isn't a Daeva build.")
        }
        return staged
    }

    /// Hands off to a tiny shell script that swaps the bundles once we've quit.
    private func relaunch(replacingWith staged: URL) throws {
        let app = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(app).old" && mv "\(app)" "\(app).old" && mv "\(staged.path)" "\(app)" && rm -rf "\(app).old"
        open "\(app)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\((tool as NSString).lastPathComponent) failed") }
        return p.terminationStatus
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

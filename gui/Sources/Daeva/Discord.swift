import Foundation

/// Minimal Discord RPC client over the local IPC socket.
///
/// Frames are `opcode:u32le, length:u32le, json`. Opcode 0 is the handshake, 1 a command.
/// The client ID comes from `DiscordClientID` in Info.plist; without one presence is off.
actor DiscordPresence {
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "DiscordClientID") as? String
        ?? ProcessInfo.processInfo.environment["DAEVA_DISCORD_CLIENT_ID"] ?? ""
    static var available: Bool { !clientID.isEmpty }

    private var fd: Int32 = -1

    @discardableResult
    func set(startedAt: Date?) -> Bool {
        guard Self.available else { return false }
        if fd < 0, !connect() { return false }
        var args: [String: Any] = ["pid": Int(getpid())]
        if let startedAt {
            args["activity"] = [
                "timestamps": ["start": Int(startedAt.timeIntervalSince1970)],
                "assets": ["large_image": "https://cdn.cloudflare.steamstatic.com/steam/apps/3393110/header.jpg",
                           "large_text": "AION 2"],
            ]
        }
        let ok = send(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString])
        if !ok { close() }
        return ok
    }

    func clear() { set(startedAt: nil) }

    private func connect() -> Bool {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        for i in 0..<10 {
            let path = (tmp as NSString).appendingPathComponent("discord-ipc-\(i)")
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { return false }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(s); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc == 0 {
                fd = s
                var one: Int32 = 1
                setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if send(op: 0, ["v": 1, "client_id": Self.clientID]), readFrame() { return true }
                close()
                return false
            }
            Darwin.close(s)
        }
        return false
    }

    private func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    private func send(op: UInt32, _ payload: [String: Any]) -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, frame.count) }
        return n == frame.count && (op != 1 || readFrame())
    }

    /// Reads and discards one reply frame (READY or the command response).
    private func readFrame() -> Bool {
        var header = [UInt8](repeating: 0, count: 8)
        guard Darwin.read(fd, &header, 8) == 8 else { return false }
        let len = Int(UInt32(header[4]) | UInt32(header[5]) << 8 | UInt32(header[6]) << 16 | UInt32(header[7]) << 24)
        var body = [UInt8](repeating: 0, count: len)
        var got = 0
        while got < len {
            let n = body.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, len - got) }
            if n <= 0 { return false }
            got += n
        }
        return true
    }
}

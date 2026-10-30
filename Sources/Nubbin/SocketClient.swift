import Foundation

/// Sends one JSON message to `Paths.socket` and optionally waits for a reply. Shared by `Nubbin hook`
/// (long timeout: Claude Code waits on a permission decision) and `Nubbin ctl` (short timeout).
enum SocketClient {
    static func send(_ data: Data, awaitReply: Bool, timeout: TimeInterval) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var sendTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))

        guard var addr = unixAddress(Paths.socket.path) else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let sent = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        guard sent, awaitReply else { return nil }

        // Signal end of message, then wait for the answer.
        shutdown(fd, SHUT_WR)
        var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
        }
        return reply.isEmpty ? nil : reply
    }
}

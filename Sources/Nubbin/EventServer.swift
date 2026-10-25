import Foundation

/// Accepts one JSON message per connection on `Paths.socket`: the client writes, then shuts down its write side.
/// Messages with `"await": true` keep the connection open until `reply(_:_:)` answers on it
/// (used to approve or deny a Claude Code permission request from the notch).
final class EventServer: @unchecked Sendable {
    typealias Token = Int32

    private let queue = DispatchQueue(label: "nubbin.events")
    private let onMessage: @Sendable (Data, Token?) -> Void
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    /// Connections waiting for a reply, keyed by their file descriptor. Only touched on `queue`.
    private var held: Set<Int32> = []

    init(onMessage: @escaping @Sendable (Data, Token?) -> Void) {
        self.onMessage = onMessage
    }

    func start() throws {
        try FileManager.default.createDirectory(at: Paths.supportDir, withIntermediateDirectories: true)
        let path = Paths.socket.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard var addr = unixAddress(path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        queue.sync {
            for fd in held { close(fd) }
            held.removeAll()
        }
        if listenFD >= 0 { close(listenFD) }
        unlink(Paths.socket.path)
    }

    /// Answer a held connection and close it. Unknown or already-answered tokens are ignored.
    func reply(_ token: Token, _ data: Data) {
        queue.async { [self] in
            guard held.remove(token) != nil else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(token, base + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
            close(token)
        }
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit O_NONBLOCK on Darwin; read blocking with a short timeout instead.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while data.count < 4 << 20 {
                let count = read(client, &buffer, buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            guard !data.isEmpty else { close(client); continue }

            let wantsReply = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["await"] as? Bool == true
            if wantsReply {
                held.insert(client)
                onMessage(data, client)
            } else {
                close(client)
                onMessage(data, nil)
            }
        }
    }
}

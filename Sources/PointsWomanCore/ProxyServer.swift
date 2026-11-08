import Foundation
import Darwin

public struct ProxyStatistics: Sendable {
    public init() {}
    public var accepted = 0
    public var connected = 0
    public var rejected = 0
    public var failed = 0
    public var active = 0
    public var lastEvent = "Idle. Bypass has not been verified."
}

public final class ProxyServer: @unchecked Sendable {
    public let configuration: Configuration
    public let allowsAllDomains: Bool
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var running = false
    private var clients: Set<Int32> = []
    private var stats = ProxyStatistics()
    private let workers = DispatchQueue(label: "PointsWoman.connections", attributes: .concurrent)
    public private(set) var boundPort: UInt16 = 0
    private let capacity = DispatchSemaphore(value: 64)

    public init(configuration: Configuration, allowsAllDomains: Bool = false) {
        self.configuration = configuration; self.allowsAllDomains = allowsAllDomains
    }
    public var statistics: ProxyStatistics { lock.withLock { stats } }
    private func event(_ text: String, failed: Bool = false, rejected: Bool = false, connected: Bool = false) {
        lock.withLock {
            stats.lastEvent = text
            if failed { stats.failed += 1 }
            if rejected { stats.rejected += 1 }
            if connected { stats.connected += 1 }
        }
    }

    public func start() throws {
        try configuration.validate()
        guard if_nametoindex(configuration.interface) != 0 else { throw PWError.message("Interface \(configuration.interface) does not exist.") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("Create listener") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 64) == 0 else { let e = socketError("Listen on 127.0.0.1:\(configuration.port)"); close(fd); throw e }
        let started = lock.withLock { () -> Bool in
            guard !running else { return false }
            listener = fd; running = true; boundPort = configuration.port
            return true
        }
        guard started else { close(fd); throw PWError.message("Proxy is already running.") }
        DispatchQueue.global(qos: .utility).async { [self] in acceptLoop(fd) }
    }

    public func stop() {
        let (fd, clientList) = lock.withLock { () -> (Int32, [Int32]) in
            guard running else { return (-1, []) }
            running = false
            let listenerFd = listener
            listener = -1
            let activeClients = Array(clients)
            return (listenerFd, activeClients)
        }
        guard fd >= 0 else { return }
        for client in clientList {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        close(fd)
    }

    private func acceptLoop(_ fd: Int32) {
        defer {
            lock.withLock {
                if listener == fd {
                    close(fd)
                    listener = -1
                }
            }
        }
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ret = poll(&pfd, 1, 200)
            if ret < 0 {
                if errno == EINTR { continue }
                break
            }
            guard lock.withLock({ running }) else { break }
            guard ret > 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == ECONNRESET || errno == EWOULDBLOCK || errno == EAGAIN {
                    continue
                }
                break
            }
            guard lock.withLock({ running }) else {
                close(client)
                break
            }
            guard capacity.wait(timeout: .now()) == .success else {
                respond(client, status: "503 Service Unavailable", text: "Too many active connections.")
                close(client)
                continue
            }
            let admitted = lock.withLock { () -> Bool in
                guard running else { return false }
                clients.insert(client); stats.accepted += 1; stats.active += 1
                return true
            }
            guard admitted else { close(client); capacity.signal(); break }
            workers.async { [self] in
                defer {
                    lock.withLock { clients.remove(client); stats.active -= 1; close(client) }
                    capacity.signal()
                }
                handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        configure(client, timeout: 15)
        var input = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let delimiter = Data("\r\n\r\n".utf8)
        var headerRange: Range<Data.Index>?
        let deadline = Date().addingTimeInterval(15)
        while headerRange == nil {
            guard Date() < deadline else { respond(client, status: "408 Request Timeout", text: "Header timeout."); return }
            let count = recv(client, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { trace("header recv fd=\(client) count=\(count) errno=\(errno)"); return }
            input.append(contentsOf: buffer.prefix(count))
            headerRange = input.range(of: delimiter)
            if (headerRange?.upperBound ?? input.count) > 65536 {
                respond(client, status: "431 Request Header Fields Too Large", text: "Header limit is 64 KiB."); return
            }
        }
        guard let end = headerRange?.upperBound else { return }
        let header = Data(input[..<end]), initial = Data(input[end...])
        let line = String(data: header, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
        if line == "GET /proxy.pac HTTP/1.1" || line == "GET /proxy.pac HTTP/1.0" {
            respond(client, status: "200 OK", text: configuration.pac(), type: "application/x-ns-proxy-autoconfig"); return
        }
        if line == "GET /health HTTP/1.1" || line == "GET /health HTTP/1.0" {
            respond(client, status: "200 OK", text: "PointsWoman running; interface=\(configuration.interface); scope=\(allowsAllDomains ? "applications" : "domains"). Connection success does not prove VPN bypass.\n"); return
        }
        let request: ProxyRequest
        do { request = try ProxyRequest.parse(header) }
        catch { respond(client, status: "400 Bad Request", text: error.localizedDescription); return }
        guard allowsAllDomains || configuration.allows(request.host) else {
            event("Rejected an unlisted destination.", rejected: true)
            respond(client, status: "403 Forbidden", text: "Domain is not in PointsWoman's bypass list."); return
        }
        var upstream: Int32 = -1
        do {
            upstream = try connectBound(host: request.host, port: request.port)
            defer { close(upstream) }
            event("Connected to \(request.host) through socket bound to \(configuration.interface); egress unverified.", connected: true)
            configure(client, timeout: 30)
            configure(upstream, timeout: 30)
            if request.tunnel {
                guard sendAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }
            } else {
                guard sendAll(upstream, request.forwardedHeader) else {
                    event("Upstream closed before request could be sent.", failed: true)
                    respond(client, status: "502 Bad Gateway", text: "Destination closed the connection before accepting the request.")
                    return
                }
            }
            guard initial.isEmpty || sendAll(upstream, initial) else { return }
            relay(client, upstream, tunnel: request.tunnel)
        } catch {
            event("\(request.host): \(error.localizedDescription)", failed: true)
            respond(client, status: "502 Bad Gateway", text: "Direct connection failed. No alternate interface was used. \(error.localizedDescription)")
        }
    }

    private func connectBound(host: String, port: UInt16) throws -> Int32 {
        let index = if_nametoindex(configuration.interface)
        guard index != 0 else { throw PWError.message("Selected interface is unavailable.") }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let resolution = getaddrinfo(host, String(port), &hints, &result)
        guard resolution == 0 else { throw PWError.message("System DNS failed: \(String(cString: gai_strerror(resolution))).") }
        defer { freeaddrinfo(result) }
        let deadline = Date().addingTimeInterval(12)
        var item = result
        var lastError = "No usable address."
        while let address = item {
            defer { item = address.pointee.ai_next }
            guard Date() < deadline else { break }
            let ai = address.pointee
            guard ai.ai_family == AF_INET || ai.ai_family == AF_INET6 else { continue }
            let fd = socket(ai.ai_family, SOCK_STREAM, IPPROTO_TCP)
            if fd < 0 { lastError = String(cString: strerror(errno)); continue }
            configure(fd, timeout: 30)
            var interfaceIndex = index
            let level = ai.ai_family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6
            let option = ai.ai_family == AF_INET ? IP_BOUND_IF : IPV6_BOUND_IF
            guard setsockopt(fd, level, option, &interfaceIndex, socklen_t(MemoryLayout.size(ofValue: interfaceIndex))) == 0 else {
                lastError = "Interface binding failed: \(String(cString: strerror(errno)))"; close(fd); continue
            }
            let oldFlags = fcntl(fd, F_GETFL)
            guard oldFlags >= 0, fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) == 0 else { close(fd); continue }
            let outcome = connect(fd, ai.ai_addr, ai.ai_addrlen)
            var connected = outcome == 0
            if !connected && errno == EINPROGRESS {
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(max(1, min(4000, deadline.timeIntervalSinceNow * 1000)))
                if poll(&descriptor, 1, milliseconds) > 0 {
                    var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                    connected = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
                    if !connected { lastError = String(cString: strerror(error)) }
                } else { lastError = "Connection timed out." }
            } else if !connected { lastError = String(cString: strerror(errno)) }
            if connected {
                guard fcntl(fd, F_SETFL, oldFlags) == 0 else { close(fd); continue }
                return fd
            }
            close(fd)
        }
        throw PWError.message(lastError)
    }

    private func relay(_ a: Int32, _ b: Int32, tunnel: Bool) {
        var descriptors = [pollfd(fd: a, events: Int16(POLLIN), revents: 0), pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
        var open = [true, true]
        var receivedResponse = false
        var bytes = [UInt8](repeating: 0, count: 32768)
        while open.contains(true) && lock.withLock({ running }) {
            let n = poll(&descriptors, 2, 300_000)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { trace("relay poll fd=\(a),\(b) result=\(n) errno=\(errno)"); return }
            for i in 0...1 where open[i] && descriptors[i].revents != 0 {
                let source = i == 0 ? a : b, target = i == 0 ? b : a
                let count = recv(source, &bytes, bytes.count, 0)
                trace("relay recv fd=\(source) count=\(count) events=\(descriptors[i].revents) errno=\(errno)")
                if count <= 0 {
                    if count < 0 && errno == EINTR { continue }
                    if i == 1 && !receivedResponse && !tunnel {
                        event("Destination closed without an HTTP response.", failed: true)
                        respond(a, status: "502 Bad Gateway", text: "Destination closed without an HTTP response.")
                        return
                    }
                    open[i] = false; descriptors[i].fd = -1; shutdown(target, SHUT_WR)
                } else {
                    if i == 1 { receivedResponse = true }
                    if !sendAll(target, Data(bytes.prefix(count))) { trace("relay send fd=\(target) failed errno=\(errno)"); return }
                }
            }
        }
    }

    private func respond(_ fd: Int32, status: String, text: String, type: String = "text/plain; charset=utf-8") {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        _ = sendAll(fd, Data(header.utf8) + body)
    }
}

private func trace(_ message: String) {
    guard ProcessInfo.processInfo.environment["POINTSWOMAN_TRACE"] == "1" else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func socketError(_ operation: String) -> PWError { .message("\(operation): \(String(cString: strerror(errno)))") }
private func configure(_ fd: Int32, timeout: Int) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    var value = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
}
@discardableResult
private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return true }
        var offset = 0
        while offset < data.count {
            let count = send(fd, base.advanced(by: offset), data.count - offset, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

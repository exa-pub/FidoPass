import Foundation
import Darwin

/// `lock` guards process state and the outstanding request; `writes` serializes frames,
/// including touch grants sent while a request is waiting. `presence` guards touch events.
/// Nonblocking pipes enforce deadlines; payloads are never logged.
package final class OpenSKHostClient: @unchecked Sendable {
    package enum Operation: UInt8 {
        case initialize = 0
        case ctap = 1
        case powerCycle = 2
        case advanceClock = 3
        case configurePresence = 4
        case prepareLegacy = 5
        case hid = 6
        case hang = 7
        case grantTouch = 9
        case waitingForTouch = 0x80
    }

    package enum Profile: UInt8 {
        case standard = 0
        case enterprise = 1
        case twoSlots = 2
        case smallBlob = 3
    }

    package enum Presence: UInt8 {
        case immediate = 0
        case timeout = 1
        case declined = 2
        case controlled = 3
    }

    private enum LegacyFixture: UInt8 {
        case local = 0
        case portable = 1
        case displayPayload = 2
    }

    package static var executable: URL {
        if let override = ProcessInfo.processInfo.environment["FIDOPASS_TEST_AUTHENTICATOR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/test-authenticator/target/debug/fidopass-test-authenticator")
    }
    private let lock = NSLock()
    private let writes = NSLock()
    private let presence = NSCondition()
    private var touches = 0
    private var processID: pid_t = 0
    private let input = Pipe()
    private let output = Pipe()
    private var sequence: UInt64 = 0
    private var pending: Data?
    private var stopped = false
    private var started = false
    private static let version: UInt8 = 1
    private static let headerSize = 2 + MemoryLayout<UInt64>.size
    private static let maximumFrame = 65_536

    private static func header(operation: Operation, requestID: UInt64) -> Data {
        var result = Data([version, operation.rawValue])
        result.append(contentsOf: withUnsafeBytes(of: requestID.bigEndian, Array.init))
        return result
    }

    private static func frame(header: Data, payload: Data = Data()) -> Data {
        let length = UInt32(header.count + payload.count).bigEndian
        return Data(withUnsafeBytes(of: length, Array.init)) + header + payload
    }

    package init(seed: UInt8, profile: Profile = .standard) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.executable.path) else { throw TestTransportError.helperMissing }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw TestTransportError.protocolViolation }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let redirects: [(Int32, Int32)] = [
            (input.fileHandleForReading.fileDescriptor, STDIN_FILENO),
            (output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        ]
        for (source, target) in redirects {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw TestTransportError.protocolViolation }
        }
        for fd in [input.fileHandleForReading.fileDescriptor, input.fileHandleForWriting.fileDescriptor,
                   output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor] where fd > 2 {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw TestTransportError.protocolViolation }
        }
        guard posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { throw TestTransportError.protocolViolation }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw TestTransportError.protocolViolation }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw TestTransportError.protocolViolation }
        guard let argument = strdup(Self.executable.path) else { throw TestTransportError.protocolViolation }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        // The helper needs no inherited environment, credentials or user configuration.
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let rc = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&processID, argument, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard rc == 0 else { throw TestTransportError.disconnected }
        started = true
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                stop()
                throw TestTransportError.protocolViolation
            }
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try begin(operation: .initialize, payload: Data(repeating: seed, count: 32) + Data([profile.rawValue]))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    deinit { stop() }

    package func begin(operation: Operation = .ctap, payload: Data) throws {
        try lock.withLock {
            guard !stopped, started, kill(processID, 0) == 0 else { throw TestTransportError.disconnected }
            guard pending == nil else { throw TestTransportError.busy }
            guard payload.count <= Self.maximumFrame - Self.headerSize else { throw TestTransportError.protocolViolation }
            sequence += 1
            let header = Self.header(operation: operation, requestID: sequence)
            let frame = Self.frame(header: header, payload: payload)
            pending = header
            do {
                try writes.withLock { try write(frame, deadline: deadline(milliseconds: 5_000)) }
            } catch {
                stopLocked()
                throw error
            }
        }
    }

    package func finish(timeoutMilliseconds: Int) throws -> Data {
        try lock.withLock {
            guard let header = pending, !stopped else { throw TestTransportError.disconnected }
            do {
                let end = deadline(milliseconds: timeoutMilliseconds)
                while true {
                    let lengthData = try read(count: 4, deadline: end)
                    let count = lengthData.reduce(0) { ($0 << 8) | Int($1) }
                    guard (Self.headerSize...Self.maximumFrame).contains(count) else { throw TestTransportError.protocolViolation }
                    let frame = try read(count: count, deadline: end)
                    if frame == Self.header(operation: .waitingForTouch, requestID: 0) {
                        presence.lock()
                        touches += 1
                        presence.broadcast()
                        presence.unlock()
                        continue
                    }
                    guard frame.prefix(Self.headerSize) == header else { throw TestTransportError.protocolViolation }
                    pending = nil
                    return Data(frame.dropFirst(Self.headerSize))
                }
            } catch {
                stopLocked()
                throw error
            }
        }
    }

    package var touchCount: Int { presence.withLock { touches } }

    package func waitForTouch(after count: Int = 0, timeout: TimeInterval = 3) -> Bool {
        presence.lock()
        defer { presence.unlock() }
        let end = Date().addingTimeInterval(timeout)
        while touches <= count {
            if !presence.wait(until: end) { return false }
        }
        return true
    }

    package func grantTouch() throws {
        let frame = Self.frame(header: Self.header(operation: .grantTouch, requestID: 0))
        try writes.withLock { try write(frame, deadline: deadline(milliseconds: 1_000)) }
    }

    package func configurePresence(_ mode: Presence) throws {
        try begin(operation: .configurePresence, payload: Data([mode.rawValue]))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func prepareLegacy(portable: Bool, displayPayload: Bool = false) throws {
        let fixture: LegacyFixture = displayPayload ? .displayPayload : (portable ? .portable : .local)
        try begin(operation: .prepareLegacy, payload: Data([fixture.rawValue]))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func powerCycle() throws {
        try begin(operation: .powerCycle, payload: Data())
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func advanceClock(milliseconds: UInt64) throws {
        try begin(operation: .advanceClock, payload: Data(withUnsafeBytes(of: milliseconds.bigEndian, Array.init)))
        _ = try finish(timeoutMilliseconds: 5_000)
    }

    package func stop() { lock.withLock { stopLocked() } }

    private func stopLocked() {
        guard !stopped else { return }
        stopped = true
        pending = nil
        if started { kill(processID, SIGKILL) }
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        if started {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
        }
    }

    private func deadline(milliseconds: Int) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(milliseconds, 35_000))) * 1_000_000
    }

    private func wait(_ fd: Int32, event: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw TestTransportError.deadlineExceeded }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let remaining = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            let result = poll(&descriptor, 1, remaining)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw TestTransportError.deadlineExceeded }
            guard descriptor.revents & event != 0 else { throw TestTransportError.disconnected }
            return
        }
    }

    private func write(_ data: Data, deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let fd = input.fileHandleForWriting.fileDescriptor
                try wait(fd, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw TestTransportError.disconnected }
                offset += count
            }
        }
    }

    private func read(count: Int, deadline: UInt64) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let fd = output.fileHandleForReading.fileDescriptor
                try wait(fd, event: Int16(POLLIN), deadline: deadline)
                let received = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard received > 0 else { throw TestTransportError.disconnected }
                offset += received
            }
        }
        return data
    }
}

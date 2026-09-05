import Foundation
import Darwin

/// `condition` guards request/event state; `writes` serializes frames and input closure.
/// Only the reader touches output. `termination` owns kill/reap; it never waits for CTAP.
final class OpenSKPipeSession: @unchecked Sendable {
    private let condition = NSCondition()
    private let writes = NSLock()
    private let termination = NSLock()
    private let input = Pipe()
    private let output = Pipe()
    private var processID: pid_t = 0
    private var started = false
    private var reaped = false
    private var stopped = false
    private var disconnected = false
    private var sequence: UInt64 = 0
    private var pending: Data?
    private var reply: Data?
    private var touch: OpenSKHostClient.Touch?
    private var touches = 0
    private var failure: VirtualKeyError?
    private var observer: (@Sendable () -> Void)?
    private static let version: UInt8 = 2
    private static let headerSize = 10
    private static let maximumFrame = 65_536

    init(executable: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw VirtualKeyError.helperMissing }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw VirtualKeyError.protocolViolation }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let redirects: [(Int32, Int32)] = [
            (input.fileHandleForReading.fileDescriptor, STDIN_FILENO),
            (output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        ]
        for (source, target) in redirects {
            guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else { throw VirtualKeyError.protocolViolation }
        }
        for fd in [input.fileHandleForReading.fileDescriptor, input.fileHandleForWriting.fileDescriptor,
                   output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor] where fd > 2 {
            guard posix_spawn_file_actions_addclose(&actions, fd) == 0 else { throw VirtualKeyError.protocolViolation }
        }
        guard posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else { throw VirtualKeyError.protocolViolation }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw VirtualKeyError.protocolViolation }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw VirtualKeyError.protocolViolation }
        guard let argument = strdup(executable.path) else { throw VirtualKeyError.protocolViolation }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        // The helper needs no inherited environment, credentials or user configuration.
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let rc = arguments.withUnsafeMutableBufferPointer { argv in
            environment.withUnsafeMutableBufferPointer { envp in
                posix_spawn(&processID, argument, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        guard rc == 0 else { throw VirtualKeyError.disconnected }
        started = true
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        for fd in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                stop()
                throw VirtualKeyError.protocolViolation
            }
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // The host owns this session and stops it in deinit; the reader does not retain the host.
        Thread.detachNewThread { [self] in readLoop() }
    }

    var state: OpenSKHostClient.State {
        condition.withLock { .init(touch: touch, touchCount: touches, failure: failure) }
    }

    func observe(_ callback: (@Sendable () -> Void)?) {
        condition.withLock { observer = callback }
    }

    func begin(operation: OpenSKHostClient.Operation, payload: Data) throws {
        guard payload.count <= Self.maximumFrame - Self.headerSize else { throw VirtualKeyError.protocolViolation }
        let header = try condition.withLock {
            guard !stopped else { throw failure ?? .disconnected }
            guard !disconnected || operation == .powerCycle else { throw VirtualKeyError.disconnected }
            guard pending == nil else { throw VirtualKeyError.busy }
            sequence += 1
            let header = Self.header(operation: operation, requestID: sequence)
            pending = header
            reply = nil
            return header
        }
        do { try send(header: header, payload: payload) }
        catch { stop(reason: .disconnected); throw error }
    }

    func finish(timeoutMilliseconds: Int) throws -> Data {
        let end = Self.deadline(milliseconds: timeoutMilliseconds)
        condition.lock()
        while !stopped, pending != nil, reply == nil, DispatchTime.now().uptimeNanoseconds < end {
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        if let reply, !stopped {
            if pending?[1] == OpenSKHostClient.Operation.powerCycle.rawValue { disconnected = false }
            self.reply = nil
            pending = nil
            condition.broadcast()
            condition.unlock()
            return reply
        }
        let error = failure ?? (pending == nil ? .protocolViolation : .deadlineExceeded)
        condition.unlock()
        stop(reason: error)
        throw error
    }

    func waitForTouch(after count: Int, timeout: TimeInterval) -> Bool {
        let end = Self.deadline(milliseconds: Int(max(0, min(timeout, 35)) * 1_000))
        condition.lock()
        defer { condition.unlock() }
        while !stopped, touches <= count, DispatchTime.now().uptimeNanoseconds < end {
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        return !stopped && touches > count
    }

    func control(operation: OpenSKHostClient.Operation, requestID: UInt64, payload: Data) throws {
        if operation == .disconnect { condition.withLock { disconnected = true } }
        do { try send(header: Self.header(operation: operation, requestID: requestID), payload: payload) }
        catch { stop(reason: .disconnected); throw error }
    }

    func stop(reason: VirtualKeyError = .disconnected) {
        let notify: (@Sendable () -> Void)? = condition.withLock {
            guard !stopped else { return nil }
            stopped = true
            failure = reason
            touch = nil
            pending = nil
            reply = nil
            condition.broadcast()
            return observer
        }
        termination.withLock {
            guard started, !reaped else { return }
            // Marked stopped first: an outstanding write exits its short poll promptly.
            kill(processID, SIGKILL)
            writes.withLock { input.fileHandleForWriting.closeFile() }
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
            reaped = true
        }
        notify?()
    }

    private static func header(operation: OpenSKHostClient.Operation, requestID: UInt64) -> Data {
        Data([version, operation.rawValue]) + Data(withUnsafeBytes(of: requestID.bigEndian, Array.init))
    }

    private static func integer(_ bytes: Data) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func deadline(milliseconds: Int) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, min(milliseconds, 35_000))) * 1_000_000
    }

    private func send(header: Data, payload: Data) throws {
        let length = UInt32(header.count + payload.count).bigEndian
        let frame = Data(withUnsafeBytes(of: length, Array.init)) + header + payload
        try writes.withLock {
            guard condition.withLock({ !stopped }) else { throw VirtualKeyError.disconnected }
            let end = Self.deadline(milliseconds: 1_000)
            try frame.withUnsafeBytes { bytes in
                var offset = 0
                while offset < frame.count {
                    let fd = input.fileHandleForWriting.fileDescriptor
                    try wait(fd, event: Int16(POLLOUT), deadline: end)
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    guard count > 0 else { throw VirtualKeyError.disconnected }
                    offset += count
                }
            }
        }
    }

    private func wait(_ fd: Int32, event: Int16, deadline: UInt64?) throws {
        while true {
            guard condition.withLock({ !stopped }) else { throw VirtualKeyError.disconnected }
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { throw VirtualKeyError.deadlineExceeded }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, deadline == nil ? -1 : 20)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw VirtualKeyError.disconnected }
            if result == 0 { continue }
            guard descriptor.revents & event != 0 else { throw VirtualKeyError.disconnected }
            return
        }
    }

    private func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let fd = output.fileHandleForReading.fileDescriptor
                try wait(fd, event: Int16(POLLIN), deadline: nil)
                let received = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard received > 0 else { throw VirtualKeyError.disconnected }
                offset += received
            }
        }
        return data
    }

    private func readLoop() {
        defer { output.fileHandleForReading.closeFile() }
        do {
            while true {
                let count = Int(Self.integer(try read(count: 4)))
                guard (Self.headerSize...Self.maximumFrame).contains(count) else { throw VirtualKeyError.protocolViolation }
                let frame = try read(count: count)
                let notify = try condition.withLock { () throws -> (@Sendable () -> Void)? in
                    guard !stopped else { return nil }
                    guard frame.first == Self.version, let pending, reply == nil else { throw VirtualKeyError.protocolViolation }
                    let requestID = Self.integer(frame.subdata(in: 2..<10))
                    guard requestID == Self.integer(pending.subdata(in: 2..<10)) else { throw VirtualKeyError.protocolViolation }
                    switch frame[1] {
                    case OpenSKHostClient.Operation.waitingForTouch.rawValue:
                        guard frame.count == 18, touch == nil else { throw VirtualKeyError.protocolViolation }
                        touch = .init(requestID: requestID, id: Self.integer(frame.subdata(in: 10..<18)))
                        touches += 1
                    case OpenSKHostClient.Operation.touchFinished.rawValue:
                        guard frame.count == 18, touch == .init(requestID: requestID, id: Self.integer(frame.subdata(in: 10..<18))) else {
                            throw VirtualKeyError.protocolViolation
                        }
                        touch = nil
                    default:
                        guard frame.prefix(Self.headerSize) == pending, touch == nil else { throw VirtualKeyError.protocolViolation }
                        reply = Data(frame.dropFirst(Self.headerSize))
                    }
                    condition.broadcast()
                    return observer
                }
                notify?()
            }
        } catch {
            stop(reason: (error as? VirtualKeyError) ?? .protocolViolation)
        }
    }
}

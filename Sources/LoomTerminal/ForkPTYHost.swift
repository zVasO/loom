import LoomCore
import Darwin
import Dispatch
import Foundation
import SwiftTerm

/// Production adapter for the PTY seam: `forkpty` + `DispatchIO` + `NOTE_EXIT`.
/// Every pitfall encoded here is documented by the research (swiftterm-pty.md §3):
/// exit handler installed BEFORE `activate()`, fd closed only through the DispatchIO
/// `cleanupHandler` (never a direct close() — EV_VANISHED crash), EOF and exit
/// emitted as two distinct events with no ordering guarantee.
public struct ForkPTYHost: PTYHost {

    public init() {}

    public func open(command: Command,
                     workingDirectory: URL,
                     environment: [String: String],
                     geometry: TerminalGeometry,
                     deliveringOn queue: DispatchQueue,
                     sink: @escaping @Sendable (PTYEvent) -> Void) throws -> any PTYChannel {
        var windowSize = winsize(ws_row: UInt16(geometry.rows), ws_col: UInt16(geometry.cols),
                                 ws_xpixel: 0, ws_ypixel: 0)
        let argv = [command.executable] + command.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        guard let child = PseudoTerminalHelpers.fork(andExec: command.executable,
                                                     args: argv,
                                                     env: envp,
                                                     currentDirectory: workingDirectory.path,
                                                     desiredWindowSize: &windowSize) else {
            throw ForkPTYError.forkFailed(executable: command.executable)
        }
        return ForkPTYChannel(pid: child.pid, masterDescriptor: child.masterFd,
                              queue: queue, sink: sink)
    }
}

public enum ForkPTYError: Error, Sendable {
    case forkFailed(executable: String)
}

final class ForkPTYChannel: PTYChannel, @unchecked Sendable {

    private let pid: pid_t
    private let masterDescriptor: Int32
    private let queue: DispatchQueue
    private let io: DispatchIO
    private let exitSource: DispatchSourceProcess
    /// Confined to `queue`: after closing, no event ever reaches the sink again.
    private var isClosed = false
    private var sink: (@Sendable (PTYEvent) -> Void)?

    init(pid: pid_t, masterDescriptor: Int32, queue: DispatchQueue,
         sink: @escaping @Sendable (PTYEvent) -> Void) {
        self.pid = pid
        self.masterDescriptor = masterDescriptor
        self.queue = queue
        self.sink = sink
        // The fd is closed ONLY by the cleanupHandler (research §3.5).
        self.io = DispatchIO(type: .stream, fileDescriptor: masterDescriptor, queue: queue,
                             cleanupHandler: { _ in Darwin.close(masterDescriptor) })
        self.exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)

        io.setLimit(lowWater: 1)
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, _ in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.sink?(.bytes(Array(data)))
            }
            if done {
                self.sink?(.endOfFile)
            }
        }

        // Handler installed BEFORE activate(): a child that exits immediately
        // still gets reaped (research §3.5).
        exitSource.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            let exited = (status & 0x7f) == 0
            let exitStatus = exited
                ? ExitStatus(code: (status >> 8) & 0xff)
                : ExitStatus(code: nil, signal: status & 0x7f)
            self.sink?(.terminated(exitStatus))
        }
        exitSource.activate()
    }

    func write(_ bytes: ArraySlice<UInt8>) {
        let data = Array(bytes).withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: data, queue: queue) { _, _, _ in }
    }

    func resize(to geometry: TerminalGeometry) {
        var windowSize = winsize(ws_row: UInt16(geometry.rows), ws_col: UInt16(geometry.cols),
                                 ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterDescriptor,
                                             windowSize: &windowSize)
    }

    func signal(_ signal: PTYSignal, scope: PTYSignalScope) {
        let number: Int32 = switch signal {
        case .interrupt: SIGINT
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
        // forkpty made the child a session leader: its pgid is its pid.
        switch scope {
        case .process: kill(pid, number)
        case .group: kill(-pid, number)
        }
    }

    func close() {
        queue.async {
            guard !self.isClosed else { return }
            self.isClosed = true
            self.sink = nil
            self.exitSource.cancel()
            self.io.close(flags: .stop)
        }
    }

    var capabilities: PTYCapabilities { [.signals, .cpuSampling] }
    var processGroup: pid_t? { pid }

    func cpuFraction() -> Double {
        // Will feed the STA-02 heuristic via proc_pid_rusage — upcoming slice along
        // with the sampler; 0 = "no CPU signal", never a false signal.
        0
    }
}

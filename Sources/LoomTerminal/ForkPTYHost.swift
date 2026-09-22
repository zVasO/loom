import LoomCore
import Darwin
import Dispatch
import Foundation
import SwiftTerm
import os

/// Production adapter for the PTY seam: `forkpty` + `DispatchIO` + `NOTE_EXIT`.
/// Every pitfall encoded here is documented by the research (swiftterm-pty.md §3,
/// §7.6): exit handler installed BEFORE `activate()`, fd closed only through the
/// DispatchIO `cleanupHandler` (never a direct close() — EV_VANISHED crash), EOF
/// and exit emitted as two distinct events with no ordering guarantee, and the
/// child's signal state reset before exec.
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
        PTYSpawn.logForkingThreadMask()
        guard let child = PTYSpawn.forkExec(executable: command.executable,
                                            argv: argv,
                                            env: envp,
                                            currentDirectory: workingDirectory.path,
                                            windowSize: &windowSize) else {
            throw ForkPTYError.forkFailed(executable: command.executable)
        }
        return ForkPTYChannel(pid: child.pid, masterDescriptor: child.master,
                              queue: queue, sink: sink)
    }
}

/// `forkpty` + exec, with the child's signal state RESET before the exec —
/// what iTerm2, kitty and WezTerm do, and what SwiftTerm's helper does not
/// (its `main` branch does since 2026, unreleased as of 1.20; this stays
/// regardless, for the CLOEXEC master and the diagnostics).
///
/// Why it matters (research §7.6): the session manager is an actor, so the
/// fork runs on a kernel workqueue thread, and XNU starts those with a mask
/// that blocks nearly every signal — SIGWINCH, SIGINT, SIGTERM, SIGHUP
/// included. `fork` hands the calling thread's mask to the child and `execve`
/// keeps it; Bun (claude) never clears it. The agent then never hears a
/// resize, and the graceful SIGINT of a stop never lands either.
///
/// Between `fork` and `execve` only async-signal-safe calls are legal, and
/// the child must not touch the Swift runtime: every string is turned into a
/// C buffer BEFORE the fork, and the child body is plain C calls on locals.
enum PTYSpawn {

    private static let log = Logger(subsystem: "app.loom", category: "pty")

    /// A NULL-terminated `char *[]`, each entry `strdup`ed — released with `release`.
    private static func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            array[index] = strdup(string)
        }
        array[strings.count] = nil
        return array
    }

    private static func release(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0..<count {
            free(array[index])
        }
        array.deallocate()
    }

    /// The child is a session leader on the new pty (`login_tty`: setsid,
    /// TIOCSCTTY, fds 0-2), with an EMPTY signal mask and default dispositions,
    /// in `currentDirectory`. `nil` when `forkpty` itself fails; an exec that
    /// fails is exit 127 on the event stream, like SwiftTerm's helper.
    static func forkExec(executable: String, argv: [String], env: [String],
                         currentDirectory: String?,
                         windowSize: inout winsize) -> (pid: pid_t, master: Int32)? {
        let cExecutable = strdup(executable)
        let cArgv = cStringArray(argv)
        let cEnv = cStringArray(env)
        var cDirectory: UnsafeMutablePointer<CChar>? = nil
        if let currentDirectory {
            cDirectory = strdup(currentDirectory)
        }
        defer {
            // Parent only: the child never returns from the block below.
            free(cExecutable)
            release(cArgv, count: argv.count)
            release(cEnv, count: env.count)
            free(cDirectory)
        }

        // The signal state the child installs, prepared here: the child only
        // hands these two locals to the kernel.
        var defaultAction = sigaction()
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&defaultAction.sa_mask)
        defaultAction.sa_flags = 0
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &windowSize)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            // CHILD — async-signal-safe C only, on Int32 locals and the
            // pointers built above. Dispositions FIRST, then the mask: no
            // handler inherited from the app may run in here once unblocked.
            var number: Int32 = 1
            while number < NSIG {
                if number != SIGKILL && number != SIGSTOP {
                    _ = sigaction(number, &defaultAction, nil)
                }
                number += 1
            }
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            if let cDirectory {
                _ = chdir(cDirectory)
            }
            _ = execve(cExecutable, cArgv, cEnv)
            _exit(127)
        }
        // The master is ours alone: the next session's child must not inherit
        // it (nor any other session's), and `forkpty` leaves it inheritable.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (pid, master)
    }

    /// Records, once per launch, what the child WOULD have inherited: the
    /// proof in Console.app that the reset above is doing real work.
    static func logForkingThreadMask() {
        var current = sigset_t()
        guard pthread_sigmask(SIG_BLOCK, nil, &current) == 0 else { return }
        let watched: [(String, Int32)] = [("SIGWINCH", SIGWINCH), ("SIGINT", SIGINT),
                                          ("SIGTERM", SIGTERM), ("SIGHUP", SIGHUP)]
        let blocked = watched.filter { sigismember(&current, $0.1) == 1 }.map(\.0)
        if blocked.isEmpty {
            log.debug("forking thread: no signal blocked")
        } else {
            log.info("forking thread blocks \(blocked.joined(separator: " "), privacy: .public) (a workqueue thread): the child's mask is reset before exec")
        }
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

    private static let log = Logger(subsystem: "app.loom", category: "pty")

    /// TIOCSWINSZ on the master, then SIGWINCH to the child's group OURSELVES.
    /// The kernel signals the tty's foreground group when the size changes;
    /// an agent that missed that one (a group of its own, a handler installed
    /// late) still hears this one, and a duplicate costs it a re-read of a
    /// size it already has.
    func resize(to geometry: TerminalGeometry) {
        var windowSize = winsize(ws_row: UInt16(geometry.rows), ws_col: UInt16(geometry.cols),
                                 ws_xpixel: 0, ws_ypixel: 0)
        let result = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: masterDescriptor,
                                                      windowSize: &windowSize)
        if result != 0 {
            let error = String(cString: strerror(errno))
            Self.log.error("TIOCSWINSZ \(geometry.cols)×\(geometry.rows) failed on pid \(self.pid): \(error)")
            return
        }
        if kill(-pid, SIGWINCH) != 0 {
            let code = errno
            if code == ESRCH {
                // The group is empty: the agent exited, the master is still
                // open (EOF pending, or an orphan holding the slave). Normal.
                Self.log.debug("SIGWINCH: process group \(self.pid) is gone")
            } else {
                let error = String(cString: strerror(code))
                Self.log.error("SIGWINCH to process group \(self.pid) failed: \(error)")
            }
        }
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

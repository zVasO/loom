import LoomCore
import Darwin
import Foundation

/// A child started with the `--remote-debugging-pipe` wiring (process-security.md §1):
/// Chromium reads commands on its fd 3 and writes replies and events on its fd 4.
/// Every descriptor here is the caller's, to close once.
public struct ChromiumSpawnedChild: Sendable, Equatable {
    public let pid: pid_t
    /// Ours to read: the child's fd 4.
    public let readDescriptor: Int32
    /// Ours to write: the child's fd 3. Closing it is Chromium's EOF, and Chromium exits on it.
    public let writeDescriptor: Int32
    /// Ours to read: the child's stderr. It must be drained, or a chatty child
    /// blocks on a full pipe.
    public let stderrDescriptor: Int32

    public init(pid: pid_t, readDescriptor: Int32, writeDescriptor: Int32, stderrDescriptor: Int32) {
        self.pid = pid
        self.readDescriptor = readDescriptor
        self.writeDescriptor = writeDescriptor
        self.stderrDescriptor = stderrDescriptor
    }
}

public enum ChromiumSpawnError: Error, Equatable, Sendable {
    /// posix_spawn searches no PATH: a relative path would run whatever the cwd holds.
    case notAbsolute(String)
    case pipeFailed(errno: Int32)
    case descriptorFailed(errno: Int32)
    case spawnFailed(executable: String, errno: Int32)
}

/// `posix_spawn`, never `fork`: no Swift runs in the child, and Foundation's
/// `Process` cannot map fds 3 and 4.
///
/// The child is born with fds 0-4 and nothing else (`POSIX_SPAWN_CLOEXEC_DEFAULT`:
/// a PTY master or the hook socket held by Chromium would keep an agent from
/// ever seeing its EOF), an empty signal mask and default dispositions (the
/// workqueue-thread trap of ForkPTYHost.swift), and a process group of its own,
/// so `kill(-pid, …)` reaches its renderers and Ctrl+C in a `swift run`
/// terminal does not.
public enum ChromiumSpawn {

    /// The child's ends are moved here or above before `adddup2` to 3 and 4:
    /// a pipe end that already sits on 3 or 4 would be clobbered by the other
    /// dup2, or be a no-op dup2 onto itself.
    static let firstFreeDescriptor: Int32 = 5

    public static func spawn(executable: String, arguments: [String],
                             environment: [String: String]) throws -> ChromiumSpawnedChild {
        guard executable.hasPrefix("/") else { throw ChromiumSpawnError.notAbsolute(executable) }

        // pipe() fills [read end, write end].
        var commands: [Int32] = [-1, -1]   // we write [1]; the child reads [0] as its fd 3
        var replies: [Int32] = [-1, -1]    // the child writes [1] as its fd 4; we read [0]
        var errors: [Int32] = [-1, -1]     // the child's stderr is [1]; we read [0]

        // Darwin has no pipe2: between pipe() and FD_CLOEXEC a forkpty on another
        // thread would hand these ends to an agent, which would then hold
        // Chromium's fd 3 open past Loom's death (SpawnLock).
        SpawnLock.lock()
        var created = pipe(&commands) == 0
        if created { created = pipe(&replies) == 0 }
        if created { created = pipe(&errors) == 0 }
        let pipeErrno = errno
        for descriptor in commands + replies + errors where descriptor >= 0 {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        SpawnLock.unlock()
        guard created else {
            closeAll(commands + replies + errors)
            throw ChromiumSpawnError.pipeFailed(errno: pipeErrno)
        }

        // Writing to a Chromium that died must fail with EPIPE, not kill Loom.
        _ = fcntl(commands[1], F_SETNOSIGPIPE, 1)

        let childRead = fcntl(commands[0], F_DUPFD_CLOEXEC, firstFreeDescriptor)
        let childWrite = fcntl(replies[1], F_DUPFD_CLOEXEC, firstFreeDescriptor)
        let childError = fcntl(errors[1], F_DUPFD_CLOEXEC, firstFreeDescriptor)
        let dupErrno = errno
        closeAll([commands[0], replies[1], errors[1]])
        let ours = [commands[1], replies[0], errors[0]]
        let childEnds = [childRead, childWrite, childError]
        guard childRead >= 0, childWrite >= 0, childError >= 0 else {
            closeAll(ours + childEnds)
            throw ChromiumSpawnError.descriptorFailed(errno: dupErrno)
        }

        let argv = [executable] + arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let cArgv = cStringArray(argv)
        let cEnvp = cStringArray(envp)
        defer {
            release(cArgv, count: argv.count)
            release(cEnvp, count: envp.count)
        }

        var failure: Int32 = 0
        func check(_ result: Int32) {
            if failure == 0 { failure = result }
        }

        var actions: posix_spawn_file_actions_t? = nil
        check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        // CLOEXEC_DEFAULT closes 0-2 as well: each one is described.
        check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
        check(posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0))
        check(posix_spawn_file_actions_adddup2(&actions, childError, 2))
        check(posix_spawn_file_actions_adddup2(&actions, childRead, 3))
        check(posix_spawn_file_actions_adddup2(&actions, childWrite, 4))

        var attributes: posix_spawnattr_t? = nil
        check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        sigdelset(&everySignal, SIGKILL)
        sigdelset(&everySignal, SIGSTOP)
        check(posix_spawnattr_setsigmask(&attributes, &noSignals))
        check(posix_spawnattr_setsigdefault(&attributes, &everySignal))
        check(posix_spawnattr_setpgroup(&attributes, 0))
        check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
                                                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP)))
        guard failure == 0 else {
            closeAll(ours + childEnds)
            throw ChromiumSpawnError.spawnFailed(executable: executable, errno: failure)
        }

        var pid: pid_t = 0
        // posix_spawn returns an errno, never -1; XNU reports a failed exec here.
        SpawnLock.lock()
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, cArgv, cEnvp)
        SpawnLock.unlock()
        closeAll(childEnds)
        guard spawned == 0 else {
            closeAll(ours)
            throw ChromiumSpawnError.spawnFailed(executable: executable, errno: spawned)
        }
        return ChromiumSpawnedChild(pid: pid, readDescriptor: replies[0], writeDescriptor: commands[1],
                                    stderrDescriptor: errors[0])
    }

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

    private static func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}

import BunshinCore
import Darwin
import Dispatch
import Foundation
import SwiftTerm

/// Adapter de production du seam PTY : `forkpty` + `DispatchIO` + `NOTE_EXIT`.
/// Chaque piège encodé ici est documenté par la recherche (swiftterm-pty.md §3) :
/// handler d'exit posé AVANT `activate()`, fermeture du fd uniquement via le
/// `cleanupHandler` du DispatchIO (jamais de close() direct — crash EV_VANISHED),
/// l'EOF et l'exit émis comme deux événements distincts d'ordre non garanti.
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
    /// Confiné à `queue` : après fermeture, plus aucun événement ne part vers le sink.
    private var isClosed = false
    private var sink: (@Sendable (PTYEvent) -> Void)?

    init(pid: pid_t, masterDescriptor: Int32, queue: DispatchQueue,
         sink: @escaping @Sendable (PTYEvent) -> Void) {
        self.pid = pid
        self.masterDescriptor = masterDescriptor
        self.queue = queue
        self.sink = sink
        // Le fd n'est fermé QUE par le cleanupHandler (recherche §3.5).
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

        // Handler posé AVANT activate() : un enfant qui sort immédiatement est
        // quand même moissonné (recherche §3.5).
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
        // forkpty a fait de l'enfant un chef de session : son pgid est son pid.
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
        // Alimentera l'heuristique STA-02 via proc_pid_rusage — tranche à venir
        // avec l'échantillonneur ; 0 = « aucun signal CPU », jamais un faux signal.
        0
    }
}

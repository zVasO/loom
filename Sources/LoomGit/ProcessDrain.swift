import Foundation

/// Launches a process and collects its output without the two classic traps:
///
/// 1. Reading pipes only after exit deadlocks past the 64 KB pipe buffer —
///    the process blocks writing, nobody reads, it never exits. A PR diff is
///    exactly the kind of output that crosses that line.
/// 2. `waitUntilExit` called from a GCD queue can spin its ad-hoc run loop
///    forever even after the child died (observed via stack samples). The
///    reliable exit signal is `terminationHandler`, installed BEFORE run().
///
/// So: three legs joined by a group — stdout drain, stderr drain, exit —
/// and the completion fires when all three land.
public enum ProcessDrain {
    public static func launch(_ process: Process, stdout: Pipe, stderr: Pipe,
                              completion: @escaping @Sendable (Int32, Data, Data) -> Void) throws {
        let group = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()
        nonisolated(unsafe) var status: Int32 = -1

        group.enter()
        process.terminationHandler = { finished in
            status = finished.terminationStatus
            group.leave()
        }
        try process.run()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            completion(status, outData, errData)
        }
    }
}

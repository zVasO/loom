import Foundation
import LoomChromium
import LoomCore
import Observation
import Security

/// Settings ▸ Agents: downloads Loom's `chrome-headless-shell` on a click
/// (ADR-0016, NFR-S — never otherwise), and removes it. The pinned size and
/// SHA-256 are the trust root; Google's signature is checked and shown, not
/// required. The download survives leaving the Settings: AppModel owns it.
@MainActor
@Observable
final class ChromiumSetupModel {

    enum Phase: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        case verifying
        case unpacking
        /// The first run: `--version` once, so the system's first scan of a
        /// new binary is not paid by the agent's first navigation.
        case warming
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    let pin = ChromiumDownloadPin.current()

    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var transfer: ChromiumArchiveTransfer?

    var isWorking: Bool {
        switch phase {
        case .idle, .failed: return false
        case .downloading, .verifying, .unpacking, .warming: return true
        }
    }

    /// What Loom downloaded and still has, if anything.
    func installed(supportDirectory: URL) -> ChromiumInstallRecord? {
        ChromiumInstaller.installed(root: AgentChromiumBinary.downloadDirectory(supportDirectory: supportDirectory))?
            .record
    }

    /// The click. The Settings follow `phase` back to idle to look again.
    func download(supportDirectory: URL) {
        guard !isWorking else { return }
        let pin = self.pin
        let root = AgentChromiumBinary.downloadDirectory(supportDirectory: supportDirectory)
        phase = .downloading(received: 0, total: pin.sizeBytes)
        let transfer = ChromiumArchiveTransfer(url: pin.url) { [weak self] received, total in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(received: received, total: total > 0 ? total : pin.sizeBytes)
            }
        }
        self.transfer = transfer
        job = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                ChromiumInstaller.sweepLeftovers(root: root)
                let archive = root.appendingPathComponent(".download-\(UUID().uuidString).zip", isDirectory: false)
                defer { try? FileManager.default.removeItem(at: archive) }
                try await transfer.run(to: archive)
                try Task.checkCancellation()

                self?.phase = .verifying
                try await Self.offMainThrowing { try ChromiumInstaller.verify(archive, pin: pin) }
                try Task.checkCancellation()

                self?.phase = .unpacking
                let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                try await ChromiumInstaller.unpack(archive, into: staging)
                let unpacked = staging.appendingPathComponent(pin.executableRelativePath, isDirectory: false)
                let signature = await Self.offMain { Self.signatureSummary(of: unpacked) }
                try Task.checkCancellation()

                let executable = try await Self.offMainThrowing {
                    try ChromiumInstaller.place(staging: staging, root: root, pin: pin, signature: signature)
                }
                self?.phase = .warming
                await Self.warmUp(executable)
                self?.phase = .idle
            } catch is CancellationError {
                self?.phase = .failed(ChromiumInstallError.cancelled.message)
            } catch let error as ChromiumInstallError {
                self?.phase = .failed(error.message)
            } catch {
                self?.phase = .failed(ChromiumInstallError.network(error.localizedDescription).message)
            }
            self?.transfer = nil
            self?.job = nil
        }
    }

    func cancel() {
        transfer?.cancel()
        job?.cancel()
    }

    /// Removes the download; refused while an agent's Chromium runs.
    /// Returns what went wrong, nil when done.
    func remove(supportDirectory: URL, chromiumInUse: Bool) -> String? {
        guard !isWorking else { return nil }
        guard !chromiumInUse else { return ChromiumInstallError.inUse.message }
        do {
            try ChromiumInstaller.remove(root: AgentChromiumBinary.downloadDirectory(supportDirectory: supportDirectory))
            phase = .idle
            return nil
        } catch let error as ChromiumInstallError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Steps off the main thread

    nonisolated private static func offMainThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Google's Developer ID (team EQHXZ8M8AV), checked and reported: the
    /// pinned SHA-256 already vouches for the bytes.
    nonisolated static func signatureSummary(of executable: URL) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess, let code else {
            return "Signature not readable"
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return "Signature not checked"
        }
        let status = SecStaticCodeCheckValidityWithErrors(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures),
                                                          requirement, nil)
        if status == errSecSuccess { return "Signed by Google (EQHXZ8M8AV)" }
        if Int(status) == Int(errSecCSUnsigned) { return "Not signed — the checksum vouches for it" }
        return "Not signed by Google — the checksum vouches for it"
    }

    /// `--version` once, within 60 s; its answer is not needed.
    nonisolated private static func warmUp(_ executable: URL) async {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OnceFlag()
            do {
                try ProcessDrain.launch(process, stdout: stdout, stderr: stderr) { _, _, _ in
                    if resumed.claim() { continuation.resume() }
                }
            } catch {
                if resumed.claim() { continuation.resume() }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                guard resumed.claim() else { return }
                process.terminate()
                continuation.resume()
            }
        }
    }
}

/// True for the first claimer only.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// One archive download with progress, cancellable; moved to `destination`
/// before URLSession deletes its temporary file.
final class ChromiumArchiveTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let url: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    /// The last progress told: about every 1 MB, not every packet.
    private var reported: Int64 = 0

    init(url: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.url = url
        self.onProgress = onProgress
    }

    func run(to destination: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = false
                configuration.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                let startNow: Bool = lock.withLock {
                    self.destination = destination
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return !cancelled
                }
                if startNow {
                    task.resume()
                } else {
                    finish(.failure(CancellationError()))
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let task: URLSessionDownloadTask? = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
        if task == nil { return }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let (continuation, session): (CheckedContinuation<Void, Error>?, URLSession?) = lock.withLock {
            defer {
                self.continuation = nil
                self.session = nil
            }
            return (self.continuation, self.session)
        }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let due: Bool = lock.withLock {
            guard totalBytesWritten - reported >= 1_000_000 || totalBytesWritten == totalBytesExpectedToWrite else {
                return false
            }
            reported = totalBytesWritten
            return true
        }
        if due { onProgress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(ChromiumInstallError.network("the server answered \(response.statusCode)")))
            return
        }
        guard let destination = lock.withLock({ self.destination }) else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(ChromiumInstallError.disk(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(ChromiumInstallError.network(error.localizedDescription)))
        }
    }
}

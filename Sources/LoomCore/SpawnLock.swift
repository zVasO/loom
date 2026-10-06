import Foundation

/// One lock around every child Loom starts and every descriptor it makes
/// close-on-exec afterwards. Darwin has no `pipe2` or `SOCK_CLOEXEC`: between
/// `pipe()` and `fcntl(FD_CLOEXEC)` a `forkpty` on another thread would hand
/// the new descriptors to an agent — and a Chromium whose pipe an agent's
/// descendant still holds open never sees Loom go (ADR-0015).
public enum SpawnLock {
    private static let mutex = NSLock()

    /// Taken and released on the same thread, around the fork or the
    /// descriptors' creation only.
    public static func lock() { mutex.lock() }
    public static func unlock() { mutex.unlock() }

    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }
}

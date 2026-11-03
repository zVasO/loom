import Foundation

// The agent's page as Chromium draws it, once it holds still (ADR-0016).
// JPEG frames while the page moves — light, 60 a second; once no frame came
// for a moment, the screencast restarts in PNG: its first frame is the page
// lossless, pixel for pixel. The next change comes as PNG too (shown, it is
// the page), and the screencast goes back to JPEG. Pure: the stream feeds it
// the frames' formats and times, and does what it answers.

public struct StillFrameRefiner: Equatable, Sendable {

    public enum Format: String, Equatable, Sendable {
        case jpeg, png

        /// Of a frame's bytes: PNG's signature, else JPEG.
        public static func of(_ data: Data) -> Format {
            data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? .png : .jpeg
        }
    }

    public enum Step: Equatable, Sendable {
        case none
        /// Wait this long (seconds), then `still(token:)` with `token`.
        case wait(seconds: Double, token: Int)
        /// Restart the screencast in this format.
        case restart(Format)
    }

    /// How long without a frame before the lossless picture is asked for.
    public static let stillDelay = 0.2
    /// The longest wait: a page changing every half second (a caret
    /// blinking) is not restarted twice a second for ever.
    public static let maxDelay = 3.2
    /// A lossless run shorter than this doubles the next wait.
    public static let shortRun = 1.0

    /// The format the screencast was last asked for.
    public private(set) var format: Format = .jpeg
    public private(set) var delay: Double = StillFrameRefiner.stillDelay
    private var token = 0
    private var losslessSince: Double?

    public init() {}

    /// A frame of `kind` came at `now` (seconds, any monotonic clock).
    public mutating func frame(_ kind: Format, at now: Double) -> Step {
        switch (format, kind) {
        case (.jpeg, .jpeg):
            token += 1
            return .wait(seconds: delay, token: token)
        case (.jpeg, .png), (.png, .jpeg):
            // In flight from the run before the restart: shown, nothing else.
            return .none
        case (.png, .png):
            guard let since = losslessSince else {
                // The restart's own frame: the page as it holds still.
                losslessSince = now
                return .none
            }
            // The page changed: frames go light again. A short still run
            // means a page that keeps changing: wait longer next time.
            delay = now - since < Self.shortRun ? min(delay * 2, Self.maxDelay) : Self.stillDelay
            format = .jpeg
            losslessSince = nil
            return .restart(.jpeg)
        }
    }

    /// The wait `token` asked for is over: still the latest frame — the
    /// lossless picture is asked for.
    public mutating func still(token waited: Int) -> Step {
        guard format == .jpeg, waited == token else { return .none }
        format = .png
        losslessSince = nil
        return .restart(.png)
    }

    /// The screencast (re)started in JPEG for another tab or size; a wait
    /// pending is void.
    public mutating func restarted() {
        format = .jpeg
        token += 1
        losslessSince = nil
    }
}

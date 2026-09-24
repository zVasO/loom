import Darwin
import Foundation

// loom-hook — the helper invoked by agent hooks (ADR-0005).
// Reads the hook's JSON payload from stdin, wraps it as {"token":…, "payload":…}
// and writes it as a single line to the app's Unix socket. More robust than
// `nc -U`: no PATH dependency, unambiguous exit code, never interactive.
//
// Usage: loom-hook --socket <path> --token <token>
//
// Status line mode (`--statusline [--then-b64 <command>]`): claude runs it as
// its status line, the one program told the context window size. The JSON is
// forwarded to the app stamped `hook_event_name: LoomStatusLine`, silently —
// nothing but the user's own line may reach the terminal — then the user's
// status line command (base64) runs in its place on the same stdin, so the
// line claude prints is theirs, unchanged.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("loom-hook: \(message)\n".utf8))
    exit(1)
}

var socketPath: String?
var token: String?
var statusLineMode = false
var thenCommandBase64: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--socket": socketPath = arguments.next()
    case "--token": token = arguments.next()
    case "--statusline": statusLineMode = true
    case "--then-b64": thenCommandBase64 = arguments.next()
    default: break   // unknown arguments ignored: hooks may evolve
    }
}

/// Sends one envelope line to the app; the error, if any, as text.
func deliver(_ payloadObject: Any, socketPath: String, token: String) -> String? {
    let envelope: [String: Any] = ["token": token, "payload": payloadObject]
    guard var line = try? JSONSerialization.data(withJSONObject: envelope) else {
        return "payload cannot be serialized"
    }
    line.append(UInt8(ascii: "\n"))

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return "socket(): errno \(errno)" }
    defer { close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        return "socket path too long"
    }
    socketPath.withCString { source in
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.baseAddress!.assumingMemoryBound(to: CChar.self)
                .update(from: source, count: strlen(source) + 1)
        }
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return "connect(\(socketPath)): errno \(errno)" }

    let written = line.withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress, buffer.count)
    }
    guard written == line.count else { return "incomplete write (\(written)/\(line.count))" }
    return nil
}

/// Replaces this process with `sh -c command`, `input` on its stdin. Only
/// returns if the exec failed.
func execShell(_ command: String, input: Data) {
    // The same bytes claude gave us, from a file already unlinked: no size
    // limit (a pipe would block past its buffer), nothing left behind.
    var template = Array((NSTemporaryDirectory() + "loom-statusline-XXXXXX").utf8CString)
    let file = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    if file >= 0 {
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        var offset = 0
        input.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let count = write(file, buffer.baseAddress! + offset, buffer.count - offset)
                guard count > 0 else { break }
                offset += count
            }
        }
        lseek(file, 0, SEEK_SET)
        dup2(file, STDIN_FILENO)
        close(file)
    }
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
    execv("/bin/sh", argv)
}

if statusLineMode {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if let socketPath, let token {
        var object = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
        object["hook_event_name"] = "LoomStatusLine"
        _ = deliver(object, socketPath: socketPath, token: token)   // silent: the app may be gone
    }
    if let encoded = thenCommandBase64,
       let decoded = Data(base64Encoded: encoded),
       let command = String(data: decoded, encoding: .utf8),
       !command.isEmpty {
        execShell(command, input: input)
    }
    exit(0)   // no user status line (or it could not start): an empty line
}

guard let socketPath, let token else { fail("--socket and --token are required") }

let payload = FileHandle.standardInput.readDataToEndOfFile()
let payloadObject: Any = (try? JSONSerialization.jsonObject(with: payload)) ?? [:]
if let error = deliver(payloadObject, socketPath: socketPath, token: token) { fail(error) }
exit(0)

import Darwin
import Foundation

// loom-hook — the helper invoked by agent hooks (ADR-0005).
// Reads the hook's JSON payload from stdin, wraps it as {"token":…, "payload":…}
// and writes it as a single line to the app's Unix socket. More robust than
// `nc -U`: no PATH dependency, unambiguous exit code, never interactive.
//
// Usage: loom-hook --socket <path> --token <token>

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("loom-hook: \(message)\n".utf8))
    exit(1)
}

var socketPath: String?
var token: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--socket": socketPath = arguments.next()
    case "--token": token = arguments.next()
    default: break   // unknown arguments ignored: hooks may evolve
    }
}
guard let socketPath, let token else { fail("--socket and --token are required") }

let payload = FileHandle.standardInput.readDataToEndOfFile()
let payloadObject: Any = (try? JSONSerialization.jsonObject(with: payload)) ?? [:]
let envelope: [String: Any] = ["token": token, "payload": payloadObject]
guard var line = try? JSONSerialization.data(withJSONObject: envelope) else {
    fail("payload cannot be serialized")
}
line.append(UInt8(ascii: "\n"))

let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { fail("socket(): errno \(errno)") }
defer { close(descriptor) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
    fail("socket path too long")
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
guard connected == 0 else { fail("connect(\(socketPath)): errno \(errno)") }

let written = line.withUnsafeBytes { buffer in
    write(descriptor, buffer.baseAddress, buffer.count)
}
guard written == line.count else { fail("incomplete write (\(written)/\(line.count))") }
exit(0)

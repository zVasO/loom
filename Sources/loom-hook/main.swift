import Darwin
import Foundation

// loom-hook — le helper appelé par les hooks des agents (ADR-0005).
// Lit le payload JSON du hook sur stdin, l'enveloppe {"token":…, "payload":…}
// et l'écrit en une ligne sur le socket Unix de l'app. Plus robuste que
// `nc -U` : pas de dépendance au PATH, code de sortie franc, jamais interactif.
//
// Usage : loom-hook --socket <chemin> --token <jeton>

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
    default: break   // arguments inconnus ignorés : les hooks peuvent évoluer
    }
}
guard let socketPath, let token else { fail("--socket et --token sont requis") }

let payload = FileHandle.standardInput.readDataToEndOfFile()
let payloadObject: Any = (try? JSONSerialization.jsonObject(with: payload)) ?? [:]
let envelope: [String: Any] = ["token": token, "payload": payloadObject]
guard var line = try? JSONSerialization.data(withJSONObject: envelope) else {
    fail("payload insérialisable")
}
line.append(UInt8(ascii: "\n"))

let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard descriptor >= 0 else { fail("socket() : errno \(errno)") }
defer { close(descriptor) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
    fail("chemin de socket trop long")
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
guard connected == 0 else { fail("connect(\(socketPath)) : errno \(errno)") }

let written = line.withUnsafeBytes { buffer in
    write(descriptor, buffer.baseAddress, buffer.count)
}
guard written == line.count else { fail("écriture incomplète (\(written)/\(line.count))") }
exit(0)

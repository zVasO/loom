import Testing
@testable import LoomChromium
import Foundation

// The steps between Loom's download of chrome-headless-shell and a binary
// the locator finds, on throwaway folders: no network, no real install.

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("loom-chromium-download-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// An unpacked archive as `ditto` leaves it: the platform folder with an
/// executable `chrome-headless-shell`.
private func stage(_ pin: ChromiumDownloadPin, in folder: URL, contents: String = "#!/bin/sh\necho shell\n") throws -> URL {
    let staging = folder.appendingPathComponent(".staging-test", isDirectory: true)
    let build = staging.appendingPathComponent(pin.folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    let executable = build.appendingPathComponent("chrome-headless-shell")
    try Data(contents.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return staging
}

@Suite("ChromiumDownload — Loom's chrome-headless-shell, pinned and placed")
struct ChromiumDownloadTests {

    @Test("each Mac gets its native build, from Chrome for Testing, at the pinned version")
    func epinglage() {
        let arm = ChromiumDownloadPin.current(for: .arm64)
        let intel = ChromiumDownloadPin.current(for: .x86_64)
        #expect(arm.platform == "mac-arm64")
        #expect(intel.platform == "mac-x64")
        #expect(arm.version == ChromiumDownloadPin.version)
        #expect(arm.url.absoluteString == "https://storage.googleapis.com/chrome-for-testing-public/"
                + "\(ChromiumDownloadPin.version)/mac-arm64/chrome-headless-shell-mac-arm64.zip")
        #expect(arm.executableRelativePath == "chrome-headless-shell-mac-arm64/chrome-headless-shell")
        for pin in [arm, intel] {
            #expect(pin.sha256.count == 64)
            #expect(pin.sha256.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(pin.sizeBytes > 50_000_000)
        }
        #expect(arm.sizeDescription == "94 MB")
    }

    @Test("the pinned build lands where the locator looks for Loom's download")
    func memeEndroitQueLeLocator() {
        let root = URL(fileURLWithPath: "/Users/ada/Library/Application Support/Loom/chromium", isDirectory: true)
        for architecture in [ChromiumLocator.Architecture.arm64, .x86_64] {
            let pin = ChromiumDownloadPin.current(for: architecture)
            let expected = root.appendingPathComponent(pin.executableRelativePath).path
            let locator = ChromiumLocator(homeDirectory: URL(fileURLWithPath: "/Users/ada", isDirectory: true),
                                          architecture: architecture,
                                          fileExists: { $0 == expected },
                                          directoryContents: { _ in [] })
            let found = locator.locate(downloadDirectory: root)
            #expect(found?.url.path == expected)
            #expect(found?.kind == .headlessShell)
            #expect(found?.source == .loomDownload)
        }
    }

    @Test("SHA-256 is read in chunks and written in lowercase hex")
    func empreinte() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        let digest = try ChromiumInstaller.sha256(of: file, chunkSize: 2)
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("an archive of another size or another checksum is refused, whatever its name")
    func verification() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chrome-headless-shell-mac-arm64.zip")
        try Data("abc".utf8).write(to: file)
        let url = URL(fileURLWithPath: "/dev/null")
        let right = ChromiumDownloadPin(version: "1", platform: "mac-arm64", url: url,
                                        sha256: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
                                        sizeBytes: 3)
        try ChromiumInstaller.verify(file, pin: right)

        let longer = ChromiumDownloadPin(version: "1", platform: "mac-arm64", url: url, sha256: right.sha256,
                                         sizeBytes: 4)
        #expect(throws: ChromiumInstallError.sizeMismatch(expected: 4, actual: 3)) {
            try ChromiumInstaller.verify(file, pin: longer)
        }
        let other = ChromiumDownloadPin(version: "1", platform: "mac-arm64", url: url,
                                        sha256: String(repeating: "0", count: 64), sizeBytes: 3)
        #expect(throws: ChromiumInstallError.checksumMismatch(
            expected: other.sha256, actual: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
            try ChromiumInstaller.verify(file, pin: other)
        }
        #expect(ChromiumInstallError.checksumMismatch(expected: "a", actual: "b").message
                == "The download didn't match Loom's checksum — nothing was installed.")
    }

    @Test("placing moves the build in, records it, and replaces an earlier one whole")
    func placement() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("chromium", isDirectory: true)
        let pin = ChromiumDownloadPin.current(for: .arm64)
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try stage(pin, in: folder, contents: "#!/bin/sh\necho first\n")
        let executable = try ChromiumInstaller.place(staging: first, root: root, pin: pin,
                                                     signature: "Signed by Google (EQHXZ8M8AV)", now: date)
        #expect(executable.path == root.appendingPathComponent(pin.executableRelativePath).path)
        #expect(ChromiumLocator.isExecutableFile(executable.path))
        let installed = ChromiumInstaller.installed(root: root)
        #expect(installed?.record == ChromiumInstallRecord(version: pin.version, platform: pin.platform,
                                                           sha256: pin.sha256, installedAt: date,
                                                           signature: "Signed by Google (EQHXZ8M8AV)"))
        #expect(installed?.executable.path == executable.path)

        try? FileManager.default.removeItem(at: first)
        let second = try stage(pin, in: folder, contents: "#!/bin/sh\necho second\n")
        try ChromiumInstaller.place(staging: second, root: root, pin: pin, signature: nil, now: date)
        let contents = try String(contentsOf: executable, encoding: .utf8)
        #expect(contents.contains("second"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".old-") }
        #expect(leftovers.isEmpty)
    }

    @Test("an archive without the executable where it belongs installs nothing")
    func mauvaiseDisposition() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("chromium", isDirectory: true)
        let pin = ChromiumDownloadPin.current(for: .arm64)
        let staging = try stage(ChromiumDownloadPin.current(for: .x86_64), in: folder)
        #expect(throws: ChromiumInstallError.self) {
            try ChromiumInstaller.place(staging: staging, root: root, pin: pin, signature: nil)
        }
        #expect(ChromiumInstaller.installed(root: root) == nil)
    }

    @Test("removing takes the builds, the record and the leftovers; nothing else in the folder")
    func suppression() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("chromium", isDirectory: true)
        let pin = ChromiumDownloadPin.current(for: .arm64)
        try ChromiumInstaller.place(staging: try stage(pin, in: folder), root: root, pin: pin, signature: nil)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".staging-123"),
                                                withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: root.appendingPathComponent("notes.txt"))

        try ChromiumInstaller.remove(root: root)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == ["notes.txt"])
        #expect(ChromiumInstaller.installed(root: root) == nil)
        // Nothing there: nothing to do.
        try ChromiumInstaller.remove(root: folder.appendingPathComponent("absent"))
    }

    @Test("a record whose executable is gone is not an install")
    func enregistrementOrphelin() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try ChromiumInstallRecord(version: "1", platform: "mac-arm64", sha256: "x", installedAt: Date(),
                                  signature: nil).write(to: folder)
        #expect(ChromiumInstallRecord.read(from: folder)?.version == "1")
        #expect(ChromiumInstaller.installed(root: folder) == nil)
    }

    @Test("ditto unpacks an archive with its executable bits")
    func depaquetage() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else { return }
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pin = ChromiumDownloadPin.current(for: .arm64)
        let staging = try stage(pin, in: folder)
        let archive = folder.appendingPathComponent("shell.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", staging.appendingPathComponent(pin.folderName).path,
                         archive.path]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let unpacked = folder.appendingPathComponent(".staging-unpacked", isDirectory: true)
        try await ChromiumInstaller.unpack(archive, into: unpacked)
        #expect(ChromiumLocator.isExecutableFile(unpacked.appendingPathComponent(pin.executableRelativePath).path))

        let broken = folder.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: broken)
        await #expect(throws: ChromiumInstallError.self) {
            try await ChromiumInstaller.unpack(broken, into: folder.appendingPathComponent(".staging-broken"))
        }
    }
}

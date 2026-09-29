import XCTest
import MachO

/// scripts/build-app.sh links Ara against the current SDK while macOS 15 stays the deployment
/// target: AppKit and SwiftUI draw an app in the design of the SDK it is marked as built with.
final class AppBuildTests: XCTestCase {
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath:tool); process.arguments = arguments
        // As SwiftPM runs its link: no SDKROOT, which would give the linker the SDK's version itself.
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "SDKROOT" }
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain:"AppBuildTests",code:Int(process.terminationStatus),userInfo:[NSLocalizedDescriptionKey:"\(tool) \(arguments.joined(separator:" ")): \(output)"])
        }
        return output.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    /// The deployment target and SDK a Mach-O file records (LC_BUILD_VERSION), as "15.0".
    private func buildVersion(of url: URL) throws -> (minos: String, sdk: String) {
        func text(_ version: UInt32) -> String {
            "\(version >> 16).\((version >> 8) & 0xff)"+(version & 0xff == 0 ? "" : ".\(version & 0xff)")
        }
        let data = try Data(contentsOf:url)
        return try data.withUnsafeBytes { raw in
            let header = raw.loadUnaligned(as:mach_header_64.self)
            XCTAssertEqual(header.magic,MH_MAGIC_64)
            var offset = MemoryLayout<mach_header_64>.size
            for _ in 0..<header.ncmds {
                let command = raw.loadUnaligned(fromByteOffset:offset,as:load_command.self)
                if command.cmd == UInt32(LC_BUILD_VERSION) {
                    let build = raw.loadUnaligned(fromByteOffset:offset,as:build_version_command.self)
                    return (text(build.minos),text(build.sdk))
                }
                offset += Int(command.cmdsize)
            }
            throw NSError(domain:"AppBuildTests",code:0,userInfo:[NSLocalizedDescriptionKey:"no LC_BUILD_VERSION in \(url.lastPathComponent)"])
        }
    }
    /// A small program linked as SwiftPM links Ara (the toolchain's swiftc, given the SDK with
    /// -sdk), with the swiftc flags the script adds, records the current SDK and macOS 15.
    func testTheAppIsLinkedAgainstTheCurrentSDK() throws {
        let script = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build-app.sh")
        let line = try XCTUnwrap(try String(contentsOf:script,encoding:.utf8).split(separator:"\n").first { $0.hasPrefix("swift build") && $0.contains("--product Ara") })
        let sdk = try run("/usr/bin/xcrun",["--sdk","macosx","--show-sdk-path"])
        let words = line.split(separator:" ").map { $0 == "\"$sdk\"" ? sdk : String($0) }
        let flags = zip(words,words.dropFirst()).filter { $0.0 == "-Xswiftc" }.map(\.1)
        XCTAssertFalse(flags.isEmpty,"build-app.sh gives swiftc no flags: \(line)")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-sdk-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let source = folder.appendingPathComponent("main.swift"), program = folder.appendingPathComponent("linked")
        try Data("print(1)\n".utf8).write(to:source)
        let swiftc = try run("/usr/bin/xcrun",["--find","swiftc"])
        _ = try run(swiftc,["-sdk",sdk,"-target","arm64-apple-macos15.0"]+flags+["-module-cache-path",folder.appendingPathComponent("cache").path,source.path,"-o",program.path])
        let version = try buildVersion(of:program)
        XCTAssertEqual(version.minos,"15.0")
        XCTAssertEqual(version.sdk,try run("/usr/bin/xcrun",["--sdk","macosx","--show-sdk-version"]),"linked against an older SDK than the one installed")
    }
}

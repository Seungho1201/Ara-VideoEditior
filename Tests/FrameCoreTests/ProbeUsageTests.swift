import XCTest

/// FrameProbe checks the media pipeline from scripts and CI: a misspelled mode or missing
/// arguments must fail (exit 64, sysexits' EX_USAGE) rather than pass having checked nothing.
final class ProbeUsageTests: XCTestCase {
    private func probe(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let url = Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("FrameProbe")
        guard FileManager.default.isExecutableFile(atPath:url.path) else { throw XCTSkip("FrameProbe is not built next to the tests (\(url.path))") }
        let process = Process(), pipe = Pipe()
        process.executableURL = url; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus,output)
    }
    func testUnknownModesAndMissingArgumentsFail() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ara-probe-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let output = folder.appendingPathComponent("out").path
        for arguments in [["smok",folder.path,output],[],["smoke",folder.path],["snapshot-roundtrip"],["bogus","a","b"]] {
            let run = try probe(arguments)
            XCTAssertEqual(run.status,64,"FrameProbe \(arguments.joined(separator:" "))")
            XCTAssertTrue(run.output.contains("Usage: FrameProbe"),run.output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:output),"nothing was run")
    }
}

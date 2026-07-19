import Darwin
import Foundation
import XCTest
@testable import PinentryCompanionCore

final class ExecutableLookupTests: XCTestCase {
    func testLookupAcceptsExecutableFilesAndRejectsExecutableDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinentry-executable-lookup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let executable = root.appendingPathComponent("real-tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
        XCTAssertEqual(chmod(executable.path, 0o700), 0)

        let directory = root.appendingPathComponent("directory-tool")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory.path, 0o700), 0)

        let environment = ["PATH": root.path]
        XCTAssertEqual(ExecutableLookup.find("real-tool", environment: environment), executable.path)
        XCTAssertNil(ExecutableLookup.find("directory-tool", environment: environment))
        XCTAssertNil(ExecutableLookup.find("invalid\0name", environment: environment))
    }
}

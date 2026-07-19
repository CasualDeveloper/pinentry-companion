import Security
import XCTest
@testable import PinentryCompanionCore

final class PinentryServerTests: XCTestCase {
    func testBadRetryWithCompleteOptInDeletesThenStores() {
        let cache = RecordingCache()
        let fallback = RecordingFallback(pin: "entered")
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "SETERROR Bad passphrase. Try again.",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [.delete("n/test-key"), .store("n/test-key", "entered")])
        XCTAssertEqual(fallback.operations, [.getPIN])
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testBadRetryWithoutOptInUsesFallbackOnly() {
        let cache = RecordingCache()
        let fallback = RecordingFallback()
        let server = makeServer(cache: cache, fallback: fallback)

        send([
            "SETKEYINFO n/test-key",
            "SETERROR Bad passphrase. Try again.",
            "GETPIN",
        ], to: server)

        XCTAssertTrue(cache.operations.isEmpty)
        XCTAssertEqual(fallback.operations, [.getPIN])
    }

    func testBadRetryWithoutKeyInfoUsesFallbackOnly() {
        let cache = RecordingCache()
        let fallback = RecordingFallback()
        let server = makeServer(cache: cache, fallback: fallback)

        send([
            "OPTION allow-external-password-cache",
            "SETERROR Bad passphrase. Try again.",
            "GETPIN",
        ], to: server)

        XCTAssertTrue(cache.operations.isEmpty)
        XCTAssertEqual(fallback.operations, [.getPIN])
    }

    func testRepeatPromptDisablesCacheEvenWithOptInAndRetry() {
        let cache = RecordingCache()
        let fallback = RecordingFallback()
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "SETREPEAT Repeat PIN",
            "SETERROR Bad passphrase. Try again.",
            "GETPIN",
        ], to: server)

        XCTAssertTrue(cache.operations.isEmpty)
        XCTAssertEqual(fallback.operations, [.getPIN])
        XCTAssertTrue(output.events.contains("line:S PIN_REPEATED"))
    }

    func testCacheHitReadsWithoutFallback() {
        let cache = RecordingCache(password: "cached")
        let fallback = RecordingFallback()
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [.read("n/test-key")])
        XCTAssertTrue(fallback.operations.isEmpty)
        XCTAssertEqual(
            Array(output.events.suffix(3)),
            ["line:S PASSWORD_FROM_CACHE", "data:cached", "line:OK"]
        )
    }

    func testCacheMissPromptsThenStores() {
        let cache = RecordingCache(passwordError: KeychainStoreError.notFound)
        let fallback = RecordingFallback(pin: "entered")
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [.read("n/test-key"), .store("n/test-key", "entered")])
        XCTAssertEqual(fallback.operations, [.getPIN])
        XCTAssertFalse(output.events.contains("line:S PASSWORD_FROM_CACHE"))
    }

    func testCacheIsAttemptedOnlyOnceUntilReset() {
        let cache = RecordingCache(password: "cached")
        let fallback = RecordingFallback(pin: "entered")
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "GETPIN",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [
            .read("n/test-key"),
            .store("n/test-key", "entered"),
        ])
        XCTAssertEqual(fallback.operations, [.getPIN])
        XCTAssertEqual(output.events.filter { $0 == "line:S PASSWORD_FROM_CACHE" }.count, 1)
    }

    func testBadRetryAfterCacheHitDeletesBeforeReplacing() {
        let cache = RecordingCache(password: "cached")
        let fallback = RecordingFallback(pin: "replacement")
        let server = makeServer(cache: cache, fallback: fallback)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "GETPIN",
            "SETERROR Bad passphrase. Try again.",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [
            .read("n/test-key"),
            .delete("n/test-key"),
            .store("n/test-key", "replacement"),
        ])
        XCTAssertEqual(fallback.operations, [.getPIN])
    }

    func testErrorIsClearedAfterGetPIN() {
        let cache = RecordingCache()
        let fallback = RecordingFallback(pin: "entered")
        let server = makeServer(cache: cache, fallback: fallback)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "SETERROR Bad passphrase. Try again.",
            "GETPIN",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [
            .delete("n/test-key"),
            .store("n/test-key", "entered"),
            .store("n/test-key", "entered"),
        ])
    }

    func testClearPassphraseIsAnExplicitComponentCacheDeletion() {
        let cache = RecordingCache()
        let output = RecordingServerOutput()
        let server = makeServer(
            cache: cache,
            fallback: RecordingFallback(),
            output: output
        )

        send(["CLEARPASSPHRASE n/test-key"], to: server)

        XCTAssertEqual(cache.operations, [.delete("n/test-key")])
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testCacheStoreFailureDoesNotFailTheCurrentPinentryRequest() {
        let cache = RecordingCache(
            passwordError: KeychainStoreError.notFound,
            storeError: KeychainStoreError.osStatus(errSecNotAvailable)
        )
        let fallback = RecordingFallback(pin: "entered")
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "SETKEYINFO n/test-key",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [.read("n/test-key"), .store("n/test-key", "entered")])
        XCTAssertEqual(output.data, ["entered"])
        XCTAssertTrue(output.errors.isEmpty)
    }

    func testEmptyFallbackPINIsRejectedWithOrWithoutCacheOptIn() {
        for commands in [
            ["GETPIN"],
            ["OPTION allow-external-password-cache", "SETKEYINFO n/test-key", "GETPIN"],
        ] {
            let cache = RecordingCache(passwordError: KeychainStoreError.notFound)
            let output = RecordingServerOutput()
            let server = makeServer(
                cache: cache,
                fallback: RecordingFallback(pin: ""),
                output: output
            )

            send(commands, to: server)

            XCTAssertEqual(output.errors.count, 1)
            XCTAssertTrue(output.data.isEmpty)
        }
    }

    func testResetPreservesAgentOptionsAndClearsPerPromptState() {
        let cache = RecordingCache(password: "cached")
        let fallback = RecordingFallback()
        let output = RecordingServerOutput()
        let server = makeServer(cache: cache, fallback: fallback, output: output)

        send([
            "OPTION allow-external-password-cache",
            "OPTION ttyname=/dev/ttys001",
            "SETTIMEOUT 30",
            "SETKEYINFO n/test-key",
            "SETREPEAT Repeat PIN",
            "SETERROR Bad passphrase. Try again.",
            "RESET",
            "SETKEYINFO n/test-key",
            "GETPIN",
        ], to: server)

        XCTAssertEqual(cache.operations, [.read("n/test-key")])
        XCTAssertTrue(fallback.operations.isEmpty)
        XCTAssertTrue(output.events.contains("line:S PASSWORD_FROM_CACHE"))
        XCTAssertFalse(output.events.contains("line:S PIN_REPEATED"))
    }

    func testFallbackOnlyCommandsNeverUseCache() {
        let cache = RecordingCache()
        let fallback = RecordingFallback()
        let server = makeServer(cache: cache, fallback: fallback)

        send(["GETPIN", "CONFIRM", "MESSAGE"], to: server)

        XCTAssertTrue(cache.operations.isEmpty)
        XCTAssertEqual(fallback.operations, [.getPIN, .confirm, .message])
    }

    func testConfirmParametersAreForwardedToFallback() {
        let fallback = RecordingFallback()
        let server = makeServer(cache: RecordingCache(), fallback: fallback)

        send(["CONFIRM --one-button --focus=ok"], to: server)

        XCTAssertEqual(fallback.confirmParameters, "--one-button --focus=ok")
    }

    func testGetInfoTTYUsesConfiguredTerminalContext() {
        let output = RecordingServerOutput()
        let server = makeServer(
            cache: RecordingCache(),
            fallback: RecordingFallback(),
            output: output
        )

        send([
            "OPTION ttyname=/dev/null",
            "OPTION ttytype=xterm-256color",
            "OPTION display=:0",
            "GETINFO ttyinfo",
        ], to: server)

        XCTAssertEqual(output.errors.count, 0)
        XCTAssertEqual(output.data.count, 1)
        XCTAssertTrue(output.data[0].hasPrefix("/dev/null xterm-256color :0 "))
    }

    func testInvalidTimeoutIsRejectedWithoutChangingPromptState() {
        let output = RecordingServerOutput()
        let server = makeServer(
            cache: RecordingCache(),
            fallback: RecordingFallback(),
            output: output
        )

        send(["SETTIMEOUT -1", "SETTIMEOUT invalid"], to: server)

        XCTAssertEqual(output.errors.count, 2)
        XCTAssertTrue(output.errors.allSatisfy { $0.code == .invalidValue })
    }

    private func makeServer(
        cache: RecordingCache,
        fallback: RecordingFallback,
        output: RecordingServerOutput = RecordingServerOutput()
    ) -> PinentryServer {
        PinentryServer(cache: cache, fallbackFactory: { fallback }, output: output)
    }

    private func send(_ lines: [String], to server: PinentryServer) {
        for line in lines {
            XCTAssertFalse(server.process(line))
        }
    }
}

private final class RecordingCache: PassphraseCache {
    enum Operation: Equatable {
        case read(String)
        case delete(String)
        case store(String, String)
    }

    var operations: [Operation] = []
    private let password: String
    private let passwordError: Error?
    private let storeError: Error?

    init(password: String = "cached", passwordError: Error? = nil, storeError: Error? = nil) {
        self.password = password
        self.passwordError = passwordError
        self.storeError = storeError
    }

    func password(identity: KeychainIdentity, reason: String) throws -> String {
        operations.append(.read(identity.account))
        if let passwordError { throw passwordError }
        return password
    }

    func store(identity: KeychainIdentity, password: String) throws {
        operations.append(.store(identity.account, password))
        if let storeError { throw storeError }
    }

    func delete(identity: KeychainIdentity) throws {
        operations.append(.delete(identity.account))
    }
}

private final class RecordingFallback: FallbackPinentryClient {
    enum Operation: Equatable {
        case getPIN
        case confirm
        case message
    }

    var operations: [Operation] = []
    var confirmParameters = ""
    private let pin: String

    init(pin: String = "entered") {
        self.pin = pin
    }

    func getPIN(settings: PinentrySettings) throws -> String {
        operations.append(.getPIN)
        return pin
    }

    func confirm(settings: PinentrySettings) throws {
        operations.append(.confirm)
        confirmParameters = settings.confirmParameters
    }

    func message(settings: PinentrySettings) throws {
        operations.append(.message)
    }
}

private final class RecordingServerOutput: PinentryServerOutput {
    var errors: [Assuan.ProtocolError] = []
    var data: [String] = []
    var events: [String] = []

    func writeLine(_ command: String, _ parameters: String) {
        events.append(parameters.isEmpty ? "line:\(command)" : "line:\(command) \(parameters)")
    }
    func writeData(_ value: String) {
        data.append(value)
        events.append("data:\(value)")
    }
    func writeError(_ error: Assuan.ProtocolError) { errors.append(error) }
}

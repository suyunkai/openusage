import XCTest
@testable import OpenUsage

/// The Claude Code CLI login is read, never renewed: renewing would rotate the refresh token the CLI
/// itself relies on and sign it out.
@MainActor
final class ClaudeCodeCLICredentialTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func blob(token: String = "cli-access", expiresIn: TimeInterval) -> Data {
        let ms = Int((now.timeIntervalSince1970 + expiresIn) * 1000)
        return Data(#"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"cli-refresh","expiresAt":\#(ms),"subscriptionType":"max"}}"#.utf8)
    }

    private func credentials(keychain: ClaudeCodeCLICredentials.SecurityResult, files: [URL] = []) -> ClaudeCodeCLICredentials {
        var credentials = ClaudeCodeCLICredentials()
        credentials.credentialFiles = files
        credentials.runSecurity = { _, _ in keychain }
        let now = now
        credentials.now = { now }
        return credentials
    }

    func testParsesTheKeychainBlobAndLeavesTheRefreshTokenOut() throws {
        let token = try credentials(keychain: .found(blob(expiresIn: 3600))).read()
        XCTAssertEqual(token.accessToken, "cli-access")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(token.subscriptionType, "max")
    }

    func testAnExpiredTokenIsReportedAsExpiredNotUsed() {
        XCTAssertThrowsError(try credentials(keychain: .found(blob(expiresIn: -60))).read()) { error in
            XCTAssertEqual(error as? ClaudeCodeCLICredentials.ReadError, .expired(now.addingTimeInterval(-60)))
        }
    }

    func testFallsBackToTheCredentialsFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cli-\(UUID().uuidString).json")
        try blob(token: "from-file", expiresIn: 600).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let token = try credentials(keychain: .missing, files: [file]).read()
        XCTAssertEqual(token.accessToken, "from-file")
    }

    func testNothingStoredIsNotFound() {
        XCTAssertThrowsError(try credentials(keychain: .missing).read()) { error in
            XCTAssertEqual(error as? ClaudeCodeCLICredentials.ReadError, .notFound)
        }
    }

    func testTheVaultHandsOutNoRefreshToken() throws {
        let vault = ClaudeCodeCLIVault(credentials: credentials(keychain: .found(blob(expiresIn: 3600))))
        guard case .oauth(let tokens)? = try vault.load(UUID()) else { return XCTFail("expected a token") }
        XCTAssertNil(tokens.refreshToken)
        XCTAssertFalse(tokens.needsRefresh(at: now.addingTimeInterval(3590)))
    }

    /// A 401 on a CLI-backed account never reaches Anthropic's token endpoint.
    func testAnUnauthorizedReadNeverRenews() async throws {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let account = Account(kind: .claude, label: "CLI", localSource: .claudeCodeCLI)
        let vault = ClaudeCodeCLIVault(credentials: credentials(keychain: .found(blob(expiresIn: 60))))
        let runtime = AccountProviderRuntime(account: account, vault: vault, http: http, now: { [now] in now })
        _ = await runtime.refresh()
        XCTAssertFalse(http.requests.contains { $0.url.path.contains("oauth/token") }, "no renewal was attempted")
        XCTAssertTrue(http.requests.contains { $0.url.path == "/api/oauth/usage" })
    }

    func testTheAccountSourceRoundTripsAndOldEntriesDecode() throws {
        let account = Account(kind: .claude, label: "CLI", localSource: .claudeCodeCLI)
        let decoded = try JSONDecoder().decode(Account.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.localSource, .claudeCodeCLI)
        XCTAssertEqual(decoded.authMethod, .localCLI)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Account(kind: .claude, label: "Old"))) as! [String: Any]
        legacy.removeValue(forKey: "localSource")
        let old = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.localSource)
        XCTAssertEqual(old.authMethod, .oauth)
    }
}

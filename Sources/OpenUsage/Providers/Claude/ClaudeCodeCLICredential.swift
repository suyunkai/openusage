import Foundation
import os

/// Where an account's sign-in lives when OpenUsage doesn't hold it itself.
enum LocalCredentialSource: String, Codable, Sendable, Hashable {
    /// The login Claude Code's CLI stored on this Mac: the Keychain item `Claude Code-credentials`, or
    /// `~/.claude/.credentials.json` when the CLI keeps it in a file.
    case claudeCodeCLI
}

/// Reads the access token Claude Code's CLI stored, and never renews it.
///
/// Claude Code rotates its refresh token on every renewal, so renewing it here would sign the CLI out
/// of its own login. The token is read again on every pass instead: while the CLI is in use it renews
/// the token itself and writes it back, and the next read picks the new one up. Once it has expired and
/// the CLI hasn't run, there is nothing to read until it does.
struct ClaudeCodeCLICredentials: Sendable {
    struct Token: Sendable, Equatable {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
    }

    enum ReadError: LocalizedError, Equatable {
        case notFound
        case expired(Date)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notFound:
                L("No Claude Code CLI sign-in was found on this Mac. Run `claude` in Terminal and sign in, then try again.")
            case .expired:
                L("The Claude Code CLI sign-in has expired. Run `claude` in Terminal once and OpenUsage picks up the renewed sign-in.")
            case .unreadable:
                L("OpenUsage couldn't read the Claude Code CLI sign-in.")
            }
        }
    }

    static let keychainService = "Claude Code-credentials"
    /// Long enough for a person to read and answer the Keychain prompt.
    static let keychainDeadline: TimeInterval = 60
    /// After a prompt nobody answered, the Keychain is left alone this long so it isn't put up every pass.
    static let keychainPause: TimeInterval = 30 * 60

    var keychainService = Self.keychainService
    var credentialFiles: [URL] = Self.defaultCredentialFiles()
    var runSecurity: @Sendable (_ service: String, _ deadline: TimeInterval) -> SecurityResult = Self.findGenericPassword
    var now: @Sendable () -> Date = Date.init

    static func defaultCredentialFiles() -> [URL] {
        var files: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            files.append(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appending(path: ".credentials.json"))
        }
        files.append(URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/.credentials.json"))
        return files
    }

    /// The CLI's current token, or why there is none to use. The Keychain item comes first, as Claude
    /// Code keeps it there on macOS; the file is what it writes when it can't.
    func read() throws(ReadError) -> Token {
        var expired: Date?
        for blob in blobs() {
            guard let token = Self.parse(blob) else { continue }
            if let expiresAt = token.expiresAt, expiresAt <= now() {
                expired = max(expired ?? expiresAt, expiresAt)
                continue
            }
            return token
        }
        if let expired { throw .expired(expired) }
        throw .notFound
    }

    private func blobs() -> [Data] {
        var blobs: [Data] = []
        if !Self.keychainIsPaused(now: now()) {
            switch runSecurity(keychainService, Self.keychainDeadline) {
            case .found(let data): blobs.append(data)
            case .timedOut:
                Self.pauseKeychain(now: now())
                AppLog.warn(Self.tag, "Keychain read timed out; leaving the Keychain alone for 30 minutes")
            case .missing: break
            }
        }
        for file in credentialFiles {
            if let data = try? Data(contentsOf: file) { blobs.append(data) }
        }
        return blobs
    }

    /// `{"claudeAiOauth": {"accessToken": …, "expiresAt": <ms>, "subscriptionType": …}}`. The refresh
    /// token beside them is left where it is on purpose.
    static func parse(_ data: Data) -> Token? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else { return nil }
        let expiresAt = ProviderParse.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Token(accessToken: accessToken, expiresAt: expiresAt, subscriptionType: oauth["subscriptionType"] as? String)
    }

    // MARK: - Keychain

    enum SecurityResult: Sendable {
        case found(Data)
        case missing
        case timedOut
    }

    static let tag = LogTag.plugin("claude-cli")

    /// `security find-generic-password` rather than `SecItemCopyMatching`: the prompt then names
    /// `security`, and "Always Allow" on it survives rebuilding OpenUsage with a different signature.
    @Sendable static func findGenericPassword(service: String, deadline: TimeInterval) -> SecurityResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            AppLog.error(tag, "couldn't run security: \(error.localizedDescription)")
            return .missing
        }
        let collected = OSAllocatedUnfairLock(initialState: Data())
        let reader = DispatchQueue(label: "openusage.claude-cli.security")
        reader.async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            collected.withLock { $0 = data }
            done.signal()
        }
        // Both the exit and the end of output.
        let deadlineTime = DispatchTime.now() + deadline
        guard done.wait(timeout: deadlineTime) == .success, done.wait(timeout: deadlineTime) == .success else {
            process.terminate()
            return .timedOut
        }
        guard process.terminationStatus == 0 else { return .missing }
        let data = collected.withLock { $0 }
        return data.isEmpty ? .missing : .found(data)
    }

    private static let pause = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static func keychainIsPaused(now: Date) -> Bool {
        pause.withLock { until in until.map { now < $0 } ?? false }
    }

    static func pauseKeychain(now: Date) {
        pause.withLock { $0 = now.addingTimeInterval(keychainPause) }
    }
}

/// The vault behind an account whose sign-in is Claude Code's CLI login. Every load reads the CLI's
/// current token; nothing is written to the Keychain. The tokens it hands out carry no refresh token,
/// so the runtime's renewal paths (early renewal, renew-on-401) never run for them.
final class ClaudeCodeCLIVault: CredentialVault, @unchecked Sendable {
    static let shared = ClaudeCodeCLIVault()

    private let credentials: ClaudeCodeCLICredentials
    /// What the profile read learned about a token (its account identity), keyed by the token itself:
    /// a different token may belong to a different account once the CLI signs in again.
    private let extras = OSAllocatedUnfairLock<[String: [String: String]]>(initialState: [:])
    private let lastError = OSAllocatedUnfairLock<ClaudeCodeCLICredentials.ReadError?>(initialState: nil)

    init(credentials: ClaudeCodeCLICredentials = ClaudeCodeCLICredentials()) {
        self.credentials = credentials
    }

    /// Why the last load returned nothing, for the card's message.
    var lastReadError: ClaudeCodeCLICredentials.ReadError? { lastError.withLock { $0 } }

    func load(_ id: UUID) throws -> AccountCredential? {
        do {
            let token = try credentials.read()
            lastError.withLock { $0 = nil }
            let known = extras.withLock { $0[token.accessToken] } ?? [:]
            return .oauth(OAuthTokens(accessToken: token.accessToken, refreshToken: nil, expiresAt: token.expiresAt, extras: known))
        } catch {
            lastError.withLock { $0 = error }
            AppLog.notice(ClaudeCodeCLICredentials.tag, "no usable CLI token: \(error.localizedDescription)")
            return nil
        }
    }

    func save(_ credential: AccountCredential, for id: UUID) throws { remember(credential) }
    func update(_ credential: AccountCredential, for id: UUID) throws { remember(credential) }
    func delete(_ id: UUID) throws {}

    private func remember(_ credential: AccountCredential) {
        guard case .oauth(let tokens) = credential, !tokens.extras.isEmpty else { return }
        extras.withLock { known in
            if known.count > 16 { known.removeAll() }
            known[tokens.accessToken, default: [:]].merge(tokens.extras) { _, new in new }
        }
    }
}

/// Adds an account that reads Claude Code's CLI login: no browser, the CLI's token proves itself with
/// a profile read, and nothing of it is stored.
struct ClaudeCodeCLILogin: ProviderLogin {
    var credentials = ClaudeCodeCLICredentials()
    var http: any HTTPClient = URLSessionHTTPClient()

    func login(prompt: @Sendable (LoginPrompt) async -> Void, pastedCode: AsyncStream<String>) async throws -> (label: String, credential: AccountCredential) {
        let reader = credentials
        let token: ClaudeCodeCLICredentials.Token
        do {
            token = try await loadOffMainActor { try reader.read() }
        } catch let error as ClaudeCodeCLICredentials.ReadError {
            throw ProviderError.unavailable(error.localizedDescription)
        }
        let response = try await LoginHTTP.get(ClaudeUsageClient.profileURL, bearerToken: token.accessToken, using: http)
        if ProviderError.isAuthFailure(response) {
            throw ProviderError.unavailable(ClaudeCodeCLICredentials.ReadError.expired(Date()).localizedDescription)
        }
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let account = body["account"] as? [String: Any],
              let uuid = account["uuid"] as? String else {
            throw ProviderError.unavailable(L("Claude didn’t return the CLI account’s profile. Try again."))
        }
        let organization = (body["organization"] as? [String: Any])?["uuid"] as? String
        let identity = ClaudeAccountProfile.identity(accountUUID: uuid, organizationUUID: organization)
        let email = account["email"] as? String ?? body["email"] as? String
        let label = email.map { L("\($0) (CLI)") } ?? L("Claude Code CLI")
        let tokens = OAuthTokens(
            accessToken: token.accessToken, refreshToken: nil, expiresAt: token.expiresAt,
            extras: [OAuthTokens.identityKey: identity]
        )
        return (label, .oauth(tokens))
    }
}

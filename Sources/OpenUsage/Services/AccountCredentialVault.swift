import os
import Foundation
import Security

protocol CredentialVault: Sendable {
    func load(_ id: UUID) throws -> AccountCredential?
    func save(_ credential: AccountCredential, for id: UUID) throws
    func update(_ credential: AccountCredential, for id: UUID) throws
    func delete(_ id: UUID) throws
}

/// Holds one sign-in in memory, so a new one proves itself without seeing the sign-in it would replace.
struct ProvisionalCredentialVault: CredentialVault {
    private let stored: OSAllocatedUnfairLock<AccountCredential?>

    init(_ credential: AccountCredential) {
        stored = OSAllocatedUnfairLock(initialState: credential)
    }

    func load(_ id: UUID) throws -> AccountCredential? { stored.withLock { $0 } }
    func save(_ credential: AccountCredential, for id: UUID) throws { stored.withLock { $0 = credential } }
    func update(_ credential: AccountCredential, for id: UUID) throws { stored.withLock { $0 = credential } }
    func delete(_ id: UUID) throws { stored.withLock { $0 = nil } }
}

enum CredentialVaultError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        "This account's sign-in is missing from the Keychain. Sign in again from the account's page."
    }
}

struct KeychainCredentialVault: CredentialVault {
    static let service = "com.robinebers.openusage.accounts"
    private let items = KeychainItems(service: service)

    func load(_ id: UUID) throws -> AccountCredential? {
        try items.load(id).map { try JSONDecoder().decode(AccountCredential.self, from: $0) }
    }

    func save(_ credential: AccountCredential, for id: UUID) throws {
        try items.save(JSONEncoder().encode(credential), for: id)
    }

    func update(_ credential: AccountCredential, for id: UUID) throws {
        try items.update(JSONEncoder().encode(credential), for: id)
    }

    func delete(_ id: UUID) throws {
        try items.delete(id)
    }
}

/// The generic-password items of one Keychain service, one per id.
///
/// Every read and write goes through Apple's `/usr/bin/security` rather than `SecItem*`. This build is
/// signed with a self-signed identity that has no Team ID, so macOS can only remember an "Always Allow"
/// given to OpenUsage itself by the exact build (its cdhash), and every rebuild asked again for every
/// item. Granted to `security`, an Apple tool, the answer survives rebuilds. The trade-off, chosen on
/// purpose: anything that runs `security` can read these items without a prompt.
struct KeychainItems: Sendable {
    let service: String

    func load(_ id: UUID) throws -> Data? {
        let result = try SecurityTool.run(["find-generic-password", "-s", service, "-a", id.uuidString, "-g"])
        if result.status == SecurityTool.itemNotFound { return nil }
        guard result.status == 0 else { throw KeychainVaultError.tool(result.status, result.message) }
        guard let data = SecurityTool.password(fromDump: result.stderr) else {
            throw KeychainVaultError.tool(result.status, "unreadable password output")
        }
        return data
    }

    func save(_ data: Data, for id: UUID) throws {
        // Hex on stdin keeps the secret out of the process list; -U updates an existing item in place.
        let command = "add-generic-password -U -s \(service) -a \(id.uuidString) -X \(data.hexString)\n"
        let result = try SecurityTool.run(["-i"], input: Data(command.utf8))
        guard result.status == 0 else { throw KeychainVaultError.tool(result.status, result.message) }
    }

    func update(_ data: Data, for id: UUID) throws {
        // Attributes only, no secret: never prompts.
        let exists = try SecurityTool.run(["find-generic-password", "-s", service, "-a", id.uuidString])
        if exists.status == SecurityTool.itemNotFound { throw CredentialVaultError.missingCredential }
        guard exists.status == 0 else { throw KeychainVaultError.tool(exists.status, exists.message) }
        try save(data, for: id)
    }

    func delete(_ id: UUID) throws {
        let result = try SecurityTool.run(["delete-generic-password", "-s", service, "-a", id.uuidString])
        guard result.status == 0 || result.status == SecurityTool.itemNotFound else {
            throw KeychainVaultError.tool(result.status, result.message)
        }
    }
}

/// Runs `/usr/bin/security` with a deadline long enough for a person to answer its Keychain prompt.
enum SecurityTool {
    /// `security`'s exit status for errSecItemNotFound.
    static let itemNotFound: Int32 = 44
    static let deadline: TimeInterval = 120

    struct Result {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var message: String {
            String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func run(_ arguments: [String], input: Data? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let finished = DispatchGroup()
        let collected = OSAllocatedUnfairLock(initialState: (Data(), Data()))
        finished.enter(); finished.enter(); finished.enter()
        process.terminationHandler = { _ in finished.leave() }
        try process.run()
        DispatchQueue.global().async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            collected.withLock { $0.0 = data }
            finished.leave()
        }
        DispatchQueue.global().async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            collected.withLock { $0.1 = data }
            finished.leave()
        }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        guard finished.wait(timeout: .now() + deadline) == .success else {
            process.terminate()
            throw KeychainVaultError.tool(-1, "the Keychain prompt wasn't answered in time")
        }
        let (stdout, stderr) = collected.withLock { $0 }
        return Result(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// The secret from `find-generic-password -g`: `password: 0x<HEX>  "…"` for anything with special
    /// characters, `password: "<text>"` for plain text.
    static func password(fromDump stderr: Data) -> Data? {
        let text = String(decoding: stderr, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("password: ") }) else { return nil }
        let rest = line.dropFirst("password: ".count)
        if rest.hasPrefix("0x") {
            let hex = rest.dropFirst(2).prefix { $0.isHexDigit }
            return Data(hexString: String(hex))
        }
        guard rest.hasPrefix("\""), rest.count >= 2, rest.hasSuffix("\"") else { return rest.isEmpty ? Data() : nil }
        return Data(rest.dropFirst().dropLast().utf8)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

enum KeychainVaultError: LocalizedError {
    case status(OSStatus)
    case tool(Int32, String)

    var errorDescription: String? {
        switch self {
        case .tool(let status, let message):
            let reason = message.isEmpty ? "security exited \(status)" : message
            return L("OpenUsage couldn't use its Keychain item for this account (\(reason)).")
        case .status(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return L("OpenUsage couldn't use its Keychain item for this account (\(reason)).")
        }
    }
}

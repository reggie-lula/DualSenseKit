import Foundation
import Security

final class TokenService: @unchecked Sendable {
    private let service = "DualSenseKitDemo"
    private let account = "LocalAPIToken"
    private let tokenFileURL: URL

    init(tokenFileURL: URL? = nil) {
        let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DualSenseKitDemo", isDirectory: true)
        self.tokenFileURL = tokenFileURL ?? supportDirectory.appendingPathComponent("api-token")
    }

    var tokenFilePath: String {
        tokenFileURL.path
    }

    func token() -> String {
        if let fileToken = readTokenFile() {
            mirrorKeychain(fileToken)
            return fileToken
        }
        if let existing = readKeychainToken() {
            mirrorTokenFile(existing)
            return existing
        }
        let token = generateToken()
        mirrorTokenFile(token)
        mirrorKeychain(token)
        return token
    }

    func isAuthorized(headers: [String: String]) -> Bool {
        Self.isAuthorized(headers: headers, expectedToken: token())
    }

    static func isAuthorized(headers: [String: String], expectedToken: String) -> Bool {
        let expected = expectedToken
        if headers["x-dualsensebridge-token"] == expected {
            return true
        }
        if let authorization = headers["authorization"] {
            let parts = authorization.split(separator: " ", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[0].lowercased() == "bearer" && parts[1] == expected
        }
        return false
    }

    private func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes).base64EncodedString()
        }
        return UUID().uuidString + UUID().uuidString
    }

    private func readKeychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func readTokenFile() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func mirrorKeychain(_ token: String) {
        DispatchQueue.global(qos: .utility).async {
            self.saveKeychainToken(token)
        }
    }

    private func saveKeychainToken(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    private func mirrorTokenFile(_ token: String) {
        do {
            try FileManager.default.createDirectory(
                at: tokenFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: tokenFileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenFileURL.path
            )
        } catch {
            NSLog("DualSenseKitDemo token mirror failed: \(error)")
        }
    }
}

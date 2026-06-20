import ApplicationServices
import Foundation

public final class PermissionService: @unchecked Sendable {
    public init() {}

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    public func requestAccessibilityTrust() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

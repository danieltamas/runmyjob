import Foundation
import Security

/// Generic passwords in the login keychain, shared by the app and the CLI. This is the file keychain
/// (the data protection keychain needs an entitlement an ad hoc signed app cannot have), and its
/// per-application access lists are what the SecAccess calls below set. A read never shows the
/// system's allow/deny dialog: when macOS would ask, the read fails with `.denied` instead, so a
/// background process or a script cannot hang on a prompt nobody sees.
public struct Keychain: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case denied
        case failed(OSStatus)

        public var description: String {
            switch self {
            case .denied: "keychain access needs the user's approval (macOS would show a prompt)"
            case .failed(let status): "keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            }
        }
    }

    public let service: String

    /// The file keychain ignores kSecUseAuthenticationUI for item content; the one switch that
    /// stops its dialog is process-wide. The CLI, scripts and tests keep it off; only the app, which
    /// can show the allow/deny dialog, asks for `allowingPrompts`.
    public init(service: String = "ro.danieltamas.rmj", allowingPrompts: Bool = false) {
        // A headless process that could not switch the dialog off must not go on to read.
        precondition(SecKeychainSetUserInteractionAllowed(allowingPrompts) == errSecSuccess, "cannot set keychain interaction")
        self.service = service
    }

    /// Replaces the item. `trusting` lists the executables that may read it without a prompt, on top
    /// of the one that writes it; each is trusted by its code signature at this moment, so an
    /// ad hoc signed build stops being trusted as soon as it is replaced by another build.
    public func write(_ secret: String, account: String, trusting executables: [String] = []) throws {
        var trusted = [SecTrustedApplication]()
        var current: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &current) == errSecSuccess, let current else {
            throw Failure.failed(errSecInternalError)
        }
        trusted.append(current)
        for path in executables {
            var application: SecTrustedApplication?
            let status = SecTrustedApplicationCreateFromPath(path, &application)
            guard status == errSecSuccess, let application else { throw Failure.failed(status) }
            trusted.append(application)
        }
        var access: SecAccess?
        let made = SecAccessCreate("\(service) \(account)" as CFString, trusted as CFArray, &access)
        guard made == errSecSuccess, let access else { throw Failure.failed(made) }
        let identity: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        var status = SecItemAdd(identity.merging([kSecValueData: Data(secret.utf8), kSecAttrAccess: access]) { $1 } as CFDictionary, nil)
        // An existing item is updated in place: a failed replacement never loses the stored value.
        if status == errSecDuplicateItem {
            status = SecItemUpdate(identity as CFDictionary,
                                   [kSecValueData: Data(secret.utf8), kSecAttrAccess: access] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure.failed(status) }
    }

    /// The secret, or nil when there is no such item.
    public func read(account: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            throw Failure.denied
        default:
            throw Failure.failed(status)
        }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.failed(status) }
    }
}

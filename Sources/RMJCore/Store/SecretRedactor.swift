import Foundation

/// Replaces known secret values in a byte stream before anything is written. A value split across
/// two chunks is still found: only a tail that could be the start of a secret is held back until the next chunk, so
/// a live log is not delayed by the length of the longest secret.
struct SecretRedactor {
    static let replacement = Data("[redacted]".utf8)
    private let secrets: [Data]
    private var carry = Data()

    init(secrets: [String]) {
        self.secrets = secrets.filter { !$0.isEmpty }.map { Data($0.utf8) }.sorted { $0.count > $1.count }
    }

    mutating func process(_ chunk: Data) -> Data {
        guard !secrets.isEmpty else { return chunk }
        carry = redacted(carry + chunk)
        let emit = carry.count - pendingPrefix(of: carry)
        defer { carry = carry.suffix(carry.count - emit) }
        return carry.prefix(emit)
    }

    /// The length of the longest suffix of `data` that is a proper prefix of a secret.
    private func pendingPrefix(of data: Data) -> Int {
        var longest = 0
        for secret in secrets {
            var length = min(secret.count - 1, data.count)
            while length > longest {
                if data.suffix(length) == secret.prefix(length) { longest = length; break }
                length -= 1
            }
        }
        return longest
    }

    mutating func flush() -> Data {
        defer { carry = Data() }
        return redacted(carry)
    }

    private func redacted(_ data: Data) -> Data {
        var output = data
        for secret in secrets {
            var searchFrom = output.startIndex
            while let range = output.range(of: secret, in: searchFrom..<output.endIndex) {
                output.replaceSubrange(range, with: Self.replacement)
                searchFrom = range.lowerBound + Self.replacement.count
            }
        }
        return output
    }

    /// Text that is stored as a string (a reason, a command, a detail): the same replacement, whole-string.
    static func scrub(_ text: String, secrets: [String]) -> String {
        var redactor = SecretRedactor(secrets: secrets)
        let output = redactor.process(Data(text.utf8)) + redactor.flush()
        return String(decoding: output, as: UTF8.self)
    }
}

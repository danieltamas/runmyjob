import Foundation

/// A tool call with bad arguments: a JSON-RPC `-32602`.
struct BadArguments: Error {
    let message: String
}

/// A tool that ran and has nothing to give: `isError: true` with this text.
struct ToolFailure: Error {
    let message: String
}

/// The arguments of one call, checked against the tool's own list and types.
struct ToolArguments {
    let values: [String: Any]

    init(_ values: [String: Any], allowed: Set<String>) throws {
        if let extra = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw BadArguments(message: "unknown argument \(UntrustedText.clean(extra, limit: 40))")
        }
        self.values = values
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 4096 else { throw BadArguments(message: "\(key) must be a non-empty string") }
        return text
    }

    func required(_ key: String) throws -> String {
        guard let text = try string(key) else { throw BadArguments(message: "\(key) is required") }
        return text
    }

    func choice(_ key: String, _ allowed: [String]) throws -> String? {
        guard let text = try string(key) else { return nil }
        guard allowed.contains(text) else { throw BadArguments(message: "\(key) must be one of \(allowed.joined(separator: ", "))") }
        return text
    }

    func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded() == number.doubleValue, range.contains(number.intValue) else {
            throw BadArguments(message: "\(key) must be an integer from \(range.lowerBound) to \(range.upperBound)")
        }
        return number.intValue
    }

    /// `24h`, `7d`: at most 30 days.
    func window(_ key: String) throws -> TimeInterval? {
        guard let text = try string(key) else { return nil }
        guard let unit = text.last, "hd".contains(unit), text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(text.dropLast()),
              count > 0 else { throw BadArguments(message: "\(key) must look like 24h or 7d") }
        let seconds = Double(count) * (unit == "h" ? 3_600 : 86_400)
        guard seconds <= 30 * 86_400 else { throw BadArguments(message: "\(key) is at most 30d") }
        return seconds
    }

    func ulid(_ key: String) throws -> String {
        let id = try required(key)
        guard id.count == 26, id.allSatisfy({ $0.isASCII && ($0.isNumber || ($0.isUppercase && !"ILOU".contains($0))) }) else {
            throw BadArguments(message: "\(key) must be a job id (26 characters)")
        }
        return id
    }

    func words(_ key: String) throws -> [String] {
        guard let list = values[key] as? [String], !list.isEmpty, list.count <= 256, list.allSatisfy({ $0.utf8.count <= 16_384 }) else {
            throw BadArguments(message: "\(key) must be a non-empty list of strings")
        }
        return list
    }
}

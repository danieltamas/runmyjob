import Foundation

public enum CleanAction: String, Sendable, Equatable {
    case removed, wouldRemove = "would_remove", skipped, failed
}

public struct CleanItem: Sendable, Equatable {
    public let path: String
    public let kind: CleanTarget.Kind
    public let action: CleanAction
    public let reason: String
    public let bytes: Int

    public init(path: String, kind: CleanTarget.Kind, action: CleanAction, reason: String, bytes: Int) {
        self.path = path
        self.kind = kind
        self.action = action
        self.reason = reason
        self.bytes = bytes
    }
}

public struct CleanRun: Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public var finishedAt: Date
    public let apply: Bool
    public var items: [CleanItem]
    public var problem: String?

    public var freedBytes: Int { items.filter { $0.action == .removed }.reduce(0) { $0 + $1.bytes } }

    public init(id: String, startedAt: Date, finishedAt: Date, apply: Bool, items: [CleanItem] = [], problem: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.apply = apply
        self.items = items
        self.problem = problem
    }
}

import Foundation

public struct GHStep: Codable, Sendable, Equatable {
    public var name: String
    public var status: String?
    public var conclusion: String?
    public var number: Int

    public init(name: String, status: String?, conclusion: String?, number: Int) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.number = number
    }
}

public struct GHRun: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String?
    public var headBranch: String?
    public var headSha: String?
    public var event: String?
    public var status: String?
    public var conclusion: String?
    public var runAttempt: Int
    public var htmlUrl: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: Int64, name: String? = nil, headBranch: String? = nil, headSha: String? = nil, event: String? = nil,
                status: String?, conclusion: String? = nil, runAttempt: Int = 1, htmlUrl: String? = nil,
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.headBranch = headBranch
        self.headSha = headSha
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.runAttempt = runAttempt
        self.htmlUrl = htmlUrl
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GHJob: Codable, Sendable, Equatable {
    public var id: Int64
    public var runId: Int64
    public var runAttempt: Int
    public var name: String
    public var status: String?
    public var conclusion: String?
    public var createdAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?
    public var labels: [String]
    public var runnerName: String?
    public var htmlUrl: String?
    public var steps: [GHStep]?

    public init(id: Int64, runId: Int64, runAttempt: Int = 1, name: String, status: String?, conclusion: String? = nil,
                createdAt: Date? = nil, startedAt: Date? = nil, completedAt: Date? = nil, labels: [String] = [],
                runnerName: String? = nil, htmlUrl: String? = nil, steps: [GHStep]? = nil) {
        self.id = id
        self.runId = runId
        self.runAttempt = runAttempt
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.labels = labels
        self.runnerName = runnerName
        self.htmlUrl = htmlUrl
        self.steps = steps
    }
}

enum GitHubJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    struct Runs: Decodable { var workflowRuns: [GHRun] }
    struct Jobs: Decodable { var jobs: [GHJob] }
    struct Runners: Decodable {
        struct Runner: Decodable {
            struct Label: Decodable { var name: String }
            var name: String
            var status: String
            var busy: Bool
            var labels: [Label]
        }
        var runners: [Runner]
    }
}

/// One GitHub runner as the API lists it, with the destination whose runner stack registers it.
public struct RunnerRegistration: Sendable, Equatable {
    public var name: String
    public var labels: [String]
    public var online: Bool
    public var busy: Bool
    public var destination: String?

    public init(name: String, labels: [String], online: Bool, busy: Bool, destination: String? = nil) {
        self.name = name
        self.labels = labels
        self.online = online
        self.busy = busy
        self.destination = destination
    }
}

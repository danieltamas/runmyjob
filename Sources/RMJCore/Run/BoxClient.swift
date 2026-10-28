import Foundation

/// A launch record written by the box: the container started, or it could not.
public enum BoxLaunch: Sendable, Equatable {
    case started(container: String, bootID: String)
    case startFailed(String)

    public static func parse(_ line: String) -> BoxLaunch? {
        let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let kind = words.first else { return nil }
        if kind == "started", words.count == 3 { return .started(container: words[1], bootID: words[2]) }
        if kind == "start-failed" { return .startFailed(words.count > 1 ? words[1...].joined(separator: " ") : "unknown") }
        return nil
    }
}

/// What the box says about one job: its records and whether the container exists now.
public struct BoxRecord: Sendable, Equatable {
    public struct Result: Sendable, Equatable {
        public var code: Int
        public var cancelled: Bool
        public init(code: Int, cancelled: Bool = false) {
            self.code = code
            self.cancelled = cancelled
        }
    }

    public struct Meta: Sendable, Equatable {
        public var started: Date?
        public var finished: Date?
        public var exit: Int?
        public init(started: Date? = nil, finished: Date? = nil, exit: Int? = nil) {
            self.started = started
            self.finished = finished
            self.exit = exit
        }
    }

    public var containerPresent: Bool
    /// The box's boot id now.
    public var bootID: String
    public var launch: BoxLaunch?
    public var result: Result?
    public var meta: Meta?
    /// The box's clock when it answered; the engine turns it into the clock offset.
    public var boxNow: Date?
    /// Whether the box-side waiter of this job still runs: a live client keeps it alive from `begin` to the launch.
    public var waiterAlive: Bool?

    public init(containerPresent: Bool, bootID: String, launch: BoxLaunch? = nil, result: Result? = nil, meta: Meta? = nil, boxNow: Date? = nil) {
        self.boxNow = boxNow
        self.containerPresent = containerPresent
        self.bootID = bootID
        self.launch = launch
        self.result = result
        self.meta = meta
    }

    /// The output of `rx-run.sh job <ulid>`. Anything unrecognised is ignored: the box is untrusted text.
    public static func parse(_ text: String) -> BoxRecord? {
        var record = BoxRecord(containerPresent: false, bootID: "")
        var sawContainer = false
        for line in text.split(separator: "\n").map(String.init) {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2 else { continue }
            switch words[0] {
            case "container":
                let parts = words[1].split(separator: " ").map(String.init)
                guard parts.count == 2, parts[0] == "present" || parts[0] == "absent" else { continue }
                record.containerPresent = parts[0] == "present"
                record.bootID = parts[1]
                sawContainer = true
            case "launch": record.launch = BoxLaunch.parse(words[1])
            case "rc":
                let parts = words[1].split(separator: " ").map(String.init)
                if let code = parts.first.flatMap(Int.init) { record.result = Result(code: code, cancelled: parts.dropFirst().first == "cancelled") }
            case "waiter": record.waiterAlive = words[1] == "alive"
            case "now": record.boxNow = Int64(words[1]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            case "meta": record.meta = parseMeta(words[1])
            default: continue
            }
        }
        return sawContainer ? record : nil
    }

    private static func parseMeta(_ text: String) -> Meta {
        var meta = Meta()
        for pair in text.split(separator: " ") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "started": meta.started = date(kv[1])
            case "finished": meta.finished = date(kv[1])
            case "exit": meta.exit = Int(kv[1])
            default: continue
            }
        }
        return meta
    }

    /// Docker's RFC 3339 times carry nanoseconds; milliseconds are enough and always parse.
    static func date(_ text: String) -> Date? {
        guard text.hasPrefix("2"), !text.hasPrefix("0001") else { return nil }
        var value = text
        if let dot = value.firstIndex(of: "."), let zone = value[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = value[value.index(after: dot)..<zone].prefix(3)
            value = String(value[..<dot]) + "." + fraction + String(value[zone...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

/// Everything the box side needs to run one job.
public struct BoxJob: Sendable, Equatable {
    public let ulid: String
    public let name: String
    /// The checkout on the Mac.
    public let worktree: String
    /// Where the synced tree lives on the box (mounted at /work).
    public let directory: String
    public let argv: [String]
    /// `docker run` options between the name and the image.
    public let options: [String]
    public let image: String
    /// Lock files on the box that serialise runs sharing a server.
    public let locks: [String]
    /// A prelude script to ship to the box: its box path and contents.
    public let prelude: (path: String, content: String)?

    public init(ulid: String, name: String, worktree: String, directory: String, argv: [String], options: [String],
                image: String, locks: [String] = [], prelude: (path: String, content: String)? = nil) {
        self.ulid = ulid
        self.name = name
        self.worktree = worktree
        self.directory = directory
        self.argv = argv
        self.options = options
        self.image = image
        self.locks = locks
        self.prelude = prelude
    }

    public static func == (lhs: BoxJob, rhs: BoxJob) -> Bool {
        lhs.ulid == rhs.ulid && lhs.name == rhs.name && lhs.argv == rhs.argv && lhs.directory == rhs.directory
            && lhs.options == rhs.options && lhs.image == rhs.image && lhs.locks == rhs.locks
    }
}

/// One destination, as the engine uses it. The real implementation speaks ssh and rsync to `rx-run.sh`;
/// tests supply a fake. Errors thrown are transport failures; a command's own failure is a record.
public protocol BoxClient: Sendable {
    /// Ships the box script (and the job's prelude) when the box's copy differs.
    func prepare(_ job: BoxJob) async throws
    /// Takes the job's locks on the box and creates its directory; returns once held. `waiting` gets the
    /// id of the job being waited for, when there is one.
    func begin(_ job: BoxJob, waiting: @escaping @Sendable (String) -> Void) async throws
    /// Mirrors the checkout into the job's directory (only after `begin`).
    func sync(_ job: BoxJob) async throws
    /// Starts the container and reports the launch record.
    func go(_ job: BoxJob) async throws -> BoxLaunch
    /// Streams the log from the start until the run ends. Returning normally means the run ended.
    func tail(_ job: BoxJob, output: @escaping @Sendable (Data) -> Void) async throws
    func record(ulid: String) async throws -> BoxRecord
    /// The whole log so far.
    func pullLog(ulid: String, output: @escaping @Sendable (Data) -> Void) async throws
    /// Removes the container by its label and stops a waiter that has not started.
    func cancel(ulid: String) async throws
}

public protocol BoxFactory: Sendable {
    func client(destination: String, address: String, config: DestinationConfig) -> BoxClient
}

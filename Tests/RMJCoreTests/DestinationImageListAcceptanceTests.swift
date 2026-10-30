import Foundation
import Testing
@testable import RMJCore

private let destinationImagesNow = Date(timeIntervalSince1970: 1_793_102_400)

private func destinationImagesRules(image: String? = nil, profile: String? = nil,
                                    routedTo: String = "ai-eu-1") throws -> Rules {
    var rules = Rules.shipped
    rules.destinations = ["ai-eu-1": try #require(rules.destinations["ai-eu-1"])]
    if image != nil || profile != nil {
        var rule = try #require(rules.rules.first)
        rule.image = image
        rule.profile = profile
        rule.to = [routedTo]
        rules.rules = [rule]
    } else {
        rules.rules = []
    }
    return rules
}

private func destinationImagesProbe(_ images: Reading<[String]>) -> DestinationProbeResult {
    DestinationProbeResult(
        availability: .online(address: "100.64.0.10"),
        docker: .ok("27.3", at: destinationImagesNow),
        rsync: .ok("3.3", at: destinationImagesNow), images: images,
        containers: .ok([], at: destinationImagesNow), cores: nil,
        memoryFreeMB: nil, memoryTotalMB: nil, diskTotalMB: nil, diskFreeMB: nil,
        osName: nil, load: nil, bootID: nil, uptime: nil, clockOffsetMS: nil,
        probedAt: destinationImagesNow
    )
}

private func destinationImagesCard(rules: Rules, probe: DestinationProbeResult?,
                                   profiles: ProfileStore? = nil) throws -> DestinationCardInput {
    let tailnet = TailnetState.parse(Data("{}".utf8), readAt: destinationImagesNow)
    let cards = DestinationLoader().cards(
        rules: rules, tailnet: tailnet, jobs: [],
        probes: probe.map { ["ai-eu-1": $0] } ?? [:], runners: [:], profiles: profiles,
        now: destinationImagesNow
    )
    #expect(cards.count == 1)
    return try #require(cards.first)
}

struct DestinationImageListAcceptanceTests {
    @Test(arguments: [
        ("python:3.12", "ai-eu-1", ["python:3.12"]),
        ("python", "ai-eu-1", ["python:3.11", "python:3.12"]),
        ("python:3.12", "s1", [])
    ])
    func profileImagesRespectTagsAndDestination(image: String, destination: String, expected: [String]) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        let directory = home.url.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(["image": image]).write(to: directory.appendingPathComponent("py.json"))
        let images = ["python:3.11", "redis:7-alpine", "python:3.12"]
        let card = try destinationImagesCard(
            rules: destinationImagesRules(profile: "py", routedTo: destination),
            probe: destinationImagesProbe(.ok(images, at: destinationImagesNow)),
            profiles: ProfileStore(home: home)
        )
        #expect(card.images == expected)
        #expect(card.otherImages == images.count - expected.count)
    }

    @Test func absentProfileStoreOrMissingProfileShowsNothingExtra() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = RMJHome(environment: ["RMJ_HOME": root.path])
        let directory = home.url.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"image":"python:3.12"}"#.utf8).write(to: directory.appendingPathComponent("py.json"))
        let probe = destinationImagesProbe(.ok([
            "python:3.11", "redis:7-alpine", "python:3.12"
        ], at: destinationImagesNow))
        let defaultCard = try destinationImagesCard(rules: destinationImagesRules(profile: "py"), probe: probe)
        let nilCard = try destinationImagesCard(
            rules: destinationImagesRules(profile: "py"), probe: probe, profiles: nil
        )
        let missingCard = try destinationImagesCard(
            rules: destinationImagesRules(profile: "missing"), probe: probe, profiles: ProfileStore(home: home)
        )
        for card in [defaultCard, nilCard, missingCard] {
            #expect(card.images.isEmpty)
            #expect(card.otherImages == 3)
        }
    }

    @Test func realBoxShowsOnlyToolchainAndRunnerImagesInProbeOrder() throws {
        let images = [
            "rx-rust:latest", "gh-runner-rust:2.338.2", "gh-runner:2.338.2",
            "redis:7-alpine", "ghcr.io/actions/actions-runner:2.338.2",
            "pgvector/pgvector:pg17", "postgres:16", "alpine:3.20"
        ]
        let card = try destinationImagesCard(
            rules: destinationImagesRules(),
            probe: destinationImagesProbe(.ok(images, at: destinationImagesNow))
        )
        #expect(card.images == [
            "rx-rust:latest", "gh-runner-rust:2.338.2", "gh-runner:2.338.2",
            "ghcr.io/actions/actions-runner:2.338.2"
        ])
        #expect(card.otherImages == 4)
    }

    @Test(arguments: [
        ("python:3.12", "ai-eu-1", ["python:3.12"]),
        ("python", "ai-eu-1", ["python:3.11", "python:3.12"]),
        ("python:3.12", "s1", [])
    ])
    func ruleImagesRespectTagsAndDestination(image: String, destination: String, expected: [String]) throws {
        let images = ["python:3.11", "redis:7-alpine", "python:3.12", "nginx:1.28-alpine"]
        let card = try destinationImagesCard(
            rules: destinationImagesRules(image: image, routedTo: destination),
            probe: destinationImagesProbe(.ok(images, at: destinationImagesNow))
        )
        #expect(card.images == expected)
        #expect(card.otherImages == images.count - expected.count)
    }

    @Test(arguments: ["registry.example:5000/team/python", "registry.example:5000/team/python:3.12"])
    func registryPortIsNotAnImageTag(image: String) throws {
        let card = try destinationImagesCard(
            rules: destinationImagesRules(image: image),
            probe: destinationImagesProbe(.ok([
                "registry.example:5000/team/python:3.12", "registry.example:5000/team/python:3.11"
            ], at: destinationImagesNow))
        )
        let expected = image.hasSuffix(":3.12")
            ? ["registry.example:5000/team/python:3.12"]
            : ["registry.example:5000/team/python:3.12", "registry.example:5000/team/python:3.11"]
        #expect(card.images == expected)
        #expect(card.otherImages == 2 - expected.count)
    }

    @Test func untaggedToolchainRuleKeepsLatestAndUnrelatedRepositoriesStayHidden() throws {
        let card = try destinationImagesCard(
            rules: destinationImagesRules(image: "rx-ledger"),
            probe: destinationImagesProbe(.ok([
                "ollama", "rx-ledger:latest", "pyrunner-pyrunner:latest",
                "gh-runnerish:latest", "ghcr.io/actions/actions-runner-extra:latest"
            ], at: destinationImagesNow))
        )
        #expect(card.images == ["rx-ledger:latest"])
        #expect(card.otherImages == 4)
    }

    @Test(arguments: ["absent", "unavailable", "failed", "empty"])
    func noImageReadingHasNoImagesOrOtherCount(kind: String) throws {
        let probe: DestinationProbeResult?
        switch kind {
        case "absent": probe = nil
        case "unavailable": probe = destinationImagesProbe(.unavailable("docker missing", at: destinationImagesNow))
        case "failed": probe = destinationImagesProbe(.failed("probe failed", at: destinationImagesNow))
        default: probe = destinationImagesProbe(.ok([], at: destinationImagesNow))
        }
        let card = try destinationImagesCard(rules: destinationImagesRules(image: "python:3.12"), probe: probe)
        #expect(card.images.isEmpty)
        #expect(card.otherImages == 0)
    }

    @Test func presentationCopiesOtherImagesAndInputDefaultsToZero() throws {
        let config = try #require(destinationImagesRules().destinations["ai-eu-1"])
        var input = DestinationCardInput(name: "ai-eu-1", config: config,
                                        availability: .online(address: "100.64.0.10"))
        #expect(input.otherImages == 0)
        #expect(DestinationCardPresentation(input, now: destinationImagesNow).otherImages == 0)
        input = DestinationCardInput(name: "ai-eu-1", config: config,
                                    availability: .online(address: "100.64.0.10"),
                                    images: ["rx-rust:latest"], otherImages: 4, pollInterval: 60)
        input.otherImages = 7
        let presentation = DestinationCardPresentation(input, now: destinationImagesNow)
        #expect(presentation.otherImages == 7)
        #expect(presentation.images.map(\.label) == ["rx-rust:latest"])
    }
}

import Testing
import Foundation
import RMJCore

private func tenantRunnerRules(targets: [String]) throws -> Rules {
    var rules = Rules.shipped
    rules.destinations = ["ai-eu-1": try #require(rules.destinations["ai-eu-1"])]
    rules.destinations["ai-eu-1"]?.runnerTargets = targets
    rules.tenants = try JSONDecoder().decode([String: TenantConfig].self, from: Data("""
    {
      "acme": {"owners": ["acme", "Acme"]},
      "globex": {"owners": ["globexco"], "repos": ["acme/globex*"]}
    }
    """.utf8))
    rules.rules = []
    return rules
}

struct TenantRunnerTargetAcceptanceTests {
    @Test(arguments: ["globexco/app", "org:globexco"])
    func rejectsRunnerTargetsOwnedByAnotherTenant(target: String) throws {
        let data = try JSONEncoder().encode(tenantRunnerRules(targets: [target]))
        do {
            _ = try RulesValidation.parse(data)
            Issue.record("An acme destination accepted globex target \(target)")
        } catch let error as RulesError {
            #expect(error.message.contains(target))
        } catch {
            Issue.record("Expected RulesError naming \(target), got \(error)")
        }
    }

    @Test func acceptsCaseInsensitiveOrganizationOwner() throws {
        let rules = try tenantRunnerRules(targets: ["org:acme"])
        #expect(try RulesValidation.parse(JSONEncoder().encode(rules)) == rules)
    }

    @Test func anotherTenantsRepoGlobOverridesOwner() throws {
        let target = "acme/globexthing"
        let data = try JSONEncoder().encode(tenantRunnerRules(targets: [target]))
        do {
            _ = try RulesValidation.parse(data)
            Issue.record("The globex repo claim must override acme's owner claim")
        } catch let error as RulesError {
            #expect(error.message.contains(target))
        } catch {
            Issue.record("Expected RulesError naming \(target), got \(error)")
        }
    }

    @Test func acceptsOnlyAcmeRunnerTargets() throws {
        let rules = try tenantRunnerRules(targets: ["acme/app", "Acme/service", "org:Acme"])
        #expect(try RulesValidation.parse(JSONEncoder().encode(rules)) == rules)
    }

    @Test(arguments: ["globexco/app", "org:globexco", "org:acme"])
    func githubRoutingNeverReturnsAnotherTenantsDestination(target: String) throws {
        // Decode directly: routing must also enforce isolation on an unvalidated Rules value.
        var rules = try tenantRunnerRules(targets: [target])
        var globex = try #require(rules.destinations["ai-eu-1"])
        globex.tenant = "globex"
        globex.peerID = "n-globex-fixture"
        globex.sshAlias = "globex-fixture"
        globex.runnerTargets = ["org:globexco", "acme/globexthing"]
        rules.destinations["globex-fixture"] = globex
        let repo = target == "org:acme" ? "acme/globexthing" : "globexco/app"
        let destinations = GitHubRouting.destinations(forRepo: repo, rules: rules)
        #expect(destinations == ["globex-fixture"])
        #expect(destinations.allSatisfy { rules.destinations[$0]?.tenant == "globex" })
    }

    @Test func githubRoutingKeepsSameTenantTargets() throws {
        let rules = try tenantRunnerRules(targets: ["org:acme", "acme/app"])
        for repo in ["Acme/service", "ACME/APP"] {
            #expect(GitHubRouting.destinations(forRepo: repo, rules: rules) == ["ai-eu-1"])
        }
    }
}

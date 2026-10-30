import Foundation
import Testing
import RMJCore

struct BuildEnvironmentsAcceptanceTests {
    @Test func catalogPinsImagesAndValidDistinctTools() throws {
        let catalog = BuildEnvironments.catalog
        #expect(catalog.count == 5)
        #expect(Set(catalog.map(\.image)) == ["rx-rust", "rx-node", "rx-python", "rx-go", "rx-claude"])
        for entry in catalog {
            #expect(entry.tools.allSatisfy(DestinationConfig.isProgramName))
            #expect(Set(entry.tools).count == entry.tools.count)
            #expect(Set(["bash", "git"]).isSubset(of: Set(entry.tools)))
            if entry.image != "rx-claude" { #expect(entry.tools.contains("zsh")) }
        }
        let rust = try #require(catalog.first { $0.image == "rx-rust" })
        let node = try #require(catalog.first { $0.image == "rx-node" })
        #expect(Set(["just", "cargo"]).isSubset(of: Set(rust.tools)))
        #expect(Set(["node", "bun"]).isSubset(of: Set(node.tools)))
        let python = try #require(catalog.first { $0.image == "rx-python" })
        let go = try #require(catalog.first { $0.image == "rx-go" })
        #expect(Set(["python3", "uv", "pytest"]).isSubset(of: Set(python.tools)))
        #expect(go.tools.contains("go"))
        let claude = try #require(catalog.first { $0.image == "rx-claude" })
        #expect(Set(claude.tools) == ["bash", "git", "jq", "claude"])
        #expect(BuildEnvironments.tools(for: "rx-python") == python.tools)
        #expect(BuildEnvironments.tools(for: "rx-go") == go.tools)
        #expect(BuildEnvironments.tools(for: "rx-rust") == rust.tools)
        #expect(BuildEnvironments.tools(for: "ubuntu").isEmpty)
    }

    @Test func shippedDockerfilesStartFromBaseAndInstallCommonTools() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for entry in BuildEnvironments.catalog {
            let file = root.appendingPathComponent("Support/box/images/\(entry.image.dropFirst(3))/Dockerfile")
            let exists = FileManager.default.fileExists(atPath: file.path)
            #expect(exists, "Missing shipped Dockerfile: \(file.path)")
            guard exists else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }
            #expect(first?.hasPrefix("FROM ") == true)
            for tool in entry.image == "rx-claude" ? ["git", "bash", "jq", "claude"] : ["zsh", "git", "bash"] {
                #expect(text.range(of: "\\b" + tool + "\\b", options: .regularExpression) != nil)
            }
        }
    }
}

import Foundation
import Testing
import RMJCore

struct BuildEnvironmentsAcceptanceTests {
    @Test func catalogPinsImagesAndValidDistinctTools() throws {
        let catalog = BuildEnvironments.catalog
        #expect(catalog.count == 2)
        #expect(Set(catalog.map(\.image)) == ["rx-rust", "rx-node"])
        for entry in catalog {
            #expect(entry.tools.allSatisfy(DestinationConfig.isProgramName))
            #expect(Set(entry.tools).count == entry.tools.count)
            #expect(Set(["bash", "zsh", "git"]).isSubset(of: Set(entry.tools)))
        }
        let rust = try #require(catalog.first { $0.image == "rx-rust" })
        let node = try #require(catalog.first { $0.image == "rx-node" })
        #expect(Set(["just", "cargo"]).isSubset(of: Set(rust.tools)))
        #expect(Set(["node", "bun"]).isSubset(of: Set(node.tools)))
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
            for tool in ["zsh", "git", "bash"] {
                #expect(text.range(of: "\\b" + tool + "\\b", options: .regularExpression) != nil)
            }
        }
    }
}

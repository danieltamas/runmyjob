import Testing
import Foundation
import RMJCore

private let guardCases = #"""
# want<TAB>cwd<TAB>command   (cwd: rust = an eligible Cargo repo, globex = no build host, plain = not a repo)
block	rust	cargo test
block	rust	cargo test --all
block	rust	cargo +nightly clippy --all-targets
block	rust	cargo check
block	rust	cargo nextest run
block	rust	cargo fmt --all -- --check
block	rust	just check
block	rust	just test
block	rust	echo start && cargo test
block	rust	cd crates/axon-core && cargo test
block	plain	cd /fixtures/rust && cargo test
block	rust	bash scripts/check.sh --fast
block	rust	./scripts/check.sh
context	rust	cargo build --release
context	rust	cargo build
allow	rust	cargo fmt --all
allow	rust	cargo run --bin axon
allow	rust	cargo install just
allow	rust	rx -- cargo test
allow	rust	RX_LOCAL=1 cargo test
allow	rust	git log --grep "cargo test"
allow	rust	echo "cargo test"
allow	globex	cargo test
allow	globex	bash scripts/check.sh --fast
allow	plain	cargo test
allow	plain	just check
allow	rust	ls scripts/check.sh
allow	rust	cat scripts/check.sh
# text that only names a build command is not a command: quotes, heredoc bodies, markdown backticks
allow	rust	git commit -m "ci: run just check on the runner"
allow	rust	git commit -m 'gate: cargo test is green'
allow	rust	cat > pr.md <<'EOF'\n- `just check` green on the box\ncargo test passes\nEOF\ngh pr create --body-file pr.md
allow	rust	cat <<EOF\ncargo test\nEOF
allow	rust	echo "`cargo test`"
block	rust	bash -c 'cargo test'
block	rust	sh -c "cd crates/axon-core && cargo clippy"
block	rust	echo start\ncargo test
block	rust	cat <<'EOF' > notes.md\nnotes\nEOF\njust check
allow	rust	echo 'it''s fine' && echo "a \"quoted\" cargo test"
"""#

private func guardDecision(_ command: String, cwd: String, destination: String = "ai-eu-1") async -> CommandGuard.Verdict {
    await CommandGuard.verdict(command: command, cwd: cwd, classify: { directory in
        if directory.contains("/rust") { return .classified(repo: "acme/orbit") }
        if directory.contains("/globex") { return .unclassified(repo: "globex/portal") }
        return .notRepo
    }, destination: { _, _ in destination })
}

@Test func commandGuardPortsAllReferenceCases() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RMJ-Guard-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rows = guardCases.split(separator: "\n").filter { !$0.hasPrefix("#") }
    #expect(rows.count == 38)
    for row in rows {
        let fields = row.split(separator: "\t", maxSplits: 2).map(String.init)
        try #require(fields.count == 3)
        let command = fields[2].replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: "/fixtures/rust", with: root.appendingPathComponent("rust").path)
        let verdict = await guardDecision(command, cwd: root.appendingPathComponent(fields[1]).path)
        switch (fields[0], fields[1], verdict) {
        case ("block", _, .block), ("context", _, .advise): break
        case ("allow", "globex", .advise(let text)): #expect(text.contains("globex/portal"))
        case ("allow", _, .allow): #expect(fields[1] != "globex", "Must advise: \(row)")
        default: Issue.record("Unexpected \(verdict) for \(row)")
        }
    }
}

@Test func commandGuardHandlesContextAndExplicitRouting() async {
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("rust-\(UUID())").path
    for command in ["cd dir && cargo test", "FOO=1 cargo test", "bash -c 'cargo test'",
                    "(cargo test)", "cargo test || true", "cat <<'EOF'\ncargo test\nEOF\ncargo test"] {
        guard case .block = await guardDecision(command, cwd: cwd) else {
            Issue.record("Must block: \(command)"); continue
        }
    }
    for command in ["RX_LOCAL=1 cargo test", "FOO=1 RX_LOCAL=1 cargo test",
                    "rmj run -- cargo test", "rmj run --shell -- 'cd x && cargo test'"] {
        #expect(await guardDecision(command, cwd: cwd) == .allow)
    }
    for command in ["cargo test", "scripts/check.sh", "just check"] {
        guard case .advise(let text) = await guardDecision(command, cwd: "/tmp/globex") else {
            Issue.record("Must advise: \(command)"); continue
        }
        #expect(text.contains("globex/portal"))
        #expect(await guardDecision(command, cwd: "/tmp/plain") == .allow)
    }
}

@Test func commandGuardBlockTextProvidesRunFormAndLocalDestination() async {
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("rust-\(UUID())").path
    let escapedQuote = "'" + "\\" + "''"
    let forms = [
        ("cargo test", "rmj run -- cargo test"),
        ("cd dir && cargo test", "rmj run --shell -- 'cd dir && cargo test'"),
        ("cargo test | cat", "rmj run --shell -- 'cargo test | cat'"),
        ("FOO=1 cargo test", "rmj run --shell -- 'FOO=1 cargo test'"),
        ("bash -c 'cargo test'", "rmj run --shell -- 'bash -c " + escapedQuote + "cargo test" + escapedQuote + "'")
    ]
    for (command, form) in forms {
        guard case .block(let text) = await guardDecision(command, cwd: cwd) else {
            Issue.record("Must block: \(command)"); continue
        }
        #expect(text.contains(form))
        #expect(text.contains("ai-eu-1"))
    }
    guard case .block(let text) = await guardDecision("cargo test", cwd: cwd, destination: "this Mac") else {
        Issue.record("Local routing must still block"); return
    }
    #expect(text.contains("this Mac"))
    #expect(text.contains("rmj run -- cargo test"))
    guard case .advise = await guardDecision("cargo build", cwd: cwd) else {
        Issue.record("cargo build must advise"); return
    }
}

@Test func commandGuardKindsAndResolvedDirectories() {
    for command in ["cargo test", "cargo check", "just check", "scripts/check.sh"] {
        #expect(CommandGuard.kind(of: command) == .check)
    }
    #expect(CommandGuard.kind(of: "cargo build") == .build)
    for command in ["echo 'cargo test'", "RX_LOCAL=1 cargo test", "rmj run -- cargo test"] {
        #expect(CommandGuard.kind(of: command) == nil)
    }
    let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("RMJ-Directory-\(UUID())").path
    #expect(CommandGuard.directory(of: "cd child && cargo test", cwd: cwd) == cwd + "/child")
    #expect(CommandGuard.directory(of: "cd /absolute && cargo test", cwd: cwd) == "/absolute")
    #expect(CommandGuard.directory(of: "cargo test", cwd: cwd) == cwd)
    // Pure expansion only: no real home directory is read or written.
    #expect(CommandGuard.directory(of: "cd ~/child && cargo test", cwd: cwd) == NSHomeDirectory() + "/child")
}

@Test func commandGuardAllowsClassifiedRepoWithoutMatchingRule() async {
    for command in ["cargo test", "just check", "scripts/check.sh", "cargo build"] {
        let verdict = await CommandGuard.verdict(command: command, cwd: "/tmp/acme", classify: { _ in
            .classified(repo: "acme/orbit")
        }, destination: { _, _ in nil })
        #expect(verdict == .allow, "No rule names the repo: \(command)")
    }
}

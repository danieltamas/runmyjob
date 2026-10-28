import Foundation
import RMJCore

extension Rules {
    static let shippedJSON = """
{
  "destinations": {
    "ai-eu-1": {
      "enabled": true, "peer_id": "nAcmeBox0001CNTRL", "ssh_alias": "ai-eu-1", "tenant": "acme",
      "roles": ["rx", "runners"], "home": "/home/builder", "max_jobs": 3, "memory_budget": "36g",
      "rx_defaults": { "cpus": 8, "memory": "12g" }, "runner_stack": "/home/builder/infra/gh-runners",
      "runner_targets": ["acme/ledger", "acme/atlas", "org:Acme"]
    },
    "s1": {
      "enabled": false, "peer_id": "", "ssh_alias": "s1", "tenant": "globex",
      "roles": ["rx", "runners"], "home": "/home/globex", "max_jobs": 2, "memory_budget": "24g",
      "runner_targets": ["org:globex"]
    }
  },
  "tenants": {
    "acme": { "owners": ["acme"], "repos": ["acme/ledger", "acme/atlas"] },
    "globex": { "owners": ["globex"], "repos": ["globex/portal*", "globex/gateway*"] },
    "personal": { "shared": true, "repos": ["acme/axon", "acme/run.dev", "acme/cloak",
                            "acme/bton", "acme/macmax", "danieltamas/runmyjob"] }
  },
  "rules": [
    { "name": "cargo build stays local (the box builds x86_64)",
      "match": { "command": ["cargo build"] }, "to": ["local"],
      "advisory": "the box builds x86_64 Linux binaries; a binary for this Mac is built here" },
    { "name": "cargo repos to the rust image",
      "match": { "tenant": ["acme", "personal"], "command": ["cargo", "just"], "has": "Cargo.toml" },
      "to": ["ai-eu-1"], "image": "rx-rust",
      "volumes": ["rx-cargo-registry:/usr/local/cargo/registry", "rx-cargo-git:/usr/local/cargo/git",
                  "rx-rustup:/usr/local/rustup", "rx-target-{repo}:/work/target"],
      "cold_marker": { "acme/atlas": "Compiling libduckdb-sys" } },
    { "name": "ledger gate image with its dev pair",
      "match": { "repo": ["acme/ledger"] }, "to": ["ai-eu-1"], "profile": "ledger" },
    { "name": "Globex repos to s1",
      "match": { "tenant": ["globex"] }, "to": ["s1"], "image": "rx-node" }
  ]
}
"""

    static var shipped: Rules {
        try! JSONDecoder().decode(Rules.self, from: Data(shippedJSON.utf8))
    }
}

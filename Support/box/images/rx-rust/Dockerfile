# rx-rust: the container `rmj run` runs cargo commands in on a destination, for Rust repos. Built on the box:
#   docker build -t rx-rust <home>/infra/rx
# Caches live on named volumes mounted by rx (cargo registry and git, rustup, one target dir per
# repo), so a repo's rust-toolchain.toml pin installs once and every later run is warm.
FROM rust:1.96-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      git pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# `just check` recipes commonly need both; one slow compile at image build, never per run.
RUN cargo install --locked just cargo-deny && rm -rf /usr/local/cargo/registry \
    && mkdir -p /usr/local/cargo/registry /usr/local/cargo/git

# uid 1000 is the box user on a default Linux install: the synced tree is bind-mounted and must stay writable by it,
# and a volume first mounted on a directory inherits that directory's owner (so every mount point
# above exists and is chowned here, or the volume comes up root-owned and cargo cannot write).
RUN useradd -m -u 1000 rx \
    && mkdir /target /work \
    && chown -R rx /usr/local/cargo /usr/local/rustup /target /work
USER rx
ENV CARGO_TARGET_DIR=/target \
    CARGO_BUILD_JOBS=8 \
    CARGO_TERM_COLOR=always \
    CARGO_INCREMENTAL=1
WORKDIR /work

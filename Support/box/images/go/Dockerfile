# rx-go: the container `rmj run` runs go commands in on a destination. Built on the box by Setup:
#   docker build --label rmj.dockerfile=<sha256 of this file> -t rx-go -
# zsh and bash because repo scripts and tests call them: jobs run in this container, never on the box itself.
FROM golang:1.23-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash zsh git jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# uid 1000 is the box user on a default Linux install: the synced tree is bind-mounted and must stay writable by it.
# The job runs as the box user's own uid, whatever it is: HOME and the Go caches sit in /tmp, which any uid can write.
RUN useradd -m -u 1000 rx && mkdir /work && chown rx /work
USER rx
ENV CI=true \
    HOME=/tmp \
    GOPATH=/tmp/go \
    GOCACHE=/tmp/go-build \
    GOFLAGS=-buildvcs=false
WORKDIR /work

# rx-codex: the container `rmj agent run` runs Codex in on a destination. Built on the box by Setup:
#   docker build --label rmj.dockerfile=<sha256 of this file> -t rx-codex -
# The login is not in the image: the prelude moves it in from a tmpfs mount for the run and the container takes it along.
FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @openai/codex

# uid 1000 is the box user on a default Linux install: the synced tree is bind-mounted and must stay writable by it.
# The run uses the box user's own uid, so HOME and the harness state live in /tmp.
RUN usermod -l rx -d /home/rx -m node && groupmod -n rx node \
    && mkdir -p /work && chown rx:rx /work
USER rx
ENV HOME=/tmp CI=true CODEX_HOME=/tmp/.codex
WORKDIR /work

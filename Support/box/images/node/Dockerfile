# rx-node: the container `rmj run` runs node and bun commands in on a destination. Built on the box by Setup:
#   docker build --label rmj.dockerfile=<sha256 of this file> -t rx-node -
# zsh and bash because repo scripts and tests call them: jobs run in this container, never on the box itself.
FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash zsh git jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g bun

# uid 1000 is the box user on a default Linux install: the synced tree is bind-mounted and must stay writable by it.
# The base image's `node` user already has that uid; it becomes `rx` so every image names its user the same.
RUN usermod -l rx -d /home/rx -m node && groupmod -n rx node \
    && mkdir -p /work /home/rx/.bun /home/rx/.npm && chown -R rx:rx /work /home/rx
USER rx
ENV CI=true \
    NPM_CONFIG_UPDATE_NOTIFIER=false
WORKDIR /work

# rx-python: the container `rmj run` runs python commands in on a destination. Built on the box by Setup:
#   docker build --label rmj.dockerfile=<sha256 of this file> -t rx-python -
# zsh and bash because repo scripts and tests call them: jobs run in this container, never on the box itself.
FROM python:3.12-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash zsh git jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir uv pytest

# uid 1000 is the box user on a default Linux install: the synced tree is bind-mounted and must stay writable by it.
# The job runs as the box user's own uid, whatever it is: HOME and the uv cache sit in /tmp, which any uid can write.
RUN useradd -m -u 1000 rx && mkdir /work && chown rx /work
USER rx
ENV CI=true \
    HOME=/tmp \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UV_LINK_MODE=copy
WORKDIR /work

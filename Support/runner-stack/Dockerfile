# One ephemeral GitHub Actions runner. GitHub's own image, pinned; the entrypoint registers the
# container for exactly one job (see entrypoint.sh). tini is exec'd by the entrypoint AFTER the
# credentials are unset, so PID 1's environment is clean (compose `init: true` would start tini
# first, with the PAT still in /proc/1/environ, readable by every job step). socat serves the
# optional loopback forwards to sibling services (FORWARDS in entrypoint.sh).
FROM ghcr.io/actions/actions-runner:2.338.2

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini socat ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/entrypoint.sh"]

# fleet node image — docs/ARCHITECTURE.md "Docker nodes".
#
#   docker build -f docker/Dockerfile -t fleet-node .          (from the repo root)
#   docker build -f docker/Dockerfile --build-arg FLEET_PREINSTALL=1 -t fleet-node:pre .
#
# Contents: debian:bookworm-slim + tailscale (official apt repo) + openssh-server
# + git + python3 + curl + the fleeter code (/opt/fleet, public, NOT secret).
# Your config repo is not in the image: the master ships it at the first
# provision and the node pulls it afterwards. Nothing secret and no auth state
# is baked in: no Tailscale state, no SSH host keys (generated at first start),
# no invite, no tokens. One container = one invite code (FLEET_INVITE_CODE or
# FLEET_INVITE_FILE at run time).
#
# The node user (FLEET_USER, default `fleet`, uid 1000) has no sudo; the
# entrypoint runs as root only to start tailscaled + sshd, then drops to the user.
FROM debian:bookworm-slim

ARG FLEET_USER=fleet
ARG FLEET_UID=1000
ARG FLEET_PREINSTALL=0
ARG FLEET_BROWSER=1

ENV DEBIAN_FRONTEND=noninteractive \
    FLEET_USER=${FLEET_USER} \
    TS_STATE_DIR=/var/lib/tailscale \
    TS_SOCKET=/var/run/tailscale/tailscaled.sock

# procps: pkill for `fleet leave`. netcat-openbsd: `fleet doctor` probes
# isolation with nc. gnupg is not needed: the keyring is binary.
# chromium + fonts: the agents' browser (lib/tools/chrome.sh); apt can only
# install it as root, so it is part of the image, never left to `fleet apply`
# (which runs as the sudo-less node user). Headless, --no-sandbox. Fleets
# without `chrome` in FLEET_TOOLS build a slimmer image with
# --build-arg FLEET_BROWSER=0.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl bash git openssh-server openssh-client python3 procps gzip tar netcat-openbsd \
 && if [ "${FLEET_BROWSER}" = 1 ]; then \
      apt-get install -y --no-install-recommends chromium fonts-liberation fonts-noto-color-emoji; \
    fi \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale \
 && rm -rf /var/lib/apt/lists/* \
 # no host keys baked into the image: the entrypoint generates them per container
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd /var/lib/tailscale /var/run/tailscale \
 && ! command -v sudo >/dev/null

# sshd: key auth only, node user only (docs/ARCHITECTURE.md "Transport").
RUN printf '%s\n' \
      '# managed by fleet (docker image)' \
      'Port 22' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PubkeyAuthentication yes' \
      'PermitRootLogin no' \
      "AllowUsers ${FLEET_USER}" \
      'X11Forwarding no' \
      'PrintMotd no' \
      'LogLevel ERROR' \
    > /etc/ssh/sshd_config.d/fleet.conf

# Node user: no password (`*` = unusable hash, not a locked `!` account, so
# pubkey login works), no sudo, bash login shell.
RUN groupadd -g "${FLEET_UID}" "${FLEET_USER}" \
 && useradd -m -u "${FLEET_UID}" -g "${FLEET_UID}" -s /bin/bash -p '*' "${FLEET_USER}" \
 && install -d -m 0700 -o "${FLEET_USER}" -g "${FLEET_USER}" \
      "/home/${FLEET_USER}/.ssh" "/home/${FLEET_USER}/.config" "/home/${FLEET_USER}/.config/fleet" "/home/${FLEET_USER}/.local"

# The fleeter code: never the vault, never tests, never .git. examples/ is
# included so tests/e2e.sh can seed a config repo from it.
COPY fleet /opt/fleet/fleet
COPY lib /opt/fleet/lib
COPY config /opt/fleet/config
COPY templates /opt/fleet/templates
COPY examples /opt/fleet/examples
COPY skills /opt/fleet/skills
COPY docker/entrypoint.sh /usr/local/bin/fleet-entrypoint
RUN chmod 0755 /opt/fleet/fleet /usr/local/bin/fleet-entrypoint \
 && ln -s /opt/fleet/fleet /usr/local/bin/fleet

# Optional: preinstall base + devtools + harness CLIs at build time so the
# container is useful seconds after it joins (`fleet apply` still converges
# everything else: skills, config, secrets, env). Default off: the image stays
# small and `fleet apply` installs the tools on first provision (chromium is
# always in the image, see above).
# Root part: apt packages (base). User part: the rest, including the chrome
# plug-in's npm MCP servers (installed where mise's node lives).
RUN if [ "${FLEET_PREINSTALL}" = 1 ]; then \
      export FLEET_ROOT=/opt/fleet; \
      bash -ec '. /opt/fleet/lib/common.sh; fleet_load_config; . /opt/fleet/lib/tools/base.sh; tool_base_install' \
   && setpriv --reuid="${FLEET_UID}" --regid="${FLEET_UID}" --init-groups \
        env HOME="/home/${FLEET_USER}" USER="${FLEET_USER}" LOGNAME="${FLEET_USER}" FLEET_ROOT=/opt/fleet \
        bash -ec 'cd "$HOME"; . /opt/fleet/lib/common.sh; fleet_load_config; \
                  for t in devtools chrome claude codex cursor grok; do . "/opt/fleet/lib/tools/$t.sh"; "tool_${t}_install"; done' \
   && rm -rf /var/lib/apt/lists/* "/home/${FLEET_USER}/.cache" /tmp/* ; \
    fi

WORKDIR /home/${FLEET_USER}
EXPOSE 22
# Without args: the node flow (tailscaled, sshd, fleet join, fleet daemon).
# With args: run them instead (e.g. `sleep infinity` for the e2e master).
ENTRYPOINT ["/usr/local/bin/fleet-entrypoint"]
STOPSIGNAL SIGTERM

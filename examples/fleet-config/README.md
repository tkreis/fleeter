# fleet-config (starter)

This directory is a template for **your private fleet-config repo**: the
personal layer that fleeter reads on the master and ships to every node. It
holds no secrets (those live in the master's vault and travel over SSH), but it
is yours: instructions, harness configuration, skills, and your fleet's settings.

```
fleet.conf          repo URLs, tool list, runtime pins, schedules
AGENTS.md           global agent instructions rendered into every harness on every node
harness/            per-harness templates, captured from the master by `fleet config publish`
skills/             skills pushed to every node (captured, or added by hand)
```

## Create your own

`fleet setup` on the master does all of this for you (copies this example,
renders `fleet.conf` from your answers, creates the private repo, pushes). By
hand:

```sh
# 1. a new private repo from this example
cp -R /path/to/fleeter/examples/fleet-config ~/fleet-config
cd ~/fleet-config
git init -b main && git add -A && git commit -m "start fleet config"
gh repo create YOU/fleet-config --private --source . --push     # or create it in the UI and push

# 2. edit fleet.conf: replace every YOU, choose FLEET_TOOLS and the runtime pins
#    (FLEET_MISE_TOOLS, FLEET_PNPM), remove what you do not use

# 3. tell the master where it is (recorded in ~/.config/fleet/fleet.conf)
fleet init master --config-dir ~/fleet-config

# 4. fill harness/ and skills/ from this machine's live configuration and push
fleet config publish
```

A private **memory** repo (the shared Markdown vault) is optional. To use one,
create an empty private repo and point `FLEET_MEMORY_REPO` at it: the master
seeds the scaffold from fleeter's `templates/memory` on its next reconcile (or
create it from that directory yourself: `cp -R /path/to/fleeter/templates/memory
~/fleet-memory`, init, push). Leave `FLEET_MEMORY_REPO=""` and nothing
memory-related exists on master or nodes.

## What goes where

- Anything a node needs that is not a secret: here.
- Anything a node needs that **is** a secret (API tokens, `.env` files, the
  CLIProxyAPI logins): on the master, `fleet secrets set`, `fleet files add`,
  `fleet proxy import`. They are pushed over SSH and never enter a repo.
- Per-machine deviations (a node that should install fewer tools, a different
  memory directory): `~/.config/fleet/fleet.conf` on that machine. It is read
  last and wins.

## How nodes get it

The master ships this checkout once during the first provision
(`~/.local/share/fleet-config` on the node). After that every node fetches the
repo itself every `FLEET_PULL_EVERY` minutes with its read-only deploy key and
re-applies when the commit changed; the master does not need to be awake.
Commit and push (`fleet config publish`, or plain git) to roll a change out.

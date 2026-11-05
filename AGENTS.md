# AGENTS.md

Operating guide for coding agents working in this repo. Humans: start with
[`README.md`](README.md) — this file is the short, imperative version plus the
traps that are not obvious from reading the compose file.

## What this repo is

A single self-hosted **GitHub Actions** runner, run rootless via **Podman
Compose**. Four services in `docker-compose.yml`:

| service          | lifetime   | role                                                                               |
| ---------------- | ---------- | ---------------------------------------------------------------------------------- |
| `dind`           | long-lived | real `dockerd` sidecar; every job container runs under this daemon                 |
| `externals-sync` | one-shot   | copies the runner image's `/actions-runner/externals` onto a volume `dind` can see |
| `binfmt`         | one-shot   | registers QEMU handlers inside `dockerd` for multi-arch builds                     |
| `runner`         | long-lived | self-registering GitHub Actions runner agent                                       |

There is no application code — no tests, no build. The deliverable is config.

## Setup

```bash
make setup      # creates ~/.gh-runners/r1/data, copies .env.example -> .env
make hooks      # installs the pre-commit hook (once per clone)
```

Then edit `.env`:

- `ACCESS_TOKEN` — GitHub PAT. Pull from a secret manager. **Never** write a
  real token into `.env.example`; that file is tracked.
- Exactly one of `REPO_URL` (repo scope) or `ORG_NAME` (org scope).
- `LABELS` — what workflows put in `runs-on`.

## Start / stop

```bash
make start                    # up -d, all services
make start RUNNER_COUNT=2     # N runner replicas (leave RUNNER_NAME unset)
make logs                     # follow runner logs
make stop
```

Confirm the runner came up under the target's **Settings → Actions → Runners**.

## Traps

**`make restart` recreates every container.** It pulls the runner image, then
runs `make stop && make start`, so new images and any `docker-compose.yml` edit
take effect — and any in-flight job dies (see Safety). The image tag floats and
`DISABLE_AUTO_UPDATE=true` pins the runner to the image's version, so a stale
image ends in `Runner version vX is deprecated and cannot receive messages`;
`make restart` (or `make pull`) is the fix. Restart is safe for registration state: the `runner` entrypoint wrapper deletes
`.runner`, `.runner_migrated` and `.credentials*` on every start, so a
container left half-registered by an unclean deregister re-registers instead of
crash-looping on `Value cannot be null. (Parameter 'configuredSettings')`. Do
not drop that wrapper, and keep its `command:` equal to the image's CMD.

**Bind-mount paths must resolve on `dind`, not on `runner`.** Job containers
are created by the `dind` daemon, so `-v /host/path:/x` is resolved against
`dind`'s filesystem. That is the entire reason `externals-sync` exists: without
it, `/actions-runner/externals` does not exist on `dind`, Docker silently
auto-creates it empty, and jobs die with
`stat /__e/node24/bin/node: no such file or directory` before the first
workflow step runs.

**Nothing under `/tmp`.** `docker:dind`'s entrypoint mounts a fresh tmpfs over
`/tmp` at startup, which silently shadows any bind mount placed there. The work
dir lives at `~/.gh-runners/r1/data` for this reason.

**Resource limits on `dind` bound every job.** Job containers inherit dind's
cgroup subtree. `memory` is a hard cap — breaching it OOM-kills `dockerd` and
every in-flight job. See README → Resource limits before tuning.

**`runner` limits are per replica.** `RUNNER_COUNT=4` reserves 4× them.

## Before committing

Hooks run automatically on `git commit`. Do not pass `--no-verify`.

- `pre-commit run --all-files` — run the full set manually
- `make scan` — gitleaks over full history, not just the staged diff

This repo is public. Before adding any example value, ask whether it names a
private resource: secret-manager URIs and item IDs, internal repo or org names,
internal hostnames. Use `<placeholder>` syntax instead.

## Safety

Do not run `make start` / `make stop` / `podman compose` against a runner that
is mid-job without checking first — it kills the running workflow:

```bash
podman exec github-runners_dind_1 docker ps
```

Empty output means no job is running and it is safe to recreate.

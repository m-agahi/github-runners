# github-runners

Self-hosted **GitHub Actions** runner using **Podman Compose** (rootless). It is a
port of an equivalent Forgejo Actions runner setup, so the service topology
(`dind` sidecar + `binfmt` one-shot + self-registering runner) deliberately
mirrors that shape:

- **Docker-in-Docker (DinD)**: a real `dockerd` sidecar so CI workflows can use
  `docker build`, `docker buildx`, `docker/build-push-action`, etc.
- **Multi-arch builds**: QEMU binfmt handlers registered inside `dockerd` at
  startup, enabling `linux/amd64` and `linux/arm64` image builds on a single
  host.
- **Auto-registering runner**: no manual `config.sh`/`run.sh` dance — the
  runner container registers itself against GitHub on startup using a PAT.

## Prerequisites

```bash
# Fedora/RHEL
sudo dnf install podman podman-compose

# Ubuntu/Debian
sudo apt install podman podman-compose
```

Rootless Podman — no daemon or group membership needed. The `dind` sidecar runs
`privileged: true` inside your rootless user namespace, so it is confined to your
own UID on the host. If the runner hits permission errors on its data volume on
first `make start`, remap ownership into the user namespace:

```bash
podman unshare chown -R 0:0 ~/.gh-runners/r1/data
```

## Setup

### 1. Create a GitHub PAT

Create it under **Settings → Developer settings → Personal access tokens**. The
token goes in `.env` (gitignored) as `ACCESS_TOKEN` — never commit it, and never
paste it into `.env.example`.

Store it in whatever secret manager you already use and pull it in at setup time
rather than keeping it in shell history. With the 1Password CLI, for example:

```bash
op read "op://<vault>/<item>/<field>" >/dev/null   # verify the reference resolves
```

Required scopes:

- **Repo-scoped runner** (`RUNNER_SCOPE=repo`): classic PAT with `repo` scope,
  or a fine-grained PAT with "Administration: Read & write" on the target
  repo.
- **Org-scoped runner** (`RUNNER_SCOPE=org`): classic PAT with `admin:org`
  scope.

### 2. Create the config

```bash
make setup
```

This creates `~/.gh-runners/r1/data` (the runner's work directory, mounted
into the container) and copies `.env.example` to `.env` if it doesn't exist
yet.

Edit `.env` and set three things:

1. `ACCESS_TOKEN` — the PAT from step 1.
2. The target — `RUNNER_SCOPE=repo` + `REPO_URL`, or `RUNNER_SCOPE=org` +
   `ORG_NAME`. They are a pair; set both halves of exactly one.
3. `LABELS` — must match what your workflows already put in `runs-on:`. A
   mismatch fails **silently**: the runner registers fine and jobs queue
   forever waiting on a runner that never matches.

### 3. Start

```bash
make start
```

On first start the `binfmt` service registers QEMU for all architectures
inside `dockerd`, then exits. The runner registers itself against GitHub
automatically using `ACCESS_TOKEN`.

Check it's online: repo/org **Settings → Actions → Runners**.

## Usage

```bash
make start            # start all services
make stop             # stop all services
make logs             # follow runner logs
make restart          # restart runner after config change
make setup-multiarch  # re-register QEMU binfmts (if dind restarted)
make hooks            # install the git pre-commit hook (once per clone)
make scan             # full-history secret sweep (gitleaks)
```

Note: `make restart` reuses the existing containers, so it does **not** pick up
changes to the resource limits or any other `docker-compose.yml` field — those
need `make stop && make start` to recreate the containers.

Scale to multiple concurrent runners (see `.env.example`'s Scaling section —
leave `RUNNER_NAME` unset when doing this):

```bash
make start RUNNER_COUNT=2
```

## How registration works

The runner image (`myoung34/github-runner`) calls the GitHub API on container
start using `ACCESS_TOKEN` to mint a short-lived registration token, then
registers and runs the GitHub Actions runner agent — no manual `config.sh`
step required. This is the auto-registration analog of the Forgejo side,
where `forgejo-runner:12` self-registers from the `uuid` + `token` baked into
`config.yaml`.

## How DinD lets `docker build` work inside a job

`DOCKER_HOST=tcp://dind:2375` is set on the `runner` container, pointing at
the `dind` sidecar (its own real `dockerd`, not the host's). Any `docker`
CLI invocation inside a job step — a raw `docker build ...` shell command, or
an action like `docker/build-push-action` — picks up `DOCKER_HOST` from the
runner process's environment and talks to that sidecar daemon instead of
requiring privileged access to the host's own Docker socket. This mirrors the
Forgejo runner's `container.docker_host: tcp://dind:2375` config exactly.

## Labels and `runs-on`

Set `LABELS` in `.env`. The shipped default is:

```
self-hosted, linux, x64, dind
```

Reference it in a workflow:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, x64, dind]
```

Add your own project-specific label if you run several runner sets against the
same org and want workflows to pin one of them.

## Resource limits

Job containers are created by the `dind` daemon and land in **dind's own cgroup
subtree**, so the limits on the `dind` service bound the entire job fleet
collectively. There is no per-job knob on this side — a workflow that wants a
tighter budget sets it in its own `container.options`.

| service  | cpus | memory | pids |
| -------- | ---- | ------ | ---- |
| `dind`   | 8    | 32G    | 8192 |
| `runner` | 2    | 4G     | 1024 |

Defaults are sized for a 24-core / 62 GiB host. Tune them in
`docker-compose.yml` to leave your desktop enough headroom; without any limit a
single test suite can saturate the machine.

Two caveats:

- `memory` is a hard cap, not a throttle — breaching it OOM-kills `dockerd` and
  takes any in-flight job with it. Leave real headroom.
- The `runner` limits apply **per replica**, so `make start RUNNER_COUNT=4`
  reserves 4× those numbers.

Rootless enforcement needs cgroup-v2 delegation. Verify:

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/cgroup.controllers
# want: cpu io memory pids
```

## Development

```bash
make hooks   # pre-commit install
```

Hooks: [gitleaks](https://github.com/gitleaks/gitleaks) secret scanning,
[prettier](https://prettier.io/) for yaml/json/markdown, plus the standard
`pre-commit-hooks` whitespace/yaml/private-key checks. `pre-commit` provisions
everything itself — no machine-wide gitleaks or node install needed.

The gitleaks hook only sees the staged diff. `make scan` sweeps full history.

## File layout

```
docker-compose.yml       # Service definitions: dind, externals-sync, binfmt, runner
.env.example             # Config template — copy to .env
Makefile                 # Convenience targets
AGENTS.md                # Setup/operation guide for coding agents
.pre-commit-config.yaml  # gitleaks secret scan + formatting hooks
.prettierrc.json         # Prettier config (yaml/json/markdown)
.gitignore               # Ignores .env + local runner state paths

~/.gh-runners/r1/data/   # Runner work directory — kept outside repo
```

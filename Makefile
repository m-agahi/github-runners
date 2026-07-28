.PHONY: start stop restart logs setup-multiarch setup hooks scan

RUNNER_COUNT ?= 1

# Create required host directories and copy example env if missing
setup:
	mkdir -p ~/.gh-runners/r1/data
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Copied .env.example → .env — fill in ACCESS_TOKEN and repo/org target"; \
	fi

# Start all services in the background. RUNNER_COUNT scales the `runner`
# service (default 1) — see .env.example's Scaling section.
start:
	podman compose up -d --scale runner=$(RUNNER_COUNT)

# Stop all services
stop:
	podman compose down

# Restart just the runner(s) (e.g. after config change)
restart:
	podman compose restart runner

# Follow runner logs
logs:
	podman compose logs -f runner

# (Re-)register QEMU binfmt handlers inside dind — useful if dind restarted
setup-multiarch:
	podman compose run --rm binfmt

# Install the git pre-commit hook (once per clone)
hooks:
	pre-commit install

# Full-history secret sweep. The pre-commit gitleaks hook only sees the staged
# diff; this scans every commit reachable from HEAD. Run before making the
# repo public or after rewriting history.
scan:
	gitleaks detect --source . --redact --verbose

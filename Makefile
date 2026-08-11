# zeroclaw-k3s-sre
#
# `make help` lists targets. CI (.github/workflows/ci.yaml) calls these same
# targets, so anything that passes locally passes there.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

IMAGE            ?= ghcr.io/backhand/zeroclaw-sre
VERSION          ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
IMAGE_REF        := $(IMAGE):$(VERSION)
PLATFORMS        ?= linux/amd64,linux/arm64
NAMESPACE        ?= zeroclaw-sre
ALLOWED_NAMESPACES ?= default
K3D_CLUSTER      ?= zeroclaw-sre-e2e

# Dummy values for the envsubst dry-run. Never used at runtime.
DRYRUN_ENV = ZC_MODEL=claude-sonnet-4-5 ZC_DATA_DIR=/data ZC_WORKSPACE_DIR=/data/workspace \
             ZC_SANDBOX_BACKEND=none ZC_WEBHOOK_PORT=42618 \
             SLACK_CHANNEL_IDS_TOML='"C0"' SLACK_DIGEST_CHANNEL=C0 \
             DISCORD_GUILD_IDS_TOML='"1"' DISCORD_CHANNEL_IDS_TOML='"2"' DISCORD_DIGEST_CHANNEL=2 \
             ZC_ALLOWED_USERS_SLACK_TOML='"U0"' ZC_ALLOWED_USERS_DISCORD_TOML='"D0"' \
             SWEEP_CRON='*/15 * * * *' RIGHTSIZE_CRON='0 6 * * 1' HEARTBEAT_CRON='0 7 * * *' \
             ALLOWED_NAMESPACES=default GH_REPO=owner/repo

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ── 1. Lint / static ─────────────────────────────────────────────

.PHONY: lint
lint: lint-shell lint-yaml lint-go render-check secret-scan ## Run every static check

.PHONY: lint-shell
lint-shell: ## shellcheck every shell script
	@shellcheck entrypoint.sh \
	  workspace/skills/k3s-admin/tests/*.sh \
	  tests/e2e/*.sh tests/e2e/cases/*.sh
	@echo "shellcheck: ok"

.PHONY: lint-yaml
lint-yaml: ## Parse every YAML manifest
	@python3 -c "import yaml,glob,sys; \
	  [list(yaml.safe_load_all(open(f))) for f in glob.glob('deploy/*.yaml') + glob.glob('tests/e2e/manifests/*.yaml') + glob.glob('.github/workflows/*.yaml')]; \
	  print('yaml: ok')"

.PHONY: lint-go
lint-go: ## Vet and test the alert adapter
	@cd alert-adapter && go vet ./... && go test ./...

.PHONY: render-check
render-check: ## envsubst dry-run: the template must render to parseable TOML with nothing left unsubstituted
	@mkdir -p .build
	@env $(DRYRUN_ENV) envsubst \
	  '$$ZC_MODEL $$ZC_DATA_DIR $$ZC_WORKSPACE_DIR $$ZC_SANDBOX_BACKEND $$ZC_WEBHOOK_PORT $$SLACK_CHANNEL_IDS_TOML $$SLACK_DIGEST_CHANNEL $$DISCORD_GUILD_IDS_TOML $$DISCORD_CHANNEL_IDS_TOML $$DISCORD_DIGEST_CHANNEL $$ZC_ALLOWED_USERS_SLACK_TOML $$ZC_ALLOWED_USERS_DISCORD_TOML $$SWEEP_CRON $$RIGHTSIZE_CRON $$HEARTBEAT_CRON $$ALLOWED_NAMESPACES $$GH_REPO' \
	  < config/config.toml.tmpl > .build/config.toml
	@if grep -n '\$${' .build/config.toml; then \
	  echo "render-check: unsubstituted placeholder above"; exit 1; fi
	@python3 -c "import tomllib,sys; tomllib.load(open('.build/config.toml','rb')); print('render-check: ok (valid TOML, no placeholders left)')"

.PHONY: secret-scan
secret-scan: ## gitleaks over the working tree (skipped with a warning if not installed)
	@if command -v gitleaks >/dev/null 2>&1; then \
	  gitleaks detect --no-banner --redact --source . && echo "gitleaks: ok"; \
	else \
	  echo "gitleaks: NOT INSTALLED — skipping (CI runs it; install locally with 'brew install gitleaks')"; \
	fi

# ── 2. Image ─────────────────────────────────────────────────────

.PHONY: build
build: ## Build the image for the host architecture
	docker build -t $(IMAGE_REF) -t zeroclaw-sre:dev .

.PHONY: image-test
image-test: ## Run the in-image self-test (config render, SOP validate, skill audit + test)
	docker run --rm \
	  -e ANTHROPIC_API_KEY=sk-ant-selftest \
	  -e DISCORD_BOT_TOKEN=selftest -e DISCORD_GUILD_ID=000 \
	  -e SLACK_BOT_TOKEN=xoxb-selftest -e SLACK_APP_TOKEN=xapp-selftest \
	  -e SLACK_CHANNEL_IDS=C0000000000 \
	  -e ZC_WEBHOOK_SECRET=selftest -e ZC_GATEWAY_TOKEN=selftest \
	  -e ZC_ALLOWED_USERS=U0000000000 \
	  -e ALLOWED_NAMESPACES=default \
	  zeroclaw-sre:dev --self-test

.PHONY: image-scan
image-scan: ## Fail if the built image carries writable state paths outside the allowed set
	@docker run --rm --entrypoint sh zeroclaw-sre:dev -c '\
	  bad=$$(find / -xdev -type d -writable 2>/dev/null \
	    | grep -vE "^/(data|tmp|proc|sys|dev)(/|$$)" || true); \
	  if [ -n "$$bad" ]; then echo "writable paths outside /data,/tmp:"; echo "$$bad"; exit 1; fi; \
	  echo "image-scan: ok"'

.PHONY: release
release: ## Build and push the multi-arch image, then pin its digest into deploy/deployment.yaml
	docker buildx build --platform $(PLATFORMS) --push -t $(IMAGE_REF) .
	@digest=$$(docker buildx imagetools inspect $(IMAGE_REF) --format '{{.Manifest.Digest}}'); \
	  echo "pinning $(IMAGE)@$$digest"; \
	  sed -i.bak -E "s|image: $(IMAGE)[^ ]*|image: $(IMAGE)@$$digest|g" deploy/deployment.yaml; \
	  rm -f deploy/deployment.yaml.bak; \
	  git --no-pager diff --stat deploy/deployment.yaml

# ── 3. Deploy ────────────────────────────────────────────────────

.PHONY: rolebindings
rolebindings: ## Emit a write RoleBinding per namespace in ALLOWED_NAMESPACES
	@list='$(ALLOWED_NAMESPACES)'; IFS=,; for ns in $$list; do \
	  printf -- '---\napiVersion: rbac.authorization.k8s.io/v1\nkind: RoleBinding\nmetadata:\n  name: zeroclaw-sre-write\n  namespace: %s\n  labels:\n    app.kubernetes.io/name: zeroclaw-sre\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: zeroclaw-sre-write\nsubjects:\n  - kind: ServiceAccount\n    name: zeroclaw-sre\n    namespace: $(NAMESPACE)\n' "$$ns"; \
	done

.PHONY: deploy
deploy: ## Apply the manifests (the Secret must already exist — see README)
	kubectl apply -f deploy/namespace.yaml
	kubectl apply -f deploy/rbac.yaml
	kubectl apply -f deploy/configmap.yaml
	kubectl apply -f deploy/pvc.yaml
	kubectl apply -f deploy/service.yaml
	kubectl apply -f deploy/deployment.yaml
	kubectl -n $(NAMESPACE) rollout status deploy/zeroclaw-sre --timeout=180s

.PHONY: undeploy
undeploy: ## Remove the workload but keep the PVC and the Secret
	-kubectl delete -f deploy/deployment.yaml
	-kubectl delete -f deploy/service.yaml
	-kubectl delete -f deploy/configmap.yaml

.PHONY: logs
logs: ## Follow the agent's logs
	kubectl -n $(NAMESPACE) logs -f deploy/zeroclaw-sre -c zeroclaw

.PHONY: receipts
receipts: ## Tail today's tool receipts from the PVC
	kubectl -n $(NAMESPACE) exec deploy/zeroclaw-sre -c zeroclaw -- \
	  sh -c 'tail -n 50 /data/workspace/receipts/$$(date -u +%Y-%m-%d).ndjson'

# ── 4. Acceptance ────────────────────────────────────────────────

.PHONY: e2e
e2e: ## Run the k3d acceptance suite (needs k3d; set ANTHROPIC_API_KEY for the LLM cases)
	K3D_CLUSTER=$(K3D_CLUSTER) IMAGE_REF=zeroclaw-sre:dev tests/e2e/run.sh

.PHONY: e2e-clean
e2e-clean: ## Delete the e2e cluster
	-k3d cluster delete $(K3D_CLUSTER)

.PHONY: clean
clean: ## Remove build scratch
	rm -rf .build

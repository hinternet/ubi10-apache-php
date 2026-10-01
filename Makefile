.DEFAULT_GOAL := help

IMAGE_NAME       ?= ubi10-apache-php
IMAGE_TAG        ?= latest
IMAGE_VERSION    ?= 1.0.0
CONTAINER_ENGINE ?= podman
CONTAINER_NAME   ?= $(IMAGE_NAME)
SHELL_CONTAINER_NAME ?= $(CONTAINER_NAME)-shell
PORT             ?= 8080
PLATFORM         ?= linux/amd64
BUILD_DATE       ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REVISION     ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
GIT_SOURCE       ?= $(shell git config --get remote.origin.url 2>/dev/null || echo unknown)

# docker.io/<Docker Hub username>/ubi10-apache-php
# Username: REGISTRY_USER or DOCKERHUB_USER (not an email). Token: DOCKERHUB_TOKEN.
REGISTRY         ?= docker.io
REGISTRY_USER    ?= $(DOCKERHUB_USER)
REMOTE_REPO      := $(REGISTRY)/$(REGISTRY_USER)/$(IMAGE_NAME)
IMAGE_VERSION_MINOR := $(word 1,$(subst ., ,$(IMAGE_VERSION))).$(word 2,$(subst ., ,$(IMAGE_VERSION)))
PUSH_LATEST      ?= 1
PUSH_MINOR       ?= 1
PUSH_DRY_RUN     ?= 0
# Default away from ~/.cache/trivy (often created by sudo, then EPERM).
TRIVY_CACHE_DIR  ?= $(HOME)/.local/share/trivy

IMAGE := $(IMAGE_NAME):$(IMAGE_TAG)

RUN_ENV :=
ifneq ($(strip $(DEBUG)),)
RUN_ENV += -e DEBUG=$(DEBUG)
endif

NOCACHE_FLAG :=
ifeq ($(NOCACHE),1)
NOCACHE_FLAG := --no-cache
endif

FOLLOW_FLAG :=
ifeq ($(FOLLOW),1)
FOLLOW_FLAG := -f
endif

# podman --format docker; docker build has no --format.
FORMAT_FLAG :=
ifeq ($(CONTAINER_ENGINE),podman)
FORMAT_FLAG := --format docker
endif

.PHONY: help build clean cc shell shell-persistent exec run logs stop health test lint scan versions login push

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the image (NOCACHE=1 to disable cache)
	$(CONTAINER_ENGINE) build $(NOCACHE_FLAG) --platform=$(PLATFORM) $(FORMAT_FLAG) \
		--build-arg IMAGE_VERSION=$(IMAGE_VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg GIT_REVISION=$(GIT_REVISION) \
		--build-arg GIT_SOURCE=$(GIT_SOURCE) \
		-t $(IMAGE) .

clean: ## Remove the local image tag
	-$(CONTAINER_ENGINE) rmi -f $(IMAGE) 2>/dev/null || true

cc: ## Remove all local containers
	-$(CONTAINER_ENGINE) rm -f -a 2>/dev/null || true

shell: ## Ephemeral shell (entrypoint still runs, CMD is /bin/bash)
	$(CONTAINER_ENGINE) run --rm -it $(RUN_ENV) $(IMAGE) /bin/bash

shell-persistent: ## Create or attach to a debug shell container (not the httpd one)
	@if ! $(CONTAINER_ENGINE) ps -a --format "{{.Names}}" | grep -qx "$(SHELL_CONTAINER_NAME)"; then \
		echo "--> Creating container '$(SHELL_CONTAINER_NAME)'..."; \
		$(CONTAINER_ENGINE) run -it --name $(SHELL_CONTAINER_NAME) $(RUN_ENV) $(IMAGE) /bin/bash; \
	elif [ "$$($(CONTAINER_ENGINE) inspect -f '{{.State.Running}}' $(SHELL_CONTAINER_NAME) 2>/dev/null)" = "true" ]; then \
		echo "--> Entering running container '$(SHELL_CONTAINER_NAME)'..."; \
		$(CONTAINER_ENGINE) exec -it $(SHELL_CONTAINER_NAME) /bin/bash; \
	else \
		echo "--> Starting existing container '$(SHELL_CONTAINER_NAME)'..."; \
		$(CONTAINER_ENGINE) start -ai $(SHELL_CONTAINER_NAME); \
	fi

exec: ## Shell into the running httpd container
	$(CONTAINER_ENGINE) exec -it $(CONTAINER_NAME) /bin/bash

run: ## Run httpd in the background (PORT=8080, DEBUG=1 optional)
	$(CONTAINER_ENGINE) run -d -p $(PORT):8080 --name $(CONTAINER_NAME) $(RUN_ENV) $(IMAGE)

logs: ## Show httpd logs (FOLLOW=1 to tail)
	$(CONTAINER_ENGINE) logs $(FOLLOW_FLAG) $(CONTAINER_NAME)

health: ## GET /healthz (Apache → FPM ping); prints pong
	$(CONTAINER_ENGINE) exec $(CONTAINER_NAME) /opt/drupal/scripts/healthcheck.sh

stop: ## Stop and remove the httpd container
	-$(CONTAINER_ENGINE) stop $(CONTAINER_NAME)
	-$(CONTAINER_ENGINE) rm -f $(CONTAINER_NAME)

test: ## Manifest checks, then image tests (requires make build)
	./tests/test-manifests.sh
	IMAGE=$(IMAGE) CONTAINER_ENGINE=$(CONTAINER_ENGINE) ./tests/test-image.sh

lint: ## hadolint + shellcheck (skips a tool if it is not installed)
	@status=0; \
	if command -v hadolint >/dev/null 2>&1; then \
		hadolint Containerfile || status=$$?; \
	else \
		echo "SKIP: hadolint not installed"; \
	fi; \
	if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning \
			rootfs/opt/drupal/scripts/entrypoint.sh \
			rootfs/opt/drupal/scripts/healthcheck.sh \
			tests/test-image.sh \
			tests/test-manifests.sh || status=$$?; \
	else \
		echo "SKIP: shellcheck not installed"; \
	fi; \
	exit $$status

scan: ## Trivy HIGH/CRITICAL --ignore-unfixed (same CONTAINER_ENGINE as make build)
	@if ! command -v trivy >/dev/null 2>&1; then \
		echo "SKIP: trivy not installed"; \
		exit 0; \
	fi; \
	cache="$(TRIVY_CACHE_DIR)"; \
	mkdir -p "$$cache" || { echo "Cannot mkdir Trivy cache $$cache (set TRIVY_CACHE_DIR)"; exit 1; }; \
	src="$(IMAGE)"; \
	if ! $(CONTAINER_ENGINE) image inspect "$$src" >/dev/null 2>&1; then \
		src="localhost/$(IMAGE)"; \
	fi; \
	if ! $(CONTAINER_ENGINE) image inspect "$$src" >/dev/null 2>&1; then \
		echo "Image $(IMAGE) not found. Run: make build (CONTAINER_ENGINE=$(CONTAINER_ENGINE))"; \
		exit 1; \
	fi; \
	tar="$$(mktemp "$${TMPDIR:-/tmp}/$(IMAGE_NAME)-scan.XXXXXX.tar")"; \
	echo "--> $(CONTAINER_ENGINE) save $$src | trivy (cache $$cache)"; \
	$(CONTAINER_ENGINE) save -o "$$tar" "$$src"; \
	status=0; \
	TRIVY_CACHE_DIR="$$cache" trivy image --input "$$tar" \
		--ignore-unfixed --severity HIGH,CRITICAL --exit-code 0 \
		--skip-version-check || status=$$?; \
	rm -f "$$tar"; \
	exit $$status

versions: ## php/httpd/composer versions and rpm -qa from the image
	$(CONTAINER_ENGINE) run --rm --user 1001:0 --entrypoint bash $(IMAGE) -lc \
		'php -v; httpd -v; composer --version; echo "--- rpm -qa ---"; rpm -qa | sort'

login: ## Log in to docker.io (REGISTRY_USER / DOCKERHUB_USER; DOCKERHUB_TOKEN or prompt)
	@user="$(REGISTRY_USER)"; \
	if [ -z "$$user" ]; then \
		echo "Set REGISTRY_USER or DOCKERHUB_USER to your Docker Hub username (not email)."; \
		exit 1; \
	fi; \
	if [ -n "$${DOCKERHUB_TOKEN:-}" ]; then \
		printf '%s\n' "$$DOCKERHUB_TOKEN" | $(CONTAINER_ENGINE) login $(REGISTRY) -u "$$user" --password-stdin; \
	else \
		$(CONTAINER_ENGINE) login $(REGISTRY) -u "$$user"; \
	fi

push: ## Push IMAGE_VERSION, 1.0, and latest to docker.io/USER/ubi10-apache-php
	@user="$(REGISTRY_USER)"; \
	if [ -z "$$user" ]; then \
		echo "Set REGISTRY_USER or DOCKERHUB_USER to your Docker Hub username (not email)."; \
		echo "Example:  export DOCKERHUB_USER=myuser DOCKERHUB_TOKEN=<access-token>"; \
		echo "          make build test push"; \
		exit 1; \
	fi; \
	repo="$(REGISTRY)/$$user/$(IMAGE_NAME)"; \
	tags="$(IMAGE_VERSION)"; \
	if [ "$(PUSH_MINOR)" = "1" ] && [ -n "$(IMAGE_VERSION_MINOR)" ]; then \
		tags="$$tags $(IMAGE_VERSION_MINOR)"; \
	fi; \
	if [ "$(PUSH_LATEST)" = "1" ]; then \
		tags="$$tags latest"; \
	fi; \
	echo "--> Remote  $$repo"; \
	echo "--> Tags    $$tags"; \
	if [ "$(PUSH_DRY_RUN)" = "1" ]; then \
		echo "PUSH_DRY_RUN=1 (no tag/push)"; \
		exit 0; \
	fi; \
	src="$(IMAGE)"; \
	if ! $(CONTAINER_ENGINE) image inspect "$$src" >/dev/null 2>&1; then \
		src="localhost/$(IMAGE)"; \
	fi; \
	if ! $(CONTAINER_ENGINE) image inspect "$$src" >/dev/null 2>&1; then \
		echo "Image $(IMAGE) not found. Run: make build"; \
		exit 1; \
	fi; \
	if [ -n "$${DOCKERHUB_TOKEN:-}" ]; then \
		$(MAKE) --no-print-directory login REGISTRY_USER="$$user"; \
	fi; \
	echo "--> Source  $$src"; \
	for t in $$tags; do \
		echo "--> Tag $$repo:$$t"; \
		$(CONTAINER_ENGINE) tag "$$src" "$$repo:$$t"; \
		echo "--> Push $$repo:$$t"; \
		$(CONTAINER_ENGINE) push "$$repo:$$t"; \
	done; \
	echo "--> Pinned pull:  $(CONTAINER_ENGINE) pull $$repo:$(IMAGE_VERSION)"

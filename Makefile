# Shim for muscle memory and older docs: Taskfile.yml is the entrypoint (Make is not on Windows by default).
# `make <target> [INST=..] [REPO=..] [ORG=..] [APPS_ORG=..] [DOCS=1] [CI_ORG=..] [CLUSTER=..]` runs `task <target>` with the same variables.
TASK ?= $(shell command -v task 2>/dev/null || echo mise exec -- task)
VARS := $(if $(INST),INST=$(INST)) $(if $(REPO),REPO=$(REPO)) $(if $(ORG),ORG=$(ORG)) $(if $(APPS_ORG),APPS_ORG=$(APPS_ORG)) $(if $(DOCS),DOCS=$(DOCS)) $(if $(CI_ORG),CI_ORG=$(CI_ORG)) $(if $(CLUSTER),CLUSTER=$(CLUSTER))

.PHONY: setup doctor hooks-install hooks-run up secrets argocd status ui down kubeconfig set-repo lint test test-openbao schemas images-audit clean

setup:        ; @$(TASK) setup $(VARS)
doctor:       ; @$(TASK) doctor $(VARS)
hooks-install: ; @$(TASK) hooks:install $(VARS)
hooks-run:    ; @$(TASK) hooks:run $(VARS)
up:           ; @$(TASK) up $(VARS)
secrets:      ; @$(TASK) secrets $(VARS)
argocd:       ; @$(TASK) argocd $(VARS)
status:       ; @$(TASK) status $(VARS)
ui:           ; @$(TASK) ui $(VARS)
down:         ; @$(TASK) down $(VARS)
kubeconfig:   ; @$(TASK) kubeconfig $(VARS)
set-repo:     ; @$(TASK) set-repo $(VARS)
lint:         ; @$(TASK) lint $(VARS)
test:         ; @$(TASK) test $(VARS)
test-openbao: ; @$(TASK) test:openbao $(VARS)
schemas:      ; @$(TASK) schemas $(VARS)
images-audit: ; @$(TASK) images:audit $(VARS)
clean:        ; @$(TASK) clean $(VARS)

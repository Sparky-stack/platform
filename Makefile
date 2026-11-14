INST ?= local
REPO ?= https://github.com/koorikla/platform.git
OLD  := $(shell grep -m1 -oE 'https://github.com/[^ ]+\.git' bootstrap/root-app.yaml)

.PHONY: up secrets argocd status ui down lint test schemas clean set-repo

up:
	./bootstrap/bootstrap.sh --inst $(INST) up

secrets:
	./bootstrap/bootstrap.sh --inst $(INST) secrets

argocd:
	./bootstrap/bootstrap.sh --inst $(INST) argocd

status:
	./bootstrap/bootstrap.sh --inst $(INST) status

ui:
	./bootstrap/bootstrap.sh --inst $(INST) ui

down:
	./bootstrap/bootstrap.sh --inst $(INST) down

lint:
	./hack/lint.sh

test:
	./hack/test.sh

schemas:
	./hack/schemas.sh

clean:
	rm -rf charts/*/charts addons/*/charts charts/*/*.tgz addons/*/*.tgz

# Rewrite repoURL across bootstrap, charts, and installations (e.g. make set-repo REPO=https://github.com/you/platform.git).
set-repo:
	test -n "$(REPO)"
	@echo "Rewriting $(OLD) -> $(REPO)"
	grep -rlF "$(OLD)" bootstrap/ charts/ installations/ | xargs -r sed -i "s|$(OLD)|$(REPO)|g"

# Skróty do obsługi labu. Lista: make help
SHELL := /bin/bash
VENV        := .venv
ANSIBLE     := cd ansible && ../$(VENV)/bin/ansible-playbook
GITEA_REPO  := https://gitea.lab.test/gitea-admin/k3d-gitops-lab.git
GITEA_AUTH   = Authorization: Basic $$(printf 'gitea-admin:%s' "$$(cat .secrets/gitea-admin-password)" | base64 -w0)
CRUD_IMAGE   = $$(grep -oP 'image: lab-registry:5000/\K\S+' gitops/crud/manifests/deployment.yaml)

.DEFAULT_GOAL := help
.PHONY: help deps install up stop status passwords push image test-crud test-hpa uninstall purge

help: ## Lista komend
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

deps: ## Instaluje Ansible (venv .venv) i kolekcje
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q 'ansible-core>=2.18,<2.20' kubernetes
	$(VENV)/bin/ansible-galaxy collection install -r ansible/requirements.yml

install: ## Instaluje cały stos (pyta o hasło sudo)
	$(ANSIBLE) site.yml -K

up: ## Wznawia pracę: uruchamia zatrzymany klaster + BPF dla Cilium
	./k8s-lab.sh up

stop: ## Zatrzymuje klaster (dane zostają)
	./k8s-lab.sh stop

status: ## Stan węzłów, Cilium, aplikacji Argo CD i podów
	./k8s-lab.sh status

passwords: ## Adresy i dane logowania
	@echo "Argo CD  https://argocd.lab.test   admin / $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@echo "Gitea    https://gitea.lab.test    gitea-admin / $$(cat .secrets/gitea-admin-password)"
	@echo "Grafana  https://grafana.lab.test  admin / $$(cat .secrets/grafana-admin-password)"
	@echo "CRUD     https://crud.lab.test/items"

push: ## Wypycha zacommitowane zmiany do Gitei (Argo CD wdroży je w ~1 min)
	git -c http.extraHeader="$(GITEA_AUTH)" push $(GITEA_REPO) HEAD:main

image: ## Buduje i wypycha obraz crud-app o tagu z gitops/crud/manifests/deployment.yaml
	docker build -t localhost:5000/$(CRUD_IMAGE) src/crud-app
	docker push localhost:5000/$(CRUD_IMAGE)

test-crud: ## Szybki test CRUD przez HTTPS
	@curl -sf -X POST https://crud.lab.test/items -H 'Content-Type: application/json' -d '{"name":"make test-crud"}' && echo
	@curl -sf https://crud.lab.test/items && echo

test-hpa: ## Test autoskalowania: obciążenie k6, skalowanie w górę i powrót (~6 min)
	./tests/hpa-test.sh

uninstall: ## Usuwa klaster, /etc/hosts i zaufanie do CA (zostawia cache obrazów i .secrets/)
	$(ANSIBLE) uninstall.yml -K

purge: ## Jak uninstall + usuwa cache obrazów i .secrets/
	$(ANSIBLE) uninstall.yml -K -e purge_cache=true -e purge_secrets=true

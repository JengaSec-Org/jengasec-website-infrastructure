# JengaSec Infrastructure — common operations.
# Run from the repository root on the Debian control node.
#
#   make help        list every target
#   make lint        yamllint + ansible-lint
#   make syntax      parse every playbook and inventory
#   make check       dry run (no changes made)
#   make bootstrap   Phase 1 — base OS

SHELL         := /bin/bash
INVENTORY     ?= inventories/production
LIMIT         ?= all
PLAYBOOK_DIR  := playbooks
ANSIBLE_ARGS  ?=

# Every target that talks to hosts honours LIMIT, e.g.
#   make bootstrap LIMIT=server1
RUN = ansible-playbook -i $(INVENTORY) --limit $(LIMIT) $(ANSIBLE_ARGS)

.PHONY: help lint syntax structure check preflight ping facts \
        bootstrap networking security platform database site \
        vault-edit vault-view clean

help:
	@echo "JengaSec Infrastructure"
	@echo ""
	@echo "  Validation"
	@echo "    make structure     structural checks (no Ansible needed - runs anywhere)"
	@echo "    make lint          yamllint + ansible-lint over the repo"
	@echo "    make syntax        --syntax-check every playbook, list every inventory"
	@echo "    make preflight     check control node, host reachability, TODO placeholders"
	@echo "    make ping          ansible ping against INVENTORY"
	@echo "    make check         full dry run with --check --diff"
	@echo ""
	@echo "  Deployment (phases, in order)"
	@echo "    make bootstrap     Phase 1  base OS"
	@echo "    make networking    Phase 2  networking, DNS, DHCP, firewall  (SEE DOCS)"
	@echo "    make security      Phase 3  hardening"
	@echo "    make platform      Phase 4  application platform (stubs)"
	@echo "    make database      Phase 5  PostgreSQL (stub)"
	@echo "    make site          everything, in phase order"
	@echo ""
	@echo "  Secrets"
	@echo "    make vault-edit    edit the encrypted vault for INVENTORY"
	@echo "    make vault-view    view it read-only"
	@echo ""
	@echo "  Variables:  INVENTORY=$(INVENTORY)  LIMIT=$(LIMIT)"

# Needs only python3 + pyyaml + jinja2, so it also runs on the Windows machine
# where this repo is authored — catching a missing template before the files are
# copied to the control node.
structure:
	python3 tests/structure-check.py

lint:
	yamllint .
	ansible-lint

syntax:
	./tests/syntax-check.sh

preflight:
	./scripts/preflight.sh $(INVENTORY)

ping:
	ansible -i $(INVENTORY) --limit $(LIMIT) all -m ansible.builtin.ping

facts:
	ansible -i $(INVENTORY) --limit $(LIMIT) all -m ansible.builtin.setup

check:
	$(RUN) --check --diff site.yml

bootstrap:
	$(RUN) $(PLAYBOOK_DIR)/bootstrap.yml

# Read docs/runbook.md before running this one — it can drop your SSH session.
networking:
	$(RUN) $(PLAYBOOK_DIR)/networking.yml

security:
	$(RUN) $(PLAYBOOK_DIR)/security.yml

platform:
	$(RUN) $(PLAYBOOK_DIR)/platform.yml

database:
	$(RUN) $(PLAYBOOK_DIR)/database.yml

site:
	$(RUN) site.yml

vault-edit:
	ansible-vault edit $(INVENTORY)/vault.yml

vault-view:
	ansible-vault view $(INVENTORY)/vault.yml

clean:
	rm -rf .facts_cache logs/*.log
	find . -name '*.retry' -delete

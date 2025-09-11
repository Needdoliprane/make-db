SHELL := /bin/bash
.DEFAULT_GOAL := help

# ------- .env loader -------
ENV_FILE ?= .env
ifneq (,$(wildcard $(ENV_FILE)))
  include $(ENV_FILE)
  # Exporte toutes les clés valides du .env vers l'environnement des commandes Make
  export $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' $(ENV_FILE))
endif

# ---- Config par défaut ----
CERTS_DIR ?= ./certs
POSTGRES_USER ?= postgres
POSTGRES_PASSWORD ?= postgres
SOFTHSM_TOKEN_LABEL ?= DOLICORP
SOFTHSM_USER_PIN ?= 1234

PG_MDP_PORT ?= 54321
PG_TLS_PORT ?= 54322
PG_MTLS_PORT ?= 54323
PG_PKCS11_PORT ?= 35432

MYSQL_MDP_PORT ?= 3306
MYSQL_TLS_PORT ?= 13306
MYSQL_MTLS_PORT ?= 23306
MYSQL_PKCS11_PORT ?= 33306

MARIADB_MDP_PORT ?= 4306
MARIADB_TLS_PORT ?= 44306
MARIADB_MTLS_PORT ?= 45306
MARIADB_PKCS11_PORT ?= 46306

MONGO_MDP_PORT ?= 27017
MONGO_TLS_PORT ?= 17017
MONGO_MTLS_PORT ?= 27027
MONGO_PKCS11_PORT ?= 37017
MONGO_INITDB_ROOT_USERNAME ?= admin
MONGO_INITDB_ROOT_PASSWORD ?= adminpwd

# Format & dossier par défaut
DUMP_FMT ?= json
DUMP_OUT ?= ./dumps


# --- Quel Python ?
PYTHON ?= python3

# Variantes à parcourir si VARIANT=all
VARIANTS ?= mdp tls mtls pkcs11
VARIANT  ?= all

# Sortie et format
DUMP_FMT ?= json
DUMP_OUT ?= ./dumps

# Chemin absolu pour éviter les surprises côté compose/containers
CERTS_DIR := $(abspath $(CERTS_DIR))

# Export explicite des variables clés (en plus de celles venues du .env)
export CERTS_DIR POSTGRES_USER POSTGRES_PASSWORD SOFTHSM_TOKEN_LABEL SOFTHSM_USER_PIN PG_MDP_PORT PG_TLS_PORT PG_MTLS_PORT PG_PKCS11_PORT \
		MYSQL_MDP_PORT MYSQL_TLS_PORT MYSQL_MTLS_PORT MYSQL_PKCS11_PORT MYSQL_ROOT_PASSWORD \
		MARIADB_MDP_PORT MARIADB_TLS_PORT MARIADB_MTLS_PORT MARIADB_PKCS11_PORT MARIADB_ROOT_PASSWORD \
		MONGO_MDP_PORT MONGO_TLS_PORT MONGO_MTLS_PORT MONGO_PKCS11_PORT MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD

# ---- Compose sets ----
COMPOSE_BASE = -f docker-compose.base.yml
COMPOSE_PG   = -f docker-compose.postgres.yml
COMPOSE_MYSQL= -f docker-compose.mysql.yml
COMPOSE_MARIA= -f docker-compose.mariadb.yml
COMPOSE_MONGO= -f docker-compose.mongo.yml
COMPOSE_ALL  = $(COMPOSE_BASE) $(COMPOSE_PG) $(COMPOSE_MYSQL) $(COMPOSE_MARIA) $(COMPOSE_MONGO)

# ---- Helpers ----
define ensure_network
	@if ! docker network inspect dbnet >/dev/null 2>&1; then \
	  echo "→ create network dbnet"; docker network create dbnet >/dev/null; \
	fi
endef

define ensure_volume
	@if ! docker volume inspect softhsm >/dev/null 2>&1; then \
	  echo "→ create volume softhsm"; docker volume create softhsm >/dev/null; \
	fi
endef

define wait_tcp
	@echo "⏳ wait tcp://localhost:$(1) …"; \
	for i in {1..60}; do \
	  (echo >/dev/tcp/127.0.0.1/$(1)) >/dev/null 2>&1 && { echo "✓ port $(1) up"; exit 0; }; \
	  sleep 1; \
	done; \
	echo "✗ timeout waiting port $(1)"; exit 1
endef

PYTHON ?= python3

_dump-one:
	@echo "== $(ENGINE) $(VAR) =="
	@dbs="$$( $(PYTHON) tools/dump_tables.py --engine $(ENGINE) --variant $(VAR) --list-dbs 2>/dev/null || true )"; \
	if [ -z "$$dbs" ]; then echo "  (aucune base trouvée)"; exit 0; fi; \
	for db in $$dbs; do \
	  echo "→ $(ENGINE):$(VAR) $$db"; \
	  names="$$( $(PYTHON) tools/dump_tables.py --engine $(ENGINE) --variant $(VAR) --db $$db --list 2>/dev/null || true )"; \
	  if [ "$(ENGINE)" = "mongo" ]; then \
	    if [ -n "$$names" ]; then \
	      csv="$$(echo "$$names" | paste -sd, - -)"; \
	      $(PYTHON) tools/dump_tables.py --engine $(ENGINE) --variant $(VAR) --db $$db --collections "$$csv" --fmt $(DUMP_FMT) --out "$(DUMP_OUT)"; \
	    else echo "  (aucune collection)"; fi; \
	  else \
	    if [ -n "$$names" ]; then \
	      csv="$$(echo "$$names" | paste -sd, - -)"; \
	      $(PYTHON) tools/dump_tables.py --engine $(ENGINE) --variant $(VAR) --db $$db --tables "$$csv" --fmt $(DUMP_FMT) --out "$(DUMP_OUT)"; \
	    else echo "  (aucune table)"; fi; \
	  fi; \
	done

# -------- Helpers: boucle sur variantes --------
# Utilise VARIANT=all|mdp|tls|mtls|pkcs11  et VARIANTS="mdp tls mtls pkcs11"
define call_dump_for_engine
	@vs="$$( [ "$(VARIANT)" = "all" ] && echo "$(VARIANTS)" || echo "$(VARIANT)" )"; \
	for v in $$vs; do \
	  $(MAKE) --no-print-directory _dump-one ENGINE=$(1) VAR=$$v; \
	done
endef


# ---- Targets génériques ----
.PHONY: help certs clean really-clean dump-pg dump-mysql dump-maria dump-mongo dump-all dump-pg dump-mysql dump-maria dump-mongo dump-all list-dbs-pg list-dbs-mysql list-dbs-maria list-dbs-mongo


help:
	@echo "make up          -> tout lancer (pg + mysql + mariadb + mongo)"
	@echo "make up-pg       -> uniquement PostgreSQL"
	@echo "make up-mysql    -> uniquement MySQL"
	@echo "make up-maria    -> uniquement MariaDB"
	@echo "make up-mongo    -> uniquement MongoDB"
	@echo "make down-*      -> idem pour arrêter"
	@echo "make restart-*   -> idem pour redémarrer"
	@echo "make certs       -> regénérer les certificats"
	@echo "make clean       -> nettoyer CSR/conf"
	@echo "make really-clean-> reset complet (certs + vol softhsm)"
	@echo "make dump-pg [VARIANT=...]   [DUMP_FMT=json|csv|ndjson] [DUMP_OUT=./dumps]"
	@echo "make dump-mysql [VARIANT=...] [DUMP_FMT=json|csv|ndjson] [DUMP_OUT=./dumps]"
	@echo "make dump-maria [VARIANT=...] [DUMP_FMT=json|csv|ndjson] [DUMP_OUT=./dumps]"
	@echo "make dump-mongo [VARIANT=...] [DUMP_FMT=json|csv|ndjson] [DUMP_OUT=./dumps]"
	@echo "make dump-all   [VARIANT=...] [DUMP_FMT=json|csv|ndjson] [DUMP_OUT=./dumps]"

certs:
	@echo "→ Génération certificats…"
	./scripts/init-certs.sh

clean:
	find "$(CERTS_DIR)/server" -type f \( -name 'server.csr' -o -name 'server.cnf' \) -delete || true

really-clean:
	@rm -rf "$(CERTS_DIR)"
	@docker volume rm -f softhsm || true

# ---- Flows isolés ----
up: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_ALL) up -d

down:
	docker compose $(COMPOSE_ALL) down -v

# --- PostgreSQL ---
up-pg:
	$(ensure_network)
	$(ensure_volume)
	$(MAKE) certs
	docker compose $(COMPOSE_BASE) $(COMPOSE_PG) up -d

down-pg:
	docker compose $(COMPOSE_BASE) $(COMPOSE_PG) down -v

restart-pg:
	docker compose $(COMPOSE_BASE) $(COMPOSE_PG) restart

# --- MySQL ---
up-mysql: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_BASE) $(COMPOSE_MYSQL) up -d

down-mysql:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MYSQL) down -v 

restart-mysql:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MYSQL) restart

# --- MariaDB ---
up-maria: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_BASE) $(COMPOSE_MARIA) up -d

down-maria:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MARIA) down -v 

restart-maria:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MARIA) restart

# --- MongoDB ---
up-mongo: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_BASE) $(COMPOSE_MONGO) up -d

down-mongo:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MONGO) down -v

restart-mongo:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MONGO) restart

# -------- Cibles publiques --------
dump-pg:    ; $(call call_dump_for_engine,pg)
dump-mysql: ; $(call call_dump_for_engine,mysql)
dump-maria: ; $(call call_dump_for_engine,mariadb)
dump-mongo: ; $(call call_dump_for_engine,mongo)

dump-all:
	@$(MAKE) dump-pg    VARIANT="$(VARIANT)" DUMP_FMT="$(DUMP_FMT)" DUMP_OUT="$(DUMP_OUT)"
	@$(MAKE) dump-mysql VARIANT="$(VARIANT)" DUMP_FMT="$(DUMP_FMT)" DUMP_OUT="$(DUMP_OUT)"
	@$(MAKE) dump-maria VARIANT="$(VARIANT)" DUMP_FMT="$(DUMP_FMT)" DUMP_OUT="$(DUMP_OUT)"
	@$(MAKE) dump-mongo VARIANT="$(VARIANT)" DUMP_FMT="$(DUMP_FMT)" DUMP_OUT="$(DUMP_OUT)"

# (optionnel) pour visualiser ce que voit le script avant de dumper
list-dbs-pg:
	@vs="$$( [ "$(VARIANT)" = "all" ] && echo "$(VARIANTS)" || echo "$(VARIANT)" )"; \
	for v in $$vs; do echo "== pg $$v =="; $(PYTHON) tools/dump_tables.py --engine pg --variant $$v --list-dbs; done

list-dbs-mysql:
	@vs="$$( [ "$(VARIANT)" = "all" ] && echo "$(VARIANTS)" || echo "$(VARIANT)" )"; \
	for v in $$vs; do echo "== mysql $$v =="; $(PYTHON) tools/dump_tables.py --engine mysql --variant $$v --list-dbs; done

list-dbs-maria:
	@vs="$$( [ "$(VARIANT)" = "all" ] && echo "$(VARIANTS)" || echo "$(VARIANT)" )"; \
	for v in $$vs; do echo "== mariadb $$v =="; $(PYTHON) tools/dump_tables.py --engine mariadb --variant $$v --list-dbs; done

list-dbs-mongo:
	@vs="$$( [ "$(VARIANT)" = "all" ] && echo "$(VARIANTS)" || echo "$(VARIANT)" )"; \
	for v in $$vs; do echo "== mongo $$v =="; $(PYTHON) tools/dump_tables.py --engine mongo --variant $$v --list-dbs; done
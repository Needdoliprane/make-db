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

# Chemin absolu pour éviter les surprises côté compose/containers
CERTS_DIR := $(abspath $(CERTS_DIR))

# Export explicite des variables clés (en plus de celles venues du .env)
export CERTS_DIR POSTGRES_USER POSTGRES_PASSWORD SOFTHSM_TOKEN_LABEL SOFTHSM_USER_PIN PG_MDP_PORT PG_TLS_PORT PG_MTLS_PORT PG_PKCS11_PORT

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

# ---- Targets génériques ----
.PHONY: help certs clean really-clean

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
	docker compose $(COMPOSE_ALL) down

# --- PostgreSQL ---
up-pg:
	$(ensure_network)
	$(ensure_volume)
	$(MAKE) certs
	docker compose $(COMPOSE_BASE) $(COMPOSE_PG) up -d

down-pg:
	docker compose $(COMPOSE_BASE) $(COMPOSE_PG) down

restart-pg:
	docker compose $(COMPOSE_BASE) $(COMPOSE_PG) restart

# --- MySQL ---
up-mysql: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_BASE) $(COMPOSE_MYSQL) up -d

down-mysql:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MYSQL) down

restart-mysql:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MYSQL) restart

# --- MariaDB ---
up-maria: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_BASE) $(COMPOSE_MARIA) up -d

down-maria:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MARIA) down

restart-maria:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MARIA) restart

# --- MongoDB ---
up-mongo: certs
	$(ensure_network)
	$(ensure_volume)
	docker compose $(COMPOSE_BASE) $(COMPOSE_MONGO) up -d

down-mongo:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MONGO) down

restart-mongo:
	docker compose $(COMPOSE_BASE) $(COMPOSE_MONGO) restart

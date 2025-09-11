# make-db

**TLS/mTLS/PKCS#11 sandbox for PostgreSQL • MySQL • MariaDB • MongoDB**

A Docker Compose sandbox that runs four database engines (PostgreSQL, MySQL, MariaDB, MongoDB) in four connection variants:

- **mdp** – cleartext + password
- **tls** – server TLS (client verifies CA)
- **mtls** – mutual TLS (client presents cert)
- **pkcs11** – TLS terminated by a proxy whose server key lives in a HSM (SoftHSM via PKCS#11)

## What you get

- Compose stacks per engine/variant
- A seeder that creates N databases and fills them with realistic random data
- An auto-discovering dump tool (`tools/dump_tables.py`) plus Make targets to export everything as JSON/CSV/NDJSON
- A local PKI (CA, server/client certs) and SoftHSM for PKCS#11

## Prerequisites

- Docker & Docker Compose v2
- GNU Make
- Python 3.10+ with:
  ```bash
  pip install psycopg2-binary pymysql pymongo faker tenacity
  ```
- Free host ports according to your `.env` (see below)

## Project layout

```
.
├─ docker-compose.*.yml        # per engine/variant stacks
├─ scripts/init-certs.sh       # local PKI generator
├─ certs/                      # CA + server/client certs (generated)
├─ tlsproxy/                   # TLS proxy + client stunnel configs
├─ seeder/                     # image that seeds all DBs
└─ tools/dump_tables.py        # list/dump tool (auto-discovery)
```

## Configuration (Makefile / .env excerpts)

```bash
# Where certs live + CN used for cert SANs
CERTS_DIR=./certs
CERT_CN_BASE=localhost          # ⚠️ important for TLS: prefer "localhost" over 127.0.0.1

# PostgreSQL
PG_MDP_PORT=5432
PG_TLS_PORT=15432
PG_MTLS_PORT=25432
PG_PKCS11_PORT=35432
POSTGRES_USER=pgadmin
POSTGRES_PASSWORD=pgadminpwd

# MySQL
MYSQL_MDP_PORT=3306
MYSQL_TLS_PORT=13306
MYSQL_MTLS_PORT=23306
MYSQL_PKCS11_PORT=33306
MYSQL_ROOT_PASSWORD=rootpwd

# MariaDB
MARIADB_MDP_PORT=4306
MARIADB_TLS_PORT=44306
MARIADB_MTLS_PORT=45306
MARIADB_PKCS11_PORT=46306
MARIADB_ROOT_PASSWORD=rootpwd

# MongoDB
MONGO_MDP_PORT=27017
MONGO_TLS_PORT=17017
MONGO_MTLS_PORT=27027
MONGO_PKCS11_PORT=37017
MONGO_INITDB_ROOT_USERNAME=admin
MONGO_INITDB_ROOT_PASSWORD=adminpwd

# SoftHSM/PKCS#11
SOFTHSM_TOKEN_LABEL=DOLICORP
SOFTHSM_USER_PIN=1234
PKCS11_KEY_LABEL_PREFIX=svc
```

*All exposed host ports are driven by these variables.*

## Quick start

1. **Generate local PKI**
   ```bash
   make certs
   ```

2. **Spin everything up** (network + SoftHSM volume are handled automatically):
   ```bash
   make up
   # or per engine:
   make up-pg
   make up-mysql
   make up-maria
   make up-mongo
   ```

### Seeding

The `seeder-*` container runs automatically and creates/seeds:
- `DB_COUNT=3` databases per engine/variant
- `MIN_TABLES..MAX_TABLES` tables/collections per database  
- `RECORDS_PER_DB` rows/documents per table/collection

## Variants & connection matrix

| Engine     | Variant | Host exposure           | Client auth      | Notes                                                                         |
|------------|---------|-------------------------|------------------|-------------------------------------------------------------------------------|
| Postgres   | mdp     | `${PG_MDP_PORT}`        | password         | Cleartext                                                                     |
| Postgres   | tls     | `${PG_TLS_PORT}`        | password + CA    | `sslmode=require`                                                             |
| Postgres   | mtls    | `${PG_MTLS_PORT}`       | client cert      | `sslmode=require + sslcert/sslkey`                                            |
| Postgres   | pkcs11  | `${PG_PKCS11_PORT}`     | password         | Connect to the *-client stunnel only (frontend is a TLS terminator; not libpq-compatible) |
| MySQL      | mdp     | `${MYSQL_MDP_PORT}`     | password         | Cleartext                                                                     |
| MySQL      | tls     | `${MYSQL_TLS_PORT}`     | password + CA    | `--ssl-mode=VERIFY_CA`                                                        |
| MySQL      | mtls    | `${MYSQL_MTLS_PORT}`    | client cert      | `--ssl-cert/--ssl-key`                                                        |
| MySQL      | pkcs11  | `${MYSQL_PKCS11_PORT}`  | password         | Exposed client stunnel only; proxy frontend remains internal                 |
| MariaDB    | …       | like MySQL              | like MySQL       | same behavior                                                                 |
| MongoDB    | mdp     | `${MONGO_MDP_PORT}`     | password         | Cleartext                                                                     |
| MongoDB    | tls     | `${MONGO_TLS_PORT}`     | password + CA    | `--tls + --tlsCAFile`                                                         |
| MongoDB    | mtls    | `${MONGO_MTLS_PORT}`    | client cert      | `--tlsCertificateKeyFile` (PEM)                                               |
| MongoDB    | pkcs11  | `${MONGO_PKCS11_PORT}`  | client cert      | Exposed client stunnel only; proxy frontend remains internal                 |

> **PKCS#11**: the frontend (TLS terminator with server key in HSM) stays internal.  
> Only the client stunnel is exposed on the host (`*_PKCS11_PORT`).

## Seeder details

For each engine/variant the seeder creates:
- Databases named `pg_<variant>_N`, `mysql_<variant>_N`, `ma_<variant>_N`, `mg_<variant>_N`
- Random tables/collections with realistic schemas
- Fake data via faker, including JSON/BLOB types where supported

Seeder logs show connection modes (TLS/mTLS/PKCS#11), DB creation and insert progress.

## Dumps (auto-discovery)

The tool `tools/dump_tables.py` discovers databases per variant and can list/dump in JSON/CSV/NDJSON.  
Make targets wrap everything for convenience.

### Ready-to-use Make commands

```bash
# Dump all variants for one engine
make dump-pg
make dump-mysql
make dump-maria
make dump-mongo

# Limit to one variant
make dump-mysql VARIANT=tls

# Change format and output directory
make dump-mongo VARIANT=mtls DUMP_FMT=ndjson DUMP_OUT=./dumps_mongo

# Dump everything (all engines)
make dump-all
```

### Using dump_tables.py directly

```bash
# Discover databases (e.g., Mongo mTLS)
python3 tools/dump_tables.py --engine mongo --variant mtls --list-dbs

# List tables/collections in a database
python3 tools/dump_tables.py --engine pg --variant tls --db pg_tls_1 --list

# Dump two MySQL tables as CSV
python3 tools/dump_tables.py --engine mysql --variant tls \
  --db mysql_tls_1 --tables foo_1,bar_2 --fmt csv --out ./dumps

# Dump two Mongo collections as NDJSON
python3 tools/dump_tables.py --engine mongo --variant mtls \
  --db mg_mtls_1 --collections c1,c2 --fmt ndjson --out ./dumps
```

The Make wrappers call `--list-dbs` first, then iterate each DB and dump all tables/collections automatically.

## Troubleshooting

### 1) TLS hostname mismatch

**Error example:**
```
certificate verify failed: IP address mismatch, certificate is not valid for '127.0.0.1'
```

**Cause:** the server cert has SANs for `localhost`, not `127.0.0.1`.

**Fixes:**
- Use `CERT_CN_BASE=localhost` and connect to localhost (not 127.0.0.1)
- Or regenerate certs with `IP:127.0.0.1` in SANs (`scripts/init-certs.sh`)
- As a last resort for dev only, relax hostname verification (not recommended)

The repo already uses `CERT_CN_BASE` in TLS/mTLS client code (MySQL/Mongo).

### 2) Postgres pkcs11 (important)

libpq sends a cleartext SSLRequest first; pure TLS terminators reject it.  
👉 **Always connect to the `*-client` stunnel endpoint on `${PG_PKCS11_PORT}`; never directly to the TLS frontend.**

### 3) MongoDB mTLS

PyMongo expects a PEM that contains client cert and private key via `tlsCertificateKeyFile` (we use `./certs/client/client.pem`).

### 4) Ports in use

If a port is taken, edit your `.env` (e.g., `MYSQL_TLS_PORT=13307`), then restart.

## Quick test snippets

**PostgreSQL (mTLS):**
```bash
psql "host=localhost port=${PG_MTLS_PORT} user=pgadmin password=pgadminpwd \
      sslmode=require sslrootcert=./certs/ca/ca.crt \
      sslcert=./certs/client/client.crt sslkey=./certs/client/client.key"
```

**MySQL (TLS):**
```bash
mysql --protocol=tcp -uroot -p"${MYSQL_ROOT_PASSWORD}" \
  -h localhost -P ${MYSQL_TLS_PORT} \
  --ssl-mode=VERIFY_CA --ssl-ca=./certs/ca/ca.crt
```

**MongoDB (mTLS):**
```bash
mongosh --host localhost --port ${MONGO_MTLS_PORT} \
  --tls --tlsCAFile ./certs/ca/ca.crt \
  --tlsCertificateKeyFile ./certs/client/client.pem \
  -u admin -p adminpwd --authenticationDatabase admin
```

## Make targets reference

```bash
make help            # overview of targets
make up / down       # bring all stacks up / down
make up-<engine>     # e.g., up-pg
make restart-<engine>
make certs           # regenerate local PKI

# discovery helpers
make list-dbs-pg VARIANT=mtls
make list-dbs-mysql VARIANT=tls
make list-dbs-maria VARIANT=pkcs11
make list-dbs-mongo VARIANT=mtls
```

## Cleanup

```bash
make down            # stop + remove stack volumes
make really-clean    # remove ./certs and the softhsm volume
```

## License

Steer the ship however you want—I’m off the hook for any icebergs. / You’re free to proceed as you see fit; please note I can’t accept responsibility for the outcome.
> **⚠️ This project is for development/demo only — do not expose as-is to production.**
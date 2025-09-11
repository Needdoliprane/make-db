#!/usr/bin/env python3
"""
Lister & dumper (JSON/CSV/NDJSON) pour tables/collections sélectionnées.

Exemples :
  # Lister bases découvertes
  python tools/dump_tables.py --engine pg --variant mdp --list-dbs

  # Lister tables
  python tools/dump_tables.py --engine pg --variant mdp --db ma_base --list

  # Dumper tables en CSV
  python tools/dump_tables.py --engine mysql --variant tls --db ma_base --tables t1,t2 --fmt csv --out ./dumps

  # Dumper collections en NDJSON
  python tools/dump_tables.py --engine mongo --variant pkcs11 --db ma_base --collections c1,c2 --fmt ndjson --out ./dumps
"""
import csv
import json
import os
import re
import sys

import psycopg2
import pymysql
from pymongo import MongoClient


# === helpers ===
def env(k, d=None):
    return os.getenv(k, d)


def _pg_conn(db, variant, for_catalog=False):
    port = {
        "mdp": int(env("PG_MDP_PORT", "5432")),
        "tls": int(env("PG_TLS_PORT", "15432")),
        "mtls": int(env("PG_MTLS_PORT", "25432")),
        "pkcs11": int(env("PG_PKCS11_PORT", "35432")),
    }[variant]
    u, w = env("POSTGRES_USER", "pgadmin"), env("POSTGRES_PASSWORD", "pgadminpwd")
    sslmode = "require" if variant in ("tls", "mtls") else "disable"
    dsn = f"host=127.0.0.1 port={port} user={u} password={w} dbname={db} sslmode={sslmode}"
    if sslmode == "require":
        dsn += " sslrootcert=./certs/ca/ca.crt"
    return psycopg2.connect(dsn)


def _mysql_conn(db, variant, mariadb=False):
    port = int(env(("MARIADB_" if mariadb else "MYSQL_") + variant.upper() + "_PORT"))
    pwd = env(("MARIADB_" if mariadb else "MYSQL_") + "ROOT_PASSWORD", "rootpwd")

    # Hôte pour le SNI : en TLS/MTLS utilise le CN/SAN (localhost)
    host = "127.0.0.1"
    if variant in ("tls", "mtls"):
        host = env("CERT_CN_BASE", "localhost")  # ton .env met CERT_CN_BASE=localhost

    # SSL params
    ssl = None
    if variant == "tls":
        ssl = {"ca": "./certs/ca/ca.crt"}
    elif variant == "mtls":
        ssl = {
            "ca": "./certs/ca/ca.crt",
            "cert": "./certs/client/client.crt",
            "key": "./certs/client/client.key",
        }

    return pymysql.connect(
        host=host, port=port, user="root", password=pwd, database=db, ssl=ssl
    )


def _mongo_client(db, variant):
    port = int(env("MONGO_" + variant.upper() + "_PORT", "27017"))
    u = env("MONGO_INITDB_ROOT_USERNAME", "admin")
    w = env("MONGO_INITDB_ROOT_PASSWORD", "adminpwd")

    # IMPORTANT : en TLS/mTLS, utiliser le CN/SAN (localhost par défaut)
    host = "127.0.0.1"
    if variant in ("tls", "mtls"):
        host = env("CERT_CN_BASE", "localhost")  # ton .env a CERT_CN_BASE=localhost

    tls = variant in ("tls", "mtls")
    uri = f"mongodb://{u}:{w}@{host}:{port}/?authSource=admin"

    kw = {}
    if tls:
        kw["tls"] = True
        kw["tlsCAFile"] = "./certs/ca/ca.crt"
    if variant == "mtls":
        # PyMongo attend un PEM qui contient cert + clé privée
        # (dans ton repo, c'est généralement ./certs/client/client.pem)
        kw["tlsCertificateKeyFile"] = "./certs/client/client.pem"

    return MongoClient(uri, **kw)


# === discover dbs ===
def discover_pg_dbs(variant):
    conn = _pg_conn(db="postgres", variant=variant, for_catalog=True)
    cur = conn.cursor()
    cur.execute("SELECT datname FROM pg_database WHERE datistemplate = false;")
    names = [r[0] for r in cur.fetchall()]
    pat = re.compile(r"^pg_(mdp|tls|mtls|pkcs11)_[0-9]+$")
    names = [n for n in names if pat.match(n)]  # <— filtre
    cur.close()
    conn.close()
    return names


def discover_mysql_like_dbs(variant, mariadb=False):
    conn = _mysql_conn("information_schema", variant, mariadb)
    cur = conn.cursor()
    cur.execute("SHOW DATABASES;")
    dbs = [
        r[0]
        for r in cur.fetchall()
        if r[0] not in ("information_schema", "mysql", "performance_schema", "sys")
    ]
    cur.close()
    conn.close()
    return dbs


def discover_mongo_dbs(variant):
    c = _mongo_client("admin", variant)
    dbs = [d for d in c.list_database_names() if d not in ("admin", "local", "config")]
    c.close()
    return dbs


# === list objects ===
def list_pg(db, variant):
    conn = _pg_conn(db, variant)
    cur = conn.cursor()
    cur.execute(
        "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY 1;"
    )
    for (t,) in cur.fetchall():
        print(t)
    cur.close()
    conn.close()


def list_mysql_like(db, variant, mariadb=False):
    conn = _mysql_conn(db, variant, mariadb)
    cur = conn.cursor()
    cur.execute("SHOW TABLES;")
    for (t,) in cur.fetchall():
        print(t)
    cur.close()
    conn.close()


def list_mongo(db, variant):
    c = _mongo_client(db, variant)
    print("\n".join(sorted(c[db].list_collection_names())))
    c.close()


# === dump objects ===
def dump_pg(db, variant, tables, out, fmt):
    conn = _pg_conn(db, variant)
    cur = conn.cursor()
    os.makedirs(out, exist_ok=True)
    for t in tables:
        cur.execute(f'SELECT * FROM "{t}"')
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        _write_rows(out, db, t, cols, rows, fmt)
    cur.close()
    conn.close()


def dump_mysql_like(db, variant, tables, out, fmt, mariadb=False):
    conn = _mysql_conn(db, variant, mariadb)
    cur = conn.cursor()
    os.makedirs(out, exist_ok=True)
    for t in tables:
        cur.execute(f"SELECT * FROM `{t}`;")
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        _write_rows(out, db, t, cols, rows, fmt)
    cur.close()
    conn.close()


def dump_mongo(db, variant, colls, out, fmt):
    c = _mongo_client(db, variant)
    os.makedirs(out, exist_ok=True)
    for col in colls:
        docs = list(c[db][col].find({}))
        if fmt == "csv":
            path = os.path.join(out, f"{db}_{col}.csv")
            if not docs:
                open(path, "w").close()
                continue
            keys = sorted({k for d in docs for k in d.keys()})
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=keys)
                w.writeheader()
                for d in docs:
                    w.writerow({k: d.get(k, "") for k in keys})
        elif fmt == "ndjson":
            with open(
                os.path.join(out, f"{db}_{col}.ndjson"), "w", encoding="utf-8"
            ) as f:
                for d in docs:
                    f.write(json.dumps(d, default=str) + "\n")
        else:
            with open(
                os.path.join(out, f"{db}_{col}.json"), "w", encoding="utf-8"
            ) as f:
                json.dump(docs, f, default=str)
    c.close()


def _write_rows(out, db, t, cols, rows, fmt):
    if fmt == "csv":
        with open(
            os.path.join(out, f"{db}_{t}.csv"), "w", newline="", encoding="utf-8"
        ) as f:
            w = csv.writer(f)
            w.writerow(cols)
            w.writerows(rows)
    elif fmt == "ndjson":
        with open(os.path.join(out, f"{db}_{t}.ndjson"), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(dict(zip(cols, r)), default=str) + "\n")
    else:
        with open(os.path.join(out, f"{db}_{t}.json"), "w", encoding="utf-8") as f:
            json.dump([dict(zip(cols, r)) for r in rows], f, default=str)


# === main ===
def main():
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--engine", required=True, choices=["pg", "mysql", "mariadb", "mongo"]
    )
    ap.add_argument(
        "--variant", required=True, choices=["mdp", "tls", "mtls", "pkcs11"]
    )
    ap.add_argument("--list-dbs", action="store_true")
    ap.add_argument("--db")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--tables")
    ap.add_argument("--collections")
    ap.add_argument("--fmt", default="json", choices=["json", "csv", "ndjson"])
    ap.add_argument("--out", default="./dumps")
    a = ap.parse_args()

    # Découverte des DB
    if a.list_dbs:
        dbs = (
            discover_pg_dbs(a.variant)
            if a.engine == "pg"
            else (
                discover_mysql_like_dbs(a.variant, mariadb=(a.engine == "mariadb"))
                if a.engine in ("mysql", "mariadb")
                else discover_mongo_dbs(a.variant)
            )
        )
        print("\n".join(dbs))
        return

    if not a.db:
        print("❌ --db requis sauf avec --list-dbs")
        sys.exit(1)

    # Lister ou dumper
    if a.engine == "pg":
        if a.list:
            list_pg(a.db, a.variant)
            return
        if not a.tables:
            print("No --tables")
            sys.exit(1)
        dump_pg(a.db, a.variant, a.tables.split(","), a.out, a.fmt)
    elif a.engine in ("mysql", "mariadb"):
        mariadb = a.engine == "mariadb"
        if a.list:
            list_mysql_like(a.db, a.variant, mariadb=mariadb)
            return
        if not a.tables:
            print("No --tables")
            sys.exit(1)
        dump_mysql_like(
            a.db, a.variant, a.tables.split(","), a.out, a.fmt, mariadb=mariadb
        )
    else:
        if a.list:
            list_mongo(a.db, a.variant)
            return
        if not a.collections:
            print("No --collections")
            sys.exit(1)
        dump_mongo(a.db, a.variant, a.collections.split(","), a.out, a.fmt)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Lister & dumper (JSON/CSV/NDJSON) pour tables/collections sélectionnées.

Exemples :
  # Lister
  python tools/dump_tables.py --engine pg --variant mdp --db pg_mdp_1 --list
  python tools/dump_tables.py --engine mongo --variant mtls --db mg_mtls_1 --list

  # Dumper 2 tables en CSV
  python tools/dump_tables.py --engine pg --variant tls --db pg_tls_1 --tables foo_1,bar_2 --fmt csv --out ./dumps

  # Dumper 2 collections en NDJSON
  python tools/dump_tables.py --engine mongo --variant pkcs11 --db mg_pkcs11_1 --collections c1,c2 --fmt ndjson --out ./dumps
"""
import argparse
import csv
import json
import os
import sys

import psycopg2
import pymysql
from pymongo import MongoClient


def env(k, d=None):
    return os.getenv(k, d)


def pg_params(variant):
    port = {
        "mdp": int(env("PG_MDP_PORT", "5432")),
        "tls": int(env("PG_TLS_PORT", "15432")),
        "mtls": int(env("PG_MTLS_PORT", "25432")),
        "pkcs11": int(env("PG_PKCS11_PORT", "35432")),
    }[variant]
    return port, env("POSTGRES_USER", "pgadmin"), env("POSTGRES_PASSWORD", "pgadminpwd")


def mysql_params(variant, mariadb=False):
    port = int(
        env(("MARIADB_" if mariadb else "MYSQL_") + variant.upper() + "_PORT", "3306")
    )
    pwd = env(("MARIADB_" if mariadb else "MYSQL_") + "ROOT_PASSWORD", "rootpwd")
    return port, "root", pwd


def mongo_params(variant):
    port = int(env("MONGO_" + variant.upper() + "_PORT", "27017"))
    return (
        port,
        env("MONGO_INITDB_ROOT_USERNAME", "admin"),
        env("MONGO_INITDB_ROOT_PASSWORD", "adminpwd"),
    )


def list_pg(db, variant):
    p, u, w = pg_params(variant)
    sslmode = "disable" if variant == "mdp" else "require"
    dsn = f"host=127.0.0.1 port={p} user={u} password={w} dbname={db} sslmode={sslmode}"
    if variant != "mdp":
        dsn += " sslrootcert=./certs/ca/ca.crt"
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    cur.execute(
        "SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY 1;"
    )
    for (t,) in cur.fetchall():
        print(t)
    cur.close()
    conn.close()


def dump_pg(db, variant, tables, out, fmt):
    p, u, w = pg_params(variant)
    sslmode = "disable" if variant == "mdp" else "require"
    dsn = f"host=127.0.0.1 port={p} user={u} password={w} dbname={db} sslmode={sslmode}"
    if variant != "mdp":
        dsn += " sslrootcert=./certs/ca/ca.crt"
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()
    os.makedirs(out, exist_ok=True)
    for t in tables:
        cur.execute(f'SELECT * FROM "{t}"')
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        if fmt == "csv":
            with open(
                os.path.join(out, f"{db}_{t}.csv"), "w", newline="", encoding="utf-8"
            ) as f:
                wri = csv.writer(f)
                wri.writerow(cols)
                wri.writerows(rows)
        elif fmt == "ndjson":
            with open(
                os.path.join(out, f"{db}_{t}.ndjson"), "w", encoding="utf-8"
            ) as f:
                for r in rows:
                    f.write(json.dumps(dict(zip(cols, r)), default=str) + "\n")
        else:
            with open(os.path.join(out, f"{db}_{t}.json"), "w", encoding="utf-8") as f:
                json.dump([dict(zip(cols, r)) for r in rows], f, default=str)
    cur.close()
    conn.close()


def list_mysql_like(db, variant, mariadb=False):
    p, u, w = mysql_params(variant, mariadb)
    ssl = None
    if variant != "mdp":
        ssl = {"ca": "./certs/ca/ca.crt"}
    conn = pymysql.connect(
        host="127.0.0.1", port=p, user=u, password=w, database=db, ssl=ssl
    )
    cur = conn.cursor()
    cur.execute("SHOW TABLES;")
    for (t,) in cur.fetchall():
        print(t)
    cur.close()
    conn.close()


def dump_mysql_like(db, variant, tables, out, fmt, mariadb=False):
    p, u, w = mysql_params(variant, mariadb)
    ssl = None
    if variant != "mdp":
        ssl = {"ca": "./certs/ca/ca.crt"}
    conn = pymysql.connect(
        host="127.0.0.1", port=p, user=u, password=w, database=db, ssl=ssl
    )
    cur = conn.cursor()
    os.makedirs(out, exist_ok=True)
    for t in tables:
        cur.execute(f"SELECT * FROM `{t}`;")
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        if fmt == "csv":
            with open(
                os.path.join(out, f"{db}_{t}.csv"), "w", newline="", encoding="utf-8"
            ) as f:
                wri = csv.writer(f)
                wri.writerow(cols)
                wri.writerows(rows)
        elif fmt == "ndjson":
            with open(
                os.path.join(out, f"{db}_{t}.ndjson"), "w", encoding="utf-8"
            ) as f:
                for r in rows:
                    f.write(json.dumps(dict(zip(cols, r)), default=str) + "\n")
        else:
            with open(os.path.join(out, f"{db}_{t}.json"), "w", encoding="utf-8") as f:
                json.dump([dict(zip(cols, r)) for r in rows], f, default=str)
    cur.close()
    conn.close()


def list_mongo(db, variant):
    p, u, w = mongo_params(variant)
    tls = variant in ("tls", "mtls", "pkcs11")
    uri = f"mongodb://{u}:{w}@127.0.0.1:{p}/?authSource=admin"
    kwargs = {}
    if tls:
        kwargs["tls"] = True
        kwargs["tlsCAFile"] = "./certs/ca/ca.crt"
    client = MongoClient(uri, **kwargs)
    print("\n".join(sorted(client[db].list_collection_names())))
    client.close()


def dump_mongo(db, variant, colls, out, fmt):
    p, u, w = mongo_params(variant)
    tls = variant in ("tls", "mtls", "pkcs11")
    uri = f"mongodb://{u}:{w}@127.0.0.1:{p}/?authSource=admin"
    kwargs = {}
    if tls:
        kwargs["tls"] = True
        kwargs["tlsCAFile"] = "./certs/ca/ca.crt"
    client = MongoClient(uri, **kwargs)
    os.makedirs(out, exist_ok=True)
    for c in colls:
        docs = list(client[db][c].find({}))
        if fmt == "csv":
            path = os.path.join(out, f"{db}_{c}.csv")
            if not docs:
                open(path, "w").close()
                continue
            keys = sorted({k for d in docs for k in d.keys()})
            import csv

            with open(path, "w", newline="", encoding="utf-8") as f:
                wri = csv.DictWriter(f, fieldnames=keys)
                wri.writeheader()
                for d in docs:
                    wri.writerow({k: d.get(k, "") for k in keys})
        elif fmt == "ndjson":
            path = os.path.join(out, f"{db}_{c}.ndjson")
            with open(path, "w", encoding="utf-8") as f:
                for d in docs:
                    f.write(json.dumps(d, default=str) + "\n")
        else:
            path = os.path.join(out, f"{db}_{c}.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(docs, f, default=str)
    client.close()


def main():
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--engine", required=True, choices=["pg", "mysql", "mariadb", "mongo"]
    )
    ap.add_argument(
        "--variant", required=True, choices=["mdp", "tls", "mtls", "pkcs11"]
    )
    ap.add_argument("--db", required=True)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--tables")
    ap.add_argument("--collections")
    ap.add_argument("--fmt", default="json", choices=["json", "csv", "ndjson"])
    ap.add_argument("--out", default="./dumps")
    a = ap.parse_args()

    if a.engine == "pg":
        if a.list:
            list_pg(a.db, a.variant)
            return
        if not a.tables:
            print("No --tables given")
            sys.exit(1)
        dump_pg(a.db, a.variant, a.tables.split(","), a.out, a.fmt)
    elif a.engine in ("mysql", "mariadb"):
        mariadb = a.engine == "mariadb"
        if a.list:
            list_mysql_like(a.db, a.variant, mariadb=mariadb)
            return
        if not a.tables:
            print("No --tables given")
            sys.exit(1)
        dump_mysql_like(
            a.db, a.variant, a.tables.split(","), a.out, a.fmt, mariadb=mariadb
        )
    else:
        if a.list:
            list_mongo(a.db, a.variant)
            return
        if not a.collections:
            print("No --collections given")
            sys.exit(1)
        dump_mongo(a.db, a.variant, a.collections.split(","), a.out, a.fmt)


if __name__ == "__main__":
    main()

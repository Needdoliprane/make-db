import os
import random
import string
import time

import psycopg2
import pymysql
from faker import Faker
from psycopg2 import OperationalError, extensions, sql
from psycopg2.extras import Json
from pymongo import MongoClient
from tenacity import retry, stop_after_attempt, wait_fixed

fake = Faker()

DB_COUNT = int(os.getenv("DB_COUNT", "3"))
RECORDS_PER_DB = int(os.getenv("RECORDS_PER_DB", "500"))
MIN_TABLES = int(os.getenv("MIN_TABLES", "4"))
MAX_TABLES = int(os.getenv("MAX_TABLES", "10"))

TLS_CA_FILE = os.getenv("TLS_CA_FILE", "/certs/ca/ca.crt")
TLS_CLIENT_CERT = os.getenv("TLS_CLIENT_CERT", "/certs/client/client.crt")
TLS_CLIENT_KEY = os.getenv("TLS_CLIENT_KEY", "/certs/client/client.key")


def rnd_word(n=8):
    return "".join(random.choices(string.ascii_lowercase, k=n))


def gen_schema(engine: str):
    tcount = random.randint(MIN_TABLES, MAX_TABLES)
    tables = []
    for i in range(tcount):
        t = {"name": f"{rnd_word()}_{i+1}", "cols": []}
        if engine == "pg":
            t["cols"].append(("id", "SERIAL"))
        else:
            t["cols"].append(("id", "INT AUTO_INCREMENT"))
        for _ in range(random.randint(6, 10)):
            choices = {
                "pg": [
                    "INT",
                    "BIGINT",
                    "DOUBLE PRECISION",
                    "VARCHAR(255)",
                    "TEXT",
                    "DATE",
                    "TIMESTAMP",
                    "BOOLEAN",
                    "BYTEA",
                    "JSONB",
                ],
                "mysql": [
                    "INT",
                    "BIGINT",
                    "DOUBLE",
                    "VARCHAR(255)",
                    "TEXT",
                    "DATE",
                    "TIMESTAMP",
                    "TINYINT(1)",
                    "BLOB",
                    "JSON",
                ],
                "maria": [
                    "INT",
                    "BIGINT",
                    "DOUBLE",
                    "VARCHAR(255)",
                    "TEXT",
                    "DATE",
                    "TIMESTAMP",
                    "TINYINT(1)",
                    "BLOB",
                    "JSON",
                ],
            }[engine]
            t["cols"].append((rnd_word(), random.choice(choices)))
        if random.random() < 0.2:
            t["cols"].append(("ref_id", "INT"))
        tables.append(t)
    return tables


# ---------- PostgreSQL ----------
@retry(stop=stop_after_attempt(5), wait=wait_fixed(1))
def pg_conn(host, port, dbname):
    sslmode = "require"
    dsn = f"host={host} port={int(port)} user={os.getenv('POSTGRES_USER','pgadmin')} password={os.getenv('POSTGRES_PASSWORD','pgadminpwd')} dbname={dbname} sslmode={sslmode}"
    if host in ("pg-mdp",):  # mdp = plain
        dsn = dsn.replace(" sslmode=require", " sslmode=disable")
    else:
        dsn += f" sslrootcert={TLS_CA_FILE}"
        if host in ("pg-mtls", "pg-mtls-frontend", "pg-pkcs11-frontend"):
            dsn += f" sslcert={TLS_CLIENT_CERT} sslkey={TLS_CLIENT_KEY}"
    # tentative de connexion (tenacity relancera en cas d'OperationalError)
    try:
        print(f"Connecting to PG {host}:{port}/{dbname} (sslmode={sslmode})...")
        return psycopg2.connect(dsn)
    except OperationalError as e:
        # rethrow pour que tenacity retry
        raise


def seed_pg_variant(name, host, port):
    # --- Création des DB (hors transaction) ---
    conn = pg_conn(host, port, "postgres")
    try:
        # Deux ceintures + bretelles pour l'autocommit
        conn.autocommit = True
        conn.set_session(autocommit=True)
        cur = conn.cursor()
        for i in range(1, DB_COUNT + 1):
            dbn = f"pg_{name}_{i}"
            cur.execute(sql.SQL("SELECT 1 FROM pg_database WHERE datname=%s"), (dbn,))
            if not cur.fetchone():
                cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(dbn)))
        cur.close()
    finally:
        conn.close()

    # --- Peuplement des DB (transactions OK) ---
    for i in range(1, DB_COUNT + 1):
        dbn = f"pg_{name}_{i}"
        with pg_conn(host, port, dbn) as conn:
            cur = conn.cursor()
            schema = gen_schema("pg")
            for t in schema:
                cols_sql = []
                for col, typ in t["cols"]:
                    if col == "id" and typ == "SERIAL":
                        cols_sql.append("id SERIAL PRIMARY KEY")
                    else:
                        cols_sql.append(f"{col} {typ}")
                cur.execute(
                    f'CREATE TABLE IF NOT EXISTS "{t["name"]}" ({", ".join(cols_sql)});'
                )
            conn.commit()
            for t in schema:
                cols = [c for c, _ in t["cols"] if c != "id"]
                placeholders = ", ".join(["%s"] * len(cols))
                for _ in range(RECORDS_PER_DB):
                    row = []
                    for c, typ in [x for x in t["cols"] if x[0] != "id"]:
                        u = typ.upper()
                        if "INT" in u and "TINYINT" not in u:
                            row.append(random.randint(0, 1_000_000))
                        elif (
                            "DOUBLE" in u
                            or "DECIMAL" in u
                            or "NUMERIC" in u
                            or "REAL" in u
                            or "FLOAT" in u
                        ):
                            row.append(random.uniform(0, 10_000))
                        elif "BOOLEAN" in u:
                            row.append(random.choice([True, False]))
                        elif "DATE" == u:
                            row.append(fake.date_object())
                        elif "TIMESTAMP" in u:
                            row.append(fake.date_time())
                        elif "JSON" in u:
                            row.append(Json(fake.pydict(5, True, True)))
                        elif "BYTEA" in u:
                            row.append(os.urandom(32))
                        else:
                            row.append(fake.text(80))
                    cur.execute(
                        f'INSERT INTO "{t["name"]}" ({", ".join(cols)}) VALUES ({placeholders})',
                        row,
                    )
            conn.commit()
        print(f"[PG:{name}] Seeded {dbn}")


# ---------- MySQL / MariaDB ----------
def mysql_conn(host, port, dbname=None, root_pw_env="MYSQL_ROOT_PASSWORD"):
    ssl_params = None
    if host.endswith("-frontend"):  # tls/mtls/pkcs11
        ssl_params = {"ca": TLS_CA_FILE}
        if (
            host.startswith(
                ("mysql-mtls", "mysql-pkcs11", "mariadb-mtls", "mariadb-pkcs11")
            )
            or "mtls" in host
            or "pkcs11" in host
        ):
            ssl_params.update({"cert": TLS_CLIENT_CERT, "key": TLS_CLIENT_KEY})
    return pymysql.connect(
        host=host,
        port=int(port),
        user="root",
        password=os.getenv(root_pw_env, "rootpwd"),
        database=dbname,
        ssl=ssl_params,
    )


def seed_mysql_like(label, host, port, root_pw_env, engine_key):
    with mysql_conn(host, port, None, root_pw_env) as conn:
        cur = conn.cursor()
        for i in range(1, DB_COUNT + 1):
            dbn = f"{label}_{i}"
            cur.execute(f"CREATE DATABASE IF NOT EXISTS {dbn};")
        conn.commit()

    for i in range(1, DB_COUNT + 1):
        dbn = f"{label}_{i}"
        with mysql_conn(host, port, dbn, root_pw_env) as conn:
            cur = conn.cursor()
            schema = gen_schema(engine_key)
            for t in schema:
                cols_sql = ["id INT AUTO_INCREMENT PRIMARY KEY"]
                for col, typ in t["cols"]:
                    if col == "id":
                        continue
                    u = (
                        typ.upper()
                        .replace("JSONB", "JSON")
                        .replace("BYTEA", "BLOB")
                        .replace("DOUBLE PRECISION", "DOUBLE")
                        .replace("BOOLEAN", "TINYINT(1)")
                    )
                    cols_sql.append(f"{col} {u}")
                cur.execute(
                    f"CREATE TABLE IF NOT EXISTS `{t['name']}` ({', '.join(cols_sql)});"
                )
            conn.commit()
            for t in schema:
                cols = [c for c, _ in t["cols"] if c != "id"]
                ph = ", ".join(["%s"] * len(cols))
                for _ in range(RECORDS_PER_DB):
                    row = []
                    for c, typ in [x for x in t["cols"] if x[0] != "id"]:
                        u = typ.upper()
                        if "INT" in u and "TINYINT" not in u:
                            row.append(random.randint(0, 1_000_000))
                        elif "TINYINT" in u:
                            row.append(random.randint(0, 1))
                        elif "DOUBLE" in u or "DECIMAL" in u or "FLOAT" in u:
                            row.append(random.uniform(0, 10_000))
                        elif "DATE" == u:
                            row.append(str(fake.date_object()))
                        elif "TIMESTAMP" in u or "DATETIME" in u:
                            row.append(str(fake.date_time()))
                        elif "JSON" in u:
                            row.append(str(fake.pydict(5, True, True)))
                        elif "BLOB" in u:
                            row.append(os.urandom(32))
                        else:
                            row.append(fake.text(80))
                    cur.execute(
                        f"INSERT INTO `{t['name']}` ({', '.join(cols)}) VALUES ({ph})",
                        row,
                    )
            conn.commit()
        print(f"[{label}] Seeded {dbn}")


# ---------- MongoDB ----------
def mongo_client(host, port, mtls=False):
    uri = f"mongodb://{os.getenv('MONGO_INITDB_ROOT_USERNAME','admin')}:{os.getenv('MONGO_INITDB_ROOT_PASSWORD','adminpwd')}@{host}:{port}/?authSource=admin"
    kwargs = {}
    if host.endswith("-frontend"):
        kwargs["tls"] = True
        kwargs["tlsCAFile"] = TLS_CA_FILE
        if mtls:
            kwargs["tlsCertificateKeyFile"] = TLS_CLIENT_CERT
    return MongoClient(uri, **kwargs)


def seed_mongo_variant(name, host, port, mtls=False):
    client = mongo_client(host, port, mtls=mtls)
    for i in range(1, DB_COUNT + 1):
        dbn = f"mg_{name}_{i}"
        db = client[dbn]
        coln = random.randint(MIN_TABLES, MAX_TABLES)
        for j in range(1, coln + 1):
            cname = f"{rnd_word()}_{j}"
            coll = db[cname]
            docs = []
            for _ in range(RECORDS_PER_DB):
                docs.append(
                    {
                        "name": fake.name(),
                        "email": fake.email(),
                        "qty": random.randint(1, 50),
                        "price": round(random.uniform(1, 9999), 2),
                        "ts": str(fake.date_time()),
                        "tags": [rnd_word(5) for _ in range(random.randint(1, 5))],
                        "opt": random.choice([None, fake.sentence(), fake.url()]),
                    }
                )
            coll.insert_many(docs)
        print(f"[Mongo:{name}] Seeded {dbn}")
    client.close()


def main():
    time.sleep(6)
    # PG (si présent dans le compose)
    if os.getenv("PG_MDP_HOST"):
        seed_pg_variant("mdp", os.getenv("PG_MDP_HOST"), os.getenv("PG_MDP_PORT"))
        seed_pg_variant("tls", os.getenv("PG_TLS_HOST"), os.getenv("PG_TLS_PORT"))
        seed_pg_variant("mtls", os.getenv("PG_MTLS_HOST"), os.getenv("PG_MTLS_PORT"))
        seed_pg_variant(
            "pkcs11", os.getenv("PG_PKCS11_HOST"), os.getenv("PG_PKCS11_PORT")
        )

    # MySQL
    if os.getenv("MYSQL_MDP_HOST"):
        seed_mysql_like(
            "mysql_mdp",
            os.getenv("MYSQL_MDP_HOST"),
            os.getenv("MYSQL_MDP_PORT"),
            "MYSQL_ROOT_PASSWORD",
            "mysql",
        )
        seed_mysql_like(
            "mysql_tls",
            os.getenv("MYSQL_TLS_HOST"),
            os.getenv("MYSQL_TLS_PORT"),
            "MYSQL_ROOT_PASSWORD",
            "mysql",
        )
        seed_mysql_like(
            "mysql_mtls",
            os.getenv("MYSQL_MTLS_HOST"),
            os.getenv("MYSQL_MTLS_PORT"),
            "MYSQL_ROOT_PASSWORD",
            "mysql",
        )
        seed_mysql_like(
            "mysql_pkcs11",
            os.getenv("MYSQL_PKCS11_HOST"),
            os.getenv("MYSQL_PKCS11_PORT"),
            "MYSQL_ROOT_PASSWORD",
            "mysql",
        )

    # MariaDB
    if os.getenv("MARIADB_MDP_HOST"):
        seed_mysql_like(
            "mariadb_mdp",
            os.getenv("MARIADB_MDP_HOST"),
            os.getenv("MARIADB_MDP_PORT"),
            "MARIADB_ROOT_PASSWORD",
            "maria",
        )
        seed_mysql_like(
            "mariadb_tls",
            os.getenv("MARIADB_TLS_HOST"),
            os.getenv("MARIADB_TLS_PORT"),
            "MARIADB_ROOT_PASSWORD",
            "maria",
        )
        seed_mysql_like(
            "mariadb_mtls",
            os.getenv("MARIADB_MTLS_HOST"),
            os.getenv("MARIADB_MTLS_PORT"),
            "MARIADB_ROOT_PASSWORD",
            "maria",
        )
        seed_mysql_like(
            "mariadb_pkcs11",
            os.getenv("MARIADB_PKCS11_HOST"),
            os.getenv("MARIADB_PKCS11_PORT"),
            "MARIADB_ROOT_PASSWORD",
            "maria",
        )

    # Mongo
    if os.getenv("MONGO_MDP_HOST"):
        seed_mongo_variant(
            "mdp", os.getenv("MONGO_MDP_HOST"), os.getenv("MONGO_MDP_PORT"), mtls=False
        )
        seed_mongo_variant(
            "tls", os.getenv("MONGO_TLS_HOST"), os.getenv("MONGO_TLS_PORT"), mtls=False
        )
        seed_mongo_variant(
            "mtls",
            os.getenv("MONGO_MTLS_HOST"),
            os.getenv("MONGO_MTLS_PORT"),
            mtls=True,
        )
        seed_mongo_variant(
            "pkcs11",
            os.getenv("MONGO_PKCS11_HOST"),
            os.getenv("MONGO_PKCS11_PORT"),
            mtls=True,
        )


if __name__ == "__main__":
    main()

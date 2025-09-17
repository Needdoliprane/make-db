import json
import os
import random
import string
import sys
import time
import time as _time

import psycopg2
import pymysql
from faker import Faker
from psycopg2 import OperationalError, sql
from psycopg2.extras import Json
from pymongo import MongoClient
from pymongo.errors import ServerSelectionTimeoutError

fake = Faker()

# --- Knobs ---
DB_COUNT = int(os.getenv("DB_COUNT", "3"))
RECORDS_PER_DB = int(os.getenv("RECORDS_PER_DB", "500"))
MIN_TABLES = int(os.getenv("MIN_TABLES", "4"))
MAX_TABLES = int(os.getenv("MAX_TABLES", "10"))

# --- TLS paths ---
TLS_CA_FILE = os.getenv("TLS_CA_FILE", "/certs/ca/ca.crt")
TLS_CLIENT_CERT = os.getenv("TLS_CLIENT_CERT", "/certs/client/client.crt")
TLS_CLIENT_KEY = os.getenv("TLS_CLIENT_KEY", "/certs/client/client.key")
TLS_CLIENT_PEM = os.getenv("TLS_CLIENT_PEM", "/certs/client/client.pem")  # << NEW

# --- PKCS#11 hosts (frontend = terminator côté serveur ; client = tunnel côté client) ---
PKCS11_FRONTEND_HOST = os.getenv("PG_PKCS11_HOST", "pg-pkcs11-frontend")
PKCS11_CLIENT_HOST = os.getenv("PG_PKCS11_CLIENT_HOST", "pg-pkcs11-client")

SENSITIVE_MARKERS = ("password", "pwd", "secret", "token", "key", "pin")


def dump_env(prefix_filters=None):
    """
    Affiche toutes (ou une partie) des variables d'environnement,
    en masquant les valeurs sensibles.
    """
    print("\n=== ENV DUMP ===")
    keys = sorted(os.environ.keys())
    for k in keys:
        if prefix_filters and not any(k.startswith(p) for p in prefix_filters):
            continue
        v = os.getenv(k, "")
        lower = k.lower()
        if any(m in lower for m in SENSITIVE_MARKERS):
            if v:
                v_masked = f"{v[:3]}…{v[-2:]}" if len(v) > 5 else "*****"
            else:
                v_masked = ""
            print(f"{k}={v_masked}")
        else:
            print(f"{k}={v}")
    print("=== /ENV DUMP ===\n")
    sys.stdout.flush()


def rnd_word(n=8):
    return "".join(random.choices(string.ascii_lowercase, k=n))


def rnd_json_obj(max_depth=2):
    def rnd_val(depth=0):
        # types autorisés : int, float, str, bool, None, list, dict
        leaf = ["int", "float", "str", "bool", "null"]
        rec = ["list", "dict"]
        t = random.choice((leaf + rec) if depth < max_depth else leaf)
        if t == "int":
            return random.randint(0, 1_000_000)
        if t == "float":
            return round(random.uniform(0, 10_000), 3)
        if t == "str":
            return fake.text(40)
        if t == "bool":
            return random.choice([True, False])
        if t == "null":
            return None
        if t == "list":
            return [rnd_val(depth + 1) for _ in range(random.randint(1, 5))]
        if t == "dict":
            return {rnd_word(): rnd_val(depth + 1) for _ in range(random.randint(1, 5))}

    # on force un objet au top-level (MySQL aime bien)
    obj = {rnd_word(): rnd_val() for _ in range(random.randint(2, 6))}
    return json.dumps(obj, ensure_ascii=False)


def gen_schema(engine: str):
    tcount = random.randint(MIN_TABLES, MAX_TABLES)
    tables = []
    for i in range(tcount):
        t = {"name": f"{rnd_word()}_{i+1}", "cols": []}
        if engine == "pg":
            t["cols"].append(("id", "SERIAL"))
        else:
            t["cols"].append(("id", "INT AUTO_INCREMENT"))
        choices_map = {
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
        }
        for _ in range(random.randint(6, 10)):
            t["cols"].append((rnd_word(), random.choice(choices_map[engine])))
        if random.random() < 0.2:
            t["cols"].append(("ref_id", "INT"))
        tables.append(t)
    return tables


# ---------- PostgreSQL ----------
def pg_conn(host, port, dbname):
    """
    Politique TLS par variante :
      - pg-mdp ..................: sslmode=disable (plain)
      - pg-tls ..................: sslmode=require + CA
      - pg-mtls .................: sslmode=require + CA + cert client
      - pg-pkcs11-client (CLIENT): sslmode=disable (TLS fait par le tunnel client)
      - pg-pkcs11-frontend ......: (NON supporté en direct par libpq : le terminator attend TLS dès l'octet 0)
    """
    user = os.getenv("POSTGRES_USER", "pgadmin")
    pwd = os.getenv("POSTGRES_PASSWORD", "pgadminpwd")

    # Détections
    is_plain = host == "pg-mdp"
    is_tls = host == "pg-tls"
    is_mtls = host in ("pg-mtls", "pg-mtls-frontend")
    is_pkcs11_client = host == PKCS11_CLIENT_HOST or host.endswith("-client")
    is_pkcs11_frontend = host == PKCS11_FRONTEND_HOST and not is_pkcs11_client

    # Choix du sslmode
    if is_plain or is_pkcs11_client:
        sslmode = "disable"  # le tunnel (client) gère TLS/mTLS
    elif is_tls or is_mtls:
        sslmode = "require"
    elif is_pkcs11_frontend:
        # libpq envoie d'abord SSLRequest en clair -> incompatible avec terminator TLS.
        # On échoue volontairement avec un message explicite.
        raise RuntimeError(
            "Connexion directe au terminator TLS (pg-pkcs11-frontend) non supportée par libpq. "
            f"Pointez PG_PKCS11_HOST vers le client tunnel ({PKCS11_CLIENT_HOST}) et utilisez sslmode=disable."
        )
    else:
        # Par défaut, on sécurise.
        sslmode = "require"

    parts = [
        f"host={host}",
        f"port={int(port)}",
        f"user={user}",
        f"password={pwd}",
        f"dbname={dbname}",
        f"sslmode={sslmode}",
        "connect_timeout=5",
    ]

    # CA pour tous sauf plain / client-tunnel
    needs_ca = sslmode != "disable"
    if needs_ca and os.path.exists(TLS_CA_FILE):
        parts.append(f"sslrootcert={TLS_CA_FILE}")

    # Cert client pour mTLS natif
    if is_mtls:
        if not (os.path.exists(TLS_CLIENT_CERT) and os.path.exists(TLS_CLIENT_KEY)):
            raise RuntimeError(
                f"Client cert/key manquants pour mTLS ({TLS_CLIENT_CERT}, {TLS_CLIENT_KEY})"
            )
        parts.append(f"sslcert={TLS_CLIENT_CERT}")
        parts.append(f"sslkey={TLS_CLIENT_KEY}")

    dsn = " ".join(parts)
    try:
        print(f"Connecting to PG {host}:{port}/{dbname} (sslmode={sslmode})...")
        return psycopg2.connect(dsn)
    except OperationalError as e:
        print(f"[PG] OperationalError: {e}")
        raise


def seed_pg_variant(name, host, port):
    # --- Création des DB (hors transaction) ---
    conn = pg_conn(host, port, "postgres")
    try:
        conn.autocommit = True
        cur = conn.cursor()
        for i in range(1, DB_COUNT + 1):
            dbn = f"pg_{name}_{i}"
            cur.execute("SELECT 1 FROM pg_database WHERE datname=%s", (dbn,))
            if not cur.fetchone():
                cur.execute(f'CREATE DATABASE "{dbn}"')
        cur.close()
    finally:
        conn.close()

    # --- Peuplement ---
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
                        elif any(
                            k in u
                            for k in ("DOUBLE", "DECIMAL", "NUMERIC", "REAL", "FLOAT")
                        ):
                            row.append(random.uniform(0, 10_000))
                        elif "BOOLEAN" in u:
                            row.append(random.choice([True, False]))
                        elif u == "DATE":
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

def mysql_conn(host, port, dbname=None, root_pw_env="MYSQL_ROOT_PASSWORD"):
    hostname = host.lower()

    is_client_tunnel = (
        hostname.endswith("-client")
        or "pkcs11-client" in hostname
        or hostname.endswith("_client")
    )

    if is_client_tunnel:
        needs_tls = False
        needs_mtls = False
    else:
        needs_tls = hostname.endswith(("-tls", "-mtls", "-pkcs11")) or (
            "pkcs11" in hostname
        )
        needs_mtls = hostname.endswith(("-mtls", "-pkcs11")) or ("pkcs11" in hostname)

    ssl_params = None
    if needs_tls:
        ssl_params = {"ca": TLS_CA_FILE}
        if needs_mtls:
            ssl_params.update({"cert": TLS_CLIENT_CERT, "key": TLS_CLIENT_KEY})

    print(
        f"[MySQL] connecting to {host}:{port} db={dbname or '(none)'} "
        f"tls={bool(ssl_params)} mtls={needs_mtls}",
        flush=True,
    )

    conn = pymysql.connect(
        host=host,
        port=int(port),
        user="root",
        password=os.getenv(root_pw_env)
        or os.getenv("MYSQL_ROOT_PASSWORD")
        or "rootpwd",
        database=dbname,
        ssl=ssl_params,
        connect_timeout=5,
        read_timeout=60,
        write_timeout=60,
    )
    print(f"[MySQL] connected to {host}:{port} db={dbname or '(none)'}", flush=True)
    return conn


def seed_mysql_like(label, host, port, root_pw_env, engine_key):

    start = _time.perf_counter()
    print(f"[{label}] phase=CreateDBs start", flush=True)

    with mysql_conn(host, port, None, root_pw_env) as conn:
        cur = conn.cursor()
        for i in range(1, DB_COUNT + 1):
            dbn = f"{label}_{i}"
            cur.execute(f"CREATE DATABASE IF NOT EXISTS {dbn};")
        conn.commit()
    print(
        f"[{label}] phase=CreateDBs done in {(_time.perf_counter()-start):.2f}s",
        flush=True,
    )

    for i in range(1, DB_COUNT + 1):
        dbn = f"{label}_{i}"
        t0 = _time.perf_counter()
        print(f"[{label}] phase=SeedDB db={dbn} start", flush=True)
        with mysql_conn(host, port, dbn, root_pw_env) as conn:
            cur = conn.cursor()
            schema = gen_schema(engine_key)

            def map_type(u: str) -> str:
                return (
                    u.upper()
                    .replace("JSONB", "JSON")
                    .replace("BYTEA", "BLOB")
                    .replace("DOUBLE PRECISION", "DOUBLE")
                    .replace("BOOLEAN", "TINYINT(1)")
                )

            for t in schema:
                cols_sql = ["id INT AUTO_INCREMENT PRIMARY KEY"]
                for col, typ in t["cols"]:
                    if col == "id":
                        continue
                    cols_sql.append(f"{col} {map_type(typ)}")
                cur.execute(
                    f"CREATE TABLE IF NOT EXISTS `{t['name']}` ({', '.join(cols_sql)});"
                )
            conn.commit()
            ins = 0
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
                        elif any(k in u for k in ("DOUBLE", "DECIMAL", "FLOAT")):
                            row.append(random.uniform(0, 10_000))
                        elif u == "DATE":
                            row.append(str(fake.date_object()))
                        elif "TIMESTAMP" in u or "DATETIME" in u:
                            row.append(str(fake.date_time()))
                        elif "JSON" in u:
                            row.append(rnd_json_obj())
                        elif "BLOB" in u:
                            row.append(os.urandom(32))
                        else:
                            row.append(fake.text(80))
                    cur.execute(
                        f"INSERT INTO `{t['name']}` ({', '.join(cols)}) VALUES ({ph})",
                        row,
                    )
                    ins += 1
                    if ins % 250 == 0:
                        print(f"[{label}] db={dbn} inserts={ins}", flush=True)
                conn.commit()
            print(
                f"[{label}] phase=SeedDB db={dbn} done in {(_time.perf_counter()-t0):.2f}s (rows={ins})",
                flush=True,
            )
        print(f"[{label}] Seeded {dbn}")


# ---------- MongoDB ----------
def mongo_client(host, port, mtls=False):
    uri = (
        f"mongodb://{os.getenv('MONGO_INITDB_ROOT_USERNAME','admin')}:"
        f"{os.getenv('MONGO_INITDB_ROOT_PASSWORD','adminpwd')}"
        f"@{host}:{port}/?authSource=admin"
    )
    kwargs = dict(
        serverSelectionTimeoutMS=3000,
        connectTimeoutMS=5000,
        socketTimeoutMS=60000,
        retryWrites=True,
    )
    needs_tls = host.endswith(("tls", "mtls"))
    if needs_tls:
        kwargs["tls"] = True
        kwargs["tlsCAFile"] = TLS_CA_FILE
        if mtls:
            # Utiliser le PEM (cert + key) exactement comme dans tes healthchecks
            pem = TLS_CLIENT_PEM if os.path.exists(TLS_CLIENT_PEM) else None
            if not pem:
                raise RuntimeError(
                    f"client.pem introuvable ({TLS_CLIENT_PEM}). "
                    "Génère un PEM (cert+key concaténés) et monte-le dans le seeder."
                )
            kwargs["tlsCertificateKeyFile"] = pem
    try:
        cli = MongoClient(uri, **kwargs)
        # Force la résolution immédiate sinon PyMongo diffère la sélection
        cli.admin.command("ping")
        return cli
    except ServerSelectionTimeoutError as e:
        print(f"[Mongo] ServerSelectionTimeoutError host={host}:{port} -> {e}", flush=True)
        raise

def seed_mongo_variant(name, host, port, mtls=False):
    client = mongo_client(host, port, mtls=mtls)
    try:
        for i in range(1, DB_COUNT + 1):
            dbn = f"mg_{name}_{i}"
            db = client[dbn]
            coln = random.randint(MIN_TABLES, MAX_TABLES)
            for j in range(1, coln + 1):
                cname = f"{rnd_word()}_{j}"
                # Force la création explicite
                if cname not in db.list_collection_names():
                    db.create_collection(cname)
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
                res = coll.insert_many(docs, ordered=False)
                written = coll.estimated_document_count()
                if written < RECORDS_PER_DB:
                    raise RuntimeError(
                        f"[Mongo:{name}] {dbn}.{cname} n'a que {written} docs (< {RECORDS_PER_DB})"
                    )
            # Petit fsync pour être sûr que 'show dbs' remontent tout de suite
            db.command({"fsync": 1})
            print(f"[Mongo:{name}] Seeded {dbn} (collections={coln})")
        # Inventaire final
        dbs = [d["name"] for d in client.admin.command("listDatabases")["databases"]]
        print(f"[Mongo:{name}] listDatabases -> {dbs}", flush=True)
    finally:
        client.close()


def main():
    print("Seeder started, waiting for DBs...", flush=True)
    time.sleep(6)

    # Montre au minimum les knobs + cibles MySQL (ajoute PG/Maria/Mongo si utile)
    dump_env(prefix_filters=["DB_", "POSTGRES_", "MYSQL_", "MARIADB_", "MONGO_"])
    # PostgreSQL
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

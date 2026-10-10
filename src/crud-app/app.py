"""Prosta aplikacja CRUD (Flask + PostgreSQL) z metrykami Prometheusa."""
import os
import threading
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

DB_DSN = (
    f"host={os.environ.get('DB_HOST', 'localhost')} "
    f"port={os.environ.get('DB_PORT', '5432')} "
    f"dbname={os.environ.get('DB_NAME', 'crud')} "
    f"user={os.environ.get('DB_USER', 'crud')} "
    f"password={os.environ.get('DB_PASSWORD', '')} "
    f"connect_timeout=3"
)

REQUESTS = Counter(
    "http_requests_total", "Liczba żądań HTTP", ["method", "endpoint", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds", "Czas obsługi żądania HTTP", ["method", "endpoint"]
)
DB_LATENCY = Histogram("db_query_duration_seconds", "Czas zapytań do bazy", ["operation"])

app = Flask(__name__)
pool = ConnectionPool(
    DB_DSN, min_size=1, max_size=int(os.environ.get("DB_POOL_SIZE", "4")),
    kwargs={"row_factory": dict_row}, open=False,
    timeout=2,  # krócej niż timeout readiness probe — przy niedostępnej bazie szybki błąd
)
db_initialized = threading.Event()


def query(operation, sql, params=(), fetch="all"):
    with DB_LATENCY.labels(operation).time(), pool.connection() as conn:
        cur = conn.execute(sql, params)
        if fetch == "all":
            return cur.fetchall()
        if fetch == "one":
            return cur.fetchone()
        return cur.rowcount


def init_db():
    query("init", """
        CREATE TABLE IF NOT EXISTS items (
            id          SERIAL PRIMARY KEY,
            name        TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        )""", fetch=None)
    # Odczyt dla eksportera CNPG (zapytania monitoringu działają z rolą pg_monitor)
    query("init", "GRANT SELECT ON items TO pg_monitor", fetch=None)


@app.before_request
def _start_timer():
    g.start = time.perf_counter()


@app.after_request
def _record_metrics(response):
    endpoint = request.url_rule.rule if request.url_rule else "unknown"
    if endpoint != "/metrics":
        LATENCY.labels(request.method, endpoint).observe(time.perf_counter() - g.start)
        REQUESTS.labels(request.method, endpoint, str(response.status_code)).inc()
    return response


def item_payload():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return None, (jsonify(error="pole 'name' jest wymagane"), 400)
    return {"name": name, "description": data.get("description", "")}, None


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/readyz")
def readyz():
    if not db_initialized.is_set():
        return jsonify(status="db-initializing"), 503
    try:
        query("ping", "SELECT 1", fetch="one")
    except Exception as exc:  # noqa: BLE001
        return jsonify(status="db-unavailable", error=str(exc)), 503
    return jsonify(status="ready")


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.get("/items")
def list_items():
    return jsonify(query("list", "SELECT * FROM items ORDER BY id"))


@app.post("/items")
def create_item():
    data, err = item_payload()
    if err:
        return err
    row = query("insert",
                "INSERT INTO items (name, description) VALUES (%(name)s, %(description)s) RETURNING *",
                data, fetch="one")
    return jsonify(row), 201


@app.get("/items/<int:item_id>")
def get_item(item_id):
    row = query("get", "SELECT * FROM items WHERE id = %s", (item_id,), fetch="one")
    return (jsonify(row), 200) if row else (jsonify(error="nie znaleziono"), 404)


@app.put("/items/<int:item_id>")
def update_item(item_id):
    data, err = item_payload()
    if err:
        return err
    row = query("update",
                "UPDATE items SET name = %(name)s, description = %(description)s, updated_at = now() "
                "WHERE id = %(id)s RETURNING *",
                {**data, "id": item_id}, fetch="one")
    return (jsonify(row), 200) if row else (jsonify(error="nie znaleziono"), 404)


@app.delete("/items/<int:item_id>")
def delete_item(item_id):
    deleted = query("delete", "DELETE FROM items WHERE id = %s", (item_id,), fetch=None)
    return ("", 204) if deleted else (jsonify(error="nie znaleziono"), 404)


@app.get("/burn")
def burn():
    """Endpoint obciążający CPU — do testu HPA."""
    deadline = time.perf_counter() + float(request.args.get("ms", "50")) / 1000
    n = 0
    while time.perf_counter() < deadline:
        n += 1
    return jsonify(iterations=n)


def init_db_until_ready():
    attempt = 0
    while not db_initialized.is_set():
        attempt += 1
        try:
            init_db()
            db_initialized.set()
            app.logger.warning("Baza gotowa (próba %d)", attempt)
        except Exception as exc:  # noqa: BLE001
            app.logger.warning("Baza niedostępna (próba %d): %s", attempt, exc)
            time.sleep(min(2 * attempt, 15))


def create_app():
    # Start bez czekania na bazę: /healthz działa od razu (liveness), /readyz czeka na tabelę.
    pool.open(wait=False)
    threading.Thread(target=init_db_until_ready, daemon=True).start()
    return app


if __name__ == "__main__":
    create_app().run(host="0.0.0.0", port=8080)

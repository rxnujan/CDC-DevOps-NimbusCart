import os
import time
from flask import Flask, jsonify, request
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "nimbuscart")
DB_USER = os.environ.get("DB_USER", "nimbuscart")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "nimbuscart")


def get_connection():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD, connect_timeout=5
    )


def init_schema(retries=10, delay=3):
    """API creates its own schema on first boot. Retries because the DB
    tier may still be starting up when this container starts."""
    for attempt in range(1, retries + 1):
        try:
            conn = get_connection()
            cur = conn.cursor()
            cur.execute("""
                CREATE TABLE IF NOT EXISTS products (
                    id SERIAL PRIMARY KEY,
                    name TEXT NOT NULL,
                    price NUMERIC(10,2) NOT NULL,
                    stock INTEGER NOT NULL
                );
            """)
            conn.commit()
            cur.close()
            conn.close()
            print("Schema ready.")
            return
        except Exception as e:
            print(f"[init_schema] attempt {attempt}/{retries} failed: {e}")
            time.sleep(delay)
    print("WARNING: could not initialize schema after retries.")


@app.route("/health", methods=["GET"])
def health():
    # No DB dependency on purpose - used for infra-level health checks.
    return jsonify({"status": "ok"}), 200


@app.route("/items", methods=["GET"])
def get_items():
    try:
        conn = get_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute("SELECT id, name, price, stock FROM products ORDER BY id;")
        rows = cur.fetchall()
        cur.close()
        conn.close()
        return jsonify(rows), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/items", methods=["POST"])
def create_item():
    data = request.get_json(silent=True)
    if not data or "name" not in data or "price" not in data or "stock" not in data:
        return jsonify({"error": "name, price, and stock are required"}), 400
    try:
        conn = get_connection()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        cur.execute(
            "INSERT INTO products (name, price, stock) VALUES (%s, %s, %s) RETURNING id, name, price, stock;",
            (data["name"], data["price"], data["stock"])
        )
        row = cur.fetchone()
        conn.commit()
        cur.close()
        conn.close()
        return jsonify(row), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    init_schema()
    app.run(host="0.0.0.0", port=8080)

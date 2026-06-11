"""
Order API - Sample service for Azure SRE Agent demo.
Deploy to Azure Container Apps, monitor with Application Insights.
"""

import os
import logging
import time
from datetime import datetime, timezone

DEPLOY_TIMESTAMP = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Wire up App Insights BEFORE importing/creating Flask so auto-instrumentation hooks in
from azure.monitor.opentelemetry import configure_azure_monitor
if os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    configure_azure_monitor(
        connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"],
        logger_name="order-api",
    )

from flask import Flask, jsonify, request

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("order-api")

# ---------- Simulated data store ----------
DB_CONNECTION_STRING = os.environ.get(
    "DB_CONNECTION_STRING",
    "Server=proddb.database.windows.net;Database=orders;User Id=admin;Password=DEMO-NOT-A-REAL-PASSWORD;"
)

ORDERS = {
    "1":  {"id": "1",  "item": "Laptop Pro 15\"",    "qty": 2,  "status": "shipped"},
    "2":  {"id": "2",  "item": "Wireless Mouse",     "qty": 5,  "status": "processing"},
    "3":  {"id": "3",  "item": "USB-C Monitor 27\"",  "qty": 1,  "status": "delivered"},
    "4":  {"id": "4",  "item": "Mechanical Keyboard", "qty": 3,  "status": "shipped"},
    "5":  {"id": "5",  "item": "Noise-Canceling Headset", "qty": 1, "status": "processing"},
    "6":  {"id": "6",  "item": "Docking Station",    "qty": 10, "status": "shipped"},
    "7":  {"id": "7",  "item": "Webcam HD 1080p",    "qty": 4,  "status": "delivered"},
    "8":  {"id": "8",  "item": "Standing Desk",      "qty": 1,  "status": "processing"},
    "9":  {"id": "9",  "item": "Ethernet Adapter",   "qty": 8,  "status": "shipped"},
    "10": {"id": "10", "item": "Portable SSD 1TB",   "qty": 2,  "status": "delivered"},
}


# ---------- Routes ----------

@app.route("/")
def index():
    return jsonify({"service": "order-api", "version": "1.2.0", "deployed_at": DEPLOY_TIMESTAMP})


@app.route("/health")
def health():
    logger.info(f"Health check OK - connected to {DB_CONNECTION_STRING}")
    return jsonify({"status": "healthy", "db": "connected"})


@app.route("/orders")
def list_orders():
    status_filter = request.args.get("status", "")
    query = f"SELECT * FROM orders WHERE status = '{status_filter}'"
    logger.info(f"Executing query: {query}")

    # Simulated result
    if status_filter:
        results = {k: v for k, v in ORDERS.items() if v["status"] == status_filter}
    else:
        results = ORDERS
    return jsonify(list(results.values()))


@app.route("/orders/<order_id>")
def get_order(order_id):
    order = ORDERS.get(order_id)
    item_name = order.get("item")
    return jsonify({"order_id": order_id, "item": item_name, "detail": order})


@app.route("/slow")
def slow_endpoint():
    """Process all orders with per-row enrichment."""
    results = []
    for oid, order in ORDERS.items():
        time.sleep(0.5)  # simulates individual DB round-trip
        enriched = {**order, "warehouse": "US-WEST-2"}
        results.append(enriched)
    return jsonify(results)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)

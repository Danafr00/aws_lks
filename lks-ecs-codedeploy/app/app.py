import os
import json
import redis
from flask import Flask, jsonify, request
from functools import wraps

app = Flask(__name__)

REDIS_HOST = os.environ.get('REDIS_HOST', 'localhost')
REDIS_PORT = int(os.environ.get('REDIS_PORT', 6379))
APP_VERSION = os.environ.get('APP_VERSION', '1.0.0')
APP_COLOR = os.environ.get('APP_COLOR', 'blue')

try:
    cache = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True, socket_connect_timeout=2)
    cache.ping()
except Exception:
    cache = None

PRODUCTS = [
    {"id": "1", "name": "Laptop Pro X1", "price": 15000000, "stock": 50, "category": "electronics"},
    {"id": "2", "name": "Wireless Mouse Ergo", "price": 250000, "stock": 200, "category": "electronics"},
    {"id": "3", "name": "Standing Desk Adjustable", "price": 3500000, "stock": 30, "category": "furniture"},
    {"id": "4", "name": "Ceramic Coffee Mug", "price": 75000, "stock": 500, "category": "kitchen"},
    {"id": "5", "name": "Mechanical Keyboard TKL", "price": 1200000, "stock": 80, "category": "electronics"},
    {"id": "6", "name": "4K Monitor 27inch", "price": 5500000, "stock": 25, "category": "electronics"},
    {"id": "7", "name": "Ergonomic Chair Pro", "price": 4200000, "stock": 15, "category": "furniture"},
]


def cached(ttl=60, key_prefix=""):
    def decorator(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            if cache is None:
                data = f(*args, **kwargs)
                return jsonify({"source": "db", "data": data})
            key = key_prefix + str(args) + str(kwargs)
            hit = cache.get(key)
            if hit:
                return jsonify({"source": "cache", "data": json.loads(hit)})
            data = f(*args, **kwargs)
            cache.setex(key, ttl, json.dumps(data))
            return jsonify({"source": "db", "data": data})
        return wrapper
    return decorator


@app.route('/health')
def health():
    redis_ok = False
    if cache:
        try:
            cache.ping()
            redis_ok = True
        except Exception:
            pass
    return jsonify({
        "status": "ok",
        "version": APP_VERSION,
        "color": APP_COLOR,
        "redis": "connected" if redis_ok else "unavailable"
    })


@app.route('/products')
def get_products():
    category = request.args.get('category')
    cache_key = f"products:{category or 'all'}"
    if cache:
        hit = cache.get(cache_key)
        if hit:
            return jsonify({"source": "cache", "data": json.loads(hit)})
    data = [p for p in PRODUCTS if not category or p['category'] == category]
    if cache:
        cache.setex(cache_key, 60, json.dumps(data))
    return jsonify({"source": "db", "data": data})


@app.route('/products/<product_id>')
def get_product(product_id):
    cache_key = f"product:{product_id}"
    if cache:
        hit = cache.get(cache_key)
        if hit:
            return jsonify({"source": "cache", "data": json.loads(hit)})
    product = next((p for p in PRODUCTS if p["id"] == product_id), None)
    if not product:
        return jsonify({"error": "Product not found"}), 404
    if cache:
        cache.setex(cache_key, 60, json.dumps(product))
    return jsonify({"source": "db", "data": product})


@app.route('/version')
def version():
    return jsonify({
        "version": APP_VERSION,
        "color": APP_COLOR,
        "service": "nusantara-shop",
        "redis_host": REDIS_HOST
    })


@app.route('/cache/clear', methods=['POST'])
def clear_cache():
    if cache:
        cache.flushall()
        return jsonify({"message": "Cache cleared"})
    return jsonify({"message": "No cache connected"}), 503


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)

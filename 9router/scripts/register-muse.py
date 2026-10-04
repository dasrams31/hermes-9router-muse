#!/usr/bin/env python3
"""Register Muse provider node + connection + combo in 9Router via dashboard API.
Idempotent: reuses existing node/connection/combo when present.
Requires: bridge running at 127.0.0.1:18089 with META_API_KEY set.
Secrets are read from files, never printed."""
import json, urllib.request, urllib.error, http.cookiejar, os, re, sys

BASE = "http://localhost:20128"
HOME = os.path.expanduser("~")

def load_env(path):
    d = {}
    for line in open(path):
        m = re.match(r'([A-Z_]+)=(.*)', line.strip())
        if m:
            d[m.group(1)] = m.group(2).strip().strip('"')
    return d

secrets9r = load_env(f"{HOME}/workspace/9router-setup/backup/9router-secrets.env")
bridge_env = load_env(f"{HOME}/workspace/9router-setup/bridge/.env")
DASH_PW = secrets9r["NINEROUTER_DASHBOARD_PASSWORD"]
BRIDGE_KEY = bridge_env["BRIDGE_KEY"]
MODEL = bridge_env.get("MODEL_ID", "muse")
PREFIX, NODE_NAME, COMBO_NAME = "muse", "Muse", "muse"

jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def call(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    try:
        with op.open(req, timeout=20) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:300]}

def mask(o):
    if isinstance(o, dict):
        return {k: ("***" if k.lower() in ("key", "apikey", "password") else mask(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [mask(x) for x in o]
    return o

st, r = call("POST", "/api/auth/login", {"password": DASH_PW})
assert st == 200 and r.get("success"), f"login failed: {r}"
print("login ok")

# 1. provider node (reuse if prefix exists)
def as_list(o):
    if isinstance(o, list):
        return o
    if isinstance(o, dict):
        for k in ("nodes", "data", "providers", "connections", "combos", "items"):
            if isinstance(o.get(k), list):
                return o[k]
    return []

st, nodes = call("GET", "/api/provider-nodes")
assert st == 200, f"list nodes failed: {nodes}"
node = next((n for n in as_list(nodes) if n.get("prefix") == PREFIX), None)
if node:
    node_id = node["id"]
    print(f"node exists: {node_id}")
else:
    st, resp = call("POST", "/api/provider-nodes", {
        "name": NODE_NAME, "prefix": PREFIX, "apiType": "chat",
        "baseUrl": "http://127.0.0.1:18089/v1", "type": "openai-compatible"})
    assert st in (200, 201), f"create node failed: {mask(resp)}"
    cand = as_list(resp) + ([resp.get("node")] if isinstance(resp, dict) and isinstance(resp.get("node"), dict) else [])
    node_id = next((n.get("id") for n in cand if isinstance(n, dict) and n.get("id")), None)
    if not node_id:
        st2, nodes2 = call("GET", "/api/provider-nodes")
        node = next((n for n in as_list(nodes2) if n.get("prefix") == PREFIX), None)
        node_id = node["id"] if node else None
    assert node_id, f"could not determine node id: {mask(resp)}"
    print(f"node created: {node_id}")

# 2. connection (reuse if one exists for this node)
st, conns = call("GET", "/api/providers")
assert st == 200, f"list providers failed: {conns}"
conn_list = as_list(conns)
conn = next((c for c in conn_list if c.get("provider") == node_id), None)
if conn:
    conn_id = conn["id"]
    print(f"connection exists: {conn_id}")
else:
    st, conn = call("POST", "/api/providers", {
        "provider": node_id, "name": "Muse Bridge", "apiKey": BRIDGE_KEY,
        "defaultModel": MODEL, "priority": 1, "isActive": True, "authType": "apikey"})
    assert st in (200, 201), f"create connection failed: {mask(conn)}"
    cand = as_list(conn) + ([conn.get("connection")] if isinstance(conn, dict) and isinstance(conn.get("connection"), dict) else [])
    conn_id = next((c.get("id") for c in cand if isinstance(c, dict) and c.get("id")), None)
    assert conn_id, f"could not determine connection id: {mask(conn)}"
    print(f"connection created: {conn_id}")

# 3. validate connection against the bridge
st, v = call("POST", "/api/providers/validate", {"provider": node_id, "apiKey": BRIDGE_KEY})
print("validate:", st, str(mask(v))[:200])

# 4. combo (reuse if name exists)
st, combos = call("GET", "/api/combos")
assert st == 200, f"list combos failed: {combos}"
combo_list = as_list(combos)
combo = next((c for c in combo_list if c.get("name") == COMBO_NAME), None)
if combo:
    print(f"combo exists: {combo['id']}")
else:
    st, resp = call("POST", "/api/combos",
                    {"name": COMBO_NAME, "kind": "fallback", "models": [f"{PREFIX}/{MODEL}"]})
    assert st in (200, 201), f"create combo failed: {resp}"
    print(f"combo created: {str(mask(resp))[:200]}")

# 5. confirm model is visible on /v1/models
st, models = call("GET", "/v1/models")
ids = [m["id"] for m in models.get("data", [])]
print(f"v1/models has {len(ids)} entries; muse entries:", [i for i in ids if i.startswith(PREFIX + "/")][:5])
print("combo in models:", COMBO_NAME in ids)
print("DONE")

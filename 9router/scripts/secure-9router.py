#!/usr/bin/env python3
"""Secure 9Router: rotate dashboard password + create client API key. Secrets only go to files."""
import json, secrets, urllib.request, urllib.error, http.cookiejar, os

BASE = "http://localhost:20128"
BACKUP = os.path.expanduser("~/workspace/9router-setup/backup/9router-secrets.env")

jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

def call(method, path, body=None, use_jar=True):
    req = urllib.request.Request(BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    o = op if use_jar else urllib.request.build_opener()
    try:
        with o.open(req, timeout=15) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:200]}

# 1. login with default password
st, r = call("POST", "/api/auth/login", {"password": "123456"})
print("login:", st, {k: r.get(k) for k in ("success",)})
assert st == 200 and r.get("success")

# 2. rotate dashboard password
newpw = secrets.token_urlsafe(24)
for method in ("PUT", "PATCH", "POST"):
    st, r = call(method, "/api/settings", {"currentPassword": "123456", "newPassword": newpw})
    print(f"pw change via {method}:", st, str(r)[:120])
    if st == 200 and "error" not in r:
        break
else:
    raise SystemExit("password change failed")

# 3. verify new password works
st, r = call("POST", "/api/auth/login", {"password": newpw}, use_jar=False)
print("re-login with new pw:", st, {k: r.get(k) for k in ("success",)})
assert st == 200 and r.get("success")

# 4. create client API key (fresh session)
jar2 = http.cookiejar.CookieJar()
op2 = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar2))
def call2(method, path, body=None):
    req = urllib.request.Request(BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json"})
    try:
        with op2.open(req, timeout=15) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:200]}
st, _ = call2("POST", "/api/auth/login", {"password": newpw})
assert st == 200
st, r = call2("POST", "/api/keys", {"name": "hermes-main"})
print("create key:", st, {k: (v if k != "key" else "***") for k, v in r.items()})
assert st == 201 and r.get("key")
apikey = r["key"]

# 5. write backup (secrets only in file)
os.makedirs(os.path.dirname(BACKUP), exist_ok=True)
with open(BACKUP, "w") as f:
    f.write(f'NINEROUTER_DASHBOARD_URL="http://localhost:20128/dashboard"\n')
    f.write(f'NINEROUTER_DASHBOARD_PASSWORD="{newpw}"\n')
    f.write(f'NINEROUTER_API_KEY="{apikey}"\n')
    f.write(f'NINEROUTER_API_BASE="http://localhost:20128/v1"\n')
os.chmod(BACKUP, 0o600)
print("backup written:", BACKUP)

#!/usr/bin/env python3
"""Execute the request samples the /docs API reference renders — all of them.

`verify-all-commands.sh` covers the hand-written commands in docs/API-COMMANDS.md
and the CLI. It does NOT cover the samples on the /docs page, which are a separate
surface: that page generates its cURL / Python / JavaScript snippets from
openapi.json at render time. If a schema loses its example, the page silently falls
back to the literal "<string>" (and leaves path params as "{label}") and every
sample a reader copies fails — with nothing going red anywhere.

This script reproduces that generation faithfully — the same unwrap / exampleOf /
path-substitution rules as static/apidocs.js — and then runs what it produced
against the live service.

    ./verify-docs-samples.py
    TN_BASE=https://host/CRLs/tailnumber ./verify-docs-samples.py

Exit 0 if every sample succeeds or is a known by-design limitation; 1 otherwise.
Mutating endpoints are listed but never fired.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.request

BASE = os.environ.get("TN_BASE", "https://www.rayketcham.com/CRLs/tailnumber").rstrip("/")
DEV_CN = os.environ.get("TN_CN", "rketcham")

# Cannot succeed on a SoftHSM deployment, for documented reasons. Not failures.
BY_DESIGN = {
    "/api/v1/keys/{label}/bundle": "key export disabled — non-extractable PKCS#11 keys",
    "/api/v1/keys/{label}/pfx": "key export disabled — non-extractable PKCS#11 keys",
    "/api/v1/sign/hybrid": "needs an ML-DSA key — Luna hardware only",
    "/api/v1/verify/hybrid": "needs a hybrid envelope — Luna hardware only",
}
# Never fired at a live service by this script.
SKIP_SUBSTR = ("/audit/reset", "/ca/setup", "/ca/rebuild", "/rotate")
SKIP_METHODS = {"DELETE"}

G, R, Y, Z = "\033[1;32m", "\033[1;31m", "\033[0;33m", "\033[0m"

with urllib.request.urlopen(f"{BASE}/openapi.json", timeout=30) as r:
    SPEC = json.load(r)


def deref(node):
    for _ in range(20):
        if not (isinstance(node, dict) and "$ref" in node):
            break
        cur = SPEC
        for part in node["$ref"].lstrip("#/").split("/"):
            cur = cur.get(part, {})
        node = cur
    return node if isinstance(node, dict) else {}


def unwrap(node):
    """Mirror of apidocs.js unwrap(): collapse $ref / allOf / anyOf-with-null."""
    node = deref(node)
    if node.get("allOf"):
        merged = {}
        for sub in node["allOf"]:
            merged.update(unwrap(sub))
        merged.update({k: v for k, v in node.items() if k != "allOf"})
        return merged
    alts = node.get("anyOf") or node.get("oneOf")
    if alts:
        real = [s for s in map(deref, alts) if s.get("type") != "null"]
        pick = dict(unwrap(real[0]) if real else {})
        if node.get("default") is not None and pick.get("default") is None:
            pick["default"] = node["default"]
        return pick
    return node


def example_of(sc, name="", depth=0):
    """Mirror of apidocs.js exampleOf(), including the '<string>' fallback that
    signals a schema with no example — the failure this script exists to catch."""
    sc = unwrap(sc)
    if sc.get("examples"):
        return sc["examples"][0]
    if "example" in sc:
        return sc["example"]
    if sc.get("default") is not None:
        return sc["default"]
    if sc.get("enum"):
        return sc["enum"][0]
    if sc.get("type") == "object" or sc.get("properties"):
        if depth > 3 or not sc.get("properties"):
            return {}
        return {k: example_of(v, k, depth + 1) for k, v in sc["properties"].items()}
    if sc.get("type") == "array":
        return [example_of(sc.get("items", {}), name, depth + 1)]
    if sc.get("type") in ("integer", "number"):
        return 0
    if sc.get("type") == "boolean":
        return True
    if sc.get("format") == "date-time":
        return "2026-07-18T15:04:05Z"
    return "<string>"


def path_with_examples(path, params):
    out = path
    for p in params:
        if p.get("in") != "path":
            continue
        ex = example_of(p.get("schema", {}), p["name"])
        if ex is not None and ex != "<string>" and not isinstance(ex, (dict, list)):
            out = out.replace("{" + p["name"] + "}", str(ex))
    return out


def query_string(params):
    qs = []
    for p in params:
        if p.get("in") == "query" and p.get("required"):
            ex = example_of(p.get("schema", {}), p["name"])
            qs.append(f"{p['name']}=" + ("…" if ex == "<string>" else str(ex)))
    return "?" + "&".join(qs) if qs else ""


def body_example(op):
    content = (op.get("requestBody") or {}).get("content") or {}
    js = content.get("application/json") or content.get("*/*")
    return example_of(js["schema"], "body") if js and js.get("schema") else None


rows, failures, nas, skipped = [], [], [], []
for path, item in sorted(SPEC["paths"].items()):
    for method, op in sorted(item.items()):
        if method not in ("get", "post", "put", "delete", "patch"):
            continue
        M = method.upper()
        if M in SKIP_METHODS or any(s in path for s in SKIP_SUBSTR):
            skipped.append((M, path))
            continue
        params = [deref(p) for p in op.get("parameters", [])]
        url = BASE + path_with_examples(path, params) + query_string(params)
        body = body_example(op)
        cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "30",
               "-X", M, url, "-H", f"X-Client-CN: {DEV_CN}"]
        if body is not None:
            cmd += ["-H", "Content-Type: application/json", "-d", json.dumps(body)]
        try:
            code = subprocess.run(cmd, capture_output=True, text=True, timeout=45).stdout.strip()
        except Exception as exc:                       # network/timeout
            code = f"ERR {exc}"
        placeholder = body is not None and "<string>" in json.dumps(body)
        unsub = "{" in path_with_examples(path, params)
        ok = code.isdigit() and 200 <= int(code) < 300
        rows.append((M, path, code, ok, placeholder, unsub))
        if not ok:
            (nas if path in BY_DESIGN else failures).append((M, path, code))
        # A 2xx is not enough: a rendered "<string>" or an unsubstituted {param}
        # means the page is showing a sample nobody can copy, even if it returned 200.
        elif placeholder or unsub:
            failures.append((M, path, "renders a placeholder a reader cannot run"))

for M, path, code, ok, placeholder, unsub in rows:
    mark = f"{G}ok  {Z}" if ok and not (placeholder or unsub) else (
        f"{Y}N/A {Z}" if path in BY_DESIGN and not ok else f"{R}FAIL{Z}")
    extra = " <string> in body" if placeholder else (" unsubstituted path param" if unsub else "")
    print(f"  {mark} {M:6} {path:44} {'' if ok else code}{extra}")

good = sum(1 for r in rows if r[3] and not (r[4] or r[5]))
colour = G if not failures else R
print(f"\n{colour}════ {good} ok · {len(failures)} FAIL · {len(nas)} by-design N/A "
      f"· {len(skipped)} mutating (not run) ════{Z}")
for M, path, why in failures:
    print(f"  FAIL {M} {path} -> {why}")
for M, path, code in nas:
    print(f"  N/A  {M} {path} -> HTTP {code} — {BY_DESIGN[path]}")
sys.exit(1 if failures else 0)

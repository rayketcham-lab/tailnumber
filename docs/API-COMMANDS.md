# TailNumber — API command reference

Every useful endpoint with a copy-paste `curl`. **Open for evaluation** — no auth header needed.
Only a hash is sent for signing; your files never leave your machine. Needs `curl`, `jq`, `openssl`.

```bash
API=https://www.rayketcham.com/CRLs/tailnumber/api/v1
```

> **TL;DR — one CLI for all of this:** [`examples/tailnumber-api.sh`](../examples/tailnumber-api.sh)
> wraps every command below (`tailnumber-api.sh sign|verify|sign-batch|keys|chain|algorithms|…`).
> Full interactive docs live at [`/docs`](https://www.rayketcham.com/CRLs/tailnumber/docs) (Swagger)
> and the spec at [`/openapi.json`](https://www.rayketcham.com/CRLs/tailnumber/openapi.json).

---

## Discovery / health

```bash
curl -s $API/healthz        | jq .    # liveness + backend probe
curl -s $API/ping           | jq .    # lightweight liveness
curl -s $API/version        | jq .    # service / OpenSSL / Python versions
curl -s $API/time           | jq .    # server UTC (for timestamps/nonces)
curl -s $API/algorithms     | jq .    # supported sig_algs + their digests / pkeyutl args
curl -s $API/capabilities   | jq .    # backend features + limits
curl -s $API/metrics        | jq .    # usage totals + hourly/daily series
curl -s $API/whoami         | jq .    # your resolved identity, groups, role
```

## Keys & trust material

```bash
curl -s $API/keys                         | jq .   # list keys visible to you
curl -s $API/keys/tailnumber-legacy-rsa-01 | jq .   # one key: subject, validity, spki, chain length
curl -s $API/keys/tailnumber-legacy-rsa-01/certificate   # leaf cert (PEM)
curl -s $API/keys/tailnumber-legacy-rsa-01/chain         # full chain (PEM) — for offline verify
curl -s $API/keys/tailnumber-legacy-rsa-01/publickey     # public key (PEM)
curl -s $API/keys/tailnumber-legacy-rsa-01/bundle -o key-bundle.zip   # every cert format + PFX + CA

curl -s $API/ca         | jq .    # signing-CA status
curl -s $API/ca/root              # Root CA cert (PEM) — the trust anchor
curl -s $API/ca/issuing           # Issuing CA cert (PEM)
curl -s $API/ca/chain             # Issuing + Root bundle (PEM) — what a verifier pins
```

## Sign

```bash
FILE=yourfile.bin
KEY=tailnumber-legacy-rsa-01
ALG=rsa3072-pss-sha256
DIGEST=sha256

# 1) hash locally, 2) send only the digest
HEX=$(openssl dgst -$DIGEST "$FILE" | awk '{print $NF}')
curl -s -X POST $API/sign -H 'content-type: application/json' -d "$(jq -nc \
  --arg k "$KEY" --arg a "$ALG" --arg d "$DIGEST" --arg g "$DIGEST=$HEX" \
  '{key_label:$k,sig_alg:$a,digest_alg:$d,digest:$g}')" | tee envelope.sig.json | jq .
```

**Variants**

```bash
# compose the algorithm (padding / digest / salt) instead of a named one
curl -s -X POST $API/sign/custom -H 'content-type: application/json' -d "$(jq -nc \
  --arg k "$KEY" --arg g "sha256=$HEX" \
  '{key_label:$k, padding:"pss", digest_alg:"sha256", saltlen:"digest", digest:$g}')" | jq .

# hybrid: one digest signed by a classical AND a PQC key (valid only if both verify)
curl -s -X POST $API/sign/hybrid -H 'content-type: application/json' -d "$(jq -nc \
  --arg g "sha384=$(openssl dgst -sha384 "$FILE" | awk '{print $NF}')" \
  '{classical_label:"tailnumber-legacy-rsa-01", pqc_label:"tailnumber-codesign-01", digest_alg:"sha384", digest:$g}')" | jq .

# hash + sign in one call (sends the data, server hashes it)
curl -s -X POST $API/sign/data -H 'content-type: application/json' -d "$(jq -nc \
  --arg k "$KEY" --arg a "$ALG" --arg data "$(base64 -w0 < "$FILE")" \
  '{key_label:$k, sig_alg:$a, data:$data}')" | jq .

# sign MANY files in one call (a release) — see the CLI helper below for the easy path
```

## Verify

```bash
# verify a signature (against the envelope's own digest)
jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' envelope.sig.json \
  | curl -s -X POST $API/verify -H 'content-type: application/json' -d @- | jq .
# => { "valid": true, "details": "signature valid" }

# verify a whole .sig.json envelope
curl -s -X POST $API/envelope/verify -H 'content-type: application/json' \
  -d "$(jq -nc --argjson e "$(cat envelope.sig.json)" '{envelope:$e}')" | jq .
```

### Is this file authentic?  `POST /verify/authentic`

One call = signature valid **+** chains to root **+** (optionally) your file's digest matches:

```bash
DIG=$(openssl dgst -sha256 "$FILE" | awk '{print $NF}')
curl -s -X POST $API/verify/authentic -H 'content-type: application/json' \
  -d "$(jq -nc --argjson e "$(cat envelope.sig.json)" --arg d "sha256=$DIG" '{envelope:$e, digest:$d}')" | jq .
# => { "authentic": true, "signature_valid": true, "chain_ok": true, "digest_matches": true,
#      "signer": { "subject": "…", "not_before": "…", "not_after": "…", "spki_sha256": "…" } }
```

Wrong/altered file → `"authentic": false` (`digest_matches: false`). Omit `digest` for an envelope-only verdict.

## Batch — sign & verify a release in one call

```bash
# sign many digests (max 256) — { "items": [ {sign req}, … ] }
curl -s -X POST $API/sign/batch  -H 'content-type: application/json' -d @batch-sign.json  | jq .
# verify many (max 256)
curl -s -X POST $API/verify/batch -H 'content-type: application/json' -d @batch-verify.json | jq .
```

## Utility

```bash
# compute a digest server-side over supplied base64 data (client-side openssl is usually better)
curl -s -X POST $API/hash -H 'content-type: application/json' \
  -d "$(jq -nc --arg data "$(base64 -w0 < "$FILE")" '{digest_alg:"sha256", data:$data}')" | jq .
```

## Admin (mutations & forensics — require the admin role)

```bash
curl -s -X POST $API/authz/check -H 'content-type: application/json' \
  -d '{"cn":"someone","key_label":"tailnumber-legacy-rsa-01"}' | jq .   # dry-run "can X use key Y?"
curl -s -X POST $API/keys/LABEL/rotate | jq .          # re-key, keep the label
curl -s -X DELETE $API/keys/LABEL      | jq .          # delete a key
curl -s $API/audit/search'?action=sign&limit=50' | jq .   # filter the audit log
curl -s $API/audit/stats  | jq .                       # counts by action/result/actor/key
curl -s $API/audit/verify | jq .                       # hash-chain integrity status
```

> **Key creation is not exposed over HTTP** (`POST /keys` → **405**). Keys are minted on-box with the
> `tailnumber-keygen` CLI, which records governance provenance (creator, reason, PMA/TSO approval, DO-178C level).

---

## The easy path — `tailnumber-api.sh`

```bash
cd examples
./tailnumber-api.sh version                     # discovery
./tailnumber-api.sh algorithms
./tailnumber-api.sh keys
./tailnumber-api.sh chain tailnumber-legacy-rsa-01 > chain.pem   # trust material

./tailnumber-api.sh sign   firmware.bin          # -> firmware.bin.sig.json
./tailnumber-api.sh verify firmware.bin firmware.bin.sig.json    # full authenticity verdict

./tailnumber-api.sh sign-batch   *.bin           # sign a whole release
./tailnumber-api.sh verify-batch *.bin           # verify it all (expects each <file>.sig.json)

./tailnumber-api.sh raw GET /capabilities        # escape hatch for any endpoint
```

Post-quantum: set `TN_KEY_LABEL=tailnumber-codesign-01 TN_SIG_ALG=ml-dsa-65` and rerun.

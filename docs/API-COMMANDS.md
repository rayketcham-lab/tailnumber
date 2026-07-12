# TailNumber — API command reference

Every useful endpoint with a copy-paste `curl`. **Open for evaluation** — no auth header needed.
Only a hash is sent for signing; your files never leave your machine. Needs `curl`, `jq`, `openssl`.

```bash
API=https://www.rayketcham.com/CRLs/tailnumber/api/v1
KEY=tailnumber-codesign-01     # a signing key that exists — list them any time with:
                               #   curl -s $API/keys | jq -r '.keys[].label'
```

> **🧪 Under active development.** This is a proof of concept — available **keys, algorithms, and
> backends can change between visits**. If a command 404s on a key label, list what's live
> (`curl -s $API/keys | jq -r '.keys[].label'`); the authoritative endpoint list is always
> [`/openapi.json`](https://www.rayketcham.com/CRLs/tailnumber/openapi.json). Last fact-checked
> end-to-end against the live service on **2026-07-12** (backend: SoftHSM, one RSA-3072 signer).

> **TL;DR — one CLI for all of this:** [`examples/tailnumber-api.sh`](../examples/tailnumber-api.sh)
> wraps every command below (`tailnumber-api.sh sign|verify|sign-batch|keys|chain|algorithms|…`).
> Full interactive docs live at [`/docs`](https://www.rayketcham.com/CRLs/tailnumber/docs) (Swagger).

---

## Discovery / health

```bash
curl -s ${API%/api/v1}/healthz | jq .    # liveness + backend probe (service root, NOT under /api/v1)
curl -s $API/ping           | jq .    # lightweight liveness
curl -s $API/version        | jq .    # service / OpenSSL / Python versions
curl -s $API/time           | jq .    # server UTC (for timestamps/nonces)
curl -s $API/algorithms     | jq .    # supported sig_algs + their digests / pkeyutl args
curl -s $API/capabilities   | jq .    # backend features + limits
curl -s $API/hsm            | jq .    # key-protection posture (backend, PKCS#11 modules, mechanisms)
curl -s $API/metrics        | jq .    # usage totals + hourly/daily series
curl -s $API/whoami         | jq .    # your resolved identity, groups, role
```

## Keys & trust material

```bash
curl -s $API/keys                | jq .   # list keys visible to you
curl -s $API/keys/$KEY           | jq .   # one key: subject, validity, spki, chain length
curl -s $API/keys/$KEY/certificate        # leaf cert (PEM)
curl -s $API/keys/$KEY/chain              # full chain (PEM) — for offline verify
curl -s $API/keys/$KEY/publickey          # public key (PEM)

curl -s $API/ca         | jq .    # signing-CA status
curl -s $API/ca/root              # Root CA cert (PEM) — the trust anchor
curl -s $API/ca/issuing           # Issuing CA cert (PEM)
curl -s $API/ca/chain             # Issuing + Root bundle (PEM) — what a verifier pins
```

> On the **HSM backend the private key cannot be exported** — there is no `.pfx`/`bundle` download
> (`/keys/$KEY/bundle` and `/keys/$KEY/pfx` → 404 by design). Use the `certificate` / `chain` /
> `publickey` endpoints above; they're all you need to verify. The PFX bundle exists only on the
> software (PFX) backend.

## Sign

```bash
FILE=yourfile.bin
ALG=rsa3072-pss-sha256      # this key is RSA-3072; see $API/keys/$KEY for its sig_algs
DIGEST=sha256

# 1) hash locally, 2) send only the digest
HEX=$(openssl dgst -$DIGEST "$FILE" | awk '{print $NF}')
curl -s -X POST $API/sign -H 'content-type: application/json' -d "$(jq -nc \
  --arg k "$KEY" --arg a "$ALG" --arg d "$DIGEST" --arg g "$DIGEST=$HEX" \
  '{key_label:$k,sig_alg:$a,digest_alg:$d,digest:$g}')" | tee envelope.sig.json | jq .
```

**Variants**

```bash
# compose the algorithm (padding / digest / salt) instead of a named one — the envelope
# records the resolved sig_alg (e.g. rsa3072-pss-sha256) so it still verifies anywhere
curl -s -X POST $API/sign/custom -H 'content-type: application/json' -d "$(jq -nc \
  --arg k "$KEY" --arg g "sha256=$HEX" \
  '{key_label:$k, padding:"pss", digest_alg:"sha256", saltlen:"digest", digest:$g}')" | jq .

# hash + sign in one call (sends the data, server hashes it)
curl -s -X POST $API/sign/data -H 'content-type: application/json' -d "$(jq -nc \
  --arg k "$KEY" --arg a "$ALG" --arg data "$(base64 -w0 < "$FILE")" \
  '{key_label:$k, sig_alg:$a, data:$data}')" | jq .

# hybrid: one digest signed by a classical AND a post-quantum (ML-DSA) key — valid while
# EITHER algorithm holds. Needs BOTH an RSA/ECDSA key and an ml-dsa-* key; ML-DSA lives on
# the Luna backend, so this errors on the classical-only SoftHSM validation backend.
curl -s -X POST $API/sign/hybrid -H 'content-type: application/json' -d "$(jq -nc \
  --arg g "sha384=$(openssl dgst -sha384 "$FILE" | awk '{print $NF}')" \
  '{classical_label:"<rsa-or-ecdsa-key>", pqc_label:"<ml-dsa-key>", digest_alg:"sha384", digest:$g}')" | jq .
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
# build a batch of sign requests (max 256) and sign them all at once
jq -nc --arg k "$KEY" --arg a "$ALG" --arg d "$DIGEST" --arg g "$DIGEST=$HEX" \
  '{items:[ {key_label:$k,sig_alg:$a,digest_alg:$d,digest:$g} ]}' > batch-sign.json
curl -s -X POST $API/sign/batch -H 'content-type: application/json' -d @batch-sign.json | jq '{signed, count}'

# turn the signed results into verify requests, then verify the whole batch
curl -s -X POST $API/sign/batch -H 'content-type: application/json' -d @batch-sign.json \
  | jq -c '{items:[.results[].envelope | {key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}]}' \
  > batch-verify.json
curl -s -X POST $API/verify/batch -H 'content-type: application/json' -d @batch-verify.json | jq '[.results[].valid] | all'
# => true
```

## Utility

```bash
# compute a digest server-side over supplied base64 data (client-side openssl is usually better)
curl -s -X POST $API/hash -H 'content-type: application/json' \
  -d "$(jq -nc --arg data "$(base64 -w0 < "$FILE")" '{digest_alg:"sha256", data:$data}')" | jq .
```

## Identity, ACL & config (read-only)

```bash
curl -s $API/whoami            | jq .   # your resolved identity, groups, role
curl -s $API/identities        | jq .   # all known identities (CN → groups / role)
curl -s $API/whois/rketcham    | jq .   # one identity: groups, role, key globs
curl -s $API/acl               | jq .   # full ACL: identities + groups
curl -s $API/acl/groups        | jq .   # groups → role + key globs
curl -s $API/acl/roles         | jq .   # defined roles
curl -s $API/config            | jq .   # effective NON-secret config (backend, paths) — admin
curl -s $API/changelog                  # service changelog (markdown, not JSON)
```

## Audit forensics (tamper-evident, hash-chained)

```bash
curl -s "$API/audit?limit=20"             | jq .   # recent entries + chain status
curl -s "$API/audit/42"                   | jq .   # one entry by sequence number
curl -s "$API/audit/search?action=sign&limit=50" | jq .   # filter by action / key / actor / result
curl -s $API/audit/stats                  | jq .   # counts by action / result / actor / key
curl -s $API/audit/verify                 | jq .   # re-verify the whole hash chain now
curl -s "$API/audit/export?limit=1000"    > audit.json    # export the chain (backup / SIEM)
```

## Admin (mutations & forensics — require the admin role)

```bash
curl -s -X POST $API/authz/check -H 'content-type: application/json' \
  -d "{\"cn\":\"someone\",\"key_label\":\"$KEY\"}" | jq .   # dry-run "can X use key Y?"
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
./tailnumber-api.sh keys                         # what key labels exist right now
./tailnumber-api.sh chain tailnumber-codesign-01 > chain.pem   # trust material

./tailnumber-api.sh sign   firmware.bin          # -> firmware.bin.sig.json
./tailnumber-api.sh verify firmware.bin firmware.bin.sig.json    # full authenticity verdict

./tailnumber-api.sh sign-batch   *.bin           # sign a whole release
./tailnumber-api.sh verify-batch *.bin           # verify it all (expects each <file>.sig.json)

./tailnumber-api.sh raw GET /capabilities        # escape hatch for any endpoint
```

**Other algorithms:** the signer key fixes the family — `tailnumber-codesign-01` is **RSA-3072**
(`rsa3072-pss-sha256` / `rsa3072-pkcs1-sha256`). ECDSA P-384 and post-quantum **ML-DSA-65/87** are
supported by the service, but need a key of that type: run `curl -s $API/keys` to see which are live.
On the SoftHSM validation backend only RSA is available; ECDSA/ML-DSA keys live on the Luna backend.

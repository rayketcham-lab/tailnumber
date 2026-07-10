# Testing TailNumber — sign, verify a file, and prove tamper-detection

Copy-paste steps for evaluators. **Only a hash is sent — your file never leaves your machine.**
Needs: `curl`, `jq`, `openssl`.

## 0 · Configure

```bash
API=https://www.rayketcham.com/CRLs/tailnumber/api/v1   # the service
FILE=yourfile.bin                                       # the file you want to sign
KEY=tailnumber-codesign-01                              # signing key (list live ones: curl -s $API/keys | jq -r '.keys[].label')
ALG=rsa3072-pss-sha256                                  # signature algorithm
DIGEST=sha256                                           # hash: sha256 for RSA · sha384 for ML-DSA
ENV=envelope.sig.json                                   # where the signed envelope is saved
```

## 1 · Sign

```bash
HEX=$(openssl dgst -"$DIGEST" "$FILE" | awk '{print $NF}')
curl -sS -X POST "$API/sign" -H 'content-type: application/json' \
  -d "{\"key_label\":\"$KEY\",\"sig_alg\":\"$ALG\",\"digest_alg\":\"$DIGEST\",\"digest\":\"$DIGEST=$HEX\"}" \
  | tee "$ENV" | jq .
```

## 2 · Verify the signature

```bash
jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' "$ENV" \
  | curl -sS -X POST "$API/verify" -H 'content-type: application/json' -d @- | jq .
# => { "valid": true, "details": "signature valid" }
```

## 3 · Verify the **file** against the envelope  ← the one you want

A valid signature only proves the *digest* was signed. To prove the envelope belongs to **this file**,
confirm the file still hashes to the signed digest.

**One command** ([`tailnumber-verify-file.sh`](../examples/tailnumber-verify-file.sh)):

```bash
./tailnumber-verify-file.sh "$FILE" "$ENV"
# => ✅ AUTHENTIC — this envelope belongs to this file, and the signature checks out.
```

**Or by hand:**

```bash
FILEHEX=$(openssl dgst -"$DIGEST" "$FILE" | awk '{print $NF}')
ENVHEX=$(jq -r .digest.value "$ENV" | sed 's/^b64://' | base64 -d | od -An -tx1 | tr -d ' \n')
[ "$FILEHEX" = "$ENVHEX" ] && echo "file matches ✓" || echo "does NOT match ✗"
```

**In the WebUI:** the dashboard → **Verify an envelope** → paste the `.sig.json` → pick the **original file**.
It reports **✓ AUTHENTIC** when the signature is valid *and* the file matches. The file is hashed **in your
browser** and never uploaded.

## 4 · Prove tamper-detection (expect a FAILURE)

Change a single byte and confirm it is rejected:

```bash
cp "$FILE" tampered.bin
printf 'X' >> tampered.bin                     # one extra byte
./tailnumber-verify-file.sh tampered.bin "$ENV"
# => ❌ NOT AUTHENTIC — file does NOT match the signed digest
```

## 5 · Load / metrics (optional)

Pound the API and gauge latency + throughput. Each iteration appends a line to a growing file
(so `wc -l` == iterations), signs a fresh digest, verifies it, and runs the integrity + tamper checks —
all logged to a CSV. ([`tailnumber-loadtest.sh`](../examples/tailnumber-loadtest.sh))

```bash
./tailnumber-loadtest.sh                          # 100 iterations, full checks, CSV metrics
TN_ITERS=1000 TN_VERIFY=0 TN_TAMPER=0 ./tailnumber-loadtest.sh   # throughput-focused
```

## Keys & algorithms

Run `curl -s $API/keys | jq -r '.keys[].label'` for the live list — keys can change (this is a POC).

| `KEY` | `ALG` | `DIGEST` |
|---|---|---|
| `tailnumber-codesign-01` | `rsa3072-pss-sha256` (or `rsa3072-pkcs1-sha256`) | `sha256` |

> ECDSA P-384 (`ecdsa-p384-sha384`, `sha384`) and post-quantum ML-DSA-65/87 are supported by the
> service, but need a key of that family. The current SoftHSM validation backend is classical-only
> (RSA); ECDSA/ML-DSA keys live on the Luna backend.
>
> For PKCS#11 (signing in a token/HSM) the algorithm is named as a **mechanism** instead —
> `rsa3072-pss-sha256` becomes `CKM_SHA256_RSA_PKCS_PSS` (`pkcs11-tool` calls it `SHA256-RSA-PKCS-PSS`).

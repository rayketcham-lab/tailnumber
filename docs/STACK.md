# Tech stack, dependencies & build requirements

What TailNumber is built with and what a deployment needs. The design goal is a
**minimal, auditable surface** — a handful of well-known Python packages, one
pinned OpenSSL, and an HSM — not a sprawling dependency tree.

## Stack at a glance

| Layer | Choice |
|---|---|
| **Language / runtime** | **Python 3.12** |
| **Web framework** | **FastAPI** (ASGI) on **uvicorn** |
| **Models / validation** | **Pydantic v2** |
| **Config** | TOML (stdlib `tomllib`) + a YAML ACL (**PyYAML**) |
| **Cryptography** | **pinned OpenSSL 3.5.4**, invoked as a subprocess — *no Python crypto library* |
| **Keys / HSM** | **PKCS#11** — SoftHSM2 (dev/CI) or **Thales Luna T3000** (prod), via `pkcs11-tool` + the OpenSSL pkcs11 engine |
| **Edge** | Apache / nginx reverse proxy (TLS / mTLS termination); **systemd** service (`tailnumberd`) |
| **Audit** | Append-only, hash-chained JSONL |

## Direct Python dependencies

That is the entire third-party surface (`requirements.txt`):

```
fastapi
uvicorn
pyyaml
```

Everything cryptographic is delegated to the pinned **OpenSSL 3.5.4** binary — a
deliberate choice so the crypto is one well-understood, FIPS-track dependency
instead of a stack of Python wheels. Post-quantum **ML-DSA** (FIPS 204) is why the
build is pinned to OpenSSL 3.5.

## Server / build requirements

- **Linux** x86-64
- **Python 3.12**
- **OpenSSL 3.5.x** — a pinned build (e.g. under `/opt/openssl-3.5`), for ML-DSA + RSA / ECDSA
- A **PKCS#11 module** — SoftHSM2 for dev/CI, a Thales Luna T-Series HSM for production
- A **reverse proxy** (Apache or nginx) for TLS / mTLS and path mounting
- **systemd** to run the service as an unprivileged user (`0600` keys; passphrase via `LoadCredential`)

## How it runs (shape)

```bash
python3.12 -m venv venv && venv/bin/pip install -r requirements.txt
# config: /etc/tailnumber/config.toml  (paths, backend = pfx | luna, openssl bin/libpath)
# run:    uvicorn app.main:app --app-dir service --host 127.0.0.1 --port 9443
#         (systemd unit `tailnumberd`, fronted by the reverse proxy)
```

Signing keys are **not** created over HTTP — they are minted on-box with the
`tailnumber-keygen` CLI, which records governance provenance (who / why / PMA
approval / DO-178C level) with each key.

## Client scripts (`examples/`)

Small, dependency-light Bash clients that exercise the flow end to end:

| Script | What it shows |
|---|---|
| [`tailnumber-sign-stepwise.sh`](../examples/tailnumber-sign-stepwise.sh) | Hash a file with **SHA-256**, sign via the API, and print the **envelope to paste into the WebUI → Verify** — step by step. |
| [`pkcs11-sign-demo.sh`](../examples/pkcs11-sign-demo.sh) | The **HSM signing primitive** with SoftHSM2 + the OpenSSL pkcs11 engine (SHA-256, RSA-3072): a key generated in — and signing inside — the token, then verified. |
| [`tailnumber-api-roundtrip.sh`](../examples/tailnumber-api-roundtrip.sh) | Sign **and** verify entirely via the API, then **independently re-verify** the envelope with raw OpenSSL and **compare the two verdicts** — proving `/verify` agrees with plain OpenSSL. |
| [`tailnumber-verify-file.sh`](../examples/tailnumber-verify-file.sh) | Point it at a **file + envelope** → confirms the file still hashes to the signed digest **and** the signature is valid → **✅ AUTHENTIC** (or ❌ for the wrong/altered file). |
| [`tailnumber-loadtest.sh`](../examples/tailnumber-loadtest.sh) | **Pound the API** for metrics: a growing file (so `wc -l` == iterations), fresh signature each pass, plus per-iteration **integrity + tamper** checks, all logged to a **CSV** with latency/throughput. |
| [`tailnumber-api.sh`](../examples/tailnumber-api.sh) | **One CLI over the whole API** — `sign` · `verify` (authenticity) · `sign-batch` · `verify-batch` · `keys` · `key` · `chain` · `ca-chain` · `algorithms` · `version` · `raw`. Wraps `/sign/batch` + `/verify/authentic`. See **[docs/API-COMMANDS.md](API-COMMANDS.md)**. |

Both print each OpenSSL / API step as they go, so you can follow exactly what
happens. They need only `bash`, `curl`, and `openssl` (the PKCS#11 demo also uses
`softhsm2-util` + `pkcs11-tool`).

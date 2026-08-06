# TailNumber — HSM: what protects the keys, and how to check

> **The public demo is retired.** The endpoints below are offline and no longer resolve.
> These commands were verified against the live service while it ran and are kept as a
> record; to run them, point `TN_ENDPOINT` / `$API` at your own instance.


Short version: **the live demo runs on SoftHSM2, a *software* HSM.** Private keys are
PKCS#11 token objects marked sensitive and non-extractable, so the API cannot export
them — but SoftHSM's token database is a file on disk, so this is software protection,
not hardware. The production target is a **Thales TCT Luna T-Series (T3000)**,
FIPS 140-2 Level 3. Same code path; different module underneath.

This page shows how to verify that claim yourself rather than take it on faith.

---

## 1. Ask the service what is protecting the keys

```bash
BASE=https://www.rayketcham.com/CRLs/tailnumber
curl -s $BASE/api/v1/hsm | jq '.backend'
```

```json
{
  "active": "luna",
  "protection": "software (SoftHSM — PKCS#11, non-extractable)",
  "hardware": false,
  "detail": "Private keys are PKCS#11 objects in a SoftHSM token, marked sensitive + non-extractable so the API cannot export them — but SoftHSM is a SOFTWARE HSM (its token DB is on disk), so this is software protection, not hardware. It is the validation stand-in for the Luna T-Series."
}
```

`"hardware": false` is the field that matters. It is computed from the configured
PKCS#11 module, not from a setting anyone types — pointing the config at a real
`libCryptoki2_64.so` is what flips it.

> `active: "luna"` is the **backend name**, not a claim of Luna hardware. Both SoftHSM2
> and a Luna partition are driven by the same `luna` PKCS#11 code path. Read
> `backend.hardware` for the hardware question.

## 2. Ask which PKCS#11 libraries are actually installed

```bash
curl -s $BASE/api/v1/hsm | jq '.modules'
```

Each module is reported by what it says about *itself* — `manufacturer` and `cryptoki`
come from the library, not from a label in our config:

```json
[
  { "name": "Configured PKCS#11 module", "path": "/usr/lib/softhsm/libsofthsm2.so",
    "present": true, "manufacturer": "SoftHSM", "cryptoki": "2.40", "is_luna_client": false },
  { "name": "Thales Luna client", "path": null, "present": false, "is_luna_client": false,
    "searched": [ "/usr/safenet/lunaclient/lib/libCryptoki2_64.so", "…" ],
    "detail": "No Luna client library found at any known path on this host — this deployment is not hardware-backed." }
]
```

An earlier build titled the configured module "Thales Luna client" regardless of vendor,
which made the SoftHSM library look like an installed Luna client. That was wrong and is
fixed; modules are never labelled by aspiration.

## 3. Confirm the key really cannot be exported

```bash
curl -s -o /dev/null -w '%{http_code}\n' $BASE/api/v1/keys/tailnumber-codesign-01/bundle   # 404
curl -s -o /dev/null -w '%{http_code}\n' $BASE/api/v1/keys/tailnumber-codesign-01/pfx      # 404
curl -s $BASE/api/v1/keys/tailnumber-codesign-01/bundle | jq -r .detail
# key bundle unavailable on the HSM backend — private keys are non-extractable
```

The **public** half is served happily — that asymmetry is the point:

```bash
curl -s $BASE/api/v1/keys/tailnumber-codesign-01/publickey | head -1   # -----BEGIN PUBLIC KEY-----
```

## 4. See the command that actually signed

The dashboard's *"how this signature was produced"* panel prints the real command for
the active backend. On the PKCS#11 backend it contains no key file, because there is none:

```bash
curl -s -X POST $BASE/db/sign-evidence --data-urlencode "envelope=$(cat yourfile.bin.sig.json)"
```

```
openssl pkeyutl -sign -engine pkcs11 -keyform engine \
  -inkey "pkcs11:token=tailnumber;object=tailnumber-codesign-01;type=private" \
  -in digest.bin -out sig.bin -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss …
```

The PIN never appears — it is redacted from every transcript, API response and audit
record. (See *Honest limitations* below for where it does exist.)

## 5. Which mechanisms are live

```bash
curl -s $BASE/api/v1/hsm | jq '.mechanisms[] | {sig_alg, support, satisfied_by}'
```

`support: "live"` means a reachable token advertises the mechanism; `satisfied_by` names
which one matched. Note ECDSA:

```json
{ "sig_alg": "ecdsa-p384-sha384", "support": "live", "satisfied_by": "ECDSA",
  "note": "token advertises the raw mechanism only; the pkcs11 engine digests in software and sends the raw sign to the token" }
```

A token that offers only raw `CKM_ECDSA` rather than combined `CKM_ECDSA_SHA384` still
satisfies the algorithm — the engine hashes in software and sends the raw sign to the
token. The private key never leaves either way; only the hashing location differs. This
is how the EC P-384 CA keys sign today.

`ml-dsa-65` / `ml-dsa-87` report `support: "luna-fw"`: **SoftHSM2 has no post-quantum
mechanisms at all.** ML-DSA needs Luna firmware 7.15.0.

## 6. Watch the whole in-token lifecycle yourself

[`examples/pkcs11-sign-demo.sh`](../examples/pkcs11-sign-demo.sh) runs against a local
SoftHSM token you control — keypair generated **in** the token, digest signed **in** the
token, verified with the exported public half, printing every `pkcs11-tool` and `openssl`
command as it goes. Swap the module for `libCryptoki2_64.so` and the same commands run
against a Luna T-Series.

---

## Luna — the production path

Both backends are the same `backend_type = "luna"` code in the service. Moving to
hardware is a **config change, not a code change**: point `[luna] module` at the client
library and `token_label` at the partition.

| | SoftHSM2 (today) | Luna T-Series (production) |
|---|---|---|
| Module | `/usr/lib/softhsm/libsofthsm2.so` | `libCryptoki2_64.so` from the client SDK |
| Partition | `softhsm2-util --init-token` | Provisioned by the **HSM admin** via `lunacm` — not by any script here |
| Client config | `SOFTHSM2_CONF` → on-disk token dir | `ChrystokiConfigurationPath` / `Chrystoki.conf`, NTLS-registered |
| Key custody | Non-extractable objects, token DB on disk — **software** | Born in tamper-resistant hardware, `CKA_SENSITIVE`/`CKA_EXTRACTABLE=FALSE` |
| Certification | none | **FIPS 140-2 Level 3** |
| Post-quantum | none | ML-DSA-65/87 with firmware 7.15.0 |
| Auth | text user PIN | password partition **or** PED (trusted path, no text PIN) |

**Readiness check.** Before cutting over, the pilot host runs a read-only preflight that
verifies the module's PKCS#11 manufacturer really is Thales/SafeNet, that NTLS is
registered, that the configured partition label is visible, that the mechanisms are
present, and that OpenSSL can load the `pkcs11` engine. It creates nothing and touches no
partition. The service also publishes the same checklist:

```bash
curl -s $BASE/api/v1/hsm | jq '.luna_readiness'
```

The partition lifecycle — create, role/PED init, activate, rotate credentials, delete —
belongs to the HSM admin, not to this service.

## Honest limitations

- **SoftHSM is not hardware.** Non-extractable via PKCS#11, but the token DB is a file.
  Anyone with root on the host and the PIN has a different threat model than a T-Series.
  No FIPS validation, no M-of-N quorum, no tamper response.
- **No post-quantum on the demo.** ML-DSA is implemented and covered by the acceptance
  suite on the software backend, but the live SoftHSM token cannot perform it. Hybrid
  signing needs an ML-DSA key and therefore Luna hardware.
- **The PIN is on the signing subprocess's argv.** The URI uses `pin-value=`, so the PIN
  is visible in `/proc/<pid>/cmdline` for the life of that subprocess — the same class as
  `pkcs11-tool --pin`. A `pin-source=file:` variant was tried and reverted because libp11
  fails `C_Login` on longer PINs. It is redacted from every transcript, response and
  audit record, but this is a POC-accepted residual, not a property to claim in a
  security review. A PED partition has no text PIN and removes it entirely.
- **Luna steps are written against the SDK docs, not exercised.** There is no Luna
  hardware in this environment. Confirm each step against the delivered appliance.

# Signature Formats & Interoperability

> How the TailNumber `.sig.json` envelope is constructed, what it actually
> signs, where it sits among the standardized JSON/CBOR/ASN.1 signature
> families (JWS/JWT, JAdES, COSE, CMS/CAdES, DSSE), and which additional
> serializations the service can emit without changing its trust model.

---

## 1. The envelope in one sentence

A TailNumber `.sig.json` is a **detached digest signature**: the client computes
a cryptographic digest of an artifact, the service signs *that digest* with an
HSM-resident key, and the envelope carries the signature, the digest, the signer's
X.509 certificate chain, and provenance metadata — **the artifact itself never
moves**. Trust flows from the X.509 chain to the TailNumber signing root, not from
the transport.

The central design claim of this document:

> **Format is orthogonal to trust.** The same HSM-backed, CA-chained signature
> bytes can be serialized as `.sig.json`, as a detached JWS, as a `COSE_Sign1`,
> or as a CMS `.p7s`. The wrapper changes; the key, the certificate chain, and
> the trust root do not.

---

## 2. Data model

The frozen wire format (the `envelope.py` module — implementation is private):

| Field | Type | Semantics |
|---|---|---|
| `version` | int | Envelope schema version (`1`). |
| `signed_at` | RFC 3339 UTC | Service-asserted signing instant (`…Z`). |
| `service` | string | Producing service + version, e.g. `tailnumber/1.0.0`. |
| `key.label` | string | Signing key identifier within the service/HSM. |
| `key.sig_alg` | enum | Signature algorithm (see §6). |
| `key.spki_sha256` | b64 | SHA-256 of the SubjectPublicKeyInfo — a key fingerprint independent of the certificate. |
| `digest.alg` | enum | Digest algorithm (`sha256` \| `sha384` \| `sha512`). |
| `digest.value` | `b64:`+base64 | The exact bytes that were signed (the message). |
| `profile` | string | `digest-as-message` (see §3). |
| `context` | string | Domain-separation label (`TailNumber/v1`). |
| `signature` | `b64:`+base64 | Raw signature octets (PKCS#1/PSS block, ECDSA `Sig-Value`, or ML-DSA signature). |
| `cert_chain` | string[] | PEM certificates, leaf first, then issuing CA. Root is **not** included — it is the pinned trust anchor. |
| `artifact` | object | Optional caller-supplied provenance (filename, media type, build id …). Not covered by the signature unless folded into the digest by the caller. |

Binary fields use a self-describing `b64:` prefix so the envelope stays valid,
copy-pasteable JSON.

---

## 3. What is actually signed — the canonicalization question

This is the crux of every JSON signing scheme, and where designs diverge.

JSON has **no canonical byte representation**: object key order, whitespace,
Unicode escaping, and number formatting are all free. You cannot sign "the JSON"
because two equal documents can serialize to different bytes. The standards each
answer this differently:

| Scheme | How it fixes the bytes-to-sign |
|---|---|
| **JWS** | Signs `ASCII(BASE64URL(header) '.' BASE64URL(payload))` — the *transmitted octets*, never the parsed JSON. |
| **JCS** (RFC 8785) | Defines one canonical serialization, then sign that. |
| **DSSE** | **PAE** (Pre-Authentication Encoding) — length-prefixed concatenation, unambiguous by construction. |
| **CMS / COSE** | Sign a DER/CBOR `SignedData`/`Sig_structure` — binary encodings that *are* canonical. |
| **TailNumber** | Signs the **client-computed digest** directly (`digest-as-message`). |

TailNumber sidesteps canonicalization entirely. The message is the artifact's
hash — a fixed 32/48/64-byte string the client already holds. Signer and verifier
agree on the signed bytes with zero encoding ambiguity, and the scheme is
**detached by construction**: the service never sees, stores, or transmits the
artifact. This is the "signing oracle over digests" model — ideal when the thing
being signed is large, sensitive, or air-gapped (aerospace firmware images), which
is exactly why it was chosen here.

The tradeoff, stated honestly: because the service signs a hash the client asserts,
authenticity of *the artifact* depends on the client computing the digest
correctly. TailNumber authenticates the **signature and the signer**; the caller
binds the digest to the artifact (and may record that binding in `artifact`).

---

## 4. Where `.sig.json` sits in the ecosystem

| Format | Serialization | Encoding | Signed bytes | Detached | Multi-sig | Long-term profile | Spec |
|---|---|---|---|---|---|---|---|
| **TailNumber `.sig.json`** | JSON | base64 | client digest | **yes** (native) | no (today) | via profile (§7) | this repo |
| **JWS Compact / JWT** | JSON→compact | base64url | `hdr.payload` | App. F | no | — | RFC 7515 / 7519 |
| **JWS JSON Serialization** | JSON | base64url | `hdr.payload` | App. F + RFC 7797 | **yes** | — | RFC 7515 |
| **JAdES** | JSON (JWS) | base64url | JWS + attrs | yes | yes | **B-LTA** | ETSI TS 119 182-1 |
| **COSE `COSE_Sign1`** | CBOR | binary | `Sig_structure` | yes | `COSE_Sign` | via profiles | RFC 9052 |
| **CMS / PKCS#7 `.p7s`** | ASN.1 | DER | `SignedData` | `-detached` | yes | **CAdES-LTA** | RFC 5652 |
| **DSSE** | JSON | base64 | PAE(payload) | yes | yes | — | Sigstore / in-toto |

Read this table as a map of **choices**, not a ranking: JSON vs CBOR vs ASN.1;
attached vs detached; single vs multi-signer; basic vs long-term. TailNumber
occupies the "minimal detached JSON, X.509-anchored, PQC-capable" corner.

---

## 5. JOSE in depth (the JWT / JWS question)

A frequent point of confusion worth stating plainly:

- **JWT (RFC 7519) is not a document-signing format.** A JWT is a *claims token* —
  a JSON set of registered claims (`iss`, `sub`, `exp`, …) that is *usually* wrapped
  in a JWS (occasionally a JWE). "Sign my file as a JWT" is a category error; what
  people mean is "sign it with **JWS**."
- **JWS (RFC 7515) is the general mechanism.** Two serializations: *Compact*
  (`h.p.s`, what JWTs use) and *JSON* (an object with `protected`, `header`,
  `signature`, or a `signatures[]` array for multiple signers). A JWS can be
  **detached** (Appendix F: omit the payload) and carry **unencoded** content
  (RFC 7797, `b64:false` + `crit`).
- **Certificates travel in the header:** `x5c` (base64-DER chain), `x5t#S256`
  (SHA-256 cert thumbprint), `x5u` (URL). TailNumber's `cert_chain` (PEM) maps to
  `x5c` (strip PEM armor → base64 DER); `spki_sha256` is the moral equivalent of a
  key thumbprint.

The consequence: for `RS256` / `PS256` / `ES384`, **TailNumber already produces a
JWS-grade signature.** Emitting a detached JWS is a *re-serialization*, not new
cryptography — same key, same certificate chain, same signature primitive.

---

## 6. Algorithm mapping

| TailNumber `sig_alg` | JOSE `alg` | COSE `alg` | X.509 / CMS | `pkeyutl` verify flags | Standard |
|---|---|---|---|---|---|
| `rsa3072-pkcs1-sha256` | `RS256` | `-257` | `sha256WithRSAEncryption` | `-pkeyopt digest:sha256` | RFC 7518 |
| `rsa3072-pss-sha256` | `PS256` | `-37` | `id-RSASSA-PSS` | `-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest` | RFC 7518 |
| `ecdsa-p384-sha384` | `ES384` | `-35` | `ecdsa-with-SHA384` | *(none — raw 48-byte digest)* | RFC 7518 |
| `ml-dsa-65` | **†** | **‡** | `id-ml-dsa-65` (2.16.840.1.101.3.4.3.18) | `-rawin` *(OpenSSL 3.5+)* | FIPS 204 |
| `ml-dsa-87` | **†** | **‡** | `id-ml-dsa-87` (2.16.840.1.101.3.4.3.19) | `-rawin` *(OpenSSL 3.5+)* | FIPS 204 |

**† No finalized JOSE algorithm identifier for ML-DSA yet.** PQC in JOSE is still
being specified in IETF LAMPS/JOSE; do not assume a stable `alg` string.
**‡ COSE is further along** (`draft-ietf-cose-dilithium`), but likewise not final.
X.509 ML-DSA certificates follow `draft-ietf-lamps-dilithium-certificates` using
the FIPS 204 OIDs above. **This is the honest interop gap:** classical algorithms
(RS256/PS256/ES384) interoperate today; ML-DSA is standardized as a *signature*
(FIPS 204) but its *container bindings* (JOSE/COSE/CMS) are draft-stage.

---

## 7. Long-term signatures (the 55/54/50-year chain)

TailNumber's decades-long validity ([README → *Built to outlive the airframe*](../README.md))
raises the same problem the *-AdES* families were built to solve: a signature must
remain **verifiable** long after the signing certificate expires or the CA is
retired. The standardized answer is a **long-term validation (LTV)** profile:

1. **Signature timestamp** (RFC 3161 token) — proves the signature existed while
   the certificate was valid, decoupling "signed" from "still-valid-today."
2. **Embedded revocation data** — CRL/OCSP responses captured at signing time, so
   verification never needs a (long-dead) responder.
3. **Archival timestamps** — periodically re-timestamp the whole structure to
   outrun algorithm decay. This is **JAdES-B-LTA** (JSON) / **CAdES-LTA** (CMS).

TailNumber today ships the *trust chain* sized for the platform lifetime; a
`profile: "digest-as-message+ltv"` variant would add the timestamp + revocation
attributes above. Tracked as a roadmap item in §8.

---

## 8. Can we emit other formats? — yes; here's the map

All of the below reuse the existing HSM key and X.509 chain. Effort is relative.

| Target | Fit | Effort | Notes |
|---|---|---|---|
| **JWS (JSON, detached)** | ★★★ natural | small | `x5c` from `cert_chain`; `PS256`/`RS256`/`ES384`. Blocked on ML-DSA JOSE reg. |
| **CMS / PKCS#7 detached `.p7s`** | ★★★ classic interop | small | `openssl cms -sign -detached -binary`; verifies in Windows/Java/Adobe. We already emit a P7B cert bundle. |
| **COSE `COSE_Sign1`** | ★★ embedded/avionics | medium | CBOR; best PQC path (`draft-ietf-cose-dilithium`); used by C2PA, WebAuthn, EAT. |
| **DSSE** | ★★ supply chain | small | JSON + PAE; carries in-toto/SLSA attestations. |
| **JWT (claims token)** | ★ demo only | small | Only meaningful as a "signed digest token" (`sub`=artifact id, custom digest claim). Not artifact signing. |

**Recommendation:** ship **JWS-detached** (modern JSON interop) and **CMS-detached
`.p7s`** (universal legacy interop) first. Together they cover ~everything a
consumer already knows how to verify, with no change to the trust model.

---

## 9. Do it yourself — verify an envelope offline

No service, no network — just OpenSSL and the envelope. **This transcript is real**
(RSA-PSS, verified against a live-issued envelope with OpenSSL 3.0.13).

Extract the parts (with [`jq`](https://jqlang.github.io/jq/)):

```bash
jq -r '.signature    | sub("^b64:";"")' env.sig.json | base64 -d > sig.bin
jq -r '.digest.value | sub("^b64:";"")' env.sig.json | base64 -d > digest.bin
jq -r '.cert_chain[0]' env.sig.json > leaf.crt
jq -r '.cert_chain[1]' env.sig.json > issuing.crt
```

Verify (RSA-PSS shown; swap the flags per §6):

```bash
# 1) recover the signer's public key from the leaf certificate
openssl x509 -in leaf.crt -pubkey -noout > pub.pem

# 2) verify the signature over the digest
openssl pkeyutl -verify -pubin -inkey pub.pem -in digest.bin -sigfile sig.bin \
  -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest
#   -> Signature Verified Successfully

# 3) chain the signer to the TailNumber signing root (authenticity)
openssl verify -CAfile tailnumber-signing-root.crt -untrusted issuing.crt leaf.crt
#   -> leaf.crt: OK
```

Then confirm the digest actually matches your artifact:

```bash
openssl dgst -sha256 -binary my-artifact.bin | cmp - digest.bin && echo "digest OK"
```

Three independent facts, checkable by anyone: the **signature** is valid for the
**digest**, the **signer** chains to the **root**, and the **digest** is your
artifact's. ML-DSA envelopes need OpenSSL 3.5+ and `-rawin`.

---

## References

- **RFC 7515** JSON Web Signature (JWS) · **RFC 7517** JWK · **RFC 7518** JWA ·
  **RFC 7519** JWT · **RFC 7797** JWS Unencoded Payload
- **RFC 8785** JSON Canonicalization Scheme (JCS)
- **RFC 9052 / 9053** CBOR Object Signing and Encryption (COSE)
- **RFC 5652** Cryptographic Message Syntax (CMS) · **RFC 3161** Time-Stamp Protocol
- **ETSI TS 119 182-1** JAdES · **ETSI EN 319 122** CAdES
- **FIPS 204** Module-Lattice Digital Signature Standard (ML-DSA)
- `draft-ietf-cose-dilithium`, `draft-ietf-lamps-dilithium-certificates` (PQC bindings)
- **DSSE** — Dead Simple Signing Envelope (Sigstore / in-toto)

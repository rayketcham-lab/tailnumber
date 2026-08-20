# Doing it by hand — OpenSSL, the envelope, and offline verification

TailNumber's whole claim is that a signature it produces is **yours**, not hostage to the service
that made it: standard algorithms, a standard X.509 chain, a JSON wrapper you can read with `jq`.
The only way to show that is to do it by hand.

This page has two halves:

- **[Part 1 — Verify an envelope](#part-1--verify-an-envelope-by-hand)**: take a `.sig.json`, an
  artifact and a root certificate, and answer "is this authentic?" with nothing but `openssl` and
  `jq`. No network, no service, no TailNumber code.
- **[Part 2 — Sign one yourself](#part-2--sign-one-yourself-no-service-at-all)**: build a CA, issue
  a code-signing certificate, sign a digest and write an envelope — entirely with OpenSSL, so you
  can see there is nothing proprietary inside.

> **Every command and every output below was executed.** Transcripts are copied from real runs
> against the live service (Part 1) and a throwaway local CA (Part 2), not written from memory.

**You need:** `openssl` 3.x, `jq`, and `base64`/`xxd` from coreutils.
ML-DSA additionally needs **OpenSSL 3.5+** — see [Post-quantum](#post-quantum-ml-dsa).

---

## The envelope, field by field

A TailNumber envelope is a small JSON document. Nothing in it is secret, and nothing in it is
required to be trusted — every field is checkable against the artifact and the certificate.

```console
$ jq '{version, signed_at, service, profile, context}' firmware.bin.sig.json
{
  "version": 1,
  "signed_at": "2026-08-20T21:54:34Z",
  "service": "tailnumber/1.2.0",
  "profile": "digest-as-message",
  "context": "TailNumber/v1"
}

$ jq '.key' firmware.bin.sig.json
{
  "label": "tailnumber-codesign-01",
  "sig_alg": "rsa3072-pss-sha256",
  "spki_sha256": "2a6ceb31e4d4d2c370d6c1c66598c5fd0cfb35aa71deacf4256df3c0b8b3afc4"
}

$ jq '{alg: .digest.alg, value: .digest.value}' firmware.bin.sig.json
{
  "alg": "sha256",
  "value": "b64:D8bfwjtjo9cAWs1I4SnpZqCSYwcMAKYEoLeCgJI5T7U="
}
```

| Field | What it is | Why you care |
|---|---|---|
| `digest.value` | The bytes that were actually signed, base64 after a `b64:` tag | Compare against your own hash of the file — this is what binds signature to artifact |
| `digest.alg` | `sha256` / `sha384` / `sha512` | Tells you which `openssl dgst` to run |
| `signature` | The raw signature, `b64:`-tagged | Fed to `openssl pkeyutl -verify` |
| `key.sig_alg` | Algorithm **and** parameters, e.g. `rsa3072-pss-sha256` | Selects your verify flags — [table below](#algorithm-reference) |
| `key.label` | The signer's name | Must equal the certificate's CN, or the envelope points at a different key than it claims |
| `key.spki_sha256` | SHA-256 of the DER public key | Binds the envelope to one specific key, not merely one name |
| `cert_chain[]` | `[signer, issuing CA]` as PEM | Establishes *who*; the root you supply yourself |
| `profile` | `digest-as-message` | The digest bytes are the message passed to the signature algorithm — **not** re-hashed |
| `artifact` | Optional caller metadata (filename, version…) | Informational; never trusted |

> **On `profile`.** `digest-as-message` means the signer treated the digest as the message. That is
> why you verify with `-in digest.bin` and not with `-rawin` over the file. It is stated in the
> envelope so a verifier never has to guess.

---

## Part 1 — Verify an envelope by hand

Four questions, in order. Answering only some of them is the usual way people fool themselves:

| # | Question | Command | Skipping it means |
|---|---|---|---|
| 1 | Does the file match the digest that was signed? | `dgst` + `cmp` | A valid signature over *some other file* |
| 2 | Is the signature genuine over that digest? | `pkeyutl -verify` | Nothing is proven at all |
| 3 | Does the signer chain to a root I trust? | `verify` | **Anyone** can self-sign the same name |
| 4 | Is the certificate the key the envelope names? | CN + SPKI | A real cert for a *different* key passes step 3 |

### Step 1 — Unpack

```console
$ jq -r '.cert_chain[0]' firmware.bin.sig.json > signer.crt
$ jq -r '.cert_chain[1]' firmware.bin.sig.json > issuing.crt
$ jq -r '.signature' firmware.bin.sig.json | sed 's/^b64://' | base64 -d > sig.bin
$ wc -c < sig.bin
384

$ openssl x509 -in signer.crt -pubkey -noout > signer.pub
$ head -2 signer.pub
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAtN8pOen7dQz2HORMWNvl
```

Note the shape of that: 384 bytes is exactly a 3072-bit RSA signature, and the public key came out
of the **certificate**, not out of the envelope. The envelope never supplies a bare key.

### Step 2 — Does the file match the digest that was signed?

Hash the artifact yourself. Do not take `digest.value` on faith — that is the entire point.

```console
$ openssl dgst -sha256 -binary firmware.bin > mine.bin
$ xxd -p -c32 mine.bin
0fc6dfc23b63a3d7005acd48e129e966a09263070c00a604a0b7828092394fb5

$ jq -r '.digest.value' firmware.bin.sig.json | sed 's/^b64://' | base64 -d | xxd -p -c32
0fc6dfc23b63a3d7005acd48e129e966a09263070c00a604a0b7828092394fb5

$ jq -r '.digest.value' firmware.bin.sig.json | sed 's/^b64://' | base64 -d | cmp - mine.bin && echo MATCH
MATCH
```

### Step 3 — Is the signature genuine over exactly that digest?

```console
$ openssl pkeyutl -verify -pubin -inkey signer.pub -in mine.bin -sigfile sig.bin \
    -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest
Signature Verified Successfully
```

The flags must match `key.sig_alg` exactly — see the [algorithm reference](#algorithm-reference).
Wrong flags produce a *failure on a perfectly good signature*, which is the most common way to
scare yourself for no reason. [What that looks like](#2-right-signature-wrong-flags).

### Step 4 — Does the signer chain to a root you trust?

Steps 2 and 3 prove the envelope is internally consistent. They say **nothing** about who signed it:
anyone can generate a key, self-sign a certificate carrying the same name, and produce an envelope
that passes both. This is the step that establishes identity.

```console
$ openssl verify -CAfile root.crt -untrusted issuing.crt signer.crt
signer.crt: OK
```

`root.crt` is your trust anchor. Fetch it **once** from `/api/v1/ca/root`, verify it out of band,
and keep it. From then on this check — and this whole page — needs no network at all.

### Step 5 — Is that certificate the key the envelope claims?

A certificate that chains correctly can still be the wrong certificate. Bind the envelope to it:

```console
$ openssl x509 -in signer.crt -noout -subject | sed -n 's/.*CN *= *//p'
tailnumber-codesign-01
$ jq -r '.key.label' firmware.bin.sig.json
tailnumber-codesign-01

$ openssl x509 -in signer.crt -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256
SHA2-256(stdin)= 2a6ceb31e4d4d2c370d6c1c66598c5fd0cfb35aa71deacf4256df3c0b8b3afc4
$ jq -r '.key.spki_sha256' firmware.bin.sig.json
2a6ceb31e4d4d2c370d6c1c66598c5fd0cfb35aa71deacf4256df3c0b8b3afc4
```

### Step 6 — Read what you just trusted

```console
$ openssl x509 -in signer.crt -noout -subject -issuer -dates -ext extendedKeyUsage
subject=DC = com, DC = rayketcham, OU = CodeSigning, CN = tailnumber-codesign-01
issuer=DC = com, DC = rayketcham, O = CAs, OU = CodeSigningCA, CN = Example Code Signing Issuing CA
notBefore=Jul 10 17:26:17 2026 GMT
notAfter=Jul 10 17:26:17 2076 GMT
X509v3 Extended Key Usage: critical
    Code Signing
```

`Code Signing` is marked **critical**: a verifier that understands EKU must refuse to accept this
certificate for TLS, email, or anything else.

---

## What failure actually looks like

A verification tool is only worth the failures it produces. All three transcripts below are real.

### 1. Tampered artifact

One byte appended, then re-hashed and re-verified against the original signature:

```console
$ printf 'X' >> tampered.bin
$ openssl dgst -sha256 -binary tampered.bin > bad.bin
$ openssl pkeyutl -verify -pubin -inkey signer.pub -in bad.bin -sigfile sig.bin \
    -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest
404787226E770000:error:02000068:rsa routines:RSA_verify_PKCS1_PSS_mgf1:bad signature:../crypto/rsa/rsa_pss.c:132:
404787226E770000:error:1C880004:Provider routines:rsa_verify:RSA lib:../providers/implementations/signature/rsa_sig.c:815:
Signature Verification Failure
```

Step 2 catches the same tamper earlier and more clearly — the digests simply differ.

### 2. Right signature, wrong flags

The identical, valid signature verified **without** the PSS options:

```console
$ openssl pkeyutl -verify -pubin -inkey signer.pub -in mine.bin -sigfile sig.bin
4037E65827780000:error:0200008A:rsa routines:RSA_padding_check_PKCS1_type_1:invalid padding:../crypto/rsa/rsa_pk1.c:79:
4037E65827780000:error:02000072:rsa routines:rsa_ossl_public_decrypt:padding check failed:../crypto/rsa/rsa_ossl.c:697:
4037E65827780000:error:1C880004:Provider routines:rsa_verify:RSA lib:../providers/implementations/signature/rsa_sig.c:833:
Signature Verification Failure
```

Note it says `PKCS1_type_1` — OpenSSL defaulted to PKCS#1 v1.5 padding for a PSS signature. **The
signature is fine; the command was wrong.** When verification fails, check `key.sig_alg` against
your flags before concluding anything.

### 3. Forged certificate, correct name

A self-signed certificate with the same CN — exactly what steps 2 and 3 alone would let through:

```console
$ openssl req -new -x509 -key evil.key -sha256 -days 365 -subj "/CN=tailnumber-codesign-01" -out evil.crt
$ openssl x509 -in evil.crt -noout -subject
subject=CN = tailnumber-codesign-01

$ openssl verify -CAfile root.crt -untrusted issuing.crt evil.crt
CN = tailnumber-codesign-01
error 18 at 0 depth lookup: self-signed certificate
error evil.crt: verification failed
```

The name was never the security boundary. The chain is.

---

## Part 2 — Sign one yourself, no service at all

Nothing above required TailNumber. Neither does producing an envelope in the first place.

### A. A CA and a signer

```console
$ openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out signer.key
$ openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out ca.key
$ openssl req -new -x509 -key ca.key -sha384 -days 7300 -subj '/O=Demo/CN=Demo Root CA' -out ca.crt
$ openssl req -new -key signer.key -subj '/O=Demo/CN=my-codesign-01' -out signer.csr
$ openssl x509 -req -in signer.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -sha384 -days 1095 -extfile ext.cnf -extensions leaf_ext -out signer.crt
Certificate request self-signature ok
subject=O = Demo, CN = my-codesign-01
```

with `ext.cnf`:

```ini
[leaf_ext]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
```

The CA key is **EC P-384** while the signer is **RSA-3072** — an issuer's algorithm is independent
of its subject's. That is how an EC certificate authority certifies a post-quantum ML-DSA signer.

### B. Hash, then sign the digest

```console
$ openssl dgst -sha256 -binary firmware.bin > digest.bin
$ xxd -p -c32 digest.bin
0fc6dfc23b63a3d7005acd48e129e966a09263070c00a604a0b7828092394fb5

$ openssl pkeyutl -sign -inkey signer.key -in digest.bin -out sig.bin \
    -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest
$ wc -c < sig.bin
384
```

The private key never saw `firmware.bin` — only its 32-byte digest. That is what "detached hash
signing" means, and why artifact size and classification are irrelevant.

### C. Assemble the envelope

```console
$ SPKI=$(openssl pkey -in signer.key -pubout -outform DER | openssl dgst -sha256 | awk '{print $NF}')
$ jq -n --arg spki "$SPKI" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg dig "b64:$(base64 -w0 < digest.bin)" --arg sig "b64:$(base64 -w0 < sig.bin)" \
     --arg leaf "$(cat signer.crt)" --arg ca "$(cat ca.crt)" \
     '{version:1, signed_at:$at,
       key:{label:"my-codesign-01", sig_alg:"rsa3072-pss-sha256", spki_sha256:$spki},
       digest:{alg:"sha256", value:$dig}, profile:"digest-as-message",
       signature:$sig, cert_chain:[$leaf,$ca]}' > firmware.bin.sig.json

$ jq '{version, key, digest, profile}' firmware.bin.sig.json
{
  "version": 1,
  "key": {
    "label": "my-codesign-01",
    "sig_alg": "rsa3072-pss-sha256",
    "spki_sha256": "755bda3d13d279fafb3ee867b13a050883cc980a72d26726dc41a997d4ec6803"
  },
  "digest": {
    "alg": "sha256",
    "value": "b64:D8bfwjtjo9cAWs1I4SnpZqCSYwcMAKYEoLeCgJI5T7U="
  },
  "profile": "digest-as-message"
}
```

### D. Verify it with Part 1

```console
$ openssl pkeyutl -verify -pubin -inkey v.pub -in v.dig -sigfile v.sig \
    -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest
Signature Verified Successfully
$ openssl verify -CAfile ca.crt v.crt
v.crt: OK
```

That envelope is the same shape as a service-issued one, and the service's own offline verifier
accepts it. **[`examples/openssl-detached-offline.sh`](../examples/openssl-detached-offline.sh)**
runs this entire section — CA, signer, sign, envelope, verify, tamper check — in one command, for
any of the five algorithm profiles.

---

## Algorithm reference

The signing and verifying flags are identical. Read `key.sig_alg` from the envelope, then use its row:

| `sig_alg` | digest | `pkeyutl` flags (sign **and** verify) |
|---|---|---|
| `rsa3072-pss-sha256` | sha256 | `-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest` |
| `rsa3072-pkcs1-sha256` | sha256 | `-pkeyopt digest:sha256` |
| `rsa4096-pss-sha384` | sha384 | `-pkeyopt digest:sha384 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest` |
| `rsa4096-pkcs1-sha384` | sha384 | `-pkeyopt digest:sha384` |
| `ecdsa-p384-sha384` | sha384 | *(none — the raw 48-byte digest is the input)* |
| `ml-dsa-65` | sha384 | `-rawin` |
| `ml-dsa-87` | sha512 | `-rawin` |

`rsa_pss_saltlen:auto` also verifies where `:digest` does. ECDSA genuinely takes no options:

```console
$ openssl pkeyutl -verify -pubin -inkey ec.pub -in d384.bin -sigfile ec.sig
Signature Verified Successfully
```

### Post-quantum: ML-DSA

ML-DSA needs **OpenSSL 3.5 or newer**. On an older build the failure is at key level, not signature
level, and looks like this:

```console
$ openssl version
OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)
$ openssl genpkey -algorithm ML-DSA-65 -out ml.key
Error initializing ML-DSA-65 context
40D70B17A77A0000:error:0308010C:digital envelope routines:inner_evp_generic_fetch:unsupported:...Algorithm (ML-DSA-65 : 0)...
```

With 3.5, `-rawin` is the whole difference — the digest bytes are handed to ML-DSA as the message:

```console
$ openssl version
OpenSSL 3.5.4 30 Sep 2025 (Library: OpenSSL 3.5.4 30 Sep 2025)
$ openssl pkeyutl -sign -inkey ml.key -in d384.bin -out ml.sig -rawin
$ wc -c < ml.sig
3309
$ openssl pkeyutl -verify -pubin -inkey ml.pub -in d384.bin -sigfile ml.sig -rawin
Signature Verified Successfully
```

3309 bytes versus RSA-3072's 384 — post-quantum signatures are large, which is a storage and
transport consideration, not a verification one.

> **HashML-DSA is not used.** The OpenSSL 3.5 CLI rejects `-digest` for ML-DSA
> (`-digest (prehash) is not supported with ML-DSA-87`), so envelopes use the `digest-as-message`
> profile throughout. The profile is recorded in the envelope so this stays unambiguous if it
> ever changes.

---

## Gotchas

- **`openssl pkey` takes `-in`; `openssl pkeyutl` takes `-inkey`.** Mixing them up gives
  `Extra (unknown) options`, an empty result, and — if you piped it into a hash — a confident
  comparison against the SHA-256 of nothing.
- **`base64` differs across platforms.** macOS wants `base64 -D` to decode and has no `-w0`; use
  `openssl base64 -d` / `openssl base64 -A` for portability.
- **`-pubin` needs a public key, `-pubout` produces one.** `openssl x509 -pubkey -noout` extracts
  the public key from a certificate; there is no private key anywhere in this document's Part 1.
- **Redirect, don't retype.** Certificates and signatures round-trip through `jq -r` exactly; typing
  or line-wrapping PEM by hand is the most common self-inflicted "invalid signature".
- **A chain check without a CN/SPKI check is not identity.** See
  [step 5](#step-5--is-that-certificate-the-key-the-envelope-claims).

## The short version

Everything on this page, as one command:

```console
$ TN_TRUST_ROOT=root.crt tailnumber-verify-offline.sh firmware.bin.sig.json firmware.bin
SIGNATURE VALID  [rsa3072-pss-sha256 / sha256 / chains to root.crt / artifact matches]

$ TN_TRUST_ROOT=root.crt tailnumber-verify-offline.sh firmware.bin.sig.json tampered.bin
DIGEST MISMATCH — artifact modified (or wrong file)
```

Use it for convenience — but the point of this page is that you never have to.

## See also

- **[`examples/openssl-detached-offline.sh`](../examples/openssl-detached-offline.sh)** — Part 2,
  automated, all five algorithm profiles
- **[TESTING.md](TESTING.md)** — the same checks against a running service
- **[INTEROP.md](INTEROP.md)** — mapping this envelope onto JWS, COSE and CMS
- **[HSM.md](HSM.md)** — where the private key lives and how to check that claim

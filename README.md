<div align="center">

# ✈️ Project TailNumber

### detached Hash-Signing as a Service — **dHSaaS**

[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)
&nbsp;![PQC](https://img.shields.io/badge/PQC-ML--DSA%20·%20FIPS%20204-8957e5.svg)
&nbsp;![HSM](https://img.shields.io/badge/keys-PKCS%2311%20non--extractable-1f6feb.svg)
&nbsp;![OpenSSL](https://img.shields.io/badge/OpenSSL-3.5-66cc00.svg)
&nbsp;![Status](https://img.shields.io/badge/demo-retired-6e7781.svg)

*Sign a hash, not the file. Verify offline. Survive the platform.*

</div>

> **⚠️ Proprietary — closed source.** Public overview only; the implementation is private and
> **not distributed**. No rights are granted to use, copy, or deploy — see [`LICENSE`](LICENSE).
> © 2026 rayketcham-lab.

> **The public demo has been retired.** The service, dashboard and API endpoints are offline and
> the URLs no longer resolve. Commands and outputs in these docs were captured while it ran; they
> are kept as a record of behaviour, not as something you can execute today.

---

## What it is

A **detached** signing service. A client sends a **digest** — never the file — and gets back a
portable envelope (`.sig.json`: signature, X.509 chain, digest, provenance). Because only the hash
travels, artifact size and classification are irrelevant. Every envelope verifies **offline** with
nothing but OpenSSL and the trust root.

Post-quantum first: **ML-DSA-65 / ML-DSA-87** (FIPS 204), with classical **RSA-3072/4096** and
**ECDSA P-384**, and hybrid (classical + PQC over one digest) for the transition.

Private keys are generated inside a **PKCS#11 token** and are non-extractable — export is refused,
the public half is served freely. Validated against SoftHSM2; the production target is a
**Thales TCT Luna T-Series (T3000)**, FIPS 140-2 Level 3. Moving between them is a config change,
not a code change. → [`docs/HSM.md`](docs/HSM.md)

## Key rotation and CA lifetime — how the chain survives 50 years

An aircraft's software has to stay verifiable for the life of the airframe. The instinct is to
issue a long certificate and be done, but **a 50-year certificate is not 50 years of trust**. Over
that horizon you will migrate algorithms (RSA today, ML-DSA tomorrow), replace HSMs and the people
holding their credentials, and possibly respond to a compromise. Each of those needs a *new key*
while everything already signed stays verifiable. So the thing that actually carries the chain is
**rotation** — certificate lifetime just buys the window to rotate inside.

### The rule

**Rotation mints the next key. It never destroys the previous one.**

Every predecessor stays resolvable: its certificate still chains, verification still answers for
it, and audit entries still name a key that exists. Deleting the outgoing key and reusing its
label — which is what this service used to do — silently rewrites what every historical envelope
and audit record points at. Retiring a key is a separate, deliberate act: stop signing with it,
let its certificate lapse, keep it resolvable.

| Kind | Pattern | Example |
|---|---|---|
| Signing key | `<name>-<seq>` | `tailnumber-codesign-01` → `-02` |
| CA generation | `<name>-g<N>` | `tn-root-g1` → `tn-root-g2` |

Padding is preserved so labels sort lexically, widening only on overflow (`-99` → `-100`); an
unsuffixed label is generation 1 by convention. `POST /api/v1/keys/{label}/rotate` reads the
predecessor's algorithm, issues the next label in the series from the same CA, and returns it with
`predecessor` and `predecessor_retained: true` — refusing with **409** rather than overwriting a
successor that already exists.

### Why the tiers are sized 55 / 54 / 50

| Certificate | Valid for | Why |
|---|---|---|
| **Root CA** | **55 years** | Must outlive every issuing CA it certifies |
| **Issuing CA** | **54 years** | Must outlive every signer it issues |
| **Signer** | **50 years** | The platform lifetime the signature has to cover |

The nesting is the point, not the specific numbers. A signature produced in year 49 under a signer
valid to year 50 is only checkable if the issuing CA is still valid past that, and the root past
*that* — a chain is only as long-lived as its shortest remaining link. The gaps between tiers are
the **overlap window**: room to stand up the next generation and migrate onto it *before* the
current one lapses, rather than at the moment it does.

50-year validity also crosses the RFC 5280 year-2049 boundary where `UTCTime` gives way to
`GeneralizedTime` — a transition that trips a lot of certificate tooling. The pinned OpenSSL 3.5
and the offline verifier handle post-2049 dates correctly.

### Rolling the CA — designed, not implemented

This is where the 50 years are actually won or lost, and **the shipped code does not do it**:
`ensure_ca()` creates a single unversioned root and issuing pair with no notion of generations.
The intended sequence:

1. Generate `tn-root-g2` in the HSM. `tn-root-g1` stays — it must keep validating everything
   issued under it.
2. Issue `tn-issuing-g2` from the new root.
3. **Overlap.** Both generations live at once: new signers come from `g2`, existing signers keep
   chaining to `g1` until they rotate.
4. Publish a **link certificate** — the new root's public key signed by the old root — so a
   verifier that only trusts `g1` can still build a path to `g2`. Skip this and every relying
   party in the field breaks the day you cut over.
5. Retire `g1` only once nothing still depends on it, which on a 50-year platform is *long* after
   `g2` exists.

### The other half: expiry ≠ invalid

Rotation keeps *issuance* alive. It does not by itself keep a decades-old signature *verifiable*,
because a verifier evaluating trust at check time will reject an expired signer even though the
signature was sound when it was made. The standard answer is a long-term validation profile: an
RFC 3161 signature timestamp proving the signature existed while the certificate was valid,
embedded revocation data so verification never needs a long-dead responder, and periodic archival
timestamps to outrun algorithm decay (JAdES-B-LTA / CAdES-LTA).

**TailNumber ships the sized trust chain, not LTV.** Those attributes are a documented roadmap
item, not shipped behaviour — see [`docs/INTEROP.md`](docs/INTEROP.md) §7 and
[`docs/ROTATION.md`](docs/ROTATION.md).

## How it works

```mermaid
flowchart LR
  F["File / firmware"] -->|"stays local"| H["Hash"]
  H -->|"only the digest is sent"| S["Sign in the token<br/>key non-extractable"]
  S --> E["Envelope (.sig.json)"]
  E --> V["Verify — offline, OpenSSL only"]
  R["Root CA · 55y"] --> I["Issuing CA · 54y"] --> L["Signer · 50y"]
  I -. certifies .-> S
  V -. chains to .-> R
```

## Documentation

[Key rotation](docs/ROTATION.md) · [HSM & Luna](docs/HSM.md) · [API commands](docs/API-COMMANDS.md) ·
[Formats & interoperability](docs/INTEROP.md) · [Tech stack](docs/STACK.md) · [Testing](docs/TESTING.md)

Runnable examples are in [`examples/`](examples/). They target a TailNumber endpoint via
`TN_ENDPOINT` and need a running instance — the retired public demo is no longer one.

## Honest limitations

- **No live instance.** Nothing here can be exercised against the public demo any more.
- **SoftHSM is not hardware.** Keys were non-extractable via PKCS#11, but its token DB is a file on
  disk — software protection. No FIPS validation, no M-of-N quorum, no tamper response.
- **No post-quantum on the retired demo.** ML-DSA is implemented and covered by the acceptance
  suite, but SoftHSM has no PQC mechanisms; ML-DSA and hybrid need Luna firmware 7.15.0.
- **CA generation rollover is unbuilt** (above) — signing-key rotation is implemented; generational
  roots, the overlap period and the link certificate are design only.
- **No long-term validation.** No RFC 3161 timestamps, no embedded revocation data, no archival
  re-timestamping — so a strict verifier will reject a signature once its signer certificate
  expires, even though the signature itself is sound.
- **Luna steps are written against the SDK docs**, not exercised against hardware.

## License

**Proprietary — © 2026 rayketcham-lab. All rights reserved.** No use, redistribution,
modification, or deployment without written permission. See [`LICENSE`](LICENSE).

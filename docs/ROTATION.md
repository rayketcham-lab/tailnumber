# Key rotation

A signature has to outlive the artifact it protects. Over 50 years the keys will
turn over several times, so rotation — not key lifetime — is what actually carries
the trust chain that far.

## The rule

**Rotation mints the next key. It never destroys the previous one.**

Every predecessor stays resolvable: its certificate still chains, `/verify` still
answers for it, and audit entries still name a key that exists. A rotation that
reused the label and deleted the old key would silently change what every
historical envelope and audit record pointed at.

Retiring a key is a separate, deliberate act — stop signing with it, let its
certificate lapse. Never a side effect of rotating.

## Nomenclature

| Kind | Pattern | Example |
|---|---|---|
| Signing key | `<name>-<seq>` | `tailnumber-codesign-01` → `-02` |
| CA generation | `<name>-g<N>` | `tn-root-g1` → `tn-root-g2` |

Zero-padding is preserved so labels sort lexically, and widens only on overflow
(`-99` → `-100`). A label with no suffix is generation 1 by convention; its
successor is `-02`.

`successor_label()` in `service/app/api_ext.py` implements this, guarded by
`tests/test_api.py`.

## Rotating a signing key

```
POST /api/v1/keys/{label}/rotate      # admin
```

Reads the predecessor's algorithm, mints the next label in the series from the
same CA, and returns it with `predecessor` and `predecessor_retained: true`.
Refuses with **409** if the successor already exists, rather than overwriting it.

New signing moves to the successor. The predecessor keeps verifying everything it
already signed.

## Rotating the CA — **design, not implemented**

The signing CA is where the 50 years are really won or lost, and the code does not
do this yet. What it takes:

1. Generate `tn-root-g2` inside the HSM. `tn-root-g1` stays — it must keep
   validating everything issued under it.
2. Issue `tn-issuing-g2` from the new root.
3. **Overlap.** Both generations are valid at once. New signers are issued from
   `g2`; existing signers keep chaining to `g1` until they rotate.
4. Publish a **link certificate** — the new root's public key signed by the old
   root — so a verifier that only trusts `g1` can still build a path to `g2`.
   Without it, every existing relying party breaks the day you cut over.
5. Retire `g1` only once nothing in the field still needs it, which for a 50-year
   platform means *long* after `g2` exists.

**Not built:** `ensure_ca()` creates a single unversioned root and issuing pair
(`tn-root`, `tn-issuing`) and has no notion of generations, overlap or link
certificates. Treat the above as the intended design, not a description of
shipped behaviour.

## Lifetimes — 20 / 10 / 3

| Certificate | Valid for | Renewed | Over a 50-year platform |
|---|---|---|---|
| Root CA | **20 years** | ~year 10 | ~3 generations |
| Issuing CA | **10 years** | ~year 5 | ~5 generations, two per root |
| Signer | **3 years** | on demand | ~17 generations |

Set in `service/app/signer/luna.py` (`ROOT_VALIDITY_YEARS`, `ISSUING_VALIDITY_YEARS`,
`LEAF_VALIDITY_YEARS`) and `tools/gen-signing-ca.sh` (`CA_ROOT_YEARS`, `CA_ISS_YEARS`).

No certificate spans the platform life; the sequence of generations does. Renewing
each tier around mid-life is what creates the overlap — the successor is established
and trusted well before the predecessor lapses, so a cutover is never a cliff.

A leaf cannot outlive its issuer, so signer certificates sit well inside the issuing
CA: issuance stops far enough before the CA lapses that the certificates expire first.

An earlier build used 55 / 54 / 50 years so that one chain covered the whole platform
life. That is the wrong shape. It makes the root effectively un-rotatable — you never
practise the procedure you will eventually depend on — and stakes fifty years on a
single key and algorithm, which is the opposite of what post-quantum migration
requires.

## Expiry is not invalidity

Rotation keeps issuance alive; it does not keep an old signature verifiable. On a
20/10/3 cycle a signature routinely outlives its whole chain — signed in year 2,
checked in year 30, with an expired signer, an expired issuing CA and possibly a
retired root. The signature is still cryptographically sound; a verifier that
evaluates trust at check time will still reject it.

Long, over-provisioned certificates used to hide this. They no longer do, which makes
long-term validation **required, not optional**: an RFC 3161 timestamp proving the
signature existed while its certificate was valid, embedded revocation data so
verification never needs a long-dead responder, and periodic archival timestamps
(JAdES-B-LTA / CAdES-LTA). None of it is implemented — see `docs/INTEROP.md` §7.

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

Sizing already assumes this: Root 55y / Issuing 54y / Signer 50y gives each tier
room to outlive the one below and leaves an overlap window to rotate inside.

**Not built:** `ensure_ca()` creates a single unversioned root and issuing pair
(`tn-root`, `tn-issuing`) and has no notion of generations, overlap or link
certificates. Treat the above as the intended design, not a description of
shipped behaviour.

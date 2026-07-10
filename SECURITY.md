# Security Policy

Project TailNumber is a signing service; please treat it accordingly.

## Reporting

The implementation is maintained privately. Report suspected vulnerabilities
**privately** to the maintainers — do **not** open a public issue. Include
reproduction steps and impact; you will get an acknowledgement and a remediation
timeline.

## Posture

- **Keys** are generated inside a PKCS#11 token and are **non-extractable** — today a
  **SoftHSM2 software-HSM** (the validation stand-in the live demo runs on); production is a
  **Thales TCT Luna T-Series (T3000)** HSM (FIPS 140-2 L3) under M-of-N quorum, the same code path.
- **Every operation** is written to a hash-chained, tamper-evident audit log.
- **Signatures** are independently verifiable offline against the published root.
- Dev-mode is intentionally open; production uses reverse-proxy identity
  (mTLS / SSO / LDAP) plus dashboard Basic auth.

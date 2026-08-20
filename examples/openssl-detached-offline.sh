#!/usr/bin/env bash
# openssl-detached-offline.sh [--alg ALG] [--file PATH]
#
# The whole detached hash-signing lifecycle with NOTHING but OpenSSL.
# No TailNumber service, no API call, no network, no PKCS#11, no root.
#
# This is the primitive the service wraps. It builds a throwaway two-tier CA,
# issues a code-signing certificate, signs a DIGEST (never the file), writes a
# TailNumber-shaped envelope, and then verifies that envelope offline — digest
# match, signature, and chain to the root — before proving it rejects a tampered
# byte. Everything lands in a temp dir that is removed on exit.
#
#   ./openssl-detached-offline.sh                        # rsa3072-pss-sha256
#   ./openssl-detached-offline.sh --alg ecdsa-p384-sha384
#   ./openssl-detached-offline.sh --alg ml-dsa-65 --file firmware.bin
#
#   ALG:  rsa3072-pss-sha256 | rsa3072-pkcs1-sha256 | ecdsa-p384-sha384
#         ml-dsa-65 | ml-dsa-87          (ML-DSA needs OpenSSL 3.5+)
#   env:  OSSL=/path/to/openssl   TN_WORK=/keep/it/here
#
# Needs: openssl, jq. Exit 0 = every check passed.
set -euo pipefail

OSSL=${OSSL:-openssl}
ALG=rsa3072-pss-sha256
ARTIFACT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --alg)  ALG=${2:?--alg needs a value}; shift 2 ;;
        --file) ARTIFACT=${2:?--file needs a path}; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
    esac
done

for t in "$OSSL" jq; do command -v "$t" >/dev/null 2>&1 || { echo "need: $t" >&2; exit 3; }; done

# --- algorithm profile -------------------------------------------------------
# keygen args, digest, and the pkeyutl args used for BOTH sign and verify.
# The sign and verify flags must agree exactly; that is the whole trick.
case $ALG in
    rsa3072-pss-sha256)
        KEYGEN=(-algorithm RSA -pkeyopt rsa_keygen_bits:3072); DALG=sha256
        PKARGS=(-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest) ;;
    rsa3072-pkcs1-sha256)
        KEYGEN=(-algorithm RSA -pkeyopt rsa_keygen_bits:3072); DALG=sha256
        PKARGS=(-pkeyopt digest:sha256) ;;
    ecdsa-p384-sha384)
        KEYGEN=(-algorithm EC -pkeyopt ec_paramgen_curve:P-384); DALG=sha384
        PKARGS=() ;;                       # the raw 48-byte digest IS the input
    ml-dsa-65)
        KEYGEN=(-algorithm ML-DSA-65); DALG=sha384; PKARGS=(-rawin) ;;
    ml-dsa-87)
        KEYGEN=(-algorithm ML-DSA-87); DALG=sha512; PKARGS=(-rawin) ;;
    *) echo "unknown --alg: $ALG (try --help)" >&2; exit 2 ;;
esac

if [[ $ALG == ml-dsa-* ]] && ! "$OSSL" genpkey -algorithm "${ALG^^}" -out /dev/null 2>/dev/null; then
    echo "$($OSSL version) cannot generate ${ALG^^} — ML-DSA needs OpenSSL 3.5+." >&2
    echo "Point OSSL at a 3.5 build:  OSSL=/opt/openssl-3.5/bin/openssl $0 --alg $ALG" >&2
    exit 3
fi

W=${TN_WORK:-$(mktemp -d)}; mkdir -p "$W"
[[ -n ${TN_WORK:-} ]] || trap 'rm -rf "$W"' EXIT

G=$'\033[1;32m'; R=$'\033[1;31m'; C=$'\033[1;36m'; D=$'\033[2m'; Z=$'\033[0m'
pass=0; fail=0
step(){ printf '\n%s▸ %s%s\n' "$C" "$*" "$Z"; }
show(){ printf '%s     $ %s%s\n' "$D" "$*" "$Z"; }
ok()  { printf '       %s✓%s %s\n' "$G" "$Z" "$*"; pass=$((pass+1)); }
no()  { printf '       %s✗%s %s\n' "$R" "$Z" "$*"; fail=$((fail+1)); }
chk() { if [[ $1 == 0 ]]; then ok "$2"; else no "$2"; fi; }

echo "TailNumber — detached hash-signing with OpenSSL only ($ALG, $DALG)"
echo "$(cd "$(dirname "$OSSL")" 2>/dev/null && pwd || echo)${D} $("$OSSL" version)${Z}"

# --- 1. a throwaway two-tier CA ---------------------------------------------
# Same shape as the real trust chain: EC P-384 root -> issuing CA -> signer.
# The issuer's key type is independent of the signer's, which is how an EC CA
# certifies an ML-DSA signer.
step "1/8  Build a throwaway CA (EC P-384 root -> issuing CA)"
cat > "$W/ca.cnf" <<'CNF'
[ca_ext]
basicConstraints = critical,CA:true
keyUsage         = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[sub_ext]
basicConstraints = critical,CA:true,pathlen:0
keyUsage         = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[leaf_ext]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
show "openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out root.key"
"$OSSL" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$W/root.key" 2>/dev/null
"$OSSL" req -new -x509 -key "$W/root.key" -sha384 -days 7300 \
    -subj "/O=OpenSSL Only Demo/CN=Demo Root CA" \
    -extensions ca_ext -config "$W/ca.cnf" -out "$W/root.crt" 2>/dev/null
"$OSSL" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$W/issuing.key" 2>/dev/null
"$OSSL" req -new -key "$W/issuing.key" -subj "/O=OpenSSL Only Demo/CN=Demo Issuing CA" -out "$W/issuing.csr" 2>/dev/null
"$OSSL" x509 -req -in "$W/issuing.csr" -CA "$W/root.crt" -CAkey "$W/root.key" -CAcreateserial \
    -sha384 -days 3650 -extfile "$W/ca.cnf" -extensions sub_ext -out "$W/issuing.crt" 2>/dev/null
chk $? "root + issuing CA created"

# --- 2. the signer -----------------------------------------------------------
step "2/8  Generate the signing key and issue its code-signing certificate"
LABEL=demo-codesign-01
show "openssl genpkey ${KEYGEN[*]} -out signer.key"
"$OSSL" genpkey "${KEYGEN[@]}" -out "$W/signer.key" 2>/dev/null
"$OSSL" req -new -key "$W/signer.key" -subj "/O=OpenSSL Only Demo/CN=$LABEL" -out "$W/signer.csr" 2>/dev/null
"$OSSL" x509 -req -in "$W/signer.csr" -CA "$W/issuing.crt" -CAkey "$W/issuing.key" -CAcreateserial \
    -sha384 -days 1095 -extfile "$W/ca.cnf" -extensions leaf_ext -out "$W/signer.crt" 2>/dev/null
chk $? "signer certificate issued (EKU codeSigning)"
"$OSSL" x509 -in "$W/signer.crt" -noout -subject | sed 's/^/       /'

# --- 3. hash ----------------------------------------------------------------
step "3/8  Hash the artifact — the digest is the ONLY thing that gets signed"
if [[ -n $ARTIFACT ]]; then
    [[ -f $ARTIFACT ]] || { echo "no such file: $ARTIFACT" >&2; exit 3; }
    cp "$ARTIFACT" "$W/artifact.bin"
else
    printf 'firmware image v1 — signed detached, hash only\n' > "$W/artifact.bin"
fi
show "openssl dgst -$DALG -binary artifact.bin > digest.bin"
"$OSSL" dgst -"$DALG" -binary "$W/artifact.bin" > "$W/digest.bin"
ok "$DALG = $("$OSSL" dgst -"$DALG" "$W/artifact.bin" | awk '{print $NF}') ($(wc -c <"$W/digest.bin") bytes)"

# --- 4. sign the digest ------------------------------------------------------
step "4/8  Sign the DIGEST, detached — the key never sees the file"
show "openssl pkeyutl -sign -inkey signer.key -in digest.bin -out sig.bin ${PKARGS[*]}"
"$OSSL" pkeyutl -sign -inkey "$W/signer.key" -in "$W/digest.bin" -out "$W/sig.bin" "${PKARGS[@]}"
chk $? "signature produced ($(wc -c <"$W/sig.bin") bytes)"

# --- 5. envelope -------------------------------------------------------------
# Same field shape as a service-issued envelope, so the same verifiers read it.
step "5/8  Write the detached envelope (.sig.json)"
SPKI=$("$OSSL" pkey -in "$W/signer.key" -pubout -outform DER 2>/dev/null | "$OSSL" dgst -sha256 | awk '{print $NF}')
jq -n --arg alg "$ALG" --arg dalg "$DALG" --arg label "$LABEL" --arg spki "$SPKI" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg dig "b64:$(base64 -w0 < "$W/digest.bin")" \
      --arg sig "b64:$(base64 -w0 < "$W/sig.bin")" \
      --arg leaf "$(cat "$W/signer.crt")" --arg iss "$(cat "$W/issuing.crt")" \
   '{version:1, signed_at:$at, service:"openssl-detached-offline.sh (no service involved)",
     key:{label:$label, sig_alg:$alg, spki_sha256:$spki},
     digest:{alg:$dalg, value:$dig}, profile:"digest-as-message", context:"TailNumber/v1",
     signature:$sig, cert_chain:[$leaf,$iss], artifact:{}}' > "$W/artifact.bin.sig.json"
chk $? "artifact.bin.sig.json ($(wc -c <"$W/artifact.bin.sig.json") bytes)"

# =============================================================================
#  VERIFY — from here on, pretend you only have the artifact, the envelope and
#  the root certificate. Nothing below contacts anything.
# =============================================================================
step "6/8  Verify offline (1/3) — the file still hashes to the signed digest"
jq -r '.digest.value' "$W/artifact.bin.sig.json" | sed 's/^b64://' | base64 -d > "$W/claimed.bin"
"$OSSL" dgst -"$DALG" -binary "$W/artifact.bin" > "$W/recomputed.bin"
show "openssl dgst -$DALG -binary artifact.bin | cmp - <(jq -r .digest.value ... | base64 -d)"
cmp -s "$W/claimed.bin" "$W/recomputed.bin"; chk $? "artifact matches the digest that was signed"

step "7/8  Verify offline (2/3) — the signature is genuine over exactly that digest"
jq -r '.cert_chain[0]' "$W/artifact.bin.sig.json" > "$W/v_leaf.crt"
jq -r '.cert_chain[1]' "$W/artifact.bin.sig.json" > "$W/v_iss.crt"
jq -r '.signature' "$W/artifact.bin.sig.json" | sed 's/^b64://' | base64 -d > "$W/v_sig.bin"
"$OSSL" x509 -in "$W/v_leaf.crt" -pubkey -noout > "$W/v_pub.pem"
show "openssl pkeyutl -verify -pubin -inkey signer.pub -in digest.bin -sigfile sig.bin ${PKARGS[*]}"
"$OSSL" pkeyutl -verify -pubin -inkey "$W/v_pub.pem" -in "$W/recomputed.bin" \
        -sigfile "$W/v_sig.bin" "${PKARGS[@]}" >/dev/null 2>&1
chk $? "signature verified with the public half only"

step "8/8  Verify offline (3/3) — the signer chains to the root you trust"
show "openssl verify -CAfile root.crt -untrusted issuing.crt signer.crt"
"$OSSL" verify -CAfile "$W/root.crt" -untrusted "$W/v_iss.crt" "$W/v_leaf.crt" >/dev/null 2>&1
chk $? "chains to the trusted root"
# The envelope names a key; the certificate must be that key, or a valid cert
# for some OTHER key would sail through the chain check above.
CN=$("$OSSL" x509 -in "$W/v_leaf.crt" -noout -subject | sed -n 's/.*CN *= *//p' | sed 's/[,/].*//;s/ *$//')
[[ $CN == "$(jq -r '.key.label' "$W/artifact.bin.sig.json")" ]]; chk $? "certificate CN matches the envelope's key label"
GOT=$("$OSSL" pkey -pubin -in "$W/v_pub.pem" -outform DER | "$OSSL" dgst -sha256 | awk '{print $NF}')
[[ $GOT == "$(jq -r '.key.spki_sha256' "$W/artifact.bin.sig.json")" ]]; chk $? "public key matches the envelope's SPKI hash"

# --- tamper ------------------------------------------------------------------
step "Tamper check — flip one byte and confirm every layer refuses"
printf 'X' >> "$W/artifact.bin"
"$OSSL" dgst -"$DALG" -binary "$W/artifact.bin" > "$W/tampered.bin"
cmp -s "$W/claimed.bin" "$W/tampered.bin" && no "digest still matches (BAD)" || ok "digest no longer matches the envelope"
if "$OSSL" pkeyutl -verify -pubin -inkey "$W/v_pub.pem" -in "$W/tampered.bin" \
      -sigfile "$W/v_sig.bin" "${PKARGS[@]}" >/dev/null 2>&1; then
    no "tampered digest still verified (BAD)"
else
    ok "signature refuses the tampered digest"
fi

printf '\n'
if [[ $fail == 0 ]]; then
    printf '%s════ %s ok · 0 failed — detached signing and offline verification, no service ════%s\n' "$G" "$pass" "$Z"
else
    printf '%s════ %s ok · %s FAILED ════%s\n' "$R" "$pass" "$fail" "$Z"; exit 1
fi
[[ -n ${TN_WORK:-} ]] && echo "artifacts kept in $W"
exit 0

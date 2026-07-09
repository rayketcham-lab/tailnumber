#!/usr/bin/env bash
# tailnumber-api-roundtrip.sh [FILE]
# Sign AND verify entirely through the API (no WebUI), then INDEPENDENTLY re-verify
# the same envelope with raw OpenSSL and COMPARE the two verdicts — proving the
# service's /verify agrees with plain OpenSSL. SHA-256 + the RSA-3072 signer by
# default; override with TN_KEY_LABEL / TN_SIG_ALG. Needs: bash, curl, jq, openssl.
set -euo pipefail

ENDPOINT=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-legacy-rsa-01}
SIG_ALG=${TN_SIG_ALG:-rsa3072-pss-sha256}
# prefer the pinned OpenSSL 3.5 (handles ML-DSA); else whatever is on PATH
if [[ -x /opt/openssl-3.5/bin/openssl ]]; then
    OSSL=/opt/openssl-3.5/bin/openssl
    export LD_LIBRARY_PATH=/opt/openssl-3.5/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
else OSSL=${OSSL:-openssl}; fi
command -v jq >/dev/null || { echo "this script needs jq" >&2; exit 1; }

step(){ printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

# sig_alg -> digest + the pkeyutl VERIFY flags (PSS verifies with saltlen:auto)
case "$SIG_ALG" in
    rsa3072-pss-sha256)   DALG=sha256; VARGS="-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto" ;;
    rsa3072-pkcs1-sha256) DALG=sha256; VARGS="-pkeyopt digest:sha256" ;;
    rsa4096-pss-sha384)   DALG=sha384; VARGS="-pkeyopt digest:sha384 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto" ;;
    rsa4096-pkcs1-sha384) DALG=sha384; VARGS="-pkeyopt digest:sha384" ;;
    ecdsa-p384-sha384)    DALG=sha384; VARGS="" ;;
    ml-dsa-65)            DALG=sha384; VARGS="-rawin" ;;   # needs OpenSSL 3.5
    ml-dsa-87)            DALG=sha512; VARGS="-rawin" ;;   # needs OpenSSL 3.5
    *) echo "unknown sig_alg: $SIG_ALG" >&2; exit 1 ;;
esac

src=${1:-}
if [[ -z "$src" ]]; then src=$(mktemp); echo "hello from tailnumber @ $(date -u +%FT%TZ)" >"$src"; echo "(no FILE — signing a demo message: $src)"; fi
WORK=${TN_WORK:-$(mktemp -d)}; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

step "1  Hash the artifact locally ($DALG) — only the digest is sent"
hex=$("$OSSL" dgst -"$DALG" "$src" | awk '{print $NF}')
echo "   $DALG = $hex"

step "2  SIGN via the API   POST $ENDPOINT/sign"
req=$(jq -nc --arg k "$KEY" --arg a "$SIG_ALG" --arg d "$DALG" --arg g "$DALG=$hex" \
      '{key_label:$k, sig_alg:$a, digest_alg:$d, digest:$g}')
envelope=$(curl -fsS -H 'content-type: application/json' -d "$req" "$ENDPOINT/sign")
echo "   -> envelope for key=$(jq -r .key.label <<<"$envelope")  sig_alg=$(jq -r .key.sig_alg <<<"$envelope")"

step "3  VERIFY via the API   POST $ENDPOINT/verify"
vreq=$(jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' <<<"$envelope")
api_res=$(curl -fsS -H 'content-type: application/json' -d "$vreq" "$ENDPOINT/verify")
api_valid=$(jq -r '.valid' <<<"$api_res")
echo "   -> API says: valid=$api_valid"

step "4  INDEPENDENT OpenSSL verify (offline, straight from the envelope)"
jq -r '.digest.value'           <<<"$envelope" | sed 's/^b64://' | base64 -d >"$WORK/digest.bin"
jq -r '.signature'              <<<"$envelope" | sed 's/^b64://' | base64 -d >"$WORK/sig.bin"
jq -r '.cert_chain[0]'          <<<"$envelope" >"$WORK/leaf.crt"
jq -r '.cert_chain[1] // empty' <<<"$envelope" >"$WORK/issuing.crt"
"$OSSL" x509 -in "$WORK/leaf.crt" -pubkey -noout >"$WORK/pub.pem"
echo "   \$ openssl pkeyutl -verify -pubin -inkey pub.pem -in digest.bin -sigfile sig.bin $VARGS"
# shellcheck disable=SC2086
if "$OSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -in "$WORK/digest.bin" -sigfile "$WORK/sig.bin" $VARGS >/dev/null 2>&1
then ossl_valid=true;  echo "   -> OpenSSL says: Signature Verified Successfully"
else ossl_valid=false; echo "   -> OpenSSL says: Signature Verification Failure"; fi

step "5  Chain the certificate to the TailNumber root (GET $ENDPOINT/ca/root)"
if curl -fsS "$ENDPOINT/ca/root" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
    curl -fsS "$ENDPOINT/ca/root" >"$WORK/root.crt"
    if [[ -s "$WORK/issuing.crt" ]]; then
        "$OSSL" verify -CAfile "$WORK/root.crt" -untrusted "$WORK/issuing.crt" "$WORK/leaf.crt" | sed 's/^/   /'
    else "$OSSL" verify -CAfile "$WORK/root.crt" "$WORK/leaf.crt" | sed 's/^/   /'; fi
else echo "   (couldn't fetch the CA root — skipping the chain check)"; fi

step "6  COMPARE — API verdict vs raw OpenSSL"
if [[ "$api_valid" == "$ossl_valid" ]]; then
    printf '   \033[1;32m✓ MATCH\033[0m  API valid=%s  ==  OpenSSL valid=%s  — the service agrees with plain OpenSSL.\n' "$api_valid" "$ossl_valid"
else
    printf '   \033[1;31m✗ MISMATCH\033[0m  API valid=%s  !=  OpenSSL valid=%s\n' "$api_valid" "$ossl_valid"; exit 2
fi

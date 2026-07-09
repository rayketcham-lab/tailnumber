#!/usr/bin/env bash
# tailnumber-api-roundtrip.sh [FILE]
# Sign AND verify entirely through the API (no WebUI), INSTANTLY re-verify the same
# envelope with raw OpenSSL, and COMPARE the two verdicts — pointing out exactly
# what each artifact is along the way. SHA-256 + the RSA-3072 signer by default;
# override with TN_KEY_LABEL / TN_SIG_ALG. Needs: bash, curl, jq, openssl.
set -euo pipefail

ENDPOINT=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-legacy-rsa-01}
SIG_ALG=${TN_SIG_ALG:-rsa3072-pss-sha256}
if [[ -x /opt/openssl-3.5/bin/openssl ]]; then          # pinned build handles ML-DSA
    OSSL=/opt/openssl-3.5/bin/openssl
    export LD_LIBRARY_PATH=/opt/openssl-3.5/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
else OSSL=${OSSL:-openssl}; fi
command -v jq >/dev/null || { echo "this script needs jq" >&2; exit 1; }

C=$'\033[1;36m'; Y=$'\033[0;33m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Z=$'\033[0m'
step(){ printf '\n%s▸ %s%s\n' "$C" "$*" "$Z"; }
look(){ printf '   %s↳ %s%s\n' "$Y" "$*" "$Z"; }        # <- "what you're looking at"
show(){ printf '   $ %s\n' "$*"; }

# sig_alg -> digest + the pkeyutl VERIFY flags (PSS verifies with saltlen:auto)
case "$SIG_ALG" in
    rsa3072-pss-sha256)   DALG=sha256; VARGS="-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto"; PAD="RSA-3072, PSS padding, SHA-256" ;;
    rsa3072-pkcs1-sha256) DALG=sha256; VARGS="-pkeyopt digest:sha256"; PAD="RSA-3072, PKCS#1 v1.5, SHA-256" ;;
    rsa4096-pss-sha384)   DALG=sha384; VARGS="-pkeyopt digest:sha384 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto"; PAD="RSA-4096, PSS padding, SHA-384" ;;
    rsa4096-pkcs1-sha384) DALG=sha384; VARGS="-pkeyopt digest:sha384"; PAD="RSA-4096, PKCS#1 v1.5, SHA-384" ;;
    ecdsa-p384-sha384)    DALG=sha384; VARGS=""; PAD="ECDSA P-384, SHA-384" ;;
    ml-dsa-65)            DALG=sha384; VARGS="-rawin"; PAD="ML-DSA-65 (post-quantum), one-shot" ;;
    ml-dsa-87)            DALG=sha512; VARGS="-rawin"; PAD="ML-DSA-87 (post-quantum), one-shot" ;;
    *) echo "unknown sig_alg: $SIG_ALG" >&2; exit 1 ;;
esac

src=${1:-}
if [[ -z "$src" ]]; then src=$(mktemp); echo "hello from tailnumber @ $(date -u +%FT%TZ)" >"$src"; echo "(no FILE — signing a demo message: $src)"; fi
WORK=${TN_WORK:-$(mktemp -d)}; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT

step "1  Hash the artifact locally ($DALG)"
hex=$("$OSSL" dgst -"$DALG" "$src" | awk '{print $NF}')
printf '   %s(%s)\n   = %s\n' "$DALG" "$src" "$hex"
look "THE DIGEST — a $(( ${#hex} / 2 ))-byte fingerprint of your file. THIS is what gets signed; the file itself never leaves your machine."

step "2  SIGN via the API   POST $ENDPOINT/sign"
req=$(jq -nc --arg k "$KEY" --arg a "$SIG_ALG" --arg d "$DALG" --arg g "$DALG=$hex" \
      '{key_label:$k, sig_alg:$a, digest_alg:$d, digest:$g}')
look "we send ONLY the digest — $req"
envelope=$(curl -fsS -H 'content-type: application/json' -d "$req" "$ENDPOINT/sign")
sigb64=$(jq -r '.signature' <<<"$envelope"); sigb64=${sigb64#b64:}
look "SIGNING uses the PRIVATE key — held in the service / HSM, it never leaves."
look "THE SIGNATURE it produced: ${sigb64:0:44}…  (alg = $(jq -r .key.sig_alg <<<"$envelope") → $PAD)"
look "the envelope also carries the signer's CERTIFICATE CHAIN ($(jq '.cert_chain|length' <<<"$envelope") certs: leaf + issuing CA)."

step "3  VERIFY via the API   POST $ENDPOINT/verify"
vreq=$(jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' <<<"$envelope")
api_res=$(curl -fsS -H 'content-type: application/json' -d "$vreq" "$ENDPOINT/verify")
api_valid=$(jq -r '.valid' <<<"$api_res")
look "the SERVICE's own verdict: valid=$api_valid. Don't take its word — step 4 checks it with raw OpenSSL."

step "4  INSTANTLY re-verify with OpenSSL (offline, straight from the envelope)"
jq -r '.digest.value'           <<<"$envelope" | sed 's/^b64://' | base64 -d >"$WORK/digest.bin"
jq -r '.signature'              <<<"$envelope" | sed 's/^b64://' | base64 -d >"$WORK/sig.bin"
jq -r '.cert_chain[0]'          <<<"$envelope" >"$WORK/leaf.crt"
jq -r '.cert_chain[1] // empty' <<<"$envelope" >"$WORK/issuing.crt"
"$OSSL" x509 -in "$WORK/leaf.crt" -pubkey -noout >"$WORK/pub.pem"
look "VERIFYING uses the PUBLIC key — pulled from the certificate in the envelope (the shareable half)."
look "digest.bin = $(wc -c <"$WORK/digest.bin") bytes · sig.bin = $(wc -c <"$WORK/sig.bin") bytes · pub.pem from leaf.crt"
show "openssl pkeyutl -verify -pubin -inkey pub.pem -in digest.bin -sigfile sig.bin $VARGS"
look "this asks: was sig.bin made by the private key matching pub.pem, over EXACTLY digest.bin?  (the -pkeyopt flags = the padding scheme)"
# shellcheck disable=SC2086
if "$OSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -in "$WORK/digest.bin" -sigfile "$WORK/sig.bin" $VARGS >/dev/null 2>&1
then ossl_valid=true;  printf '   %s→ Signature Verified Successfully%s\n' "$G" "$Z"
else ossl_valid=false; printf '   %s→ Signature Verification Failure%s\n'   "$R" "$Z"; fi

step "5  Chain the certificate to the TailNumber root   GET $ENDPOINT/ca/root"
if curl -fsS "$ENDPOINT/ca/root" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
    curl -fsS "$ENDPOINT/ca/root" >"$WORK/root.crt"
    look "this proves the signer's cert is TRUSTED (chains leaf → issuing CA → root), not just any self-made key."
    if [[ -s "$WORK/issuing.crt" ]]; then
        "$OSSL" verify -CAfile "$WORK/root.crt" -untrusted "$WORK/issuing.crt" "$WORK/leaf.crt" | sed "s/^/   /"
    else "$OSSL" verify -CAfile "$WORK/root.crt" "$WORK/leaf.crt" | sed "s/^/   /"; fi
else echo "   (couldn't fetch the CA root — skipping the chain check)"; fi

step "6  COMPARE — API verdict vs raw OpenSSL"
look "service said valid=$api_valid  ·  independent OpenSSL said valid=$ossl_valid"
if [[ "$api_valid" == "$ossl_valid" ]]; then
    printf '   %s✓ MATCH%s — the API and plain OpenSSL agree. The service is not just *claiming* validity; the crypto checks out independently.\n' "$G" "$Z"
else
    printf '   %s✗ MISMATCH%s — API=%s but OpenSSL=%s. Do NOT trust this envelope.\n' "$R" "$Z" "$api_valid" "$ossl_valid"; exit 2
fi

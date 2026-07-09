#!/usr/bin/env bash
# tailnumber-api-roundtrip.sh [FILE]
#
# A hands-on self-test for EXTERNAL TESTERS. It signs a file with the live
# TailNumber service, then INDEPENDENTLY re-verifies the result with *your* OpenSSL
# and compares the two verdicts — so you can confirm the service works and isn't
# just claiming validity. Only a hash is sent; your file never leaves this machine.
#
# Walks you through it one step at a time (Enter to advance). Runs straight through
# when piped or with TN_NOPAUSE=1. SHA-256 + an RSA key by default; try
# TN_SIG_ALG=ml-dsa-65 for post-quantum. Needs: bash, curl, jq, openssl.
set -euo pipefail

ENDPOINT=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-legacy-rsa-01}
SIG_ALG=${TN_SIG_ALG:-rsa3072-pss-sha256}
if [[ -x /opt/openssl-3.5/bin/openssl ]]; then          # pinned build handles ML-DSA
    OSSL=/opt/openssl-3.5/bin/openssl
    export LD_LIBRARY_PATH=/opt/openssl-3.5/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
else OSSL=${OSSL:-openssl}; fi

# --- prerequisites ---------------------------------------------------------
need=(); command -v curl >/dev/null || need+=(curl); command -v jq >/dev/null || need+=(jq)
[[ -x "$OSSL" ]] || command -v "$OSSL" >/dev/null 2>&1 || need+=(openssl)
if ((${#need[@]})); then
    printf 'This tester needs: %s\n  Ubuntu/Debian:  sudo apt install %s\n  macOS (brew):   brew install %s\n' \
        "${need[*]}" "${need[*]}" "${need[*]}" >&2; exit 1
fi

C=$'\033[1;36m'; Y=$'\033[0;33m'; G=$'\033[1;32m'; R=$'\033[1;31m'; B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'
rule(){ printf '%s  ────────────────────────────────────────────────────────────%s\n' "$D" "$Z"; }
step(){ printf '\n %s%s%s\n' "$C$B" "$*" "$Z"; }
look(){ printf '    %s↳ %s%s\n' "$Y" "$*" "$Z"; }
show(){ printf '    %s$ %s%s\n' "$D" "$*" "$Z"; }
pause(){ [[ -t 0 && -z ${TN_NOPAUSE:-} ]] || return 0; printf '\n    %s— press Enter to continue —%s' "$D" "$Z"; read -r _ || true; }

case "$SIG_ALG" in
    rsa3072-pss-sha256)   DALG=sha256; VARGS="-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto"; PAD="RSA-3072 · PSS · SHA-256" ;;
    rsa3072-pkcs1-sha256) DALG=sha256; VARGS="-pkeyopt digest:sha256"; PAD="RSA-3072 · PKCS#1 v1.5 · SHA-256" ;;
    rsa4096-pss-sha384)   DALG=sha384; VARGS="-pkeyopt digest:sha384 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto"; PAD="RSA-4096 · PSS · SHA-384" ;;
    rsa4096-pkcs1-sha384) DALG=sha384; VARGS="-pkeyopt digest:sha384"; PAD="RSA-4096 · PKCS#1 v1.5 · SHA-384" ;;
    ecdsa-p384-sha384)    DALG=sha384; VARGS=""; PAD="ECDSA P-384 · SHA-384" ;;
    ml-dsa-65)            DALG=sha384; VARGS="-rawin"; PAD="ML-DSA-65 (post-quantum)" ;;
    ml-dsa-87)            DALG=sha512; VARGS="-rawin"; PAD="ML-DSA-87 (post-quantum)" ;;
    *) echo "unknown sig_alg: $SIG_ALG" >&2; exit 1 ;;
esac
# ML-DSA verification needs OpenSSL 3.5+; note it rather than fail the compare
OSSL_CAN=yes
[[ "$SIG_ALG" == ml-dsa* ]] && ! "$OSSL" list -signature-algorithms 2>/dev/null | grep -qiE 'ml-?dsa' && OSSL_CAN=no

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=${1:-}; note=""
if [[ -z "$src" && -f "$HERE/test-hash-based-signing.txt" ]]; then src="$HERE/test-hash-based-signing.txt"; note="  ${D}(the sample file in this folder)${Z}"; fi
if [[ -z "$src" ]]; then src=$(mktemp); echo "hello from tailnumber @ $(date -u +%FT%TZ)" >"$src"; note="  ${D}(a demo message — pass a FILE to sign your own)${Z}"; fi
WORK=${TN_WORK:-$(mktemp -d)}; mkdir -p "$WORK"; trap 'rm -rf "$WORK"' EXIT
OUT=${TN_OUT:-./tailnumber-envelope.sig.json}

printf '\n %s✈  TailNumber%s — sign a file and prove it is legit, end to end\n' "$C$B" "$Z"
printf ' %s   a hands-on test: sign via the API, then independently verify with YOUR OpenSSL%s\n' "$D" "$Z"
rule
printf '    %sfile   %s %s%s\n' "$B" "$Z" "$src" "$note"
printf '    %skey    %s %s   %s%s%s\n' "$B" "$Z" "$KEY" "$D" "$PAD" "$Z"
printf '    %sservice%s %s\n' "$B" "$Z" "$ENDPOINT"
pause

step "① 🔒  Hash the file on your machine"
hex=$("$OSSL" dgst -"$DALG" "$src" | awk '{print $NF}')
printf '    %s = %s\n' "$DALG" "$hex"
look "this is THE DIGEST — a $(( ${#hex} / 2 ))-byte fingerprint of your file. Only this is sent; the file itself stays with you."
pause

step "② 🖊  Sign it — over the API"
req=$(jq -nc --arg k "$KEY" --arg a "$SIG_ALG" --arg d "$DALG" --arg g "$DALG=$hex" '{key_label:$k, sig_alg:$a, digest_alg:$d, digest:$g}')
show "POST $ENDPOINT/sign   (body = just the digest)"
envelope=$(curl -fsS -H 'content-type: application/json' -d "$req" "$ENDPOINT/sign")
printf '%s\n' "$envelope" >"$OUT" 2>/dev/null || OUT=""
sigb64=$(jq -r '.signature' <<<"$envelope"); sigb64=${sigb64#b64:}
look "SIGNING uses the PRIVATE key — it lives in the service / HSM and never leaves."
look "here is the SIGNATURE it made: ${sigb64:0:40}…"
look "the reply carries the signer's CERTIFICATE ($(jq '.cert_chain|length' <<<"$envelope") certs: the signer + its issuing CA)."
[[ -n "$OUT" ]] && look "saved the full envelope to ${B}$OUT${Z}${Y} — you can inspect it or paste it into the web dashboard's Verify pane."
pause

step "③ 🔎  Verify it — over the API"
vreq=$(jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' <<<"$envelope")
api_valid=$(curl -fsS -H 'content-type: application/json' -d "$vreq" "$ENDPOINT/verify" | jq -r '.valid')
printf '    %s↳ the service says: %svalid = %s%s.  But let us not just take its word for it…%s\n' "$Y" "$B" "$api_valid" "$Y" "$Z"
pause

step "④ 🔬  Re-verify it yourself — plain OpenSSL, offline"
jq -r '.digest.value'           <<<"$envelope" | sed 's/^b64://' | base64 -d >"$WORK/digest.bin"
jq -r '.signature'              <<<"$envelope" | sed 's/^b64://' | base64 -d >"$WORK/sig.bin"
jq -r '.cert_chain[0]'          <<<"$envelope" >"$WORK/leaf.crt"
jq -r '.cert_chain[1] // empty' <<<"$envelope" >"$WORK/issuing.crt"
"$OSSL" x509 -in "$WORK/leaf.crt" -pubkey -noout >"$WORK/pub.pem"
look "VERIFYING uses the PUBLIC key — taken from the certificate in the envelope (safe to share)."
if [[ "$OSSL_CAN" == no ]]; then
    ossl_valid=skip
    look "$(printf '%syour OpenSSL does not support ML-DSA (needs 3.5+), so the independent check is skipped this run. Try an RSA/ECDSA key, or install OpenSSL 3.5.%s' "$R" "$Y")"
else
    show "openssl pkeyutl -verify -pubin -inkey pub.pem -in digest.bin -sigfile sig.bin $VARGS"
    look "in plain words: was this signature made by the private key that matches this public key, over exactly this digest?"
    # shellcheck disable=SC2086
    if "$OSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -in "$WORK/digest.bin" -sigfile "$WORK/sig.bin" $VARGS >/dev/null 2>&1
    then ossl_valid=true;  printf '    %s✓ Signature Verified Successfully%s\n' "$G" "$Z"
    else ossl_valid=false; printf '    %s✗ Signature Verification Failure%s\n'   "$R" "$Z"; fi
fi
pause

step "⑤ 🧪  Tamper check — change the file, confirm it gets REJECTED"
if [[ "$OSSL_CAN" == no ]]; then
    tamper_ok=skip; look "(skipped — the OpenSSL verify above did not run)"
else
    cp "$src" "$WORK/tampered"; printf 'X' >>"$WORK/tampered"           # append ONE byte to a copy
    "$OSSL" dgst -"$DALG" -binary "$WORK/tampered" >"$WORK/tdigest.bin"
    look "we appended ONE byte to a copy of your file and re-hashed it — same signature, changed content."
    show "openssl pkeyutl -verify -pubin -inkey pub.pem -in tampered-digest.bin -sigfile sig.bin $VARGS"
    # shellcheck disable=SC2086
    if "$OSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -in "$WORK/tdigest.bin" -sigfile "$WORK/sig.bin" $VARGS >/dev/null 2>&1
    then tamper_ok=false; printf '    %s✗ Uh oh — the tampered copy still verified (it should NOT)%s\n' "$R" "$Z"
    else tamper_ok=true;  printf '    %s✓ Rejected: Signature Verification Failure — exactly right!%s\n' "$G" "$Z"; fi
    look "THIS is what makes 'valid' mean something: the signature is bound to the exact bytes. Change anything → it fails."
fi
pause

step "⑥ 🔗  Is the signer trusted? — chain the cert to the root"
chain_ok=skip
if curl -fsS "$ENDPOINT/ca/root" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
    curl -fsS "$ENDPOINT/ca/root" >"$WORK/root.crt"
    look "this walks signer → issuing CA → root. 'OK' means it chains to the TailNumber root — not just some key someone made up."
    if [[ -s "$WORK/issuing.crt" ]]; then out=$("$OSSL" verify -CAfile "$WORK/root.crt" -untrusted "$WORK/issuing.crt" "$WORK/leaf.crt" 2>&1)
    else out=$("$OSSL" verify -CAfile "$WORK/root.crt" "$WORK/leaf.crt" 2>&1); fi
    printf '    %s\n' "$out"; [[ "$out" == *": OK" ]] && chain_ok=yes || chain_ok=no
else look "(couldn't reach the CA root — skipping this check)"; fi
pause

step "⑦ 🔬  Byte-for-byte — the exact bytes, and the key"
env_hex=$(od -An -tx1 "$WORK/digest.bin" | tr -d ' \n')
look "the RAW DIGEST — the exact bytes the service signed:"
printf '      you hashed the file  : %s%s%s\n' "$D" "$hex" "$Z"
printf '      the envelope carries : %s%s%s\n' "$D" "$env_hex" "$Z"
[[ "$hex" == "$env_hex" ]] \
    && printf '      %s✓ byte-for-byte identical%s — the service signed exactly the hash of your file.\n' "$G" "$Z" \
    || printf '      %s✗ they differ!%s\n' "$R" "$Z"
if [[ "$SIG_ALG" == rsa* ]]; then
    cm=$("$OSSL" x509 -in "$WORK/leaf.crt" -noout -modulus 2>/dev/null | "$OSSL" md5 2>/dev/null | awk '{print $NF}')
    pm=$("$OSSL" rsa -pubin -in "$WORK/pub.pem" -noout -modulus 2>/dev/null | "$OSSL" md5 2>/dev/null | awk '{print $NF}')
    echo
    look "MODULUS check — the RSA modulus (N) proves the cert and the key are the same pair:"
    printf '      cert   modulus (md5): %s%s%s\n' "$D" "$cm" "$Z"
    printf '      pubkey modulus (md5): %s%s%s\n' "$D" "$pm" "$Z"
    [[ -n "$cm" && "$cm" == "$pm" ]] \
        && printf '      %s✓ same modulus%s — the key that verified is the key inside the certificate.\n' "$G" "$Z" \
        || printf '      %s✗ modulus mismatch%s\n' "$R" "$Z"
fi
cert_spki=$("$OSSL" x509 -in "$WORK/leaf.crt" -pubkey -noout 2>/dev/null | "$OSSL" pkey -pubin -outform DER 2>/dev/null | "$OSSL" dgst -sha256 2>/dev/null | awk '{print $NF}')
env_spki=$(jq -r '.key.spki_sha256' <<<"$envelope")
echo
look "KEY FINGERPRINT — does the cert match the key the envelope names?"
printf '      envelope claims spki : %s%s%s\n' "$D" "$env_spki" "$Z"
printf '      cert actual     spki : %s%s%s\n' "$D" "${cert_spki:-<needs OpenSSL 3.5 for this key>}" "$Z"
[[ -n "$cert_spki" && "$cert_spki" == "$env_spki" ]] \
    && printf '      %s✓ match%s — the certificate is exactly the key the envelope claims.\n' "$G" "$Z" \
    || printf '      %s(fingerprint not computed here — skipping)%s\n' "$D" "$Z"
pause

step "⑧ ⚖️  Side by side — the service vs. your own OpenSSL"
ov=$([[ $ossl_valid == true ]] && printf '%s✓ valid%s' "$G" "$Z" || { [[ $ossl_valid == skip ]] && printf '%sskipped%s' "$D" "$Z" || printf '%s✗ FAILED%s' "$R" "$Z"; })
tv=$([[ $tamper_ok == true ]] && printf '%s✓ rejected%s' "$G" "$Z" || { [[ $tamper_ok == skip ]] && printf '%sskipped%s' "$D" "$Z" || printf '%s✗ passed!%s' "$R" "$Z"; })
cv=$([[ $chain_ok == yes ]] && printf '%s✓ to root%s' "$G" "$Z" || { [[ $chain_ok == skip ]] && printf '%sskipped%s' "$D" "$Z" || printf '%s✗ fail%s' "$R" "$Z"; })
RL="------------------------------------"
echo
printf '   %s%-36s%s %s│%s %s%s%s\n' "$B$C" "THE SERVICE  (via the API)" "$Z" "$D" "$Z" "$B$C" "YOU  (independent OpenSSL)" "$Z"
printf '   %-36s %s│%s %s\n' "$RL" "$D" "$Z" "$RL"
printf '   %-36s %s│%s %s\n' "signs with the PRIVATE key (HSM)"  "$D" "$Z" "verifies with the PUBLIC key"
printf '   %-36s %s│%s %s\n' "POST /sign   -> envelope"          "$D" "$Z" "envelope carries the sig + cert"
printf '   %-36s %s│%s pkeyutl -verify -> %s\n' "POST /verify -> valid = $api_valid" "$D" "$Z" "$ov"
printf '   %-36s %s│%s tampered copy   -> %s\n' "(the service only signs+verifies)"  "$D" "$Z" "$tv"
printf '   %-36s %s│%s verify -CAfile  -> %s\n' "issued the signer certificate"      "$D" "$Z" "$cv"
echo
rule
if [[ "$ossl_valid" == skip ]]; then
    printf ' %s✓ Service says valid=%s.%s Independent OpenSSL check skipped (needs OpenSSL 3.5 for ML-DSA).\n\n' "$G$B" "$api_valid" "$Z"
elif [[ "$api_valid" == "$ossl_valid" && "$api_valid" == true ]]; then
    printf ' %s🏁  MATCH — all good!%s The service said valid, YOUR OpenSSL agreed' "$G$B" "$Z"
    [[ "$tamper_ok" == true ]] && printf ', a tampered copy was REJECTED'
    [[ "$chain_ok" == yes ]] && printf ', and the cert chains to the root'
    printf '.\n %s   You did not have to trust the service — you checked it yourself. 🎉%s\n\n' "$D" "$Z"
elif [[ "$api_valid" == "$ossl_valid" ]]; then
    printf ' %s✓ MATCH%s — the service and OpenSSL both say NOT valid (as expected for this input).\n\n' "$G" "$Z"
else
    printf ' %s⚠  MISMATCH:%s service said valid=%s, YOUR OpenSSL said valid=%s — do NOT trust this envelope.\n\n' "$R$B" "$Z" "$api_valid" "$ossl_valid"; exit 2
fi

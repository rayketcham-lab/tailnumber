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
sigsz=$(printf '%s' "$sigb64" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
look "SIGNING uses the PRIVATE key — it lives in the service / HSM and never leaves."
look "here is the SIGNATURE it produced — ${B}${sigsz} bytes${Z}${Y}: ${sigb64:0:32}…${sigb64: -12}"
look "the reply also carries the signer's CERTIFICATE ($(jq '.cert_chain|length' <<<"$envelope") certs — the signer + its issuing CA), so a verifier needs nothing from you but this envelope."
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

step "⑥ 🔗  Who signed it, and is the signer trusted? — the cert + chain to root"
subj=$("$OSSL" x509 -in "$WORK/leaf.crt" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
iss=$( "$OSSL" x509 -in "$WORK/leaf.crt" -noout -issuer  -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')
ser=$( "$OSSL" x509 -in "$WORK/leaf.crt" -noout -serial  2>/dev/null | sed 's/^serial=//')
nb=$(  "$OSSL" x509 -in "$WORK/leaf.crt" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')
na=$(  "$OSSL" x509 -in "$WORK/leaf.crt" -noout -enddate   2>/dev/null | sed 's/^notAfter=//')
yb=$(date -d "$nb" +%Y 2>/dev/null || true); ya=$(date -d "$na" +%Y 2>/dev/null || true)
span=""; [[ -n "$yb" && -n "$ya" ]] && span="   (a $((ya-yb))-year certificate — built to outlive the airframe)"
look "the certificate that produced this signature — WHO vouches for it:"
printf '      subject : %s%s%s\n' "$B" "${subj:-?}" "$Z"
printf '      issuer  : %s%s%s\n' "$D" "${iss:-?}" "$Z"
printf '      serial  : %s%s%s\n' "$D" "${ser:-?}" "$Z"
printf '      valid   : %s%s  ->  %s%s%s\n' "$D" "$nb" "$na" "$span" "$Z"
chain_ok=skip
if curl -fsS "$ENDPOINT/ca/root" 2>/dev/null | grep -q 'BEGIN CERTIFICATE'; then
    curl -fsS "$ENDPOINT/ca/root" >"$WORK/root.crt"
    echo
    look "now CHAIN it: signer → issuing CA → root. 'OK' means it ties back to the TailNumber root — not just some key someone made up."
    if [[ -s "$WORK/issuing.crt" ]]; then out=$("$OSSL" verify -CAfile "$WORK/root.crt" -untrusted "$WORK/issuing.crt" "$WORK/leaf.crt" 2>&1)
    else out=$("$OSSL" verify -CAfile "$WORK/root.crt" "$WORK/leaf.crt" 2>&1); fi
    printf '    %s\n' "$out"; [[ "$out" == *": OK" ]] && chain_ok=yes || chain_ok=no
else look "(couldn't reach the CA root — skipping the chain check)"; fi
pause

step "⑦ 🔬  Byte-for-byte — the exact bytes, and the key"
env_hex=$(od -An -tx1 "$WORK/digest.bin" | tr -d ' \n')
look "the RAW DIGEST — the exact bytes the service signed:"
printf '      you hashed the file  : %s%s%s\n' "$D" "$hex" "$Z"
printf '      the envelope carries : %s%s%s\n' "$D" "$env_hex" "$Z"
[[ "$hex" == "$env_hex" ]] \
    && printf '      %s✓ byte-for-byte identical%s — the service signed exactly the hash of your file.\n' "$G" "$Z" \
    || printf '      %s✗ they differ!%s\n' "$R" "$Z"
# the public-key MATERIAL — RSA's "modulus" is just its name for the raw key value;
# every algorithm has an analog: ECDSA's public point Q, ML-DSA's raw lattice key.
matfp(){ awk '/pub:|Modulus:/{f=1;next} /^[A-Za-z]/{f=0} f' | tr -dc '0-9a-f' | "$OSSL" md5 2>/dev/null | awk '{print $NF}'; }
case "$SIG_ALG" in
    rsa*)    matname="modulus (N)"      ; matwhat="the RSA modulus N" ;;
    ecdsa*)  matname="public point (Q)" ; matwhat="the public curve point Q" ;;
    ml-dsa*) matname="raw public key"   ; matwhat="the raw lattice public key" ;;
    *)       matname="public key"       ; matwhat="the raw public key" ;;
esac
if [[ "$SIG_ALG" == rsa* ]]; then
    mat=$("$OSSL" x509 -in "$WORK/leaf.crt" -noout -modulus 2>/dev/null | "$OSSL" md5 2>/dev/null | awk '{print $NF}')
else
    mat=$("$OSSL" pkey -pubin -in "$WORK/pub.pem" -text_pub -noout 2>/dev/null | matfp)
fi
echo
look "PUBLIC KEY MATERIAL — the raw value of the signer key ($matwhat):"
printf '      %-18s : %s%s%s\n' "algorithm" "$D" "$SIG_ALG" "$Z"
printf '      %-18s : %s%s%s  %s(md5)%s\n' "$matname" "$D" "${mat:-<needs OpenSSL 3.5 for this key>}" "$Z" "$D" "$Z"
printf '      %s↳ RSA calls it the modulus; ECDSA the point Q; ML-DSA the raw key — same idea, different shape.%s\n' "$D" "$Z"
if [[ "$SIG_ALG" == rsa* ]]; then
    pm=$("$OSSL" rsa -pubin -in "$WORK/pub.pem" -noout -modulus 2>/dev/null | "$OSSL" md5 2>/dev/null | awk '{print $NF}')
    echo
    look "MODULUS cross-check — the classic 'openssl x509 -modulus | md5' cert-vs-key proof:"
    printf '      cert   modulus (md5): %s%s%s\n' "$D" "$mat" "$Z"
    printf '      pubkey modulus (md5): %s%s%s\n' "$D" "$pm" "$Z"
    [[ -n "$pm" && "$mat" == "$pm" ]] \
        && printf '      %s✓ same modulus%s — the key that verified is the key inside the certificate.\n' "$G" "$Z" \
        || printf '      %s✗ modulus mismatch%s\n' "$R" "$Z"
fi
# the algorithm-agnostic version of the modulus check — works for RSA, ECDSA, ML-DSA alike
cert_spki=$("$OSSL" x509 -in "$WORK/leaf.crt" -pubkey -noout 2>/dev/null | "$OSSL" pkey -pubin -outform DER 2>/dev/null | "$OSSL" dgst -sha256 2>/dev/null | awk '{print $NF}')
env_spki=$(jq -r '.key.spki_sha256' <<<"$envelope")
echo
look "SAME-KEY PROOF (every algorithm) — does the cert match the key the envelope names?"
printf '      envelope claims spki : %s%s%s\n' "$D" "$env_spki" "$Z"
printf '      cert actual     spki : %s%s%s\n' "$D" "${cert_spki:-<needs OpenSSL 3.5 for this key>}" "$Z"
[[ -n "$cert_spki" && "$cert_spki" == "$env_spki" ]] \
    && printf '      %s✓ match%s — SPKI is a SHA-256 over exactly this key material: the modulus check, generalized.\n' "$G" "$Z" \
    || printf '      %s(fingerprint not computed here — skipping)%s\n' "$D" "$Z"
pause

step "⑧ ⚖️  Side by side — the service vs. your own OpenSSL, value for value"
# a real side-by-side: the ACTUAL value each side produced, lined up so you can eyeball the match —
# with the exact command that produced each one underneath, runnable against the files unpacked below.
sh(){ local h=${1:-}; [[ -n "$h" ]] && printf '%s...%s' "${h:0:10}" "${h: -6}" || printf '(n/a)'; }
srcname=$(basename "$src")
env_alg=$(jq -r '.key.sig_alg' <<<"$envelope")
dm=$([[ -n "$env_hex" && "$hex" == "$env_hex" ]] && printf '%s✓ identical%s' "$G" "$Z" || printf '%s✗ differ%s' "$R" "$Z")
km=$([[ -n "$cert_spki" && "$cert_spki" == "$env_spki" ]] && printf '%s✓ same key%s' "$G" "$Z" || printf '%s— n/a%s' "$D" "$Z")
if   [[ $ossl_valid == true ]]; then vm="${G}✓ agree${Z}";   vtext="Signature Verified"
elif [[ $ossl_valid == skip ]]; then vm="${D}— skipped${Z}"; vtext="(needs OpenSSL 3.5)"
else                                 vm="${R}✗ FAILED${Z}";  vtext="Verification FAILURE"; fi
cm2=$([[ $chain_ok == yes ]] && printf '%s✓ to root%s' "$G" "$Z" || { [[ $chain_ok == skip ]] && printf '%s— skipped%s' "$D" "$Z" || printf '%s✗ fail%s' "$R" "$Z"; })
tm=$([[ $tamper_ok == true ]] && printf '%s✓ rejected%s' "$G" "$Z" || { [[ $tamper_ok == skip ]] && printf '%s— skipped%s' "$D" "$Z" || printf '%s✗ leaked!%s' "$R" "$Z"; })
cap(){ printf '   %s%-38.38s%s %s│%s %s%s%s\n' "$D" "$1" "$Z" "$D" "$Z" "$D" "$2" "$Z"; }
val(){ printf '   %-38.38s %s│%s %s\n' "$1" "$D" "$Z" "$2"; }
cmd(){ printf '       %s└─ $ %s%s\n' "$D" "$1" "$Z"; }
barL=$(printf '─%.0s' {1..38}); barR=$(printf '─%.0s' {1..34})
chaincmd="openssl verify -CAfile root.crt leaf.crt"; [[ -s "$WORK/issuing.crt" ]] && chaincmd="openssl verify -CAfile root.crt -untrusted issuing.crt leaf.crt"
# unpack the envelope's parts next to the saved envelope, so every command below actually runs
if [[ -n "$OUT" ]] && PARTS="$(cd "$(dirname "$OUT")" && pwd)/tailnumber-parts" && mkdir -p "$PARTS" 2>/dev/null; then
    cp -f "$src" "$PARTS/$srcname" 2>/dev/null || true
    for f in digest.bin sig.bin pub.pem leaf.crt issuing.crt root.crt; do [[ -s "$WORK/$f" ]] && cp -f "$WORK/$f" "$PARTS/$f" 2>/dev/null || true; done
    [[ -s "$WORK/tdigest.bin" ]] && cp -f "$WORK/tdigest.bin" "$PARTS/tampered-digest.bin" 2>/dev/null || true
else PARTS=""; fi
echo
printf '   %s%-38.38s%s %s│%s %s%s%s\n' "$B$C" "THE SERVICE - what its API returned" "$Z" "$D" "$Z" "$B$C" "YOU - what your OpenSSL computed" "$Z"
printf '   %s%s │ %s%s\n' "$D" "$barL" "$barR" "$Z"
cap "digest it signed  (from the envelope)" "digest you hashed  (openssl dgst)"
val "  $(sh "$env_hex")" "  $(sh "$hex")   $dm"
cmd "openssl dgst -$DALG $srcname"
cap "verdict   POST /verify  ->" "verdict   openssl pkeyutl -verify  ->"
val "  { \"valid\": $api_valid }" "  $vtext   $vm"
cmd "openssl pkeyutl -verify -pubin -inkey pub.pem -in digest.bin -sigfile sig.bin $VARGS"
cap "signer key it names  (spki-256)" "signer key you re-derived  (spki-256)"
val "  $(sh "$env_spki")" "  $(sh "$cert_spki")   $km"
cmd "openssl x509 -in leaf.crt -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256"
cap "algorithm  (envelope.key.sig_alg)" "params you handed OpenSSL"
val "  $env_alg" "  $PAD   ${G}✓ match${Z}"
cmd "openssl x509 -in leaf.crt -noout -text        # shows the key + signature algorithm"
cap "it ISSUED the signer certificate" "you CHAINED signer -> issuing -> root"
val "  TailNumber issuing CA" "  leaf.crt: OK   $cm2"
cmd "$chaincmd"
cap "(the service only signs + verifies)" "you flipped ONE byte, re-checked"
val "  --" "  tampered -> REJECTED   $tm"
cmd "openssl pkeyutl -verify -pubin -inkey pub.pem -in tampered-digest.bin -sigfile sig.bin $VARGS"
if [[ -n "$PARTS" ]]; then
    echo; look "every command above is RUNNABLE — its inputs are unpacked here:"
    printf '        %s%s%s   %s(cd there and try any line)%s\n' "$B" "$PARTS" "$Z" "$D" "$Z"
fi
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

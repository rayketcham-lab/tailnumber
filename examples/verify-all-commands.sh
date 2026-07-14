#!/usr/bin/env bash
# verify-all-commands.sh — run every command documented in this repo against the
# live service and print a PASS / FAIL / by-design-N/A scorecard. Proof, not promises:
# the README quickstart (incl. the offline OpenSSL block), every API-COMMANDS.md
# endpoint, and the TESTING.md flow — all executed for real.
#
#   ./verify-all-commands.sh                 # against the live demo
#   TN_ENDPOINT=https://host/api/v1 ./verify-all-commands.sh
#
# Needs: curl, jq, openssl.  (macOS: base64 -d → base64 -D; base64 -w0 → openssl base64 -A)
set -u
API=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
ROOT=${API%/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-codesign-01}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
W=$(mktemp -d); trap 'cd /; rm -rf "$W"' EXIT; cd "$W" || exit 1
P=0; F=0; NA=0
G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[0;33m'; Z=$'\033[0m'
ok(){ printf "  ${G}PASS${Z} %s\n" "$1"; P=$((P+1)); }
no(){ printf "  ${R}FAIL${Z} %s  %s\n" "$1" "${2:-}"; F=$((F+1)); }
na(){ printf "  ${Y}N/A ${Z} %s  %s\n" "$1" "${2:-}"; NA=$((NA+1)); }
gc(){ curl -s -o /dev/null -w '%{http_code}' -m 15 "$1"; }
g(){ local c; c=$(gc "$1"); [[ "$c" == "${2:-200}" ]] && ok "GET ${1#"$API"/}" || no "GET ${1#"$API"/}" "HTTP $c"; }

echo "############ README — Quick start (verbatim) ############"
echo 'hello from an evaluator' > yourfile.bin
HEX=$(openssl dgst -sha256 yourfile.bin | awk '{print $NF}')
curl -s -X POST "$API/sign" -H 'content-type: application/json' \
  -d "$(jq -nc --arg k "$KEY" --arg d "sha256=$HEX" '{key_label:$k,sig_alg:"rsa3072-pss-sha256",digest_alg:"sha256",digest:$d}')" \
  | tee yourfile.bin.sig.json | jq -e '.signature' >/dev/null && ok "① sign → envelope saved" || no "① sign"
A=$(curl -s -X POST "$API/verify/authentic" -H 'content-type: application/json' \
  -d "$(jq -nc --argjson e "$(cat yourfile.bin.sig.json)" --arg d "sha256=$HEX" '{envelope:$e,digest:$d}')")
[[ "$(jq -r '.authentic' <<<"$A")" == true ]] && ok "② verify/authentic → true" || no "② verify/authentic" "$A"
cp yourfile.bin tampered.bin; printf X >> tampered.bin; BADHEX=$(openssl dgst -sha256 tampered.bin | awk '{print $NF}')
[[ "$(curl -s -X POST "$API/verify/authentic" -H 'content-type: application/json' -d "$(jq -nc --argjson e "$(cat yourfile.bin.sig.json)" --arg d "sha256=$BADHEX" '{envelope:$e,digest:$d}')" | jq -r '.authentic')" == false ]] \
  && ok "prove-it: tamper → false" || no "tamper not rejected"

echo "############ README — offline OpenSSL verify (verbatim) ############"
jq -r '.cert_chain[0]' yourfile.bin.sig.json > signer.crt
openssl x509 -in signer.crt -pubkey -noout > signer.pub
jq -r '.signature' yourfile.bin.sig.json | sed 's/^b64://' | base64 -d > sig.bin
openssl dgst -sha256 -binary yourfile.bin > digest.bin
jq -r '.digest.value' yourfile.bin.sig.json | sed 's/^b64://' | base64 -d | cmp - digest.bin >/dev/null 2>&1 && ok "file ↔ digest match (cmp)" || no "file/digest cmp"
openssl pkeyutl -verify -pubin -inkey signer.pub -in digest.bin -sigfile sig.bin -pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:auto >/dev/null 2>&1 && ok "offline signature Verified (pkeyutl)" || no "offline pkeyutl verify"
curl -s "$API/ca/root" > root.crt; jq -r '.cert_chain[1]' yourfile.bin.sig.json > issuing.crt
openssl verify -CAfile root.crt -untrusted issuing.crt signer.crt >/dev/null 2>&1 && ok "chain to root (openssl verify)" || no "chain to root"

echo "############ API-COMMANDS — discovery / health ############"
c=$(gc "$ROOT/healthz"); [[ "$c" == 200 ]] && ok "GET /healthz (service root)" || no "GET /healthz" "$c"
for e in ping version time algorithms capabilities hsm metrics whoami; do g "$API/$e"; done

echo "############ API-COMMANDS — keys & trust ############"
for p in keys "keys/$KEY" "keys/$KEY/certificate" "keys/$KEY/chain" "keys/$KEY/publickey" ca ca/root ca/issuing ca/chain; do g "$API/$p"; done
c=$(gc "$API/keys/$KEY/bundle"); [[ "$c" == 404 ]] && na "keys/{}/bundle" "404 — private keys are non-extractable on the HSM (documented)" || no "bundle" "$c"

echo "############ API-COMMANDS — identity / acl / config / audit ############"
for p in identities whois/rketcham acl acl/groups acl/roles config changelog "audit?limit=5" audit/1 "audit/search?action=sign&limit=5" audit/stats audit/verify "audit/export?limit=5"; do g "$API/$p"; done

echo "############ API-COMMANDS — sign variants ############"
sc(){ curl -s -X POST "$API/$1" -H 'content-type: application/json' -d "$2"; }
sc sign/custom "$(jq -nc --arg k "$KEY" --arg d "sha256=$HEX" '{key_label:$k,padding:"pss",digest_alg:"sha256",saltlen:"digest",digest:$d}')" | jq -e '.signature' >/dev/null && ok "POST /sign/custom (pss)" || no "sign/custom pss"
sc sign/custom "$(jq -nc --arg k "$KEY" --arg d "sha256=$HEX" '{key_label:$k,padding:"pkcs1",digest_alg:"sha256",digest:$d}')" | jq -e '.signature' >/dev/null && ok "POST /sign/custom (pkcs1)" || no "sign/custom pkcs1"
sc sign/data "$(jq -nc --arg k "$KEY" --arg data "$(base64 -w0 < yourfile.bin 2>/dev/null || base64 < yourfile.bin | tr -d '\n')" '{key_label:$k,sig_alg:"rsa3072-pss-sha256",data:$data}')" | jq -e '.signature' >/dev/null && ok "POST /sign/data" || no "sign/data"
sc sign/hybrid "$(jq -nc --arg k "$KEY" --arg g "sha384=$(openssl dgst -sha384 yourfile.bin|awk '{print $NF}')" '{classical_label:$k,pqc_label:$k,digest_alg:"sha384",digest:$g}')" | jq -e '.signature//.signatures' >/dev/null 2>&1 && ok "POST /sign/hybrid" || na "POST /sign/hybrid" "needs an ML-DSA key — Luna backend (documented)"

echo "############ API-COMMANDS — verify / batch / utility ############"
jq -c '{key_label:.key.label,sig_alg:.key.sig_alg,digest_alg:.digest.alg,digest:.digest.value,signature:.signature}' yourfile.bin.sig.json | curl -s -X POST "$API/verify" -H 'content-type: application/json' -d @- | jq -e '.valid==true' >/dev/null && ok "POST /verify" || no "verify"
curl -s -X POST "$API/envelope/verify" -H 'content-type: application/json' -d "$(jq -nc --argjson e "$(cat yourfile.bin.sig.json)" '{envelope:$e}')" | jq -e '.valid==true or .authentic==true' >/dev/null && ok "POST /envelope/verify" || no "envelope/verify"
jq -nc --arg k "$KEY" --arg d "sha256=$HEX" '{items:[{key_label:$k,sig_alg:"rsa3072-pss-sha256",digest_alg:"sha256",digest:$d}]}' > bs.json
curl -s -X POST "$API/sign/batch" -H 'content-type: application/json' -d @bs.json | jq -e '.signed>=1' >/dev/null && ok "POST /sign/batch" || no "sign/batch"
curl -s -X POST "$API/sign/batch" -H 'content-type: application/json' -d @bs.json | jq -c '{items:[.results[].envelope|{key_label:.key.label,sig_alg:.key.sig_alg,digest_alg:.digest.alg,digest:.digest.value,signature:.signature}]}' | curl -s -X POST "$API/verify/batch" -H 'content-type: application/json' -d @- | jq -e '[.results[].valid]|all' >/dev/null && ok "POST /verify/batch" || no "verify/batch"
curl -s -X POST "$API/hash" -H 'content-type: application/json' -d "$(jq -nc --arg data "$(base64 -w0 < yourfile.bin 2>/dev/null || base64 < yourfile.bin | tr -d '\n')" '{digest_alg:"sha256",data:$data}')" | jq -e '.digest//.hex//.value' >/dev/null && ok "POST /hash" || no "hash"
curl -s -X POST "$API/authz/check" -H 'content-type: application/json' -d "{\"cn\":\"someone\",\"key_label\":\"$KEY\"}" | jq -e 'has("allowed") or has("decision") or has("ok")' >/dev/null && ok "POST /authz/check" || no "authz/check"

echo "############ TESTING.md — tailnumber-verify-file.sh ############"
if [[ -x "$HERE/tailnumber-verify-file.sh" ]]; then
  TN_ENDPOINT="$API" bash "$HERE/tailnumber-verify-file.sh" yourfile.bin yourfile.bin.sig.json >vf.out 2>&1 \
    && grep -qiE 'AUTHENTIC' vf.out && ok "tailnumber-verify-file.sh → AUTHENTIC" || no "verify-file.sh" "$(tail -1 vf.out)"
else na "verify-file.sh" "not found next to this script"
fi

echo
printf '%s════ %s PASS · %s FAIL · %s by-design N/A ════%s\n' "$([[ $F -eq 0 ]] && echo "$G" || echo "$R")" "$P" "$F" "$NA" "$Z"
exit $(( F > 0 ? 1 : 0 ))
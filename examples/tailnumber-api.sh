#!/usr/bin/env bash
# tailnumber-api.sh <command> [args]   —   a thin CLI over the TailNumber REST API.
# One tool for every useful endpoint: discovery, keys/trust material, sign & verify
# (single + batch), and a raw escape hatch. Only a hash is sent for signing; your
# files never leave the machine. Needs: curl, jq, openssl.
#
# Config (env, all optional):
#   TN_ENDPOINT   API root      (default: live service)
#   TN_KEY_LABEL  signing key   (default: tailnumber-legacy-rsa-01)
#   TN_SIG_ALG    algorithm     (default: rsa3072-pss-sha256)
set -uo pipefail
API=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-legacy-rsa-01}
ALG=${TN_SIG_ALG:-rsa3072-pss-sha256}
OSSL=${OSSL:-openssl}
for t in curl jq "$OSSL"; do command -v "$t" >/dev/null 2>&1 || { echo "need: $t" >&2; exit 3; }; done
G=$'\033[1;32m'; R=$'\033[1;31m'; B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'

digest_for() { case "$1" in
  rsa3072-*|*-sha256) echo sha256 ;; rsa4096-*|ecdsa-p384-*|ml-dsa-65|*-sha384) echo sha384 ;;
  ml-dsa-87|*-sha512) echo sha512 ;; *) echo sha256 ;; esac; }

get()  { curl -sS "$API$1"; }                                              # GET, JSON
getp() { curl -sS "$API$1"; }                                              # GET, plain (PEM/text)
post() { curl -sS -X POST "$API$1" -H 'content-type: application/json' -d "$2"; }
jqok() { jq . 2>/dev/null || cat; }                                        # pretty if JSON

usage() {
  cat <<EOF
tailnumber-api.sh — CLI over the TailNumber API   (endpoint: $API)

 discovery:   health · ping · version · time · algorithms · capabilities · metrics · whoami
 keys/trust:  keys · key <label> · cert <label> · chain <label> · pubkey <label>
              bundle <label> [out.zip] · ca · ca-chain · root
 sign/verify: sign <file> [key] [alg]           sign one file  -> <file>.sig.json
              verify <file> <envelope>          full authenticity verdict (/verify/authentic)
              sign-batch <file>...              sign many        -> each <file>.sig.json
              verify-batch <file>...            verify many (expects <file>.sig.json each)
              hash <file> [alg]                 local digest (nothing sent)
 raw:         raw GET  <path>                    e.g. raw GET /keys
              raw POST <path> <json>             e.g. raw POST /verify '{...}'

 env: TN_ENDPOINT, TN_KEY_LABEL (=$KEY), TN_SIG_ALG (=$ALG)
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
  health)       get /healthz | jqok ;;
  ping)         get /ping | jqok ;;
  version)      get /version | jqok ;;
  time)         get /time | jqok ;;
  algorithms)   get /algorithms | jqok ;;
  capabilities) get /capabilities | jqok ;;
  metrics)      get /metrics | jqok ;;
  whoami)       get /whoami | jqok ;;
  keys)         get /keys | jqok ;;
  key)          get "/keys/$1" | jqok ;;
  cert)         getp "/keys/$1/certificate" ;;
  chain)        getp "/keys/$1/chain" ;;
  pubkey)       getp "/keys/$1/publickey" ;;
  bundle)       out=${2:-$1-bundle.zip}; curl -sS "$API/keys/$1/bundle" -o "$out" && echo "saved $out" ;;
  ca)           get /ca | jqok ;;
  ca-chain)     getp /ca/chain ;;
  root)         getp /ca/root ;;

  hash)         f=$1; a=${2:-$(digest_for "$ALG")}; printf '%s=%s\n' "$a" "$("$OSSL" dgst -"$a" "$f" | awk '{print $NF}')" ;;

  sign)
    f=$1; k=${2:-$KEY}; a=${3:-$ALG}; da=$(digest_for "$a")
    hx=$("$OSSL" dgst -"$da" "$f" | awk '{print $NF}')
    body=$(jq -nc --arg k "$k" --arg a "$a" --arg d "$da" --arg g "$da=$hx" '{key_label:$k,sig_alg:$a,digest_alg:$d,digest:$g}')
    env=$(post /sign "$body"); echo "$env" > "$f.sig.json"
    echo "signed $f -> ${B}$f.sig.json${Z}  ($(jq -r '.key.sig_alg' <<<"$env"))" ;;

  verify)
    f=$1; envf=$2; da=$(jq -r '.digest.alg' "$envf")
    hx=$("$OSSL" dgst -"$da" "$f" | awk '{print $NF}')
    body=$(jq -nc --argjson e "$(cat "$envf")" --arg d "$da=$hx" '{envelope:$e,digest:$d}')
    resp=$(post /verify/authentic "$body")
    auth=$(jq -r '.authentic' <<<"$resp")
    jq '{authentic,signature_valid,chain_ok,digest_matches,signer:{subject:.signer.subject,not_after:.signer.not_after}}' <<<"$resp"
    [[ "$auth" == true ]] && echo "${G}${B}AUTHENTIC${Z}" || { echo "${R}${B}NOT AUTHENTIC${Z}"; exit 1; } ;;

  sign-batch)
    [[ $# -ge 1 ]] || { echo "usage: sign-batch <file>..." >&2; exit 2; }
    da=$(digest_for "$ALG")
    items=$(for f in "$@"; do hx=$("$OSSL" dgst -"$da" "$f" | awk '{print $NF}')
      jq -nc --arg k "$KEY" --arg a "$ALG" --arg d "$da" --arg g "$da=$hx" '{key_label:$k,sig_alg:$a,digest_alg:$d,digest:$g}'; done | jq -sc '{items:.}')
    resp=$(post /sign/batch "$items"); files=("$@")
    n=$(jq -r '.count' <<<"$resp")
    for i in $(seq 0 $((n-1))); do
      if [[ "$(jq -r ".results[$i].ok" <<<"$resp")" == true ]]; then
        jq -c ".results[$i].envelope" <<<"$resp" > "${files[$i]}.sig.json"
        echo "${G}✓${Z} ${files[$i]} -> ${files[$i]}.sig.json"
      else echo "${R}✗${Z} ${files[$i]}: $(jq -r ".results[$i].error" <<<"$resp")"; fi
    done
    echo "signed $(jq -r '.signed' <<<"$resp")/$n" ;;

  verify-batch)
    [[ $# -ge 1 ]] || { echo "usage: verify-batch <file>..." >&2; exit 2; }
    ok=0; tot=0
    for f in "$@"; do envf="$f.sig.json"; tot=$((tot+1))
      [[ -f "$envf" ]] || { echo "${R}✗${Z} $f (no $envf)"; continue; }
      da=$(jq -r '.digest.alg' "$envf"); hx=$("$OSSL" dgst -"$da" "$f" | awk '{print $NF}')
      body=$(jq -nc --argjson e "$(cat "$envf")" --arg d "$da=$hx" '{envelope:$e,digest:$d}')
      auth=$(post /verify/authentic "$body" | jq -r '.authentic')
      [[ "$auth" == true ]] && { ok=$((ok+1)); echo "${G}✓ AUTHENTIC${Z}  $f"; } || echo "${R}✗ NOT${Z}       $f"
    done
    echo "${B}$ok/$tot authentic${Z}"; [[ "$ok" == "$tot" ]] || exit 1 ;;

  raw)
    m=$1; p=$2
    if [[ "$m" == GET ]]; then getp "$p"; else post "$p" "${3:-{}}"; fi ;;

  help|-h|--help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac

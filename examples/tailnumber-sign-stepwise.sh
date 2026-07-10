#!/usr/bin/env bash
# tailnumber-sign-stepwise.sh [FILE]
# Sign a file with the TailNumber service, showing every step in the CLI, then
# print the envelope to paste into the WebUI -> "Verify an envelope".
# SHA-256 + the RSA-3072 signer by default. Only the hash is sent — the file stays.
set -euo pipefail

ENDPOINT=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-codesign-01}        # an RSA key => SHA-256
SIG_ALG=${TN_SIG_ALG:-rsa3072-pss-sha256}
OSSL=${OSSL:-openssl}                                # any OpenSSL is fine for SHA-256

step(){ printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }

# what to sign: your FILE, or a throwaway demo message
src=${1:-}
if [[ -z "$src" ]]; then
    src=$(mktemp); echo "hello from tailnumber @ $(date -u +%FT%TZ)" >"$src"
    echo "(no FILE given — signing a demo message at $src)"
fi

step "1/4  Hash the artifact locally with SHA-256 — the file never leaves your machine"
hex=$("$OSSL" dgst -sha256 "$src" | awk '{print $NF}')
printf '     sha256(%s)\n       = %s\n' "$src" "$hex"

step "2/4  Send only the digest to the service"
if command -v jq >/dev/null; then   # build JSON safely (no injection via KEY/SIG_ALG) when jq is present
    req=$(jq -nc --arg k "$KEY" --arg a "$SIG_ALG" --arg d "sha256=$hex" '{key_label:$k,sig_alg:$a,digest_alg:"sha256",digest:$d}')
else
    req=$(printf '{"key_label":"%s","sig_alg":"%s","digest_alg":"sha256","digest":"sha256=%s"}' "$KEY" "$SIG_ALG" "$hex")
fi
printf '     POST %s/sign\n     %s\n' "$ENDPOINT" "$req"

step "3/4  The service signs with its key (which never leaves the service / HSM)"
envelope=$(curl -fsS -H 'content-type: application/json' -d "$req" "$ENDPOINT/sign")
if command -v jq >/dev/null; then pretty=$(jq . <<<"$envelope"); else pretty=$envelope; fi
echo "     got the envelope ($(printf '%s' "$envelope" | wc -c) bytes)"

step "4/4  Copy the envelope below and paste it into the dashboard -> Verify an envelope"
echo '----------------------------- COPY FROM HERE -----------------------------'
printf '%s\n' "$pretty"
echo '------------------------------- TO HERE ----------------------------------'

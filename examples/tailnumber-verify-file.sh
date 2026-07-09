#!/usr/bin/env bash
# tailnumber-verify-file.sh FILE ENVELOPE.sig.json
#
# Confirm a file is AUTHENTIC against its TailNumber envelope. Two independent checks:
#   (1) integrity — the file still hashes to the digest that was signed, and
#   (2) signature — that digest was signed by the key (checked via the API).
# Both pass  ->  ✅ AUTHENTIC (exit 0).  Either fails  ->  ❌ (exit 1).
# Needs: curl, jq, openssl.
set -uo pipefail
API=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
OSSL=${OSSL:-openssl}
FILE=${1:?usage: tailnumber-verify-file.sh FILE ENVELOPE.sig.json}
ENV=${2:?usage: tailnumber-verify-file.sh FILE ENVELOPE.sig.json}
for t in curl jq "$OSSL"; do command -v "$t" >/dev/null 2>&1 || { echo "need: $t" >&2; exit 3; }; done
[[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 3; }
[[ -f "$ENV"  ]] || { echo "no such envelope: $ENV" >&2; exit 3; }
G=$'\033[1;32m'; R=$'\033[1;31m'; B=$'\033[1m'; D=$'\033[2m'; Z=$'\033[0m'

DA=$(jq -r '.digest.alg' "$ENV" 2>/dev/null)
file_hex=$("$OSSL" dgst -"$DA" "$FILE" | awk '{print $NF}')
env_hex=$(jq -r '.digest.value' "$ENV" 2>/dev/null | sed 's/^b64://' | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')

printf '%sfile %s %s\n%senv  %s %s\n\n' "$B" "$Z" "$FILE" "$B" "$Z" "$ENV"
printf '  %s(your file) = %s%s%s\n' "$DA" "$D" "$file_hex" "$Z"
printf '  signed digest%s = %s%s%s\n' " " "$D" "$env_hex" "$Z"
if [[ -n "$env_hex" && "$file_hex" == "$env_hex" ]]; then match=1; printf '  %s✓ file matches the signed digest%s — unchanged since signing\n' "$G" "$Z"
else match=0; printf '  %s✗ file does NOT match%s — wrong file, or it was altered\n' "$R" "$Z"; fi

echo
vreq=$(jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' "$ENV" 2>/dev/null)
valid=$(printf '%s' "$vreq" | curl -sS -X POST "$API/verify" -H 'content-type: application/json' -d @- 2>/dev/null | jq -r '.valid' 2>/dev/null)
[[ "$valid" == true ]] && printf '  %s✓ signature is valid%s — the digest was signed by the key\n' "$G" "$Z" \
                       || printf '  %s✗ signature invalid%s (valid=%s)\n' "$R" "$Z" "${valid:-?}"

echo
if [[ "$match" == 1 && "$valid" == true ]]; then
    printf '%s✅ AUTHENTIC%s — this envelope belongs to this file, and the signature checks out.\n' "$G$B" "$Z"; exit 0
else
    printf '%s❌ NOT AUTHENTIC%s — do not trust this file/envelope pair.\n' "$R$B" "$Z"; exit 1
fi

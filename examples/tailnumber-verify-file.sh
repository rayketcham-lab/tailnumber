#!/usr/bin/env bash
# tailnumber-verify-file.sh FILE ENVELOPE.sig.json
#
# Confirm a file is AUTHENTIC against its TailNumber envelope in one call
# (POST /verify/authentic): (1) the file still hashes to the signed digest,
# (2) the signature is valid, and (3) the signer cert chains to the TailNumber root.
# All pass  ->  ✅ AUTHENTIC (exit 0).  Any fail  ->  ❌ (exit 1).
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

# one call: signature valid + chains to root + your file's digest matches -> authentic
body=$(jq -nc --argjson e "$(cat "$ENV")" --arg d "$DA=$file_hex" '{envelope:$e,digest:$d}')
resp=$(curl -sS -X POST "$API/verify/authentic" -H 'content-type: application/json' -d "$body" 2>/dev/null)
authentic=$(jq -r '.authentic // false' <<<"$resp" 2>/dev/null)
sigok=$(jq -r '.signature_valid // false' <<<"$resp" 2>/dev/null)
chainok=$(jq -r '.chain_ok // false' <<<"$resp" 2>/dev/null)
match=$(jq -r '.digest_matches // false' <<<"$resp" 2>/dev/null)
subject=$(jq -r '.signer.subject // "?"' <<<"$resp" 2>/dev/null)
not_after=$(jq -r '.signer.not_after // "?"' <<<"$resp" 2>/dev/null)

printf '%sfile %s %s\n%senv  %s %s\n\n' "$B" "$Z" "$FILE" "$B" "$Z" "$ENV"
printf '  %s(your file) = %s%s%s\n\n' "$DA" "$D" "$file_hex" "$Z"
[[ "$match"   == true ]] && printf '  %s✓ file matches the signed digest%s — unchanged since signing\n' "$G" "$Z" \
                         || printf '  %s✗ file does NOT match%s — wrong file, or it was altered\n' "$R" "$Z"
[[ "$sigok"   == true ]] && printf '  %s✓ signature is valid%s — the digest was signed by the key\n' "$G" "$Z" \
                         || printf '  %s✗ signature invalid%s\n' "$R" "$Z"
[[ "$chainok" == true ]] && printf '  %s✓ chains to the TailNumber root%s\n' "$G" "$Z" \
                         || printf '  %s· chain not verified (offline / no CA)%s\n' "$D" "$Z"
printf '  %ssigner%s %s  %s(valid to %s)%s\n' "$B" "$Z" "$subject" "$D" "$not_after" "$Z"

echo
if [[ "$authentic" == true ]]; then
    printf '%s✅ AUTHENTIC%s — this envelope belongs to this file, the signature checks out, and it chains to the root.\n' "$G$B" "$Z"; exit 0
else
    printf '%s❌ NOT AUTHENTIC%s — do not trust this file/envelope pair.\n' "$R$B" "$Z"; exit 1
fi

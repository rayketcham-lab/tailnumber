#!/usr/bin/env bash
# tailnumber-loadtest.sh — pound the TailNumber API to gauge throughput/latency.
#
# Each iteration APPENDS one line to a growing file, re-hashes it, and signs it
# (a genuinely different signature every time), optionally verifying too. The file
# is purged at the start, so afterwards  wc -l <file>  == iterations run, and its
# size climbs steadily over the run. Per-request latency/size is logged to a CSV
# and summarized (min/avg/p50/p95/max, req/s) at the end or on Ctrl-C.
#
# Config via env (all optional):
#   TN_ENDPOINT  API root            (default: live service)
#   TN_KEY_LABEL signing key         (default: tailnumber-codesign-01)
#   TN_SIG_ALG   algorithm           (default: rsa3072-pss-sha256)
#   TN_DIGEST    hash                 (default: sha256)   # sha384 for ml-dsa-65
#   TN_ITERS     iterations, 0=until Ctrl-C   (default: 100)
#   TN_VERIFY    also call /verify each iter, 1/0          (default: 1)
#   TN_TAMPER    integrity + tamper checks each iter, 1/0  (default: 1)
#   TN_OTHER     file for the tamper/failure test         (default: auto-altered copy)
#   TN_SLEEP     seconds between requests                  (default: 0 = pound)
#   TN_SRC       the growing file     (default: ./pound.txt)
#   TN_CSV       metrics log          (default: ./pound-metrics.csv)
# Needs: curl, jq, openssl.
set -uo pipefail   # deliberately NOT -e: a failed request must not kill the run

API=${TN_ENDPOINT:-https://www.rayketcham.com/CRLs/tailnumber/api/v1}
KEY=${TN_KEY_LABEL:-tailnumber-codesign-01}
ALG=${TN_SIG_ALG:-rsa3072-pss-sha256}
DIGEST=${TN_DIGEST:-sha256}
N=${TN_ITERS:-100}
VERIFY=${TN_VERIFY:-1}
TAMPER=${TN_TAMPER:-1}
SLEEP=${TN_SLEEP:-0}
SRC=${TN_SRC:-./pound.txt}
CSV=${TN_CSV:-./pound-metrics.csv}
ENV=${TN_ENV:-./pound.sig.json}
OSSL=${OSSL:-openssl}

for t in curl jq "$OSSL"; do command -v "$t" >/dev/null 2>&1 || { echo "need: $t" >&2; exit 1; }; done
C=$'\033[1;36m'; G=$'\033[1;32m'; R=$'\033[1;31m'; D=$'\033[2m'; B=$'\033[1m'; Z=$'\033[0m'

: > "$SRC"                                    # purge — recreate by appending below
echo "iter,lines,bytes,sign_ms,sign_code,verify_ms,verify_valid,intact,tamper_caught" > "$CSV"

LAT=(); ok=0; sign_err=0; ver_bad=0; cum_bytes=0; integ_fail=0; tamper_missed=0
START=$(date +%s)
STOP=0; trap 'STOP=1' INT

printf '%s✈ TailNumber load test%s  %s%s%s  key=%s alg=%s\n' "$C$B" "$Z" "$D" "$API" "$Z" "$KEY" "$ALG"
printf '%siters=%s verify=%s tamper=%s sleep=%ss  file=%s  csv=%s%s\n\n' "$D" "${N/0/∞}" "$VERIFY" "$TAMPER" "$SLEEP" "$SRC" "$CSV" "$Z"

i=0
while :; do
    [[ "$STOP" == 1 ]] && break
    i=$((i+1)); [[ "$N" -gt 0 && "$i" -gt "$N" ]] && { i=$((i-1)); break; }

    # append a unique line -> the file grows and its hash changes every iteration
    printf 'iteration %06d %s pid=%d\n' "$i" "$(date -u +%FT%T.%NZ)" "$$" >> "$SRC"
    lines=$(wc -l < "$SRC" | tr -d ' '); bytes=$(wc -c < "$SRC" | tr -d ' ')
    cum_bytes=$((cum_bytes + bytes))

    HEX=$("$OSSL" dgst -"$DIGEST" "$SRC" | awk '{print $NF}')
    body=$(jq -nc --arg k "$KEY" --arg a "$ALG" --arg dg "$DIGEST" --arg d "$DIGEST=$HEX" \
        '{key_label:$k, sig_alg:$a, digest_alg:$dg, digest:$d}')

    meta=$(curl -sS -o "$ENV" -w '%{http_code} %{time_total}' -X POST "$API/sign" \
        -H 'content-type: application/json' -d "$body" 2>/dev/null)
    read -r code t <<<"$meta"; code=${code:-000}
    sign_ms=$(awk "BEGIN{printf \"%.0f\", ${t:-0}*1000}")
    [[ "$code" == 200 ]] && { ok=$((ok+1)); LAT+=("$sign_ms"); } || sign_err=$((sign_err+1))

    verify_ms=""; valid=""
    if [[ "$VERIFY" == 1 && "$code" == 200 ]]; then
        vb=$(jq -c '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:.digest.value, signature:.signature}' "$ENV" 2>/dev/null)
        vmeta=$(printf '%s' "$vb" | curl -sS -o "$ENV.v" -w '%{http_code} %{time_total}' -X POST "$API/verify" \
            -H 'content-type: application/json' -d @- 2>/dev/null)
        read -r vcode vt <<<"$vmeta"
        verify_ms=$(awk "BEGIN{printf \"%.0f\", ${vt:-0}*1000}")
        valid=$(jq -r '.valid' "$ENV.v" 2>/dev/null); rm -f "$ENV.v"
        [[ "$valid" == true ]] || ver_bad=$((ver_bad+1))
    fi

    # NEW — integrity + tamper: prove the envelope matches THIS file, and would REJECT another
    intact=""; tamper=""
    if [[ "$TAMPER" == 1 && "$code" == 200 ]]; then
        # (a) integrity: the digest the envelope signed must still match the file on disk
        env_dig=$(jq -r '.digest.value' "$ENV" 2>/dev/null | sed 's/^b64://' | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')
        file_dig=$("$OSSL" dgst -"$DIGEST" "$SRC" | awk '{print $NF}')
        [[ -n "$env_dig" && "$env_dig" == "$file_dig" ]] && intact=yes || { intact=no; integ_fail=$((integ_fail+1)); }
        # (b) failure demo: verify the SAME signature against ANOTHER file -> must be rejected
        if [[ -n "${TN_OTHER:-}" && -f "${TN_OTHER:-}" ]]; then other="$TN_OTHER"; mk=""
        else cp "$SRC" "$ENV.bad"; printf 'X' >> "$ENV.bad"; other="$ENV.bad"; mk=1; fi
        bad_hex=$("$OSSL" dgst -"$DIGEST" "$other" | awk '{print $NF}'); [[ -n "$mk" ]] && rm -f "$ENV.bad"
        bad_valid=$(jq -c --arg d "$DIGEST=$bad_hex" '{key_label:.key.label, sig_alg:.key.sig_alg, digest_alg:.digest.alg, digest:$d, signature:.signature}' "$ENV" \
            | curl -sS -X POST "$API/verify" -H 'content-type: application/json' -d @- 2>/dev/null | jq -r '.valid' 2>/dev/null)
        [[ "$bad_valid" == false ]] && tamper=caught || { tamper=MISSED; tamper_missed=$((tamper_missed+1)); }
    fi

    echo "$i,$lines,$bytes,$sign_ms,$code,$verify_ms,$valid,$intact,$tamper" >> "$CSV"

    sc=$([[ "$code" == 200 ]] && printf '%s%s%s' "$G" "$code" "$Z" || printf '%s%s%s' "$R" "$code" "$Z")
    vc=""; [[ -n "$valid" ]]  && vc=$([[ "$valid" == true ]]     && printf ' v=%sms%s✓%s' "$verify_ms" "$G" "$Z" || printf ' v=%sms%s✗%s' "$verify_ms" "$R" "$Z")
    ic=""; [[ -n "$intact" ]] && ic=$([[ "$intact" == yes ]]    && printf ' %sintact✓%s' "$G" "$Z"            || printf ' %sintact✗%s' "$R" "$Z")
    tc=""; [[ -n "$tamper" ]] && tc=$([[ "$tamper" == caught ]] && printf ' %stamper✓%s' "$G" "$Z"            || printf ' %stamper✗MISS%s' "$R" "$Z")
    printf '\r\033[K#%06d  L=%-5s %-8s sign=%4sms[%s]%s%s%s ' "$i" "$lines" "${bytes}B" "$sign_ms" "$sc" "$vc" "$ic" "$tc"

    [[ "$SLEEP" != 0 ]] && sleep "$SLEEP"
done

summary(){
    local wall=$(( $(date +%s) - START )); [[ "$wall" -lt 1 ]] && wall=1
    local rps=$(awk "BEGIN{printf \"%.1f\", $ok/$wall}")
    local stats; stats=$(printf '%s\n' "${LAT[@]:-}" | sort -n | awk '
        NF{a[++n]=$1; s+=$1}
        END{ if(!n){print "0 0 0 0 0"; exit}
             printf "%.0f %.0f %.0f %.0f %.0f", a[1], s/n, a[int((n-1)*0.50)+1], a[int((n-1)*0.95)+1], a[n] }')
    read -r mn avg p50 p95 mx <<<"$stats"
    printf '\n\n%s════ summary ════%s\n' "$C$B" "$Z"
    printf '  requests   : %s%s sign%s' "$B" "$ok" "$Z"; [[ "$VERIFY" == 1 ]] && printf ' (+%s verify)' "$ok"; printf '\n'
    printf '  wall / rate: %ss  →  %s%s req/s%s (sign)\n' "$wall" "$B" "$rps" "$Z"
    printf '  sign lat.  : min %sms · avg %s%s%sms · p50 %sms · p95 %s%s%sms · max %sms\n' "$mn" "$B" "$avg" "$Z" "$p50" "$B" "$p95" "$Z" "$mx"
    printf '  errors     : %s%s%s sign non-200 · %s%s%s verify invalid\n' "$([[ $sign_err -gt 0 ]] && echo "$R")" "$sign_err" "$Z" "$([[ $ver_bad -gt 0 ]] && echo "$R")" "$ver_bad" "$Z"
    [[ "$TAMPER" == 1 ]] && printf '  integrity  : %s%s%s digest≠file · %s%s%s tamper MISSED  %s(both should be 0)%s\n' "$([[ $integ_fail -gt 0 ]] && echo "$R")" "$integ_fail" "$Z" "$([[ $tamper_missed -gt 0 ]] && echo "$R")" "$tamper_missed" "$Z" "$D" "$Z"
    printf '  file grew  : %s lines · %s bytes  %s(%s)%s\n' "$(wc -l < "$SRC" | tr -d ' ')" "$(wc -c < "$SRC" | tr -d ' ')" "$D" "$SRC" "$Z"
    printf '  data hashed: %s bytes cumulative across all iterations\n' "$cum_bytes"
    printf '  metrics csv: %s%s%s   %s(iter,lines,bytes,sign_ms,sign_code,verify_ms,verify_valid,intact,tamper_caught)%s\n' "$B" "$CSV" "$Z" "$D" "$Z"
}
summary

#!/usr/bin/env bash
# pkcs11-sign-demo.sh — the HSM signing primitive, step by step, with SoftHSM2 +
# the OpenSSL pkcs11 engine (SHA-256, RSA-3072). This is the *server-side* path:
# a key generated INSIDE the token, non-extractable, signs a digest in hardware.
# Self-contained + throwaway (its own token). No root needed.
set -euo pipefail

OSSL=${OSSL:-/usr/bin/openssl}                       # system OpenSSL ships the pkcs11 engine
MODULE=${PKCS11_MODULE:-/usr/lib/softhsm/libsofthsm2.so}
export PKCS11_MODULE_PATH="$MODULE"                  # the engine finds SoftHSM here
PIN=1234; SOPIN=123456; LABEL=tn-demo; ID=A1         # throwaway token — demo values only

WORK=${TN_WORK:-$(mktemp -d)}; mkdir -p "$WORK/tokens"
export SOFTHSM2_CONF="$WORK/softhsm2.conf"
printf 'directories.tokendir = %s/tokens\n' "$WORK" >"$SOFTHSM2_CONF"
trap 'rm -rf "$WORK"' EXIT
PSS="-pkeyopt digest:sha256 -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:digest"

step(){ printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
show(){ printf '     $ %s\n' "$*"; }

step "1/6  Create a SoftHSM token (stands in for a Luna T3000 partition)"
show "softhsm2-util --init-token --free --label $LABEL --pin *** --so-pin ***"
softhsm2-util --init-token --free --label "$LABEL" --pin "$PIN" --so-pin "$SOPIN" | sed 's/^/       /'

step "2/6  Generate an RSA-3072 keypair INSIDE the token (private key non-extractable)"
show "pkcs11-tool --module \$MODULE --login --keypairgen --key-type rsa:3072 --label $LABEL --id $ID"
pkcs11-tool --module "$MODULE" --login --pin "$PIN" --keypairgen --key-type rsa:3072 \
    --label "$LABEL" --id "$ID" >/dev/null
echo "       ok — sensitive, always-sensitive, never-extractable"

step "3/6  Hash a message with SHA-256 (only the digest is signed, never the file)"
echo "firmware image v1" >"$WORK/artifact.bin"
"$OSSL" dgst -sha256 -binary "$WORK/artifact.bin" >"$WORK/digest.bin"
echo "       sha256 = $("$OSSL" dgst -sha256 "$WORK/artifact.bin" | awk '{print $NF}')  ($(wc -c <"$WORK/digest.bin") bytes)"

step "4/6  Sign the digest IN THE HSM via the pkcs11 engine (RSA-PSS)"
URI="pkcs11:token=$LABEL;object=$LABEL;type=private;pin-value=$PIN"
show "openssl pkeyutl -sign -engine pkcs11 -keyform engine -inkey 'pkcs11:token=$LABEL;object=$LABEL;type=private;pin-value=***' -in digest.bin -out sig.bin $PSS"
# shellcheck disable=SC2086
"$OSSL" pkeyutl -sign -engine pkcs11 -keyform engine -inkey "$URI" \
    -in "$WORK/digest.bin" -out "$WORK/sig.bin" $PSS 2>/dev/null
echo "       wrote sig.bin ($(wc -c <"$WORK/sig.bin") bytes) — the private key never left the token"

step "5/6  Export the PUBLIC key (the only half that ever leaves the token)"
pkcs11-tool --module "$MODULE" --read-object --type pubkey --label "$LABEL" --id "$ID" -o "$WORK/pub.der" 2>/dev/null
"$OSSL" pkey -pubin -inform DER -in "$WORK/pub.der" -out "$WORK/pub.pem"
echo "       pub.pem ready"

step "6/6  Verify the signature with the public key (what any verifier does)"
show "openssl pkeyutl -verify -pubin -inkey pub.pem -in digest.bin -sigfile sig.bin $PSS"
# shellcheck disable=SC2086
"$OSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -in "$WORK/digest.bin" -sigfile "$WORK/sig.bin" $PSS | sed 's/^/       /'

printf '\nThat is the TailNumber Luna backend in miniature: key born in the HSM ->\ndigest signed in the HSM -> verified with the public half. Swap the module for\nlibCryptoki2_64.so and the same commands run on a real Luna T3000.\n'

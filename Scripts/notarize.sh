#!/usr/bin/env bash
# Notarize + staple a DMG (or .app) with Apple's notary service, then verify it.
#
# Run AFTER Scripts/build.sh (Developer ID signed) and Scripts/make-dmg.sh.
# Notarizing the DMG covers the signed app inside it; the stapled ticket is what
# stops Gatekeeper showing "Clipline is damaged / move to Trash" to people who
# download it.
#
# ── Authentication (App Store Connect API key) ───────────────────────────────
# Provide ONE of:
#
#   A) A stored notarytool keychain profile (best for repeated LOCAL runs):
#        xcrun notarytool store-credentials clipline-notary \
#          --key    /path/AuthKey_XXXXXX.p8 \
#          --key-id <KEY_ID> \
#          --issuer <ISSUER_ID>
#        AC_KEYCHAIN_PROFILE=clipline-notary bash Scripts/notarize.sh
#
#   B) The three API-key values directly (best for CI):
#        AC_API_KEY_ID=<KEY_ID>
#        AC_API_ISSUER_ID=<ISSUER_ID>
#        AC_API_KEY_P8=<base64 of the .p8>   # or AC_API_KEY_P8_PATH=/path/AuthKey.p8
#
# Get these from App Store Connect → Users and Access → Integrations → Keys,
# with key role "Developer" or higher. The .p8 downloads exactly once.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-$(ls -t build/Clipline-*.dmg 2>/dev/null | head -1 || true)}"
if [[ -z "${TARGET:-}" || ! -e "$TARGET" ]]; then
    echo "ERROR: notarize target not found (got: '${TARGET:-<none>}'). Run Scripts/make-dmg.sh first." >&2
    exit 1
fi

echo "==> Notarizing $TARGET"
submit_args=(--wait)

if [[ -n "${AC_KEYCHAIN_PROFILE:-}" ]]; then
    submit_args+=(--keychain-profile "$AC_KEYCHAIN_PROFILE")
else
    : "${AC_API_KEY_ID:?set AC_API_KEY_ID (or AC_KEYCHAIN_PROFILE)}"
    : "${AC_API_ISSUER_ID:?set AC_API_ISSUER_ID (or AC_KEYCHAIN_PROFILE)}"
    KEY_PATH="${AC_API_KEY_P8_PATH:-}"
    if [[ -z "$KEY_PATH" && -n "${AC_API_KEY_P8:-}" ]]; then
        KEY_PATH="$(mktemp -t ac_api_key_XXXXXX).p8"
        # shellcheck disable=SC2064
        trap "rm -f '$KEY_PATH'" EXIT
        printf '%s' "$AC_API_KEY_P8" | base64 --decode > "$KEY_PATH"
    fi
    if [[ -z "$KEY_PATH" || ! -f "$KEY_PATH" ]]; then
        echo "ERROR: provide AC_API_KEY_P8_PATH or AC_API_KEY_P8 (base64), or AC_KEYCHAIN_PROFILE." >&2
        exit 1
    fi
    submit_args+=(--key "$KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")
fi

# --wait blocks until Apple finishes; a non-"Accepted" status exits non-zero.
xcrun notarytool submit "$TARGET" "${submit_args[@]}"

echo "==> Stapling notarization ticket"
xcrun stapler staple "$TARGET"

echo "==> Verifying"
xcrun stapler validate "$TARGET"
# DMG assessment (best-effort; stapler validate above is the authoritative gate)
spctl -a -vvv -t open --context context:primary-signature "$TARGET" 2>&1 || true

echo "==> Done. Notarized + stapled: $TARGET"

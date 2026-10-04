#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")" && pwd)"
: "${ANDROID_HOME:=${ANDROID_SDK_ROOT:-}}"
if [[ -z "$ANDROID_HOME" ]]; then echo 'Set ANDROID_HOME to your SDK (platform 36 and build-tools 36.0.0).' >&2; exit 1; fi
export ANDROID_HOME
mkdir -p "$ROOT/.local"
chmod 700 "$ROOT/.local"
if [[ ! -f "$ROOT/.local/debug.keystore" ]]; then
  keytool -genkeypair -keystore "$ROOT/.local/debug.keystore" \
    -alias androiddebugkey -storepass android -keypass android \
    -dname 'CN=Android Debug,O=Android,C=US' -keyalg RSA -keysize 2048 -validity 10000
fi
chmod 600 "$ROOT/.local/debug.keystore"
"$ROOT/gradlew" -p "$ROOT" testDebugUnitTest assembleDebug "$@"
echo "$ROOT/build/outputs/apk/debug/Captura-debug.apk"

#!/bin/bash
set -euo pipefail

SIGNING_IDENTITY_NAME="Ice Local Development"
SIGNING_IDENTITY="-"
INSTALL_APP_PATH=""
ARTIFACT_TMPDIR=""
STAGING_TMPDIR=""
STAGED_APP_PATH=""
DESTINATION_APP_PATH="${ICE_INSTALL_APP_PATH:-/Applications/Ice.app}"
LOGIN_KEYCHAIN="$(
  security default-keychain -d user 2>/dev/null |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' || true
)"
LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"

cleanup_artifact_tmpdir() {
  if [[ -n "$ARTIFACT_TMPDIR" && -d "$ARTIFACT_TMPDIR" ]]; then
    rm -rf "$ARTIFACT_TMPDIR"
  fi
  if [[ -n "$STAGING_TMPDIR" && -d "$STAGING_TMPDIR" ]]; then
    rm -rf "$STAGING_TMPDIR"
  fi
}

trap cleanup_artifact_tmpdir EXIT

# No -v: the self-signed certificate is never "trusted", but codesign can still
# use it, and its fixed fingerprint keeps the Accessibility grant across builds.
find_local_signing_identity() {
  security find-identity -p codesigning 2>/dev/null |
    awk -v name="$SIGNING_IDENTITY_NAME" '$0 ~ "\"" name "\"" { print $2; exit }'
}

cleanup_and_fail() {
  rm -rf "$1"
  return 1
}

create_local_signing_identity() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  WARN: openssl not found; falling back to ad-hoc signing."
    return 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"

  local key_path="$tmpdir/ice-local-dev.key"
  local cert_path="$tmpdir/ice-local-dev.crt"
  local p12_path="$tmpdir/ice-local-dev.p12"
  local p12_password="ice-local-development"

  openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -nodes \
    -keyout "$key_path" \
    -out "$cert_path" \
    -subj "/CN=${SIGNING_IDENTITY_NAME}" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1 || { cleanup_and_fail "$tmpdir"; return 1; }

  # OpenSSL 3+ defaults to AES/PBKDF2 PKCS#12, which `security import` rejects
  # ("MAC verification failed"); force the SHA1/3DES format macOS understands.
  openssl pkcs12 \
    -export \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$key_path" \
    -in "$cert_path" \
    -out "$p12_path" \
    -name "$SIGNING_IDENTITY_NAME" \
    -passout pass:"$p12_password" >/dev/null 2>&1 || { cleanup_and_fail "$tmpdir"; return 1; }

  if ! security import "$p12_path" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$p12_password" \
    -T /usr/bin/codesign >/dev/null; then
    echo "  WARN: Could not import the local signing identity into ${LOGIN_KEYCHAIN}."
    cleanup_and_fail "$tmpdir"
    return 1
  fi

  rm -rf "$tmpdir"
}

resolve_signing_identity() {
  local identity
  identity="$(find_local_signing_identity)"
  if [[ -n "$identity" ]]; then
    SIGNING_IDENTITY="$identity"
    echo "  Using existing local signing identity: ${SIGNING_IDENTITY_NAME}"
    return
  fi

  echo "  Creating local signing identity: ${SIGNING_IDENTITY_NAME}"
  create_local_signing_identity || true

  identity="$(find_local_signing_identity)"
  if [[ -n "$identity" ]]; then
    SIGNING_IDENTITY="$identity"
    echo "  Created local signing identity: ${SIGNING_IDENTITY_NAME}"
    return
  fi

  SIGNING_IDENTITY="-"
  echo "  WARN: Could not create a stable local signing identity."
  echo "  WARN: This install will be ad-hoc signed and may need Accessibility approval again."
}

sign_app_with_identity() {
  local app_path="$1"
  local identity="$2"
  local codesign_args=(--force --sign "$identity" --timestamp=none)

  # Sign nested beta services and frameworks from the inside out.
  while IFS= read -r -d '' nested; do
    codesign "${codesign_args[@]}" "$nested" || return 1
  done < <(find "$app_path/Contents" -depth -type d \
    \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
  codesign "${codesign_args[@]}" "$app_path" || return 1
  codesign --verify --deep --strict "$app_path"
}

# Sign a staged copy before touching the installed app, so a signing failure
# never leaves a half-signed Ice in place (mixed signatures fail to load Sparkle).
stage_and_sign_app() {
  STAGING_TMPDIR="$(mktemp -d)"
  STAGED_APP_PATH="$STAGING_TMPDIR/Ice.app"
  ditto --norsrc --noextattr "$INSTALL_APP_PATH" "$STAGED_APP_PATH"
  if sign_app_with_identity "$STAGED_APP_PATH" "$SIGNING_IDENTITY" >/dev/null; then
    return
  fi

  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "  ERROR: Ad-hoc signing failed; the installed app was not changed."
    exit 1
  fi

  echo "  WARN: Signing with ${SIGNING_IDENTITY_NAME} failed; falling back to ad-hoc signing."
  SIGNING_IDENTITY="-"
  rm -rf "$STAGED_APP_PATH"
  ditto --norsrc --noextattr "$INSTALL_APP_PATH" "$STAGED_APP_PATH"
  sign_app_with_identity "$STAGED_APP_PATH" "-" >/dev/null ||
    { echo "  ERROR: Ad-hoc signing failed; the installed app was not changed."; exit 1; }
}

xcodebuild_available() {
  xcodebuild -version >/dev/null 2>&1
}

build_local_app() {
  echo "=== Building Ice ==="
  xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Release \
    -derivedDataPath build.noindex \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    DEBUG_INFORMATION_FORMAT=dwarf \
    build 2>&1 | tail -3
  INSTALL_APP_PATH="build.noindex/Build/Products/Release/Ice.app"
}

download_artifact_app() {
  local repo="${ICE_ARTIFACT_REPO:-mariowabnig/Ice}"
  local workflow="${ICE_ARTIFACT_WORKFLOW:-build-artifact.yml}"
  local branch="${ICE_ARTIFACT_BRANCH:-main}"
  local artifact_name="${ICE_ARTIFACT_NAME:-Ice-app}"
  local run_id="${ICE_ARTIFACT_RUN_ID:-}"

  echo "=== Fetching Ice artifact ==="
  if ! command -v gh >/dev/null 2>&1; then
    echo "  ERROR: Full Xcode is unavailable and GitHub CLI (gh) is not installed."
    echo "  Install Xcode for local builds, or install/authenticate gh for artifact installs."
    exit 1
  fi

  if [[ -z "$run_id" ]]; then
    run_id="$(
      gh run list \
        --repo "$repo" \
        --workflow "$workflow" \
        --branch "$branch" \
        --status success \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId'
    )"
  fi

  if [[ -z "$run_id" || "$run_id" == "null" ]]; then
    echo "  ERROR: No successful ${workflow} run found on ${repo}/${branch}."
    echo "  Trigger the workflow once, or set ICE_ARTIFACT_RUN_ID to a known good run."
    exit 1
  fi

  ARTIFACT_TMPDIR="$(mktemp -d)"
  local download_dir="$ARTIFACT_TMPDIR/download"
  local app_dir="$ARTIFACT_TMPDIR/app"
  mkdir -p "$download_dir" "$app_dir"

  gh run download "$run_id" \
    --repo "$repo" \
    --name "$artifact_name" \
    --dir "$download_dir"

  local zip_path="$download_dir/Ice.app.zip"
  if [[ ! -f "$zip_path" ]]; then
    zip_path="$(find "$download_dir" -name "*.zip" -print | head -n 1)"
  fi
  if [[ -z "$zip_path" || ! -f "$zip_path" ]]; then
    echo "  ERROR: Downloaded artifact did not contain Ice.app.zip."
    exit 1
  fi

  ditto -x -k "$zip_path" "$app_dir"
  if [[ ! -d "$app_dir/Ice.app" ]]; then
    echo "  ERROR: Downloaded artifact did not unpack to Ice.app."
    exit 1
  fi

  INSTALL_APP_PATH="$app_dir/Ice.app"
  echo "  Using artifact ${artifact_name} from run ${run_id}."
}

prepare_install_source() {
  if xcodebuild_available; then
    build_local_app
    return
  fi

  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  echo "  Full Xcode is not available locally."
  echo "  Current developer directory: ${developer_dir:-not set}"
  echo "  Falling back to the latest GitHub Actions app artifact."
  download_artifact_app
}

if [[ -n "${ICE_INSTALL_SOURCE:-}" ]]; then
  INSTALL_APP_PATH="$ICE_INSTALL_SOURCE"
else
  prepare_install_source
fi
[[ -d "$INSTALL_APP_PATH/Contents" ]] || { echo "ERROR: Invalid app source: $INSTALL_APP_PATH"; exit 1; }

echo "=== Preparing signing identity ==="
resolve_signing_identity

echo "=== Signing ==="
stage_and_sign_app

if [[ "${ICE_INSTALL_NO_STOP:-0}" != "1" ]]; then
  echo "=== Stopping Ice ==="
  pkill -x Ice 2>/dev/null || true
  sleep 1
fi

echo "=== Installing ==="
if [[ -e "$DESTINATION_APP_PATH" ]]; then
  backup_dir="${DESTINATION_APP_PATH%.app}-backups.noindex"
  mkdir -p "$backup_dir"
  backup_path="$backup_dir/Ice-$(date +%Y%m%d-%H%M%S).app"
  [[ ! -e "$backup_path" ]] || { echo "ERROR: Backup already exists: $backup_path"; exit 1; }
  mv "$DESTINATION_APP_PATH" "$backup_path"
  echo "  Previous app preserved at $backup_path"
fi
ditto --norsrc --noextattr "$STAGED_APP_PATH" "$DESTINATION_APP_PATH"
codesign --verify --deep --strict "$DESTINATION_APP_PATH"

if [[ "${ICE_INSTALL_NO_LAUNCH:-0}" != "1" ]]; then
  echo "=== Launching ==="
  open "$DESTINATION_APP_PATH"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "=== Done! Existing permissions were left in place, but this app is ad-hoc signed ==="
else
  echo "=== Done! Existing permissions were left in place ==="
  echo "If this is the first stable local-signed install, approve Ice once in Accessibility."
fi

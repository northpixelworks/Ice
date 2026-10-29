#!/bin/bash
set -euo pipefail

SIGNING_IDENTITY_NAME="Ice Local Development"
SIGNING_IDENTITY="-"
INSTALL_APP_PATH=""
ARTIFACT_TMPDIR=""
STAGING_TMPDIR=""
STAGED_APP_PATH=""
KEY_TMPDIR=""
BACKUP_PATH=""
INSTALL_DONE=0
INSTALL_STARTED=0
ICE_STOPPED=0
DESTINATION_APP_PATH="${ICE_INSTALL_APP_PATH:-/Applications/Ice.app}"
[[ "$DESTINATION_APP_PATH" == *.app ]] || { echo "ERROR: ICE_INSTALL_APP_PATH must end in .app: $DESTINATION_APP_PATH"; exit 1; }
LOGIN_KEYCHAIN="$(
  security default-keychain -d user 2>/dev/null |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' || true
)"
LOGIN_KEYCHAIN="${LOGIN_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"

# Explicit template: macOS mktemp ignores TMPDIR without one.
make_tmpdir() {
  mktemp -d "${TMPDIR:-/tmp}/ice.XXXXXX"
}

cleanup_tmpdirs() {
  local dir
  for dir in "$ARTIFACT_TMPDIR" "$STAGING_TMPDIR" "$KEY_TMPDIR"; do
    if [[ -n "$dir" && -d "$dir" ]]; then
      rm -rf "$dir"
    fi
  done
}

# If anything fails after the installed app was moved to its backup, put the
# backup back so a failed install never leaves Ice missing or half-copied.
restore_backup_if_incomplete() {
  if [[ "$INSTALL_DONE" == "1" || "$INSTALL_STARTED" != "1" ]]; then
    return 0
  fi

  if ! rm -rf "$DESTINATION_APP_PATH"; then
    echo "  ERROR: Could not remove the incomplete app; previous app remains at $BACKUP_PATH"
    return 1
  fi
  if [[ -z "$BACKUP_PATH" ]]; then
    return 0
  fi
  echo "  ERROR: Install did not finish; restoring the previous app."
  if mv "$BACKUP_PATH" "$DESTINATION_APP_PATH"; then
    echo "  Restored $DESTINATION_APP_PATH"
    if [[ "$ICE_STOPPED" == "1" && "${ICE_INSTALL_NO_LAUNCH:-0}" != "1" ]]; then
      open "$DESTINATION_APP_PATH" || true
    fi
  else
    echo "  ERROR: Could not restore the previous app; it is still at $BACKUP_PATH"
  fi
}

on_exit() {
  local status=$?
  # Recovery must not short-circuit cleanup, or replace the install's status.
  trap - EXIT
  set +e
  restore_backup_if_incomplete
  cleanup_tmpdirs
  exit "$status"
}

trap on_exit EXIT

# No -v: the self-signed certificate is never "trusted", but codesign can still
# use it, and its fixed fingerprint keeps the Accessibility grant across builds.
find_local_signing_identity() {
  security find-identity -p codesigning 2>/dev/null |
    awk -v name="$SIGNING_IDENTITY_NAME" '$0 ~ "\"" name "\"" { print $2; exit }' || true
}

create_local_signing_identity() {
  if ! command -v openssl >/dev/null 2>&1; then
    echo "  WARN: openssl not found."
    return 1
  fi

  # Tracked globally so the EXIT trap removes the unencrypted key on interrupts.
  KEY_TMPDIR="$(make_tmpdir)" || return 1

  local key_path="$KEY_TMPDIR/ice-local-dev.key"
  local cert_path="$KEY_TMPDIR/ice-local-dev.crt"
  local p12_path="$KEY_TMPDIR/ice-local-dev.p12"
  # Throwaway password: the .p12 only carries the key into the keychain.
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
    -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1 || return 1

  # OpenSSL 3+ defaults to AES/PBKDF2 PKCS#12, which `security import` rejects
  # ("MAC verification failed"); force the SHA1/3DES format macOS understands.
  # Tested with Homebrew OpenSSL 4.1 and macOS LibreSSL 3.3.
  openssl pkcs12 \
    -export \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$key_path" \
    -in "$cert_path" \
    -out "$p12_path" \
    -name "$SIGNING_IDENTITY_NAME" \
    -passout pass:"$p12_password" >/dev/null 2>&1 || return 1
  rm -f "$key_path"

  if ! security import "$p12_path" \
    -k "$LOGIN_KEYCHAIN" \
    -P "$p12_password" \
    -T /usr/bin/codesign >/dev/null; then
    echo "  WARN: Could not import the local signing identity into ${LOGIN_KEYCHAIN}."
    return 1
  fi

  rm -rf "$KEY_TMPDIR"
  KEY_TMPDIR=""
}

ADHOC_HINT="Set ICE_ADHOC_SIGNING=1 to install ad-hoc anyway (Accessibility must then be re-approved)."

resolve_signing_identity() {
  if [[ "${ICE_ADHOC_SIGNING:-0}" == "1" ]]; then
    SIGNING_IDENTITY="-"
    echo "  WARN: ICE_ADHOC_SIGNING=1: signing ad-hoc; Accessibility will need re-approval."
    return
  fi

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

  # Stop rather than silently switching to ad-hoc: a new signature loses the
  # Accessibility grant. Ice has not been stopped or changed at this point.
  echo "  ERROR: Could not create a stable local signing identity; the installed app was not changed."
  echo "  $ADHOC_HINT"
  exit 1
}

sign_app_with_identity() {
  local app_path="$1"
  local identity="$2"
  local codesign_args=(--force --sign "$identity" --timestamp=none)
  local nested
  local nested_list="$STAGING_TMPDIR/nested-bundles"

  # Sign nested beta services and frameworks from the inside out.
  # Check find's status explicitly; process substitution hides its failures.
  find "$app_path/Contents" -depth -type d \
    \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0 > "$nested_list" || return 1
  while IFS= read -r -d '' nested; do
    codesign "${codesign_args[@]}" "$nested" || return 1
  done < "$nested_list"
  codesign "${codesign_args[@]}" "$app_path" || return 1
  codesign --verify --deep --strict "$app_path"
}

# Sign a staged copy before touching the installed app, so a signing failure
# never leaves a half-signed Ice in place (mixed signatures fail to load Sparkle).
stage_and_sign_app() {
  STAGING_TMPDIR="$(make_tmpdir)"
  STAGED_APP_PATH="$STAGING_TMPDIR/Ice.app"
  ditto --norsrc --noextattr "$INSTALL_APP_PATH" "$STAGED_APP_PATH"
  # stdout only: codesign's errors still reach the terminal.
  if sign_app_with_identity "$STAGED_APP_PATH" "$SIGNING_IDENTITY" >/dev/null; then
    return
  fi

  echo "  ERROR: Signing failed; the installed app was not changed."
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    echo "  $ADHOC_HINT"
  fi
  exit 1
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
  local repo="${ICE_ARTIFACT_REPO:-northpixelworks/Ice}"
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

  ARTIFACT_TMPDIR="$(make_tmpdir)"
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

# Pick the backup name before stopping Ice, so a name clash exits with Ice untouched.
backup_dir="${DESTINATION_APP_PATH%.app}-backups.noindex"
backup_path=""
if [[ -e "$DESTINATION_APP_PATH" || -L "$DESTINATION_APP_PATH" ]]; then
  backup_path="$backup_dir/Ice-$(date +%Y%m%d-%H%M%S).app"
  [[ ! -e "$backup_path" && ! -L "$backup_path" ]] || { echo "ERROR: Backup already exists: $backup_path"; exit 1; }
fi

if [[ "${ICE_INSTALL_NO_STOP:-0}" != "1" ]]; then
  echo "=== Stopping Ice ==="
  if pkill -x Ice 2>/dev/null; then
    ICE_STOPPED=1
  fi
  sleep 1
fi

echo "=== Installing ==="
if [[ -n "$backup_path" ]]; then
  mkdir -p "$backup_dir"
  mv "$DESTINATION_APP_PATH" "$backup_path"
  BACKUP_PATH="$backup_path"
  echo "  Previous app preserved at $backup_path"
fi
INSTALL_STARTED=1
ditto --norsrc --noextattr "$STAGED_APP_PATH" "$DESTINATION_APP_PATH"
codesign --verify --deep --strict "$DESTINATION_APP_PATH"
INSTALL_DONE=1

if [[ "${ICE_INSTALL_NO_LAUNCH:-0}" != "1" ]]; then
  echo "=== Launching ==="
  open "$DESTINATION_APP_PATH"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "=== Done! Ice is ad-hoc signed: macOS will likely ask for Accessibility again ==="
  echo "In Accessibility, remove Ice with − and add /Applications/Ice.app again."
else
  echo "=== Done! Signed with ${SIGNING_IDENTITY_NAME}; an existing Accessibility grant is kept ==="
  echo "If Ice still asks for Accessibility, remove it with − in Accessibility and add /Applications/Ice.app again (once per certificate)."
fi

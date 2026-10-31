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
COPY_STARTED=0
PENDING_SIGNAL=""
ICE_STOPPED=0
DESTINATION_APP_PATH="${ICE_INSTALL_APP_PATH:-/Applications/Ice.app}"
[[ "$DESTINATION_APP_PATH" == *.app ]] || { echo "ERROR: ICE_INSTALL_APP_PATH must end in .app: $DESTINATION_APP_PATH"; exit 1; }
# One installer per destination. The lock sits in the app's folder, so every
# spelling of that folder (symlinks, case on APFS) reaches the same lock.
if [[ "$DESTINATION_APP_PATH" == */* ]]; then
  INSTALL_LOCK="${DESTINATION_APP_PATH%/*}/.${DESTINATION_APP_PATH##*/}.install-lock"
else
  INSTALL_LOCK=".${DESTINATION_APP_PATH}.install-lock"
fi
# PID plus a random part: a stale lock from an earlier process that had our PID
# is never mistaken for ours.
LOCK_TOKEN="$$-$RANDOM$RANDOM"
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

lock_owner() {
  readlink "$INSTALL_LOCK" 2>/dev/null || true
}

# A symlink is created atomically together with its owner token, so no signal
# can leave an ownerless lock (mkdir plus a PID file would have that window).
# Ownership is read back instead of trusting ln's status.
acquire_install_lock() {
  # A first install may target a folder that does not exist yet (~/Applications).
  if [[ "$INSTALL_LOCK" == */* && ! -d "${INSTALL_LOCK%/*}" ]]; then
    mkdir -p "${INSTALL_LOCK%/*}" || { echo "ERROR: Could not create the destination folder: ${INSTALL_LOCK%/*}"; exit 1; }
  fi
  if [[ -e "$INSTALL_LOCK" && ! -L "$INSTALL_LOCK" ]]; then
    # ln would create its link inside a directory here.
    echo "ERROR: Install lock path is occupied by something else; nothing was changed: $INSTALL_LOCK"
    exit 1
  fi
  ln -sn "$LOCK_TOKEN" "$INSTALL_LOCK" 2>/dev/null || true
  local owner pid
  owner="$(lock_owner)"
  if [[ "$owner" == "$LOCK_TOKEN" ]]; then
    return 0
  fi
  if [[ -z "$owner" ]]; then
    echo "ERROR: Could not create the install lock; nothing was changed: $INSTALL_LOCK"
    exit 1
  fi

  # Never break someone else's lock: a guess about a dead owner could let two
  # installers move the same app.
  pid="${owner%%-*}"
  echo "ERROR: Another install into $DESTINATION_APP_PATH holds $INSTALL_LOCK (PID $pid); nothing was changed."
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "  Wait for it to finish, then run the installer again."
  else
    echo "  PID $pid is not running (or belongs to another user): the lock is probably left over from a killed installer, crash or power loss."
    # %q keeps the command usable for paths with quotes or spaces.
    printf '  Make sure no installer is running and check %s and its backups, then remove the lock: rm %q\n' "$DESTINATION_APP_PATH" "$INSTALL_LOCK"
  fi
  exit 75
}

# Only the owner removes the lock; a refused installer leaves it alone.
release_install_lock() {
  if [[ "$(lock_owner)" == "$LOCK_TOKEN" ]]; then
    rm -f "$INSTALL_LOCK"
  fi
}

# If anything fails after the installed app was moved to its backup, put the
# backup back so a failed install never leaves Ice missing or half-copied.
restore_backup_if_incomplete() {
  if [[ "$INSTALL_DONE" == "1" || "$INSTALL_STARTED" != "1" ]]; then
    return 0
  fi
  # Until the copy starts, an app at the destination is the untouched original
  # (e.g. a failed backup move that left a partial backup): never replace it.
  if [[ "$COPY_STARTED" != "1" ]] && [[ -e "$DESTINATION_APP_PATH" || -L "$DESTINATION_APP_PATH" ]]; then
    return 0
  fi

  if ! rm -rf "$DESTINATION_APP_PATH"; then
    if [[ -n "$BACKUP_PATH" ]]; then
      echo "  ERROR: Could not remove the incomplete app; previous app remains at $BACKUP_PATH"
    else
      echo "  ERROR: Could not remove the incomplete app at $DESTINATION_APP_PATH"
    fi
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

# Recovery runs once: a signal arriving during it is held until it finishes
# (a second run would delete the app it just restored), then exits by it.
finish() {
  trap - EXIT
  trap 'PENDING_SIGNAL="${PENDING_SIGNAL:-HUP}"' HUP
  trap 'PENDING_SIGNAL="${PENDING_SIGNAL:-INT}"' INT
  trap 'PENDING_SIGNAL="${PENDING_SIGNAL:-TERM}"' TERM
  set +e
  restore_backup_if_incomplete
  cleanup_tmpdirs
  # Last, so no other installer starts while recovery is still running.
  release_install_lock
  if [[ -n "$PENDING_SIGNAL" ]]; then
    trap - "$PENDING_SIGNAL"
    kill -s "$PENDING_SIGNAL" "$$"
  fi
}

on_exit() {
  local status=$?
  # Recovery must not short-circuit cleanup, or replace the install's status.
  finish
  exit "$status"
}

# Bash runs a signal trap only after the running command returns, so recovery
# never races a half-finished `mv` or `ditto`. Then exit by the same signal.
on_signal() {
  PENDING_SIGNAL="$1"
  finish
}

trap on_exit EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# Lock before building or touching the keychain or the installed app.
acquire_install_lock

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

# Pick the backup name before stopping Ice. Two installs in the same second get
# -2, -3, ... instead of failing; an existing entry is never touched or reused.
backup_dir="${DESTINATION_APP_PATH%.app}-backups.noindex"
backup_path=""
if [[ -e "$DESTINATION_APP_PATH" || -L "$DESTINATION_APP_PATH" ]]; then
  backup_stem="$backup_dir/Ice-$(date +%Y%m%d-%H%M%S)"
  backup_path="$backup_stem.app"
  backup_suffix=1
  while [[ -e "$backup_path" || -L "$backup_path" ]]; do
    backup_suffix=$((backup_suffix + 1))
    (( backup_suffix <= 99 )) || { echo "ERROR: No free backup name for $backup_stem.app; nothing was changed."; exit 1; }
    backup_path="$backup_stem-$backup_suffix.app"
  done
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
  # Record the backup before the move, so an interrupt right after it still restores.
  BACKUP_PATH="$backup_path"
  INSTALL_STARTED=1
  mv "$DESTINATION_APP_PATH" "$backup_path"
  echo "  Previous app preserved at $backup_path"
fi
INSTALL_STARTED=1
COPY_STARTED=1
ditto --norsrc --noextattr "$STAGED_APP_PATH" "$DESTINATION_APP_PATH"
codesign --verify --deep --strict "$DESTINATION_APP_PATH"
INSTALL_DONE=1

# Keep only the newest backups. Runs after a verified install, so a failure here
# only warns. Touches nothing but real folders named like our own backups.
prune_backups() {
  local keep="${ICE_KEEP_BACKUPS:-5}"
  [[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "  WARN: ICE_KEEP_BACKUPS must be a positive number; no backups removed."; return 0; }
  [[ -d "$backup_dir" && ! -L "$backup_dir" ]] || return 0
  # Byte order for [[ < ]], whatever the user's locale.
  local LC_ALL=C
  local entry name suffix key
  local -a keys=()
  for entry in "$backup_dir"/Ice-*.app; do
    name="${entry##*/}"
    [[ "$name" =~ ^Ice-([0-9]{8}-[0-9]{6})(-([0-9]{1,2}))?\.app$ ]] || continue
    [[ -d "$entry" && ! -L "$entry" ]] || continue
    suffix="${BASH_REMATCH[3]:-1}"
    # Sortable key: timestamp, then -2, -3 ... after the plain name.
    printf -v key '%s-%02d' "${BASH_REMATCH[1]}" "$suffix"
    keys+=("$key/$name")
  done
  (( ${#keys[@]} > keep )) || return 0
  # Newest first (insertion sort: the installer's PATH has no sort).
  local i j current
  for ((i = 1; i < ${#keys[@]}; i++)); do
    current="${keys[i]}"
    for ((j = i - 1; j >= 0; j--)); do
      [[ "${keys[j]}" < "$current" ]] || break
      keys[j + 1]="${keys[j]}"
    done
    keys[j + 1]="$current"
  done
  echo "=== Removing old backups (keeping newest $keep) ==="
  for ((i = keep; i < ${#keys[@]}; i++)); do
    entry="$backup_dir/${keys[i]#*/}"
    # Never remove the backup this run just made, even with a skewed clock.
    [[ "$entry" != "$backup_path" ]] || continue
    if rm -rf "$entry"; then
      echo "  Removed $entry"
    else
      echo "  WARN: Could not remove old backup $entry"
    fi
  done
}
prune_backups

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

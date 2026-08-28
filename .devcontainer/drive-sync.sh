#!/usr/bin/env bash
# Carry Claude Code state (memories, conversations, plans) between codespaces
# through Google Drive. The code itself already travels via git -- this is only
# for the state a rebuild would otherwise destroy.
#
#   drive-sync.sh push      stage -> redact -> upload to Drive
#   drive-sync.sh pull      download from Drive -> merge into ~/.claude
#   drive-sync.sh stage     stage + redact locally, upload nothing (dry run)
#   drive-sync.sh status    what is here, what is on Drive
#   drive-sync.sh doctor    check rclone + credentials without touching data
#
# Credentials come from the GDRIVE_TOKEN Codespaces secret, never from a config
# file on disk, so a rebuilt codespace picks them up automatically.
set -euo pipefail

RCLONE_VERSION="1.75.0"
RCLONE_SHA256="aa2804e08f48250e71009c727124b6341cd0288465804a9a09d14663cabafbaa"
RCLONE="$HOME/bin/rclone"

REMOTE="gdrive"
REMOTE_ROOT="${DRIVE_SYNC_ROOT:-MaiChatState}"
DEST="$REMOTE:$REMOTE_ROOT"

CLAUDE_DIR="$HOME/.claude"
PROJECT_KEY="${DRIVE_SYNC_PROJECT:--workspaces-Maichat}"
PROJECT_DIR="$CLAUDE_DIR/projects/$PROJECT_KEY"
REPO_DIR="${DRIVE_SYNC_REPO:-/workspaces/Maichat}"
STAGE="$HOME/.drive-stage"
REDACT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive-redact.py"

log() { printf '[drive-sync] %s\n' "$*" >&2; }
die() { printf '[drive-sync] ERROR: %s\n' "$*" >&2; exit 1; }

ensure_rclone() {
  if [ -x "$RCLONE" ] && "$RCLONE" version 2>/dev/null | grep -q "v$RCLONE_VERSION"; then
    return
  fi
  log "installing rclone v$RCLONE_VERSION"
  local tmp zip
  tmp="$(mktemp -d)"
  zip="$tmp/rclone.zip"
  curl -fsSL -o "$zip" \
    "https://downloads.rclone.org/v$RCLONE_VERSION/rclone-v$RCLONE_VERSION-linux-amd64.zip"
  echo "$RCLONE_SHA256  $zip" | sha256sum -c - >/dev/null \
    || die "rclone checksum mismatch -- refusing to install"
  unzip -q -o "$zip" -d "$tmp"
  mkdir -p "$HOME/bin"
  install -m 0755 "$tmp/rclone-v$RCLONE_VERSION-linux-amd64/rclone" "$RCLONE"
  rm -rf "$tmp"
}
# Build rclone's remote purely from the environment, so nothing secret is
# written to disk. GDRIVE_TOKEN is the JSON blob printed by `rclone authorize`.
ensure_remote() {
  [ -n "${GDRIVE_TOKEN:-}" ] || die "GDRIVE_TOKEN is not set -- run 'drive-sync.sh doctor' for setup steps"
  export RCLONE_CONFIG_GDRIVE_TYPE="drive"
  export RCLONE_CONFIG_GDRIVE_TOKEN="$GDRIVE_TOKEN"
  export RCLONE_CONFIG_GDRIVE_SCOPE="${GDRIVE_SCOPE:-drive.file}"
  [ -n "${GDRIVE_CLIENT_ID:-}" ] && export RCLONE_CONFIG_GDRIVE_CLIENT_ID="$GDRIVE_CLIENT_ID"
  [ -n "${GDRIVE_CLIENT_SECRET:-}" ] && export RCLONE_CONFIG_GDRIVE_CLIENT_SECRET="$GDRIVE_CLIENT_SECRET"
  [ -n "${GDRIVE_ROOT_FOLDER_ID:-}" ] && export RCLONE_CONFIG_GDRIVE_ROOT_FOLDER_ID="$GDRIVE_ROOT_FOLDER_ID"
  # No config file at all; everything above is enough for rclone to resolve it.
  export RCLONE_CONFIG="/dev/null"
  return 0
}

# Explicit allowlist. Anything not named here does not leave the machine.
# Deliberately excluded: settings.json (holds ANTHROPIC_API_KEY), sessions/ and
# session-env/ and shell-snapshots/ (environment dumps), plugins/ and cache/
# (large and re-downloadable), ~/.config/gh (holds the GitHub OAuth token).
stage_push() {
  rm -rf "$STAGE"
  mkdir -p "$STAGE"/{memory,conversations,plans,scratch}

  if [ -d "$PROJECT_DIR/memory" ]; then
    cp -a "$PROJECT_DIR/memory/." "$STAGE/memory/"
  fi
  if compgen -G "$PROJECT_DIR"/*.jsonl >/dev/null; then
    cp -a "$PROJECT_DIR"/*.jsonl "$STAGE/conversations/"
  fi
  if [ -d "$CLAUDE_DIR/plans" ]; then
    cp -a "$CLAUDE_DIR/plans/." "$STAGE/plans/"
  fi
  [ -f "$CLAUDE_DIR/history.jsonl" ] && cp -a "$CLAUDE_DIR/history.jsonl" "$STAGE/history.jsonl"

  # Untracked, non-ignored working-tree files -- real progress git is not carrying.
  if [ -d "$REPO_DIR/.git" ]; then
    ( cd "$REPO_DIR" && git ls-files --others --exclude-standard -z ) \
      | while IFS= read -r -d '' f; do
          [ -f "$REPO_DIR/$f" ] || continue
          [ "$(stat -c%s "$REPO_DIR/$f")" -le 1048576 ] || continue
          mkdir -p "$STAGE/scratch/$(dirname "$f")"
          cp -a "$REPO_DIR/$f" "$STAGE/scratch/$f"
        done
  fi

  {
    echo "synced_at   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "codespace   ${CODESPACE_NAME:-$(hostname)}"
    echo "repo_head   $(cd "$REPO_DIR" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo n/a)"
    echo "rclone      v$RCLONE_VERSION"
  } > "$STAGE/MANIFEST.txt"
}
cmd_push() {
  ensure_rclone
  ensure_remote
  stage_push
  log "staged $(find "$STAGE" -type f | wc -l) file(s), $(du -sh "$STAGE" | cut -f1)"

  python3 "$REDACT" scrub "$STAGE"
  python3 "$REDACT" check "$STAGE" || die "redaction gate failed -- nothing uploaded"

  "$RCLONE" sync "$STAGE" "$DEST" \
    --create-empty-src-dirs \
    --drive-use-trash=true \
    --transfers 4 --checkers 8 \
    --stats-one-line --stats 10s \
    ${DRIVE_SYNC_EXTRA_FLAGS:-}
  log "pushed to $DEST"
  rm -rf "$STAGE"
}

cmd_pull() {
  ensure_rclone
  ensure_remote
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  "$RCLONE" copy "$DEST" "$STAGE" --stats-one-line --stats 10s
  [ -f "$STAGE/MANIFEST.txt" ] || die "no MANIFEST.txt at $DEST -- nothing has been pushed yet"
  log "remote manifest:"; sed 's/^/    /' "$STAGE/MANIFEST.txt" >&2

  mkdir -p "$PROJECT_DIR/memory" "$CLAUDE_DIR/plans"
  # Memories are the point of this: newest wins, per file.
  [ -d "$STAGE/memory" ] && cp -a -u "$STAGE/memory/." "$PROJECT_DIR/memory/"
  [ -d "$STAGE/plans" ] && cp -a -u "$STAGE/plans/." "$CLAUDE_DIR/plans/"
  # Transcripts are append-only history keyed by UUID; never clobber a local one.
  if [ -d "$STAGE/conversations" ]; then
    for f in "$STAGE"/conversations/*.jsonl; do
      [ -e "$f" ] || continue
      [ -e "$PROJECT_DIR/$(basename "$f")" ] || cp -a "$f" "$PROJECT_DIR/"
    done
  fi
  if [ -d "$STAGE/scratch" ]; then
    log "scratch files left in $STAGE/scratch -- copy into the repo by hand"
    return 0
  fi
  rm -rf "$STAGE"
  log "pulled from $DEST"
}
cmd_status() {
  ensure_rclone
  echo "local:"
  echo "  memories       $(ls -1 "$PROJECT_DIR/memory" 2>/dev/null | wc -l) file(s)"
  echo "  conversations  $(ls -1 "$PROJECT_DIR"/*.jsonl 2>/dev/null | wc -l) file(s)"
  echo "  plans          $(ls -1 "$CLAUDE_DIR/plans" 2>/dev/null | wc -l) file(s)"
  if [ -z "${GDRIVE_TOKEN:-}" ]; then
    echo "remote: unavailable (GDRIVE_TOKEN not set)"
    return 0
  fi
  ensure_remote
  echo "remote ($DEST):"
  "$RCLONE" size "$DEST" 2>/dev/null | sed 's/^/  /' || echo "  not reachable / not created yet"
  "$RCLONE" cat "$DEST/MANIFEST.txt" 2>/dev/null | sed 's/^/  /' || true
}

cmd_doctor() {
  ensure_rclone
  echo "rclone     $("$RCLONE" version | head -1)"
  echo "redactor   $([ -f "$REDACT" ] && echo present || echo MISSING) ($REDACT)"
  echo "remote     $DEST"
  if [ -z "${GDRIVE_TOKEN:-}" ]; then
    cat <<'SETUP'

GDRIVE_TOKEN is not set. One-time setup:

  1. Make your own Google OAuth client id. NOT optional -- rclone's shared
     client_id is being retired and stops working during 2026:
         https://rclone.org/drive/#making-your-own-client-id
     Save the pair as Codespaces secrets GDRIVE_CLIENT_ID / GDRIVE_CLIENT_SECRET.

  2. On a machine with a browser, install rclone and run:
         rclone authorize "drive" --drive-scope=drive.file \
           --client-id YOUR_ID --client-secret YOUR_SECRET
     Approve the Google prompt. It prints a JSON blob like
         {"access_token":"...","refresh_token":"...","expiry":"..."}

  3. Save that whole blob (including the braces) as a Codespaces user secret
     named GDRIVE_TOKEN, scoped to this repository:
         https://github.com/settings/codespaces
     or:  gh secret set GDRIVE_TOKEN --user --repos Ansh99999/Maichat

  4. Restart the codespace so the secrets are present in the environment, then:
         .devcontainer/drive-sync.sh doctor

Note: drive.file scope means rclone can only see files it created -- it cannot
read the rest of your Drive. The refresh_token is what keeps this working
long-term; the access_token in the blob expires within the hour.
SETUP
    return 1
  fi
  ensure_remote
  echo -n "auth       "
  if "$RCLONE" about "$REMOTE:" >/dev/null 2>&1; then
    echo "ok"; "$RCLONE" about "$REMOTE:" | sed 's/^/           /'
  else
    echo "FAILED -- token rejected or expired; redo step 1 above"; return 1
  fi
}

cmd_stage() {
  stage_push
  log "staged $(find "$STAGE" -type f | wc -l) file(s), $(du -sh "$STAGE" | cut -f1) at $STAGE"
  python3 "$REDACT" scrub "$STAGE"
  python3 "$REDACT" check "$STAGE"
}

case "${1:-}" in
  push)   cmd_push ;;
  pull)   cmd_pull ;;
  stage)  cmd_stage ;;
  status) cmd_status ;;
  doctor) cmd_doctor ;;
  *) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 2 ;;
esac

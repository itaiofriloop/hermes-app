#!/usr/bin/env bash
#
# backup.sh — Hermes backup: encrypt DB + personal files → hermes-data repo
#
# Usage: ./scripts/backup.sh
#
# Requires: sqlite3, age, git
# Reads AGE_RECIPIENT from config.yaml or env var.
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_DB="$HERMES_HOME/hermes.db"
HERMES_DATA_REPO="${HERMES_DATA_REPO:-$HOME/projects/hermes-data}"
CONFIG_FILE="${CONFIG_FILE:-$HOME/projects/hermes-app/config.yaml}"
TEMP_DIR="/tmp/hermes-backup-$$"

# ── Helpers ───────────────────────────────────────────────────
log()  { echo "📦 backup: $*"; }
err()  { echo "❌ backup: $*" >&2; exit 1; }

# ── Load AGE_RECIPIENT ────────────────────────────────────────
if [ -z "${AGE_RECIPIENT:-}" ]; then
  if [ -f "$CONFIG_FILE" ]; then
    AGE_RECIPIENT=$(grep -E '^AGE_RECIPIENT' "$CONFIG_FILE" | sed 's/.*=\s*//' | tr -d '"'"'" || true)
  fi
fi
[ -z "${AGE_RECIPIENT:-}" ] && err "AGE_RECIPIENT not set (in env or config.yaml)"
log "Recipient: $AGE_RECIPIENT"

# ── Validate prerequisites ───────────────────────────────────
command -v age    >/dev/null || err "age not found"
[ -f "$HERMES_DB" ]           || err "hermes.db not found at $HERMES_DB"
[ -d "$HERMES_DATA_REPO" ]    || err "hermes-data repo not found at $HERMES_DATA_REPO"

# sqlite3 CLI or Python sqlite3 module (one must be available)
SQLITE3_CLI=""
if command -v sqlite3 >/dev/null; then
  SQLITE3_CLI="sqlite3"
elif command -v python3 >/dev/null; then
  SQLITE3_CLI="python3"
else
  err "neither sqlite3 CLI nor python3 found"
fi

DB_OUT="$HERMES_DATA_REPO/database"
FILES_OUT="$HERMES_DATA_REPO/files"
MANIFEST="$HERMES_DATA_REPO/manifest.json"

mkdir -p "$DB_OUT" "$FILES_OUT"

# ── Step 1: SQLite consistent snapshot ────────────────────────
log "Creating SQLite snapshot..."
SNAPSHOT="$TEMP_DIR/hermes-backup.db"
mkdir -p "$TEMP_DIR"

if [ "$SQLITE3_CLI" = "sqlite3" ]; then
  sqlite3 "$HERMES_DB" ".backup '$SNAPSHOT'"
elif [ "$SQLITE3_CLI" = "python3" ]; then
  python3 -c "
import sqlite3, sys
src = sqlite3.connect(sys.argv[1])
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close()
src.close()
" "$HERMES_DB" "$SNAPSHOT"
fi
log "  → snapshot: $(stat -c %s "$SNAPSHOT" 2>/dev/null || echo '?') bytes"

# ── Step 2: Encrypt DB ───────────────────────────────────────
log "Encrypting database..."
DB_ENC="$DB_OUT/hermes.db.age"
age -r "$AGE_RECIPIENT" -o "$DB_ENC" "$SNAPSHOT"
log "  → $DB_ENC"

DB_SHA=$(sha256sum "$DB_ENC" | awk '{print $1}')
DB_SIZE=$(stat -c %s "$DB_ENC")

# ── Step 3: Encrypt personal files ───────────────────────────
FILES_ENC_LIST="[]"
# Backup everything in ~/.hermes EXCEPT the DB itself
# (DB already encrypted above) and the age private key
COUNT=0
while IFS= read -r -d '' f; do
  # Skip the DB (already backed up) and private keys
  case "$f" in
    *.db)        continue ;;
    *identity*)  continue ;;
    *.key)       continue ;;
  esac

  REL="files/$COUNT.age"
  age -r "$AGE_RECIPIENT" -o "$HERMES_DATA_REPO/$REL" "$f"

  F_SHA=$(sha256sum "$HERMES_DATA_REPO/$REL" | awk '{print $1}')
  F_SIZE=$(stat -c %s "$HERMES_DATA_REPO/$REL")
  ORIG_SHA=$(sha256sum "$f" | awk '{print $1}')

  # Build JSON entry — use generated ID, keep original size/SHA encrypted-side
  FILES_ENC_LIST=$(echo "$FILES_ENC_LIST" | jq -c \
    --arg id "$COUNT" \
    --arg enc "$REL" \
    --arg sha "$F_SHA" \
    --argjson size "$F_SIZE" \
    --arg orig_sha "$ORIG_SHA" \
    --arg orig_size "$(stat -c %s "$f")" \
    '. + [{"id":$id,"enc_path":$enc,"enc_sha256":$sha,"enc_size":$size,"orig_sha256":$orig_sha,"orig_size":$orig_size}]')

  COUNT=$((COUNT + 1))
done < <(find "$HERMES_HOME" -type f -print0 2>/dev/null | sort -z)

log "  → $COUNT file(s) encrypted"

# ── Step 4: Update manifest ──────────────────────────────────
log "Updating manifest..."
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg ts "$TIMESTAMP" \
  --arg db_enc "database/hermes.db.age" \
  --arg db_sha "$DB_SHA" \
  --argjson db_size "$DB_SIZE" \
  --argjson files "$FILES_ENC_LIST" \
  '{timestamp: $ts, database: {path: $db_enc, sha256: $db_sha, size: $db_size}, files: $files}' \
  > "$MANIFEST"

log "  → manifest written"

# ── Step 5: Clean up temp ────────────────────────────────────
rm -rf "$TEMP_DIR"

# ── Step 6: Git commit + push ────────────────────────────────
log "Committing to hermes-data..."
cd "$HERMES_DATA_REPO"
git add -A
git commit -m "backup: $TIMESTAMP" || log "  → no changes to commit"

# Push only if a remote is configured
if [ -n "$(git remote)" ]; then
  git push || err "git push failed"
  log "  → pushed to remote"
else
  log "  → no remote configured, commit saved locally"
fi

log "✅ Backup complete: $TIMESTAMP"

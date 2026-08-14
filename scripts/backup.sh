#!/usr/bin/env bash
#
# backup.sh — Hermes unencrypted backup: copy DB + workspace/memories → hermes-data repo
#
# Usage: ./scripts/backup.sh
#

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_APP="${HERMES_APP:-$HOME/projects/hermes-app}"
HERMES_DATA_REPO="${HERMES_DATA_REPO:-$HOME/projects/hermes-data}"

# Auto-detect main DB
HERMES_DB="${HERMES_DB:-}"
if [ -z "$HERMES_DB" ]; then
  for candidate in "$HERMES_HOME/state.db" "$HERMES_HOME/hermes.db"; do
    if [ -f "$candidate" ]; then
      HERMES_DB="$candidate"
      break
    fi
  done
fi

log()  { echo "📦 backup: $*"; }
err()  { echo "❌ backup: $*" >&2; exit 1; }

[ -f "$HERMES_DB" ]        || err "Database not found"
[ -d "$HERMES_DATA_REPO" ] || err "hermes-data repo not found at $HERMES_DATA_REPO"

DB_OUT="$HERMES_DATA_REPO/database"
FILES_OUT="$HERMES_DATA_REPO/files"
MANIFEST="$HERMES_DATA_REPO/manifest.json"

mkdir -p "$DB_OUT" "$FILES_OUT"

log "Backing up database directly..."
cp "$HERMES_DB" "$DB_OUT/state.db"

log "Exporting database tables to CSV..."
HERMES_DATA_REPO="$HERMES_DATA_REPO" python3 "$HERMES_APP/scripts/export_db_csv.py"

log "Backing up user data and workspace files via Python..."
HERMES_DATA_REPO="$HERMES_DATA_REPO" python3 "$HERMES_APP/scripts/backup_files.py"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
log "Committing to hermes-data..."
cd "$HERMES_DATA_REPO"
git add -A
git commit -m "backup (unencrypted): $TIMESTAMP" || log "no changes"

if [ -n "$(git remote)" ]; then
  git push || err "git push failed"
  log "pushed to remote"
else
  log "no remote configured"
fi

log "✅ Backup complete: $TIMESTAMP"

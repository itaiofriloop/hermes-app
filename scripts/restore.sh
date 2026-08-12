#!/usr/bin/env bash
#
# restore.sh — Hermes unencrypted restore: copy DB + files from hermes-data repo
#
# Usage: ./scripts/restore.sh [destination_dir]
#   destination_dir defaults to ~/.hermes
#

set -euo pipefail

DEST="${1:-$HOME/.hermes}"
HERMES_DATA_REPO="${HERMES_DATA_REPO:-$HOME/projects/hermes-data}"

log()  { echo "♻️  restore: $*"; }
err()  { echo "❌ restore: $*" >&2; exit 1; }

[ -d "$HERMES_DATA_REPO" ] || err "hermes-data repo not found at $HERMES_DATA_REPO"
MANIFEST="$HERMES_DATA_REPO/manifest.json"
[ -f "$MANIFEST" ] || err "manifest.json not found"

# Read manifest
DB_PATH=$(jq -r '.database.path' "$MANIFEST")
DB_SHA=$(jq -r '.database.sha256' "$MANIFEST")
FILE_COUNT=$(jq '.files | length' "$MANIFEST")
TIMESTAMP=$(jq -r '.timestamp' "$MANIFEST")

log "Backup timestamp: $TIMESTAMP"
log "Database: $DB_PATH (sha256: ${DB_SHA:0:16}...)"
log "Files: $FILE_COUNT"

# Restore database
DB_ENC="$HERMES_DATA_REPO/$DB_PATH"
[ -f "$DB_ENC" ] || err "Database file not found: $DB_ENC"
ACTUAL_SHA=$(sha256sum "$DB_ENC" | awk '{print $1}')
[ "$ACTUAL_SHA" = "$DB_SHA" ] || err "DB checksum mismatch! Expected $DB_SHA, got $ACTUAL_SHA"
log "DB checksum verified ✓"

mkdir -p "$DEST"
DB_DEST="$DEST/$(basename "$DB_PATH")"
cp "$DB_ENC" "$DB_DEST"
log "  → copied database to $DB_DEST"

# Restore personal/workspace files
if [ "$FILE_COUNT" -gt 0 ]; then
  log "Restoring $FILE_COUNT file(s)..."
  
  for i in $(seq 0 $((FILE_COUNT - 1))); do
    FILE_PATH=$(jq -r ".files[$i].path" "$MANIFEST")
    FILE_SHA=$(jq -r ".files[$i].sha256" "$MANIFEST")
    FILE_NAME=$(jq -r ".files[$i].name" "$MANIFEST")
    ORIG_PATH=$(jq -r ".files[$i].orig_path" "$MANIFEST")
    
    SRC="$HERMES_DATA_REPO/$FILE_PATH"
    [ -f "$SRC" ] || { err "File not found: $SRC"; }
    
    ACTUAL=$(sha256sum "$SRC" | awk '{print $1}')
    [ "$ACTUAL" = "$FILE_SHA" ] || err "File $FILE_NAME checksum mismatch!"
    
    cp "$SRC" "$DEST/$FILE_NAME"
    log "  → restored $FILE_NAME ✓"
  done
else
  log "No personal files to restore."
fi

log ""
log "✅ Restore complete!"
log "   Database:     $DB_DEST"
log "   Files:        $FILE_COUNT restored to $DEST/"
log "   Backup from:  $TIMESTAMP"
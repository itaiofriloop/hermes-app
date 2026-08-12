#!/usr/bin/env bash
#
# restore.sh — Hermes restore: decrypt DB + files from hermes-data repo
#
# Usage: ./scripts/restore.sh [destination_dir]
#   destination_dir defaults to ~/.hermes
#
# Requires: age, git, jq
# Reads AGE_IDENTITY from env or --identity flag.
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
DEST="${1:-$HOME/.hermes}"
HERMES_DATA_REPO="${HERMES_DATA_REPO:-$HOME/projects/hermes-data}"
AGE_IDENTITY="${AGE_IDENTITY:-}"

# ── Helpers ───────────────────────────────────────────────────
log()  { echo "♻️  restore: $*"; }
err()  { echo "❌ restore: $*" >&2; exit 1; }

# ── Validate prerequisites ───────────────────────────────────
command -v age >/dev/null || err "age not found"
command -v jq  >/dev/null || err "jq not found"
[ -d "$HERMES_DATA_REPO" ] || err "hermes-data repo not found at $HERMES_DATA_REPO"

MANIFEST="$HERMES_DATA_REPO/manifest.json"
[ -f "$MANIFEST" ] || err "manifest.json not found — nothing to restore"

# Check age identity
if [ -z "$AGE_IDENTITY" ]; then
  # Try default age identity location
  DEFAULT_KEY="$HOME/.config/age/identity.txt"
  if [ -f "$DEFAULT_KEY" ]; then
    AGE_IDENTITY="$DEFAULT_KEY"
    log "Using age identity from $DEFAULT_KEY"
  else
    err "AGE_IDENTITY not set and no default key found at $DEFAULT_KEY"
  fi
fi
[ -f "$AGE_IDENTITY" ] || err "Age identity file not found: $AGE_IDENTITY"

# ── Create destination ────────────────────────────────────────
mkdir -p "$DEST"
log "Destination: $DEST"

# ── Read manifest ─────────────────────────────────────────────
BACKUP_TS=$(jq -r '.timestamp' "$MANIFEST")
DB_PATH=$(jq -r '.database.path' "$MANIFEST")
DB_SHA=$(jq -r '.database.sha256' "$MANIFEST")
FILE_COUNT=$(jq '.files | length' "$MANIFEST")

log "Backup timestamp: $BACKUP_TS"
log "Database: $DB_PATH (sha256: ${DB_SHA:0:16}...)"
log "Files: $FILE_COUNT"

# ── Step 1: Verify + decrypt database ─────────────────────────
DB_ENC="$HERMES_DATA_REPO/$DB_PATH"
[ -f "$DB_ENC" ] || err "Encrypted DB not found: $DB_ENC"

# Verify checksum
ACTUAL_SHA=$(sha256sum "$DB_ENC" | awk '{print $1}')
[ "$ACTUAL_SHA" = "$DB_SHA" ] || err "DB checksum mismatch! Expected $DB_SHA, got $ACTUAL_SHA"
log "DB checksum verified ✓"

DB_DEST="$DEST/hermes.db"
age -d -i "$AGE_IDENTITY" -o "$DB_DEST" "$DB_ENC"
log "  → decrypted to $DB_DEST"

# ── Step 2: Decrypt personal files ───────────────────────────
if [ "$FILE_COUNT" -gt 0 ]; then
  log "Decrypting $FILE_COUNT file(s)..."

  for i in $(seq 0 $((FILE_COUNT - 1))); do
    ENC_PATH=$(jq -r ".files[$i].enc_path" "$MANIFEST")
    ENC_SHA=$(jq -r ".files[$i].enc_sha256" "$MANIFEST")
    ENC_SIZE=$(jq -r ".files[$i].enc_size" "$MANIFEST")
    FILE_ID=$(jq -r ".files[$i].id" "$MANIFEST")

    ENC_FULL="$HERMES_DATA_REPO/$ENC_PATH"
    [ -f "$ENC_FULL" ] || { err "Encrypted file not found: $ENC_FULL"; }

    # Verify checksum
    ACTUAL=$(sha256sum "$ENC_FULL" | awk '{print $1}')
    [ "$ACTUAL" = "$ENC_SHA" ] || err "File $FILE_ID checksum mismatch!"

    # Decrypt to destination with original basename (or ID if unknown)
    OUT_FILE="$DEST/restored-$FILE_ID"
    age -d -i "$AGE_IDENTITY" -o "$OUT_FILE" "$ENC_FULL"
    log "  → restored-$FILE_ID ($ENC_SIZE bytes) ✓"
  done
else
  log "No personal files to restore."
fi

# ── Summary ──────────────────────────────────────────────────
log ""
log "✅ Restore complete!"
log "   Database:     $DB_DEST"
log "   Files:        $FILE_COUNT restored to $DEST/"
log "   Backup from:  $BACKUP_TS"
log ""
log "⚠️  NOTE: Verify the restored data before using it."
log "   File names are restored as 'restored-<ID>' — map them"
log "   to original names manually or enhance manifest."

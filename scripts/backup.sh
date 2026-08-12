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
# Auto-detect main DB: state.db (current) or hermes.db (plan default)
HERMES_DB="${HERMES_DB:-}"
if [ -z "$HERMES_DB" ]; then
  for candidate in "$HERMES_HOME/state.db" "$HERMES_HOME/hermes.db"; do
    if [ -f "$candidate" ]; then
      HERMES_DB="$candidate"
      break
    fi
  done
fi
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
DB_ENC="$DB_OUT/state.db.age"
age -r "$AGE_RECIPIENT" -o "$DB_ENC" "$SNAPSHOT"
log "  → $DB_ENC"

DB_SHA=$(sha256sum "$DB_ENC" | awk '{print $1}')
DB_SIZE=$(stat -c %s "$DB_ENC")
export DB_SHA DB_SIZE

# ── Step 3 & 4: Encrypt user data & workspace data via Python ────
log "Encrypting core user data and workspace attachments/databases..."

python3 -c "
import os, subprocess, hashlib, json, datetime

data_repo = os.environ['HERMES_DATA_REPO']
recipient = os.environ['AGE_RECIPIENT']
files_out = os.path.join(data_repo, 'files')
os.makedirs(files_out, exist_ok=True)

# Sources to back up (user core data + workspace data/attachments)
sources = [
    os.path.expanduser('~/.hermes/memories'),
    os.path.expanduser('~/.hermes/config.yaml'),
    os.path.expanduser('~/.hermes/.env'),
    os.path.expanduser('~/workspace/data')
]

files_list = []
count = 0

for src in sources:
    if not os.path.exists(src):
        continue
        
    if os.path.isfile(src):
        item_paths = [src]
    else:
        item_paths = []
        for root, dirs, filenames in os.walk(src):
            # Skip node_modules or caches if inside workspace
            dirs[:] = [d for d in dirs if d not in ('node_modules', '.cache', 'dist', 'build')]
            for fn in filenames:
                item_paths.append(os.path.join(root, fn))
                
    for f_path in item_paths:
        if not os.path.isfile(f_path):
            continue
            
        # Skip temporary/lock files
        if f_path.endswith('.lock') or '-shm' in f_path or '-wal' in f_path:
            continue
            
        # Encrypt file
        rel_enc = f'files/{count}.age'
        full_enc = os.path.join(data_repo, rel_enc)
        
        res = subprocess.run(['age', '-r', recipient, '-o', full_enc, f_path], capture_output=True)
        if res.returncode != 0:
            print(f'Warning: failed to encrypt {f_path}: {res.stderr.decode()}', file=sys.stderr)
            continue
            
        with open(full_enc, 'rb') as ef:
            enc_data = ef.read()
            enc_sha = hashlib.sha256(enc_data).hexdigest()
            enc_size = len(enc_data)
            
        with open(f_path, 'rb') as of:
            orig_data = of.read()
            orig_sha = hashlib.sha256(orig_data).hexdigest()
            orig_size = len(orig_data)
            
        files_list.append({
            'id': str(count),
            'name': os.path.basename(f_path),
            'rel_path': os.path.relpath(f_path, os.path.expanduser('~')),
            'enc_path': rel_enc,
            'enc_sha256': enc_sha,
            'enc_size': enc_size,
            'orig_sha256': orig_sha,
            'orig_size': orig_size
        })
        count += 1

print(f'Encrypted {count} core user/workspace file(s).')

# Write manifest
timestamp = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
db_sha = os.environ.get('DB_SHA', '')
db_size = int(os.environ.get('DB_SIZE', '0'))

manifest_data = {
    'timestamp': timestamp,
    'database': {
        'path': 'database/state.db.age',
        'sha256': db_sha,
        'size': db_size
    },
    'files': files_list
}

with open(os.path.join(data_repo, 'manifest.json'), 'w') as mf:
    json.dump(manifest_data, mf, indent=2)

print('Manifest updated successfully.')
"

# ── Step 5: Clean up temp & Commit ─────────────────────────────
rm -rf "$TEMP_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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

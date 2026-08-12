#!/usr/bin/env bash
#
# backup.sh — Hermes unencrypted backup: copy DB + workspace/memories → hermes-data repo
#
# Usage: ./scripts/backup.sh
#

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
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

log "Backing up user data and workspace files via Python..."
python3 -c "
import os, shutil, hashlib, json, datetime

data_repo = os.environ['HERMES_DATA_REPO']
files_out = os.path.join(data_repo, 'files')

# Clean old files in files_out
for f in os.listdir(files_out):
    if f != '.gitkeep':
        p = os.path.join(files_out, f)
        if os.path.isfile(p):
            os.remove(p)

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
            dirs[:] = [d for d in dirs if d not in ('node_modules', '.cache', 'dist', 'build')]
            for fn in filenames:
                item_paths.append(os.path.join(root, fn))
                
    for f_path in item_paths:
        if not os.path.isfile(f_path):
            continue
        if f_path.endswith('.lock') or '-shm' in f_path or '-wal' in f_path:
            continue
            
        rel_dest = f'{count}_{os.path.basename(f_path)}'
        full_dest = os.path.join(files_out, rel_dest)
        
        shutil.copy2(f_path, full_dest)
        
        with open(full_dest, 'rb') as f:
            data = f.read()
            sha = hashlib.sha256(data).hexdigest()
            size = len(data)
            
        files_list.append({
            'id': str(count),
            'name': os.path.basename(f_path),
            'path': rel_dest,
            'orig_path': f_path,
            'sha256': sha,
            'size': size
        })
        count += 1

print(f'Backed up {count} file(s).')

timestamp = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
db_path_full = os.path.join(data_repo, 'database/state.db')
db_sha = ''
db_size = 0
if os.path.exists(db_path_full):
    with open(db_path_full, 'rb') as f:
        db_data = f.read()
        db_sha = hashlib.sha256(db_data).hexdigest()
        db_size = len(db_data)

manifest_data = {
    'timestamp': timestamp,
    'database': {
        'path': 'database/state.db',
        'sha256': db_sha,
        'size': db_size
    },
    'files': files_list
}

with open(os.path.join(data_repo, 'manifest.json'), 'w') as mf:
    json.dump(manifest_data, mf, indent=2)

print('Manifest updated.')
"

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

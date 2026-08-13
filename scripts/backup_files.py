#!/usr/bin/env python3
"""
Backup files from Hermes home and workspace to hermes-data repo,
preserving directory structure.
"""
import os
import shutil
import hashlib
import json
import datetime
import sys


def main():
    data_repo = os.environ.get('HERMES_DATA_REPO', os.path.expanduser('~/projects/hermes-data'))
    files_out = os.path.join(data_repo, 'files')

    # Clean old files in files_out (keep .gitkeep)
    for f in os.listdir(files_out):
        if f != '.gitkeep':
            p = os.path.join(files_out, f)
            if os.path.isfile(p):
                os.remove(p)
            elif os.path.isdir(p):
                shutil.rmtree(p)

    sources = [
        (os.path.expanduser('~/.hermes/memories'), 'hermes/memories'),
        (os.path.expanduser('~/.hermes/config.yaml'), 'hermes/config.yaml'),
        (os.path.expanduser('~/.hermes/.env'), 'hermes/.env'),
        (os.path.expanduser('~/.hermes/skills'), 'hermes/skills'),
        (os.path.expanduser('~/.hermes/plugins'), 'hermes/plugins'),
        (os.path.expanduser('~/.hermes/cron'), 'hermes/cron'),
        (os.path.expanduser('~/workspace'), 'workspace'),
    ]

    files_list = []
    count = 0

    for src, dest_prefix in sources:
        if not os.path.exists(src):
            print(f"  Skipping {src} (not found)")
            continue

        if os.path.isfile(src):
            item_paths = [src]
        else:
            item_paths = []
            for root, dirs, filenames in os.walk(src):
                # Skip common build/cache directories
                dirs[:] = [d for d in dirs if d not in ('node_modules', '.cache', 'dist', 'build', '__pycache__', '.git')]
                for fn in filenames:
                    item_paths.append(os.path.join(root, fn))

        for f_path in item_paths:
            if not os.path.isfile(f_path):
                continue
            # Skip lock/shm/wal files
            if f_path.endswith('.lock') or '-shm' in f_path or '-wal' in f_path:
                continue

            # Compute relative path from source root to preserve directory structure
            if os.path.isfile(src):
                # For single files, dest_prefix already includes the filename
                rel_dest = dest_prefix
            else:
                rel_path = os.path.relpath(f_path, src)
                rel_dest = os.path.join(dest_prefix, rel_path)
            
            full_dest = os.path.join(files_out, rel_dest)

            # Ensure parent directories exist
            os.makedirs(os.path.dirname(full_dest), exist_ok=True)

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


if __name__ == '__main__':
    main()
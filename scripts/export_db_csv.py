#!/usr/bin/env python3
"""
Export all SQLite tables to CSV files for backup.
"""
import sqlite3
import csv
import os
import sys


def export_table_to_csv(db_path, table_name, output_dir):
    """Export a single table to CSV."""
    db = sqlite3.connect(db_path)
    db.row_factory = sqlite3.Row
    
    # Get all rows
    rows = db.execute(f"SELECT * FROM {table_name}").fetchall()
    
    if not rows:
        print(f"  Table '{table_name}' is empty, skipping")
        return False
    
    # Get column names
    columns = rows[0].keys()
    
    output_path = os.path.join(output_dir, f"{table_name}.csv")
    os.makedirs(output_dir, exist_ok=True)
    
    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow(dict(row))
    
    print(f"  Exported {table_name}: {len(rows)} rows -> {output_path}")
    return True


def main():
    db_path = "/home/node/.hermes/state.db"
    output_dir = os.path.join(os.environ.get('HERMES_DATA_REPO', os.path.expanduser('~/projects/hermes-data')), 'database')
    
    db = sqlite3.connect(db_path)
    tables = [r[0] for r in db.execute('SELECT name FROM sqlite_master WHERE type="table"').fetchall()]
    db.close()
    
    print(f"Exporting {len(tables)} tables to CSV...")
    
    for table in tables:
        export_table_to_csv(db_path, table, output_dir)
    
    print("CSV export complete.")


if __name__ == '__main__':
    main()
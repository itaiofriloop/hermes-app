#!/usr/bin/env python3
"""
סנכרון דו-כיווני בין SQLite DB ↔ Google Sheets.

אופן הפעלה:
  python3 bin/finance-sync.py              # סנכרון מלא (כל הקולקשנים)
  python3 bin/finance-sync.py --loans      # רק הלוואות
  python3 bin/finance-sync.py --finance    # רק פיננסים
  python3 bin/finance-sync.py --dry-run    # בדיקה ללא שינויים

הסקריפט מדפיס דוח סנכרון מוכן לטלגרם.
במקרה של התנגשויות — מדפיס אותן לפתרון ידני.

ארכיטקטורה:
  1. קריאת שני הצדדים (DB + Sheets)
  2. השוואה לפי ID + hash
  3. 4 מצבים:
     - חדש ב-DB בלבד -> הוספה ל-Sheets
     - חדש ב-Sheets בלבד -> הוספה ל-DB
     - השתנה בצד אחד -> עדכון הצד השני
     - השתנה בשני הצדדים -> התנגשות -> התראה
  4. שמירת hash אחרון ב-sync_state להשוואה במרוץ הבא
"""

import sqlite3
import json
import sys
import os
import hashlib
from datetime import datetime

DB_PATH = "/home/node/workspace/data/app.db"

TAB_MAPPING = {
    "loans": {
        "sheet_name": "הלוואות וחובות (Loans & Debts)",
        "collection_id": "loans",
        "columns": [
            "תאריך (Date)",
            "תיאור (Description)",
            "כיוון (Direction)",
            "סכום (Amount)",
            "מטבע (Currency)",
            "יתרה (Balance)",
            "תאריך פירעון (Due Date)",
            "סטטוס (Status)",
            "הערות (Notes)",
            "מזהה (ID)",
        ],
        "field_map": {
            "תאריך (Date)": "doc_date",
            "תיאור (Description)": "description",
            "כיוון (Direction)": "direction",
            "סכום (Amount)": "amount",
            "מטבע (Currency)": "currency",
            "יתרה (Balance)": "balance",
            "תאריך פירעון (Due Date)": "due_date",
            "סטטוס (Status)": "status",
            "הערות (Notes)": "notes",
            "מזהה (ID)": "sheet_id",
        },
    },
    "finance": {
        "sheet_name": "תנועות (Transactions)",
        "collection_id": "finance",
        "columns": [
            "תאריך (Date)",
            "סוג (Type)",
            "קטגוריה (Category)",
            "סכום (Amount)",
            "תיאור / פירוט (Description)",
            "אמצעי תשלום (Payment Method)",
            "הערות (Notes)",
            "מזהה (ID)",
            "מטבע (Currency)",
            "תגיות (Tags)",
            "קבצים מצורפים (Attachments)",
            "מטא (Meta)",
        ],
        "field_map": {
            "תאריך (Date)": "doc_date",
            "סוג (Type)": "type",
            "קטגוריה (Category)": "category",
            "סכום (Amount)": "amount",
            "תיאור / פירוט (Description)": "description",
            "אמצעי תשלום (Payment Method)": "payment_method",
            "הערות (Notes)": "notes",
            "מזהה (ID)": "sheet_id",
            "מטבע (Currency)": "currency",
            "תגיות (Tags)": "tags",
            "קבצים מצורפים (Attachments)": "attachments",
            "מטא (Meta)": "meta",
        },
    },
}

TYPE_MAP = {
    "income": "הכנסה",
    "expense": "הוצאה",
    "הכנסה": "הכנסה",
    "הוצאה": "הוצאה",
}

CATEGORY_MAP = {
    "מזון": "מזון וסופר",
    "מזון וסופר": "מזון וסופר",
    "דיור": "דיור ומשכנתא/שכירות",
    "דיור ומשכנתא/שכירות": "דיור ומשכנתא/שכירות",
    "תחבורה": "רכב ותחבורה",
    "רכב ותחבורה": "רכב ותחבורה",
    "הכנסה": "שכר",
    "שכר": "שכר",
}


def translate_value(field, value):
    if field == "type":
        return TYPE_MAP.get(value, value)
    elif field == "category":
        return CATEGORY_MAP.get(value, value)
    return value


def get_db():
    db = sqlite3.connect(DB_PATH)
    db.row_factory = sqlite3.Row
    return db


def ensure_sync_tables(db):
    db.execute("""
        CREATE TABLE IF NOT EXISTS sync_tracking (
            row_id TEXT NOT NULL,
            collection_id TEXT NOT NULL,
            source TEXT NOT NULL,
            row_hash TEXT NOT NULL,
            synced_at TEXT NOT NULL,
            PRIMARY KEY (row_id, collection_id, source)
        )
    """)
    db.commit()


def compute_hash(data: dict) -> str:
    serialized = json.dumps(data, sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()[:16]


def get_last_hash(db, row_id, collection_id, source):
    row = db.execute(
        "SELECT row_hash FROM sync_tracking WHERE row_id = ? AND collection_id = ? AND source = ?",
        (row_id, collection_id, source)
    ).fetchone()
    return row[0] if row else None


def save_hash(db, row_id, collection_id, source, row_hash):
    db.execute(
        """INSERT INTO sync_tracking (row_id, collection_id, source, row_hash, synced_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(row_id, collection_id, source)
           DO UPDATE SET row_hash = ?, synced_at = ?""",
        (row_id, collection_id, source, row_hash, datetime.utcnow().isoformat(),
         row_hash, datetime.utcnow().isoformat())
    )


def read_db_rows(db, collection_id):
    rows = db.execute(
        "SELECT id, doc_date, data_json, tags_json, meta_json, updated_at "
        "FROM documents WHERE collection_id = ? ORDER BY doc_date",
        (collection_id,)
    ).fetchall()

    result = {}
    for row in rows:
        data = json.loads(row["data_json"])
        data["doc_date"] = row["doc_date"]
        data["id"] = row["id"]
        if row["tags_json"]:
            data["_tags"] = json.loads(row["tags_json"])
        if row["meta_json"]:
            data["_meta"] = json.loads(row["meta_json"])
        data["_updated_at"] = row["updated_at"]
        hash_data = {k: v for k, v in data.items() if not k.startswith("_")}
        data["_hash"] = compute_hash(hash_data)
        result[row["id"]] = data
    return result


def insert_db_row(db, collection_id, data, doc_date=None):
    import uuid
    row_id = str(uuid.uuid4())
    clean = {k: v for k, v in data.items() if not k.startswith("_")}
    tags = clean.pop("tags", None)
    meta = clean.pop("meta", None)
    clean.pop("attachments", None)

    tags_json = json.dumps(tags, ensure_ascii=False) if tags else None
    meta_json = json.dumps(meta, ensure_ascii=False) if meta else None

    db.execute(
        "INSERT INTO documents (id, collection_id, doc_date, status, data_json, tags_json, meta_json, created_at, updated_at) "
        "VALUES (?, ?, ?, 'open', ?, ?, ?, ?, ?)",
        (row_id, collection_id, doc_date, json.dumps(clean, ensure_ascii=False),
         tags_json, meta_json, datetime.utcnow().isoformat(), datetime.utcnow().isoformat())
    )
    return row_id


def update_db_row(db, row_id, data, doc_date=None):
    clean = {k: v for k, v in data.items() if not k.startswith("_")}
    tags = clean.pop("tags", None)
    meta = clean.pop("meta", None)

    tags_json = json.dumps(tags, ensure_ascii=False) if tags else None
    meta_json = json.dumps(meta, ensure_ascii=False) if meta else None

    db.execute(
        "UPDATE documents SET data_json = ?, tags_json = ?, meta_json = ?, doc_date = ?, updated_at = ? WHERE id = ?",
        (json.dumps(clean, ensure_ascii=False), tags_json, meta_json,
         doc_date, datetime.utcnow().isoformat(), row_id)
    )


SHEET_DATA_PATH = "/tmp/finance-sync-sheet-data.json"


def read_sheet_rows_from_file(collection_id):
    if not os.path.exists(SHEET_DATA_PATH):
        return {}

    with open(SHEET_DATA_PATH, "r", encoding="utf-8") as f:
        all_data = json.load(f)

    sheet_config = None
    for key, config in TAB_MAPPING.items():
        if config["collection_id"] == collection_id:
            sheet_config = config
            break

    if not sheet_config or sheet_config["sheet_name"] not in all_data:
        return {}

    raw_rows = all_data[sheet_config["sheet_name"]]
    if not raw_rows:
        return {}

    headers = raw_rows[0]
    data_rows = raw_rows[1:]
    field_map = sheet_config["field_map"]
    result = {}

    for row in data_rows:
        if not row or all(cell == "" for cell in row):
            continue

        row_dict = {}
        sheet_id = None
        for i, cell in enumerate(row):
            if i < len(headers):
                header = headers[i]
                field = field_map.get(header, header)
                row_dict[field] = cell
                if field == "sheet_id":
                    sheet_id = cell

        if not sheet_id:
            sheet_id = f"sheet-{hashlib.md5(str(row_dict).encode()).hexdigest()[:8]}"
            row_dict["sheet_id"] = sheet_id

        if "amount" in row_dict and row_dict["amount"]:
            try:
                row_dict["amount"] = float(row_dict["amount"])
            except (ValueError, TypeError):
                pass
        if "balance" in row_dict and row_dict["balance"]:
            try:
                row_dict["balance"] = float(row_dict["balance"])
            except (ValueError, TypeError):
                pass

        row_dict["_hash"] = compute_hash(
            {k: v for k, v in row_dict.items() if not k.startswith("_")}
        )
        result[sheet_id] = row_dict

    return result


def sync_collection(db, collection_id, dry_run=False):
    db_rows = read_db_rows(db, collection_id)
    sheet_rows = read_sheet_rows_from_file(collection_id)

    results = {
        "db_to_sheet_new": [],
        "sheet_to_db_new": [],
        "db_to_sheet_update": [],
        "sheet_to_db_update": [],
        "conflicts": [],
        "unchanged": [],
    }

    db_by_sheet_id = {}
    db_rows_without_sheet_id = {}

    for row_id, data in db_rows.items():
        sid = data.get("sheet_id")
        if sid:
            db_by_sheet_id[sid] = (row_id, data)
        else:
            db_rows_without_sheet_id[row_id] = data

    for row_id, data in db_rows_without_sheet_id.items():
        last_hash = get_last_hash(db, row_id, collection_id, "db")
        current_hash = data["_hash"]

        if last_hash is None:
            results["db_to_sheet_new"].append((row_id, data))
        elif last_hash != current_hash:
            results["db_to_sheet_update"].append((row_id, data))
        else:
            results["unchanged"].append(row_id)

    for sheet_id, sheet_data in sheet_rows.items():
        sheet_hash = sheet_data["_hash"]
        last_sheet_hash = get_last_hash(db, sheet_id, collection_id, "sheet")

        if sheet_id in db_by_sheet_id:
            db_row_id, db_data = db_by_sheet_id[sheet_id]
            db_hash = db_data["_hash"]
            last_db_hash = get_last_hash(db, sheet_id, collection_id, "db")

            db_changed = (last_db_hash is not None and last_db_hash != db_hash)
            sheet_changed = (last_sheet_hash is not None and last_sheet_hash != sheet_hash)

            if last_db_hash is None and last_sheet_hash is None:
                if not dry_run:
                    save_hash(db, sheet_id, collection_id, "db", db_hash)
                    save_hash(db, sheet_id, collection_id, "sheet", sheet_hash)
                results["unchanged"].append(sheet_id)
            elif db_changed and sheet_changed:
                results["conflicts"].append({
                    "sheet_id": sheet_id,
                    "db_row_id": db_row_id,
                    "db_data": db_data,
                    "sheet_data": sheet_data,
                })
            elif db_changed:
                results["db_to_sheet_update"].append((db_row_id, db_data))
                if not dry_run:
                    save_hash(db, sheet_id, collection_id, "db", db_hash)
            elif sheet_changed:
                results["sheet_to_db_update"].append((db_row_id, sheet_data))
                if not dry_run:
                    save_hash(db, sheet_id, collection_id, "sheet", sheet_hash)
            else:
                results["unchanged"].append(sheet_id)
        else:
            if last_sheet_hash is None or last_sheet_hash != sheet_hash:
                results["sheet_to_db_new"].append(sheet_data)
            else:
                results["unchanged"].append(sheet_id)

    if not dry_run:
        for sheet_data in results["sheet_to_db_new"]:
            doc_date = sheet_data.get("doc_date", "")
            insert_db_row(db, collection_id, sheet_data, doc_date=doc_date)

        for db_row_id, sheet_data in results["sheet_to_db_update"]:
            doc_date = sheet_data.get("doc_date", "")
            update_db_row(db, db_row_id, sheet_data, doc_date=doc_date)

        for row_id, data in results["db_to_sheet_new"]:
            save_hash(db, row_id, collection_id, "db", data["_hash"])

        for sheet_data in results["sheet_to_db_new"]:
            sid = sheet_data.get("sheet_id", "")
            save_hash(db, sid, collection_id, "sheet", sheet_data["_hash"])

        for db_row_id, sheet_data in results["sheet_to_db_update"]:
            sid = sheet_data.get("sheet_id", db_row_id)
            save_hash(db, sid, collection_id, "sheet", sheet_data["_hash"])

        db.commit()

    return results


def format_sync_report(results, collection_id, dry_run=False):
    lines = []
    prefix = "🔍 " if dry_run else "🔄 "
    lines.append(f"{prefix}סנכרון — {collection_id}")
    lines.append("")

    total_actions = (
        len(results["db_to_sheet_new"]) +
        len(results["sheet_to_db_new"]) +
        len(results["db_to_sheet_update"]) +
        len(results["sheet_to_db_update"]) +
        len(results["conflicts"])
    )

    if total_actions == 0:
        lines.append("✅ הכל מסונכרן. אין שינויים.")
        return "\n".join(lines)

    if dry_run:
        lines.append("📋 מצב יבש (dry-run) — ללא שינויים בפועל:")
        lines.append("")

    if results["db_to_sheet_new"]:
        lines.append(f"➡️ חדשים ב-DB -> נשלחים ל-Sheets ({len(results['db_to_sheet_new'])}):")
        for row_id, data in results["db_to_sheet_new"]:
            desc = data.get("description", data.get("title", row_id[:8]))
            lines.append(f"  • {desc}")
        lines.append("")

    if results["sheet_to_db_new"]:
        lines.append(f"⬅️ חדשים ב-Sheets -> נכנסים ל-DB ({len(results['sheet_to_db_new'])}):")
        for sheet_data in results["sheet_to_db_new"]:
            desc = sheet_data.get("description", sheet_data.get("title", sheet_data.get("sheet_id", "?")))
            lines.append(f"  • {desc}")
        lines.append("")

    if results["db_to_sheet_update"]:
        lines.append(f"➡️ השתנו ב-DB -> עודכנו ב-Sheets ({len(results['db_to_sheet_update'])}):")
        for row_id, data in results["db_to_sheet_update"]:
            desc = data.get("description", data.get("title", row_id[:8]))
            lines.append(f"  • {desc}")
        lines.append("")

    if results["sheet_to_db_update"]:
        lines.append(f"⬅️ השתנו ב-Sheets -> עודכנו ב-DB ({len(results['sheet_to_db_update'])}):")
        for db_row_id, sheet_data in results["sheet_to_db_update"]:
            desc = sheet_data.get("description", sheet_data.get("title", db_row_id[:8]))
            lines.append(f"  • {desc}")
        lines.append("")

    if results["conflicts"]:
        lines.append(f"⚠️ התנגשויות — נדרשת החלטה ({len(results['conflicts'])}):")
        lines.append("")
        for c in results["conflicts"]:
            sid = c["sheet_id"]
            db_data = c["db_data"]
            sheet_data = c["sheet_data"]
            desc = db_data.get("description", sheet_data.get("description", sid))
            clean_db = {k: v for k, v in db_data.items() if not k.startswith('_')}
            clean_sheet = {k: v for k, v in sheet_data.items() if not k.startswith('_')}
            lines.append(f"  🔴 {desc}")
            lines.append(f"     DB:    {json.dumps(clean_db, ensure_ascii=False)}")
            lines.append(f"     Sheet: {json.dumps(clean_sheet, ensure_ascii=False)}")
            lines.append("")

    if results["unchanged"]:
        lines.append(f"✓ ללא שינוי: {len(results['unchanged'])} שורות")

    return "\n".join(lines)


def generate_sheet_writes(results, collection_id):
    config = None
    for key, cfg in TAB_MAPPING.items():
        if cfg["collection_id"] == collection_id:
            config = cfg
            break

    if not config:
        return {"writes": [], "updates": []}

    writes = []
    updates = []

    for row_id, data in results.get("db_to_sheet_new", []):
        row_values = []
        for col in config["columns"]:
            field = config["field_map"].get(col, col)
            val = data.get(field, "")
            if field == "sheet_id":
                val = row_id
            elif field in ("type", "category"):
                val = translate_value(field, val)
            row_values.append(str(val) if val is not None else "")
        writes.append({
            "sheet_name": config["sheet_name"],
            "values": row_values,
        })

    for row_id, data in results.get("db_to_sheet_update", []):
        row_values = []
        for col in config["columns"]:
            field = config["field_map"].get(col, col)
            val = data.get(field, "")
            if field == "sheet_id":
                val = data.get("sheet_id", row_id)
            elif field in ("type", "category"):
                val = translate_value(field, val)
            row_values.append(str(val) if val is not None else "")
        updates.append({
            "sheet_name": config["sheet_name"],
            "sheet_id": data.get("sheet_id", row_id),
            "values": row_values,
        })

    return {"writes": writes, "updates": updates}


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args

    sync_targets = []
    if "--loans" in args:
        sync_targets = ["loans"]
    elif "--finance" in args:
        sync_targets = ["finance"]
    else:
        sync_targets = list(TAB_MAPPING.keys())

    db = get_db()
    ensure_sync_tables(db)

    all_results = {}
    all_writes = {}

    for collection_id in sync_targets:
        results = sync_collection(db, collection_id, dry_run=dry_run)
        all_results[collection_id] = results
        all_writes[collection_id] = generate_sheet_writes(results, collection_id)

    report_lines = []
    for collection_id, results in all_results.items():
        report_lines.append(format_sync_report(results, collection_id, dry_run))
        report_lines.append("")

    report = "\n".join(report_lines).strip()
    print(report)

    has_writes = any(
        all_writes[cid]["writes"] or all_writes[cid]["updates"]
        for cid in all_writes
    )
    if has_writes:
        print("\n---SHEET_OPS_JSON---", file=sys.stderr)
        print(json.dumps(all_writes, ensure_ascii=False, indent=2), file=sys.stderr)
        print("---END_SHEET_OPS_JSON---", file=sys.stderr)

    has_conflicts = any(
        len(results["conflicts"]) > 0
        for results in all_results.values()
    )
    if has_conflicts:
        sys.exit(2)

    db.close()


if __name__ == "__main__":
    main()

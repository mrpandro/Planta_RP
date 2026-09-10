"""
Applies sql/002_v0_2_features.sql to the staging MySQL database.
Forward-only: aborts if schema version is not 1. Idempotent for the CREATE
TABLE IF NOT EXISTS statements; the ALTER TABLE statements are guarded by a
schema-version check so re-running on an already-v2 database is a no-op.
"""
import sys
import os
import re

import pymysql

DB_CONFIG = dict(
    host="127.0.0.1",
    port=3306,
    user="root",
    password="Dracothiel1!",
    database="qbcore",
    charset="utf8mb4",
    autocommit=False,
)

MIGRATION_PATH = os.path.join(
    "resources", "[meus-scripts]", "qb-czcraft", "sql", "002_v0_2_features.sql"
)
EXPECTED_PREV_VERSION = 1
TARGET_VERSION = 2


def split_sql_statements(sql_text):
    """Split SQL into individual statements, stripping line comments.

    Handles `--` line comments and splits on `;` at the end of lines.
    Does NOT handle `/* ... */` block comments (none in this migration).
    """
    statements = []
    current = []
    for line in sql_text.splitlines():
        # Strip line comments (everything after `--`).
        comment_idx = line.find("--")
        if comment_idx != -1:
            line = line[:comment_idx]
        stripped = line.strip()
        if not stripped:
            continue
        current.append(line)
        if stripped.endswith(";"):
            stmt = "\n".join(current).strip()
            if stmt:
                statements.append(stmt)
            current = []
    # Handle any trailing statement without a semicolon.
    if current:
        stmt = "\n".join(current).strip()
        if stmt:
            statements.append(stmt)
    return statements


def main():
    conn = pymysql.connect(**DB_CONFIG)
    try:
        with conn.cursor() as cur:
            # Check current schema version.
            cur.execute(
                "SELECT version FROM czcraft_schema_version WHERE id = 1 FOR UPDATE"
            )
            row = cur.fetchone()
            if not row:
                print("ERROR: czcraft_schema_version row not found", file=sys.stderr)
                conn.rollback()
                sys.exit(1)
            current_version = row[0]
            if current_version >= TARGET_VERSION:
                print(
                    f"Schema already at version {current_version} (>= {TARGET_VERSION}). No-op."
                )
                conn.rollback()
                return

            if current_version != EXPECTED_PREV_VERSION:
                print(
                    f"ERROR: expected schema version {EXPECTED_PREV_VERSION}, "
                    f"got {current_version}",
                    file=sys.stderr,
                )
                conn.rollback()
                sys.exit(1)

            # Read and split the migration SQL.
            with open(MIGRATION_PATH, "r", encoding="utf-8") as f:
                sql_text = f.read()
            statements = split_sql_statements(sql_text)
            print(f"Applying {len(statements)} statements from migration 002...")

            for i, stmt in enumerate(statements, 1):
                # Truncate for display.
                preview = re.sub(r"\s+", " ", stmt)[:80]
                print(f"  [{i}/{len(statements)}] {preview}...")
                cur.execute(stmt)

            # Verify the schema version stamp took effect.
            cur.execute("SELECT version FROM czcraft_schema_version WHERE id = 1")
            row = cur.fetchone()
            if not row or row[0] != TARGET_VERSION:
                print(
                    f"ERROR: schema version not stamped to {TARGET_VERSION} "
                    f"(got {row[0] if row else 'NULL'})",
                    file=sys.stderr,
                )
                conn.rollback()
                sys.exit(1)

            conn.commit()
            print(f"Migration 002 applied. Schema version is now {TARGET_VERSION}.")

            # Verify key v0.2 columns/tables exist.
            cur.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = %s AND table_name = 'czcraft_machines' "
                "AND column_name IN ('condition', 'power_level', 'upgrade_budget_used')",
                (DB_CONFIG["database"],),
            )
            cols = [r[0] for r in cur.fetchall()]
            print(f"  czcraft_machines v0.2 columns: {cols}")

            cur.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = %s AND table_name = 'czcraft_financial_exports'",
                (DB_CONFIG["database"],),
            )
            fin = [r[0] for r in cur.fetchall()]
            print(f"  czcraft_financial_exports table: {fin}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()

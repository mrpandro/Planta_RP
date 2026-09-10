#!/usr/bin/env python3
"""Probe the staging DB for czcraft schema state."""
import pymysql

conn = pymysql.connect(
    host="127.0.0.1", port=3306, user="root", password="Dracothiel1!",
    database="qbcore", charset="utf8mb4",
)
cur = conn.cursor()

try:
    cur.execute("SELECT version, applied_at FROM czcraft_schema_version WHERE id = 1")
    print("SCHEMA_VERSION:", cur.fetchone())
except Exception as e:
    print("SCHEMA_VERSION query failed:", e)

cur.execute(
    "SELECT TABLE_NAME FROM information_schema.TABLES "
    "WHERE TABLE_SCHEMA = 'qbcore' AND TABLE_NAME LIKE 'czcraft%' "
    "ORDER BY TABLE_NAME"
)
print("CZCRAFT_TABLES:", [r[0] for r in cur.fetchall()])

try:
    cur.execute("SELECT COUNT(*) FROM bank_statements")
    print("BANK_STATEMENTS_ROWS:", cur.fetchone()[0])
except Exception as e:
    print("bank_statements query failed:", e)

# Check if v0.2 columns exist on czcraft_machines
cur.execute(
    "SELECT COLUMN_NAME FROM information_schema.COLUMNS "
    "WHERE TABLE_SCHEMA = 'qbcore' AND TABLE_NAME = 'czcraft_machines' "
    "AND COLUMN_NAME IN ('condition','power_level','upgrade_budget_used') "
    "ORDER BY COLUMN_NAME"
)
print("V0_2_MACHINE_COLS:", [r[0] for r in cur.fetchall()])

# Check if czcraft_financial_exports exists
cur.execute(
    "SELECT TABLE_NAME FROM information_schema.TABLES "
    "WHERE TABLE_SCHEMA = 'qbcore' AND TABLE_NAME = 'czcraft_financial_exports'"
)
print("FINANCIAL_EXPORTS_TABLE:", cur.fetchone())

conn.close()

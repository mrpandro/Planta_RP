"""One-off fixup: widen condition columns to DECIMAL(5,2) on staging.

The original migration 002 defined condition as SMALLINT UNSIGNED (integer),
but wearPerCycle is 0.5 (fractional). This alters the staging columns to
DECIMAL(5,2) to match the corrected migration. Run once after migration 002.
"""
import pymysql

conn = pymysql.connect(
    host='127.0.0.1', port=3306, user='root',
    password='Dracothiel1!', database='qbcore', charset='utf8mb4',
)
cur = conn.cursor()

stmts = [
    'ALTER TABLE czcraft_machines MODIFY COLUMN `condition` DECIMAL(5,2) NOT NULL DEFAULT 100.00',
    'ALTER TABLE czcraft_machines DROP CHECK IF EXISTS chk_machines_condition',
    'ALTER TABLE czcraft_machines ADD CONSTRAINT chk_machines_condition CHECK (`condition` <= 100.00)',
    'ALTER TABLE czcraft_active_cycles MODIFY COLUMN condition_before DECIMAL(5,2) DEFAULT NULL',
    'ALTER TABLE czcraft_active_cycles MODIFY COLUMN condition_after DECIMAL(5,2) DEFAULT NULL',
    'ALTER TABLE czcraft_production_events MODIFY COLUMN condition_before DECIMAL(5,2) DEFAULT NULL',
    'ALTER TABLE czcraft_production_events MODIFY COLUMN condition_after DECIMAL(5,2) DEFAULT NULL',
    'ALTER TABLE czcraft_daily_rollups MODIFY COLUMN condition_start DECIMAL(5,2) DEFAULT NULL',
    'ALTER TABLE czcraft_daily_rollups MODIFY COLUMN condition_end DECIMAL(5,2) DEFAULT NULL',
]

for s in stmts:
    try:
        cur.execute(s)
        print('OK:', s[:70])
    except Exception as e:
        print('SKIP:', s[:70], '->', str(e)[:80])

conn.commit()

cur.execute(
    "SELECT column_type FROM information_schema.columns "
    "WHERE table_schema = DATABASE() AND table_name = 'czcraft_machines' "
    "AND column_name = 'condition'"
)
row = cur.fetchone()
print('machines.condition:', row[0] if row else 'NOT FOUND')
conn.close()

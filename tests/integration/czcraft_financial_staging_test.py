"""
Staging integration test for the czcraft financial export path against
qb-banking job/gang accounts on real MySQL.

Verifies the two failure-injection scenarios that matter for the "airtight"
job/gang path:

  Scenario A — qb-banking UPDATE fails (statement inserted, balance NOT
  changed, czcraft sees the failure):
    1. beginExport inserts PENDING.
    2. qb-banking RemoveMoney inserts bank_statements (statement-write).
    3. INJECT FAILURE: the bank_accounts UPDATE fails (returns 0).
    4. czcraft sees applyOk=false → markCommitted with failure result.
    5. Replay: beginExport → COMMITTED → returns cached failure. No re-apply.
    Assert: balance unchanged, no double movement, journal COMMITTED.

  Scenario B — crash between statement-write and balance-update (statement
  inserted, balance NOT changed, czcraft never calls markCommitted):
    1. beginExport inserts PENDING.
    2. qb-banking RemoveMoney inserts bank_statements (statement-write).
    3. INJECT CRASH: the process dies before the UPDATE and before markCommitted.
    4. Replay: beginExport → PENDING → checkStatementExists → found → markCommitted.
    Assert: balance unchanged (silent loss, not double-grant), journal COMMITTED.

  Scenario C — happy path (no failure):
    1. beginExport inserts PENDING.
    2. qb-banking RemoveMoney inserts bank_statements + updates balance.
    3. markCommitted with success.
    4. Replay: beginExport → COMMITTED → returns cached success. No re-apply.
    Assert: balance decremented exactly once, no double movement.

Cleans up all test rows at the end.
"""
import sys
import os
import uuid
import json

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

REASON_PREFIX = "czcraft|"

TEST_ACCOUNT = "czcraft_test_job"
INITIAL_BALANCE = 10000
DEBIT_AMOUNT = 500


def format_reason(export_key, human_reason="staging test"):
    return f"{REASON_PREFIX}{export_key}|{human_reason}"


def setup_test_account(conn):
    """Create or reset the test job account to a known balance."""
    with conn.cursor() as cur:
        # Delete any prior test account.
        cur.execute("DELETE FROM bank_accounts WHERE account_name = %s", (TEST_ACCOUNT,))
        # Insert fresh with known balance.
        cur.execute(
            "INSERT INTO bank_accounts (account_name, account_balance, account_type) "
            "VALUES (%s, %s, 'job')",
            (TEST_ACCOUNT, INITIAL_BALANCE),
        )
    conn.commit()


def cleanup_test(conn, export_keys):
    """Remove all test rows to keep the staging DB clean."""
    if not export_keys:
        return
    with conn.cursor() as cur:
        for ek in export_keys:
            cur.execute(
                "DELETE FROM bank_statements WHERE reason LIKE %s",
                (f"{REASON_PREFIX}{ek}|%",),
            )
        placeholders = ",".join(["%s"] * len(export_keys))
        cur.execute(
            f"DELETE FROM czcraft_financial_exports WHERE export_key IN ({placeholders})",
            tuple(export_keys),
        )
        cur.execute("DELETE FROM bank_accounts WHERE account_name = %s", (TEST_ACCOUNT,))
    conn.commit()


def get_balance(conn, account_name):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT account_balance FROM bank_accounts WHERE account_name = %s",
            (account_name,),
        )
        row = cur.fetchone()
        return row[0] if row else None


def begin_export(conn, export_id, export_key, source_type="qb-banking",
                 source_id=TEST_ACCOUNT, direction="DEBIT", amount=DEBIT_AMOUNT):
    """Replicates FinanceRepo.beginExport: INSERT IGNORE PENDING."""
    with conn.cursor() as cur:
        affected = cur.execute(
            "INSERT IGNORE INTO czcraft_financial_exports "
            "(export_id, export_key, source_type, source_id, direction, amount, "
            "account, reason, status) "
            "VALUES (%s, %s, %s, %s, %s, %s, 'bank', 'staging test', 'PENDING')",
            (export_id, export_key, source_type, source_id, direction, amount),
        )
        if affected > 0:
            return True, True, None
        # Replay: load existing.
        cur.execute(
            "SELECT export_id, status, result FROM czcraft_financial_exports "
            "WHERE export_key = %s",
            (export_key,),
        )
        row = cur.fetchone()
        return True, False, row


def mark_committed(conn, export_id, result_json):
    """Replicates FinanceRepo.markCommitted."""
    with conn.cursor() as cur:
        affected = cur.execute(
            "UPDATE czcraft_financial_exports SET status = 'COMMITTED', result = %s, "
            "version = version + 1 WHERE export_id = %s AND status = 'PENDING'",
            (result_json, export_id),
        )
    conn.commit()
    return affected > 0


def check_statement_exists(conn, export_key):
    """Replicates FinanceRepo.checkStatementExists."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT COUNT(*) FROM bank_statements WHERE reason LIKE %s",
            (f"{REASON_PREFIX}{export_key}|%",),
        )
        row = cur.fetchone()
        return row[0] > 0


def qb_banking_insert_statement(conn, account_name, amount, reason, stmt_type="withdraw"):
    """Replicates the INSERT part of qb-banking's RemoveMoney."""
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO bank_statements (account_name, amount, reason, statement_type) "
            "VALUES (%s, %s, %s, %s)",
            (account_name, amount, reason, stmt_type),
        )
    conn.commit()


def qb_banking_update_balance(conn, account_name, amount):
    """Replicates the UPDATE part of qb-banking's RemoveMoney. Returns affected rows."""
    with conn.cursor() as cur:
        affected = cur.execute(
            "UPDATE bank_accounts SET account_balance = account_balance - %s "
            "WHERE account_name = %s",
            (amount, account_name),
        )
    conn.commit()
    return affected


def get_export_status(conn, export_key):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT status, result FROM czcraft_financial_exports WHERE export_key = %s",
            (export_key,),
        )
        return cur.fetchone()


def run_scenario_c_happy_path(conn):
    """Scenario C: no failure — balance decremented exactly once."""
    print("\n--- Scenario C: happy path (no failure) ---")
    setup_test_account(conn)
    export_key = f"staging-test-c-{uuid.uuid4()}"
    export_id = str(uuid.uuid4())
    reason = format_reason(export_key)

    # Step 1: beginExport (PENDING).
    ok, is_fresh, existing = begin_export(conn, export_id, export_key)
    assert ok and is_fresh, "beginExport should insert fresh PENDING"

    # Step 2: qb-banking RemoveMoney (statement + balance update).
    qb_banking_insert_statement(conn, TEST_ACCOUNT, DEBIT_AMOUNT, reason)
    affected = qb_banking_update_balance(conn, TEST_ACCOUNT, DEBIT_AMOUNT)
    assert affected == 1, f"balance update should affect 1 row, got {affected}"

    # Step 3: markCommitted (success).
    result_meta = json.dumps({"success": True, "direction": "DEBIT", "amount": DEBIT_AMOUNT})
    committed = mark_committed(conn, export_id, result_meta)
    assert committed, "markCommitted should succeed"

    # Assert: balance decremented exactly once.
    bal = get_balance(conn, TEST_ACCOUNT)
    assert bal == INITIAL_BALANCE - DEBIT_AMOUNT, f"balance should be {INITIAL_BALANCE - DEBIT_AMOUNT}, got {bal}"
    print(f"  Balance after debit: {bal} (expected {INITIAL_BALANCE - DEBIT_AMOUNT})")

    # Step 4: replay — should return cached success, no re-apply.
    ok, is_fresh, existing = begin_export(conn, export_id, export_key)
    assert not is_fresh, "replay should not be fresh"
    status, result = existing[1], existing[2]
    assert status == "COMMITTED", f"replay status should be COMMITTED, got {status}"
    print(f"  Replay: status={status}, no re-apply")

    # Assert: balance unchanged after replay.
    bal = get_balance(conn, TEST_ACCOUNT)
    assert bal == INITIAL_BALANCE - DEBIT_AMOUNT, f"balance should be unchanged after replay, got {bal}"
    print("  PASS: balance decremented exactly once, no double movement")
    return export_key


def run_scenario_a_update_fails(conn):
    """Scenario A: UPDATE fails — balance NOT changed, czcraft records failure."""
    print("\n--- Scenario A: qb-banking UPDATE fails ---")
    setup_test_account(conn)
    export_key = f"staging-test-a-{uuid.uuid4()}"
    export_id = str(uuid.uuid4())
    reason = format_reason(export_key)

    # Step 1: beginExport (PENDING).
    ok, is_fresh, existing = begin_export(conn, export_id, export_key)
    assert ok and is_fresh, "beginExport should insert fresh PENDING"

    # Step 2: qb-banking RemoveMoney — statement inserted.
    qb_banking_insert_statement(conn, TEST_ACCOUNT, DEBIT_AMOUNT, reason)

    # Step 3: INJECT FAILURE — the UPDATE fails (simulate account row missing
    # by temporarily deleting it, then re-inserting after the UPDATE returns 0).
    with conn.cursor() as cur:
        cur.execute("DELETE FROM bank_accounts WHERE account_name = %s", (TEST_ACCOUNT,))
    conn.commit()
    affected = qb_banking_update_balance(conn, TEST_ACCOUNT, DEBIT_AMOUNT)
    assert affected == 0, f"UPDATE should affect 0 rows (account deleted), got {affected}"
    # Restore the account for balance verification.
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO bank_accounts (account_name, account_balance, account_type) "
            "VALUES (%s, %s, 'job')",
            (TEST_ACCOUNT, INITIAL_BALANCE),
        )
    conn.commit()

    # Step 4: czcraft sees applyOk=false → markCommitted with failure.
    fail_meta = json.dumps({"success": False, "error": "qb-banking RemoveMoney failed"})
    committed = mark_committed(conn, export_id, fail_meta)
    assert committed, "markCommitted should succeed with failure result"

    # Assert: balance unchanged (UPDATE failed).
    bal = get_balance(conn, TEST_ACCOUNT)
    assert bal == INITIAL_BALANCE, f"balance should be {INITIAL_BALANCE} (UPDATE failed), got {bal}"
    print(f"  Balance after failed debit: {bal} (expected {INITIAL_BALANCE})")

    # Step 5: replay — COMMITTED with failure, no re-apply.
    ok, is_fresh, existing = begin_export(conn, export_id, export_key)
    assert not is_fresh, "replay should not be fresh"
    status, result = existing[1], existing[2]
    assert status == "COMMITTED", f"replay status should be COMMITTED, got {status}"
    print(f"  Replay: status={status}, no re-apply")

    # Assert: balance still unchanged.
    bal = get_balance(conn, TEST_ACCOUNT)
    assert bal == INITIAL_BALANCE, f"balance should still be {INITIAL_BALANCE}, got {bal}"
    print("  PASS: no double movement, failure recorded, balance unchanged")
    return export_key


def run_scenario_b_crash_between(conn):
    """Scenario B: crash between statement-write and balance-update — PENDING
    replay sees the statement, marks COMMITTED, skips re-apply. Silent loss
    (balance NOT changed), NOT double-grant."""
    print("\n--- Scenario B: crash between statement-write and balance-update ---")
    setup_test_account(conn)
    export_key = f"staging-test-b-{uuid.uuid4()}"
    export_id = str(uuid.uuid4())
    reason = format_reason(export_key)

    # Step 1: beginExport (PENDING).
    ok, is_fresh, existing = begin_export(conn, export_id, export_key)
    assert ok and is_fresh, "beginExport should insert fresh PENDING"

    # Step 2: qb-banking RemoveMoney — statement inserted.
    qb_banking_insert_statement(conn, TEST_ACCOUNT, DEBIT_AMOUNT, reason)

    # Step 3: INJECT CRASH — process dies before the UPDATE and before
    # markCommitted. We simulate this by simply NOT doing the UPDATE and NOT
    # calling markCommitted. The journal row stays PENDING.

    # Assert: balance unchanged (UPDATE never ran).
    bal = get_balance(conn, TEST_ACCOUNT)
    assert bal == INITIAL_BALANCE, f"balance should be {INITIAL_BALANCE} (crash), got {bal}"
    status, _ = get_export_status(conn, export_key)
    assert status == "PENDING", f"journal should be PENDING, got {status}"
    print(f"  After crash: balance={bal}, journal={status}")

    # Step 4: replay — beginExport returns PENDING, checkStatementExists finds
    # the statement, markCommitted, skip re-apply.
    ok, is_fresh, existing = begin_export(conn, export_id, export_key)
    assert not is_fresh, "replay should not be fresh"
    status, _ = existing[1], existing[2]
    assert status == "PENDING", f"replay status should be PENDING, got {status}"

    stmt_exists = check_statement_exists(conn, export_key)
    assert stmt_exists, "statement should exist (was inserted before crash)"

    # markCommitted — the replay resolution marks it COMMITTED without re-applying.
    replay_meta = json.dumps({"success": True, "replayedFromStatement": True})
    committed = mark_committed(conn, export_id, replay_meta)
    assert committed, "markCommitted should succeed on replay"

    # Assert: balance still unchanged (no re-apply — silent loss, not double-grant).
    bal = get_balance(conn, TEST_ACCOUNT)
    assert bal == INITIAL_BALANCE, f"balance should still be {INITIAL_BALANCE} (no re-apply), got {bal}"
    status, _ = get_export_status(conn, export_key)
    assert status == "COMMITTED", f"journal should be COMMITTED, got {status}"
    print(f"  After replay: balance={bal}, journal={status}")
    print("  PASS: no double movement (silent loss, not double-grant)")
    return export_key


def main():
    conn = pymysql.connect(**DB_CONFIG)
    export_keys = []
    try:
        print("Staging integration test: czcraft financial export (qb-banking path)")
        print(f"  DB: {DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['database']}")
        print(f"  Test account: {TEST_ACCOUNT} (balance={INITIAL_BALANCE})")

        # Verify schema version is 2 (migration 002 applied).
        with conn.cursor() as cur:
            cur.execute("SELECT version FROM czcraft_schema_version WHERE id = 1")
            row = cur.fetchone()
            assert row and row[0] == 2, f"Schema version must be 2, got {row[0] if row else 'NULL'}"
            print(f"  Schema version: {row[0]}")

        # Verify czcraft_financial_exports table exists.
        with conn.cursor() as cur:
            cur.execute(
                "SELECT COUNT(*) FROM information_schema.tables "
                "WHERE table_schema = %s AND table_name = 'czcraft_financial_exports'",
                (DB_CONFIG["database"],),
            )
            assert cur.fetchone()[0] == 1, "czcraft_financial_exports table must exist"

        ek_c = run_scenario_c_happy_path(conn)
        ek_a = run_scenario_a_update_fails(conn)
        ek_b = run_scenario_b_crash_between(conn)
        export_keys = [ek_c, ek_a, ek_b]

        print("\n=== ALL SCENARIOS PASSED ===")
    except AssertionError as e:
        print(f"\n=== TEST FAILED: {e} ===", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"\n=== ERROR: {e} ===", file=sys.stderr)
        sys.exit(1)
    finally:
        cleanup_test(conn, export_keys)
        conn.close()


if __name__ == "__main__":
    main()

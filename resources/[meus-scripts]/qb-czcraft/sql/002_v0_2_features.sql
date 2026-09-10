-- qb-czcraft v0.2 features schema (migration 002)
--
-- Manual, forward-only migration. Apply once against the staging database
-- after migration 001 is applied (schema version 1). The resource never
-- runs DDL itself. InnoDB/utf8mb4; condition/power on a 0-100 scale; costs
-- in DECIMAL(18,4) config units; timestamps in UTC DATETIME(3).
--
-- Adds: machine condition/power/upgrade columns, UNTIL_X bill mode +
-- priority expansion, immutable cycle effect columns (condition/power
-- before/after), financial export journal, sale events, daily rollups.
--
-- The schema-version singleton is stamped LAST so a partial failure cannot
-- mark migration 002 as applied. Re-running this file is safe for schemas
-- at version 1; on an existing newer schema do not downgrade — abort.

-- ---------------------------------------------------------------------------
-- czcraft_machines: add condition, power, and upgrade columns.
-- Condition is DECIMAL(5,2) to support fractional wear (e.g. 0.5/cycle); power
-- is SMALLINT UNSIGNED (whole units). Upgrade levels are per-track TINYINT;
-- budget_used tracks total points spent across all tracks.
-- ---------------------------------------------------------------------------
ALTER TABLE `czcraft_machines`
    ADD COLUMN `condition`             DECIMAL(5,2) NOT NULL DEFAULT 100.00,
    ADD COLUMN `power_level`           SMALLINT UNSIGNED NOT NULL DEFAULT 100,
    ADD COLUMN `upgrade_speed_level`     TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `upgrade_capacity_level`  TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `upgrade_efficiency_level` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `upgrade_durability_level` TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN `upgrade_budget_used`    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD CONSTRAINT `chk_machines_condition` CHECK (`condition` <= 100.00),
    ADD CONSTRAINT `chk_machines_power` CHECK (`power_level` <= 100);

-- ---------------------------------------------------------------------------
-- czcraft_bills: add UNTIL_X threshold column and expand mode/priority
-- constraints. UNTIL_X produces until stock + reserved >= until_threshold.
-- The priority column gains HIGH/LOW in addition to NORMAL.
-- ---------------------------------------------------------------------------
ALTER TABLE `czcraft_bills`
    ADD COLUMN `until_threshold` INT(10) UNSIGNED DEFAULT NULL,
    DROP CHECK `chk_bills_mode`;

ALTER TABLE `czcraft_bills`
    ADD CONSTRAINT `chk_bills_mode` CHECK (`mode` IN ('PRODUCE_X', 'MAINTAIN_X', 'UNTIL_X')),
    ADD CONSTRAINT `chk_bills_priority` CHECK (`priority` IN ('HIGH', 'NORMAL', 'LOW')),
    ADD CONSTRAINT `chk_bills_until_threshold` CHECK (
        (`mode` <> 'UNTIL_X' AND `until_threshold` IS NULL)
        OR (`mode` = 'UNTIL_X' AND `until_threshold` > 0)
    );

-- ---------------------------------------------------------------------------
-- czcraft_active_cycles: add immutable condition/power snapshot columns.
-- These record the machine's condition/power before the cycle started and
-- the wear/power to apply on completion, so the completion transaction can
-- apply deterministic effects without re-reading the machine row.
-- ---------------------------------------------------------------------------
ALTER TABLE `czcraft_active_cycles`
    ADD COLUMN `condition_before`   DECIMAL(5,2) DEFAULT NULL,
    ADD COLUMN `condition_after`    DECIMAL(5,2) DEFAULT NULL,
    ADD COLUMN `power_level_before` SMALLINT UNSIGNED DEFAULT NULL,
    ADD COLUMN `power_level_after`  SMALLINT UNSIGNED DEFAULT NULL,
    ADD COLUMN `wear_to_apply`      DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    ADD COLUMN `power_to_consume`   SMALLINT UNSIGNED NOT NULL DEFAULT 0;

-- ---------------------------------------------------------------------------
-- czcraft_production_events: add condition/power effect columns so each
-- aggregated event records the machine state transition it caused.
-- ---------------------------------------------------------------------------
ALTER TABLE `czcraft_production_events`
    ADD COLUMN `condition_before`   DECIMAL(5,2) DEFAULT NULL,
    ADD COLUMN `condition_after`    DECIMAL(5,2) DEFAULT NULL,
    ADD COLUMN `power_level_before` SMALLINT UNSIGNED DEFAULT NULL,
    ADD COLUMN `power_level_after`  SMALLINT UNSIGNED DEFAULT NULL,
    ADD COLUMN `wear_applied`       DECIMAL(5,2) DEFAULT 0.00,
    ADD COLUMN `power_consumed`    SMALLINT UNSIGNED DEFAULT 0;

-- ---------------------------------------------------------------------------
-- czcraft_financial_exports: idempotent journal for money movements to
-- qb-core (player cash/bank) and qb-banking (bank accounts). The unique
-- export_key prevents double-application on replay. DEBIT = money removed
-- from the player; CREDIT = money added to the player.
-- ---------------------------------------------------------------------------

-- Widen bank_statements.reason (owned by qb-banking) so czcraft's structured
-- reason format "czcraft|<export_key>|<human_reason>" fits. The export_key
-- can include machine_uuid + bill_id + operation, easily exceeding 50 chars.
-- VARCHAR(255) is wide enough for any reasonable export_key without being
-- unbounded. This ALTER is idempotent via information_schema guard in the
-- applying script; MySQL does not support IF NOT EXISTS on ALTER COLUMN.
ALTER TABLE `bank_statements`
    MODIFY COLUMN `reason` VARCHAR(255) DEFAULT NULL;

CREATE TABLE IF NOT EXISTS `czcraft_financial_exports` (
    `export_id`    CHAR(36)         NOT NULL,
    `export_key`   VARCHAR(255)     NOT NULL,
    `source_type`  VARCHAR(20)      NOT NULL,
    `source_id`    VARCHAR(100)     NOT NULL,
    `direction`    VARCHAR(10)      NOT NULL,
    `amount`       DECIMAL(18,4)    NOT NULL,
    `account`      VARCHAR(20)      NOT NULL DEFAULT 'bank',
    `reason`       VARCHAR(100)     NOT NULL,
    `machine_uuid` CHAR(36)         DEFAULT NULL,
    `bill_id`      CHAR(36)         DEFAULT NULL,
    `status`       VARCHAR(20)      NOT NULL DEFAULT 'COMMITTED',
    `result`       JSON             DEFAULT NULL,
    `version`      INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`   DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`   DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`export_id`),
    UNIQUE KEY `uq_financial_exports_key` (`export_key`),
    KEY `idx_financial_exports_source` (`source_type`, `source_id`),
    KEY `idx_financial_exports_machine` (`machine_uuid`),
    KEY `idx_financial_exports_status_updated` (`status`, `updated_at`),
    CONSTRAINT `chk_financial_exports_direction` CHECK (`direction` IN ('DEBIT', 'CREDIT')),
    CONSTRAINT `chk_financial_exports_source` CHECK (`source_type` IN ('qb-core', 'qb-banking')),
    CONSTRAINT `chk_financial_exports_amount` CHECK (`amount` >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_sale_events: one row per sale of produced items from a machine.
-- Links to the financial export that credited the player.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_sale_events` (
    `sale_id`             CHAR(36)      NOT NULL,
    `machine_uuid`        CHAR(36)      NOT NULL,
    `item_name`           VARCHAR(100)  NOT NULL,
    `quantity`            INT(10) UNSIGNED NOT NULL,
    `unit_price`          DECIMAL(18,4) NOT NULL,
    `total_amount`        DECIMAL(18,4) NOT NULL,
    `buyer_type`          VARCHAR(20)   NOT NULL DEFAULT 'PLAYER',
    `buyer_id`            VARCHAR(50)   NOT NULL,
    `financial_export_id` CHAR(36)      DEFAULT NULL,
    `version`             INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`sale_id`),
    UNIQUE KEY `uq_sale_events_financial_export` (`financial_export_id`),
    KEY `idx_sale_events_machine_created` (`machine_uuid`, `created_at`),
    KEY `idx_sale_events_buyer` (`buyer_type`, `buyer_id`),
    CONSTRAINT `fk_sale_events_machine` FOREIGN KEY (`machine_uuid`) REFERENCES `czcraft_machines` (`machine_uuid`) ON DELETE RESTRICT,
    CONSTRAINT `chk_sale_events_quantity` CHECK (`quantity` > 0),
    CONSTRAINT `chk_sale_events_total` CHECK (`total_amount` = `quantity` * `unit_price`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_daily_rollups: one row per machine per day, aggregated from
-- production_events. Keeps the events table bounded (old events are
-- rolled up and deleted per the retention config).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_daily_rollups` (
    `rollup_id`         BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,
    `machine_uuid`      CHAR(36)      NOT NULL,
    `rollup_date`       DATE         NOT NULL,
    `cycles_completed`  INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `items_produced`    JSON         NOT NULL,
    `items_consumed`    JSON         NOT NULL,
    `revenue`           DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
    `cost`              DECIMAL(18,4) NOT NULL DEFAULT 0.0000,
    `condition_start`   DECIMAL(5,2) DEFAULT NULL,
    `condition_end`     DECIMAL(5,2) DEFAULT NULL,
    `version`           INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`        DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`rollup_id`),
    UNIQUE KEY `uq_rollups_machine_date` (`machine_uuid`, `rollup_date`),
    KEY `idx_rollups_date` (`rollup_date`),
    CONSTRAINT `fk_rollups_machine` FOREIGN KEY (`machine_uuid`) REFERENCES `czcraft_machines` (`machine_uuid`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Stamp the schema-version singleton LAST. Never downgrade an existing
-- newer version; only insert or upgrade to 2.
-- ---------------------------------------------------------------------------
INSERT INTO `czcraft_schema_version` (`id`, `version`, `applied_at`)
VALUES (1, 2, CURRENT_TIMESTAMP(3))
ON DUPLICATE KEY UPDATE
    `version`    = IF(`version` < VALUES(`version`), VALUES(`version`), `version`),
    `applied_at` = IF(`version` < VALUES(`version`), VALUES(`applied_at`), `applied_at`);

-- qb-czcraft v0.1 core schema (migration 001)
--
-- Manual, forward-only migration. Apply once against the staging database; the
-- resource never runs DDL itself. InnoDB/utf8mb4; weights in integer grams;
-- costs in DECIMAL(18,4) config units; timestamps in UTC DATETIME(3).
--
-- The schema-version singleton is stamped LAST so a partial failure cannot
-- mark migration 001 as applied. Re-running this file is safe for empty
-- schemas; on an existing newer schema do not downgrade — abort and recover.

-- ---------------------------------------------------------------------------
-- czcraft_schema_version: singleton row with the applied migration version.
-- Bootstrap compares `version` against CZCraft.REQUIRED_SCHEMA_VERSION and
-- stays fully disabled when missing, unreadable, or behind.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_schema_version` (
    `id`         TINYINT(3) UNSIGNED NOT NULL DEFAULT 1,
    `version`    INT(10) UNSIGNED    NOT NULL,
    `applied_at` DATETIME(3)         NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_machines: one row per machine instance. UUID/serial, lifecycle
-- (PACKED|INSTALLED), single owner + location, numeric transform, operational
-- status + blocked reason/detail, used/reserved weight vs capacity, active
-- bill/cycle denormalization, optimistic version, timestamps.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_machines` (
    `machine_uuid`       CHAR(36)         NOT NULL,
    `serial`             VARCHAR(100)     NOT NULL,
    `machine_type`       VARCHAR(50)      NOT NULL,
    `lifecycle`          VARCHAR(20)      NOT NULL DEFAULT 'PACKED',
    `owner_type`         VARCHAR(20)      DEFAULT NULL,
    `owner_id`           VARCHAR(50)      DEFAULT NULL,
    `location_type`      VARCHAR(20)      DEFAULT NULL,
    `location_id`        VARCHAR(255)     DEFAULT NULL,
    `pos_x`              DECIMAL(12,4)    DEFAULT NULL,
    `pos_y`              DECIMAL(12,4)    DEFAULT NULL,
    `pos_z`              DECIMAL(12,4)    DEFAULT NULL,
    `heading`            DECIMAL(12,4)    DEFAULT NULL,
    `operational_status` VARCHAR(20)      NOT NULL DEFAULT 'STOPPED',
    `blocked_reason`     VARCHAR(100)     DEFAULT NULL,
    `blocked_detail`     TEXT             DEFAULT NULL,
    `used_weight`        INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `reserved_weight`    INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `stock_capacity`     INT(10) UNSIGNED NOT NULL,
    `active_bill_id`     CHAR(36)         DEFAULT NULL,
    `active_cycle_id`    CHAR(36)         DEFAULT NULL,
    `next_due_at`        DATETIME(3)      DEFAULT NULL,
    `version`            INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`         DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`         DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`machine_uuid`),
    UNIQUE KEY `uq_machines_serial` (`serial`),
    KEY `idx_machines_status_due` (`operational_status`, `next_due_at`),
    KEY `idx_machines_owner` (`owner_type`, `owner_id`),
    KEY `idx_machines_location` (`location_type`, `location_id`),
    KEY `idx_machines_lifecycle` (`lifecycle`),
    CONSTRAINT `chk_machines_weight` CHECK (`used_weight` + `reserved_weight` <= `stock_capacity`),
    CONSTRAINT `chk_machines_lifecycle` CHECK (`lifecycle` IN ('PACKED', 'INSTALLED'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_machine_stock: PK (machine_id, item_name, metadata_key). Quantity
-- and reserved_quantity are unsigned; reserved_quantity <= quantity. Metadata
-- JSON is minimal; standard_unit_cost is the config cost per unit.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_machine_stock` (
    `machine_uuid`       CHAR(36)         NOT NULL,
    `item_name`          VARCHAR(100)     NOT NULL,
    `metadata_key`       VARCHAR(100)     NOT NULL DEFAULT '',
    `quantity`           INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `reserved_quantity`  INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `metadata`           JSON             DEFAULT NULL,
    `standard_unit_cost` DECIMAL(18,4)    NOT NULL DEFAULT 0.0000,
    `version`            INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`         DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`         DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`machine_uuid`, `item_name`, `metadata_key`),
    KEY `idx_stock_item` (`item_name`),
    CONSTRAINT `fk_stock_machine` FOREIGN KEY (`machine_uuid`) REFERENCES `czcraft_machines` (`machine_uuid`) ON DELETE RESTRICT,
    CONSTRAINT `chk_stock_reserve` CHECK (`reserved_quantity` <= `quantity`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_bills: UUID, machine, recipe, mode (PRODUCE_X|MAINTAIN_X), primary
-- output, target, produced quantity, enabled, status/block reason, NORMAL
-- priority, created by, deterministic creation sequence, version, timestamps.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_bills` (
    `bill_id`           CHAR(36)          NOT NULL,
    `machine_uuid`      CHAR(36)          NOT NULL,
    `recipe_id`         VARCHAR(100)      NOT NULL,
    `mode`              VARCHAR(20)       NOT NULL,
    `primary_output`    VARCHAR(100)      NOT NULL,
    `target_quantity`   INT(10) UNSIGNED  NOT NULL,
    `produced_quantity` INT(10) UNSIGNED  NOT NULL DEFAULT 0,
    `enabled`           TINYINT(1)        NOT NULL DEFAULT 1,
    `status`            VARCHAR(20)       NOT NULL DEFAULT 'PENDING',
    `block_reason`      VARCHAR(100)      DEFAULT NULL,
    `block_detail`      TEXT              DEFAULT NULL,
    `priority`          VARCHAR(20)       NOT NULL DEFAULT 'NORMAL',
    `created_by_type`   VARCHAR(20)       DEFAULT NULL,
    `created_by_id`     VARCHAR(50)       DEFAULT NULL,
    `created_sequence`  BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,
    `version`           INT(10) UNSIGNED  NOT NULL DEFAULT 0,
    `created_at`        DATETIME(3)       NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`        DATETIME(3)       NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`bill_id`),
    UNIQUE KEY `uq_bills_created_sequence` (`created_sequence`),
    KEY `idx_bills_machine_enabled_seq` (`machine_uuid`, `enabled`, `created_sequence`),
    KEY `idx_bills_status_updated` (`status`, `updated_at`),
    KEY `idx_bills_machine_status` (`machine_uuid`, `status`),
    CONSTRAINT `fk_bills_machine` FOREIGN KEY (`machine_uuid`) REFERENCES `czcraft_machines` (`machine_uuid`) ON DELETE RESTRICT,
    CONSTRAINT `chk_bills_target` CHECK (`target_quantity` > 0),
    CONSTRAINT `chk_bills_mode` CHECK (`mode` IN ('PRODUCE_X', 'MAINTAIN_X'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_active_cycles: PK per machine (one active cycle max). Cycle UUID +
-- sequence, bill, recipe hash/snapshot, start/due/duration, reserved output
-- weight, standard cost, version, timestamps.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_active_cycles` (
    `cycle_id`               CHAR(36)         NOT NULL,
    `cycle_sequence`         BIGINT(20) UNSIGNED NOT NULL,
    `machine_uuid`           CHAR(36)         NOT NULL,
    `bill_id`                CHAR(36)         DEFAULT NULL,
    `recipe_id`              VARCHAR(100)     NOT NULL,
    `recipe_hash`            CHAR(64)         NOT NULL,
    `recipe_snapshot`        JSON             NOT NULL,
    `started_at`             DATETIME(3)      NOT NULL,
    `due_at`                 DATETIME(3)      NOT NULL,
    `duration_seconds`       INT(10) UNSIGNED NOT NULL,
    `reserved_output_weight` INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `standard_cost`          DECIMAL(18,4)    NOT NULL DEFAULT 0.0000,
    `version`                INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`             DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`             DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`machine_uuid`),
    UNIQUE KEY `uq_cycles_cycle_id` (`cycle_id`),
    UNIQUE KEY `uq_cycles_cycle_sequence` (`cycle_sequence`),
    KEY `idx_cycles_due` (`due_at`),
    KEY `idx_cycles_bill` (`bill_id`),
    CONSTRAINT `fk_cycles_machine` FOREIGN KEY (`machine_uuid`) REFERENCES `czcraft_machines` (`machine_uuid`) ON DELETE RESTRICT,
    CONSTRAINT `fk_cycles_bill` FOREIGN KEY (`bill_id`) REFERENCES `czcraft_bills` (`bill_id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_production_events: one aggregated event per commit/chunk.
-- cycles_completed, inputs/outputs JSON, cost, start/end, idempotency key,
-- status, version, timestamps. Not one row per cycle.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_production_events` (
    `event_id`         CHAR(36)         NOT NULL,
    `machine_uuid`     CHAR(36)         NOT NULL,
    `bill_id`          CHAR(36)         DEFAULT NULL,
    `cycles_completed` INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `inputs`           JSON             NOT NULL,
    `outputs`          JSON             NOT NULL,
    `cost`             DECIMAL(18,4)    NOT NULL DEFAULT 0.0000,
    `started_at`       DATETIME(3)      NOT NULL,
    `ended_at`         DATETIME(3)      NOT NULL,
    `idempotency_key`  VARCHAR(255)     NOT NULL,
    `status`           VARCHAR(20)      NOT NULL DEFAULT 'COMMITTED',
    `version`          INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`       DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`       DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`event_id`),
    UNIQUE KEY `uq_production_idempotency_key` (`idempotency_key`),
    KEY `idx_production_machine_created` (`machine_uuid`, `created_at`),
    KEY `idx_production_status_updated` (`status`, `updated_at`),
    KEY `idx_production_bill` (`bill_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_operations: journal of actions/transfers. Unique operation key,
-- actor, owner, type, stage, payload hash, result/error, version, timestamps.
-- Independent of mutable domain-row deletion so recovery history survives.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_operations` (
    `operation_id`   CHAR(36)         NOT NULL,
    `operation_key`  VARCHAR(255)     NOT NULL,
    `actor_type`     VARCHAR(20)      NOT NULL,
    `actor_id`       VARCHAR(50)      NOT NULL,
    `owner_type`     VARCHAR(20)      DEFAULT NULL,
    `owner_id`       VARCHAR(50)      DEFAULT NULL,
    `machine_uuid`   CHAR(36)         DEFAULT NULL,
    `bill_id`        CHAR(36)         DEFAULT NULL,
    `type`           VARCHAR(50)      NOT NULL,
    `stage`          VARCHAR(50)      NOT NULL DEFAULT 'PENDING',
    `payload_hash`   VARCHAR(512)     NOT NULL,
    `status`         VARCHAR(50)      NOT NULL DEFAULT 'PENDING',
    `error`          TEXT             DEFAULT NULL,
    `version`        INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`     DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`     DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`operation_id`),
    UNIQUE KEY `uq_operations_operation_key` (`operation_key`),
    KEY `idx_operations_owner` (`owner_type`, `owner_id`),
    KEY `idx_operations_actor` (`actor_type`, `actor_id`),
    KEY `idx_operations_machine` (`machine_uuid`),
    KEY `idx_operations_status_updated` (`status`, `updated_at`),
    KEY `idx_operations_bill` (`bill_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_operation_steps: idempotent steps (STOCK_RESERVED, INVENTORY_APPLIED,
-- DOMAIN_COMMITTED, ...). Composite PK with parent operation. Result/error JSON.
-- Cascades with the parent operation row.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_operation_steps` (
    `operation_id`  CHAR(36)         NOT NULL,
    `step_name`     VARCHAR(50)      NOT NULL,
    `status`        VARCHAR(50)      NOT NULL DEFAULT 'PENDING',
    `result`        JSON             DEFAULT NULL,
    `error`         TEXT             DEFAULT NULL,
    `attempted_at`  DATETIME(3)      DEFAULT NULL,
    `version`       INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`    DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`    DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`operation_id`, `step_name`),
    KEY `idx_steps_status_updated` (`status`, `updated_at`),
    CONSTRAINT `fk_steps_operation` FOREIGN KEY (`operation_id`) REFERENCES `czcraft_operations` (`operation_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_inventory_mutations: journal consumed by the qb-inventory batch
-- patch. Unique mutation ID, batch hash, identifier, removals/additions JSON,
-- status, result, version, timestamps. Independent of machine rows so the
-- inventory patch can replay even if the machine is later removed.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_inventory_mutations` (
    `mutation_id`  VARCHAR(255)     NOT NULL,
    `batch_hash`   CHAR(64)         NOT NULL,
    `identifier`   VARCHAR(100)     NOT NULL,
    `removals`     JSON             NOT NULL,
    `additions`    JSON             NOT NULL,
    `status`       VARCHAR(50)      NOT NULL DEFAULT 'PENDING',
    `result`       JSON             DEFAULT NULL,
    `version`      INT(10) UNSIGNED NOT NULL DEFAULT 0,
    `created_at`   DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`   DATETIME(3)      NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`mutation_id`),
    UNIQUE KEY `uq_mutations_batch_hash` (`batch_hash`),
    KEY `idx_mutations_status_updated` (`status`, `updated_at`),
    KEY `idx_mutations_identifier` (`identifier`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_audit_events: actor/org/machine/storage/bill, action, previous/next
-- state, deltas, reason. Indexed by machine, owner + event_date, and
-- created_at. Independent journal — no FK to mutable rows so audit history
-- survives cleanup.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_audit_events` (
    `audit_id`       BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,
    `actor_type`     VARCHAR(20)         DEFAULT NULL,
    `actor_id`       VARCHAR(50)         DEFAULT NULL,
    `owner_type`     VARCHAR(20)         DEFAULT NULL,
    `owner_id`       VARCHAR(50)         DEFAULT NULL,
    `machine_uuid`   CHAR(36)            DEFAULT NULL,
    `storage_type`   VARCHAR(50)         DEFAULT NULL,
    `storage_id`     VARCHAR(255)        DEFAULT NULL,
    `bill_id`        CHAR(36)            DEFAULT NULL,
    `action`         VARCHAR(100)        NOT NULL,
    `previous_state` JSON                DEFAULT NULL,
    `next_state`     JSON                DEFAULT NULL,
    `deltas`         JSON                DEFAULT NULL,
    `reason`         TEXT                DEFAULT NULL,
    `created_at`     DATETIME(3)         NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `event_date`     DATE                AS (DATE(`created_at`)) STORED,
    PRIMARY KEY (`audit_id`),
    KEY `idx_audit_machine_created` (`machine_uuid`, `created_at`),
    KEY `idx_audit_owner_event_date` (`owner_type`, `owner_id`, `event_date`),
    KEY `idx_audit_action_created` (`action`, `created_at`),
    KEY `idx_audit_bill` (`bill_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- czcraft_legacy_migrations: idempotency + outcome of the paginated conversion
-- of legacy inventories (item_bench -> cz_workbench_machine,
-- attachment_bench -> cz_assembly_machine). Unique migration key.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `czcraft_legacy_migrations` (
    `migration_id`        BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT,
    `migration_key`       VARCHAR(255)        NOT NULL,
    `source_item`         VARCHAR(100)        NOT NULL,
    `target_machine_type` VARCHAR(50)         NOT NULL,
    `dry_run`             TINYINT(1)          NOT NULL DEFAULT 0,
    `page_size`           INT(10) UNSIGNED    NOT NULL DEFAULT 100,
    `pages`               INT(10) UNSIGNED    NOT NULL DEFAULT 0,
    `rows_processed`      INT(10) UNSIGNED    NOT NULL DEFAULT 0,
    `status`              VARCHAR(50)         NOT NULL DEFAULT 'PENDING',
    `result`              JSON                DEFAULT NULL,
    `version`             INT(10) UNSIGNED    NOT NULL DEFAULT 0,
    `created_at`          DATETIME(3)         NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    `updated_at`          DATETIME(3)         NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (`migration_id`),
    UNIQUE KEY `uq_legacy_migrations_key` (`migration_key`),
    KEY `idx_legacy_status_updated` (`status`, `updated_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------------
-- Stamp the schema-version singleton LAST. Never downgrade an existing newer
-- version; only insert or upgrade to 1.
-- ---------------------------------------------------------------------------
INSERT INTO `czcraft_schema_version` (`id`, `version`, `applied_at`)
VALUES (1, 1, CURRENT_TIMESTAMP(3))
ON DUPLICATE KEY UPDATE
    `version`    = IF(`version` < VALUES(`version`), VALUES(`version`), `version`),
    `applied_at` = IF(`version` < VALUES(`version`), VALUES(`applied_at`), `applied_at`);

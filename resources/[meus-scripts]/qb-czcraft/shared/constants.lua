-- qb-czcraft shared constants
-- Domain identifiers, permission vocabulary, and the unresolved-override sentinel.
-- This module is side-effect free so it can be loaded under stock Lua 5.4 in tests.

CZCraft = CZCraft or {}

CZCraft.VERSION = '0.2.0'

-- Required database schema version for this resource build.
-- Bootstrap compares this against czcraft_schema_version.version and stays
-- fully disabled when the applied version is missing, unreadable, or behind.
-- Migration 001_v0_1_core.sql stamps version 1.
-- Migration 002_v0_2_features.sql stamps version 2 (condition, power,
-- upgrades, UNTIL_X, financial exports, sale events, daily rollups).
CZCraft.REQUIRED_SCHEMA_VERSION = 2

-- Sentinel for required balance overrides that have not been supplied yet.
-- Validation must report any config value equal to this sentinel as an unresolved blocker.
CZCraft.UNRESOLVED = '__CZCRAFT_UNRESOLVED_OVERRIDE__'

CZCraft.OwnerType = {
    PLAYER = 'PLAYER',
    JOB = 'JOB',
    GANG = 'GANG',
}

CZCraft.LocationType = {
    HOUSE = 'HOUSE',
    ORG = 'ORG',
}

CZCraft.Permission = {
    OWNER = 'OWNER',
    MANAGER = 'MANAGER',
    PRODUCTION = 'PRODUCTION',
    WITHDRAW = 'WITHDRAW',
    DEPOSIT = 'DEPOSIT',
    VIEW = 'VIEW',
}

CZCraft.AccessTag = {
    CIVIL = 'CIVIL',
    ORG_WEAPONS = 'ORG_WEAPONS',
}

CZCraft.MachineType = {
    WORKBENCH = 'workbench',
    REFINERY = 'refinery',
    FABRICATOR = 'fabricator',
    ASSEMBLY = 'assembly',
}

-- v0.2 bill modes. UNTIL_X produces until stock + reserved >= until_threshold.
CZCraft.BillMode = {
    PRODUCE_X = 'PRODUCE_X',
    MAINTAIN_X = 'MAINTAIN_X',
    UNTIL_X = 'UNTIL_X',
}

-- v0.2 bill priorities. Lower sortValue = higher priority.
CZCraft.BillPriority = {
    HIGH = 'HIGH',
    NORMAL = 'NORMAL',
    LOW = 'LOW',
}

-- v0.2 upgrade tracks. Each maps to a column on czcraft_machines.
CZCraft.UpgradeTrack = {
    SPEED = 'speed',
    CAPACITY = 'capacity',
    EFFICIENCY = 'efficiency',
    DURABILITY = 'durability',
}

-- v0.2 financial export directions and sources.
CZCraft.FinancialDirection = {
    DEBIT = 'DEBIT',
    CREDIT = 'CREDIT',
}

CZCraft.FinancialSourceType = {
    QB_CORE = 'qb-core',
    QB_BANKING = 'qb-banking',
}

-- Approved placeholder prop models for the four MVP machines.
-- Config validation checks membership here instead of calling FiveM natives.
-- These are placeholders, not permanent art decisions.
CZCraft.ApprovedProps = {
    prop_tool_bench02 = true,
    gr_prop_gr_bench_01a = true,
    gr_prop_gr_bench_03a = true,
    prop_tool_bench02_ld = true,
}

-- qb-czcraft general configuration
-- v0.2: condition/wear/maintenance, power, upgrades, priority ordering,
-- UNTIL_X, sale events, and financial exports are feature-gated so they
-- can be deployed incrementally. All gameplay flags default to enabled
-- for v0.2; disable individually for staged rollout.

CZCraft.Config = CZCraft.Config or {}

CZCraft.Config.General = {
    resourceName = 'qb-czcraft',
    version = '0.2.0',

    -- Feature flags. v0.1 flags remain; v0.2 flags are added below.
    features = {
        placement = true,
        storageTransfers = false,
        bills = true,
        production = true,
        scheduler = true,
        nui = true,
        repairkit = true,
        admin = false,
        -- v0.2 feature flags
        condition = true,
        power = true,
        upgrades = true,
        priorityOrdering = true,
        untilX = true,
        sales = true,
        financialExports = true,
        rollups = true,
    },

    -- Fixture location caps are pre-gate test defaults explicitly called out by the spec.
    -- Production overrides still require review before the v0.1 gate.
    fixtureCaps = {
        HOUSE = 4,
        ORG = 20,
    },

    -- Maximum bills per machine. Pre-gate default; production may override before the v0.1 gate.
    maxBillsPerMachine = 5,
}

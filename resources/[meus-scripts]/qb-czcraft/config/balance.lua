-- qb-czcraft v0.2 balance configuration
-- Proposed defaults for condition/wear/maintenance, power, upgrades, and
-- priority ordering. Every numeric value here is a tunable default that can
-- be adjusted without touching logic code — the domain modules read from
-- CZCraft.Config.Balance, never from hardcoded literals.
--
-- RATIONALE: These values were chosen by the implementing agent (not the
-- user) to make the game playable without trivialising the economy. They
-- are conservative starting points: machines degrade slowly enough that
-- maintenance is an occasional chore (not per-session), power lasts long
-- enough that recharging is planned (not frantic), and upgrades are
-- scarce enough to force meaningful choices (10-point budget vs 27-point
-- max-out). Adjust freely before production.

CZCraft.Config = CZCraft.Config or {}

CZCraft.Config.Balance = {

    -- =====================================================================
    -- Condition / Wear / Maintenance
    -- =====================================================================
    condition = {
        -- Maximum condition a machine can reach (percentage scale 0-100).
        max = 100,
        -- Condition a new machine starts at. New placements and fresh
        -- purchases begin at full condition.
        start = 100,
        -- Condition lost per cycle (at cycle start, same as inputs and
        -- energy). At 0.5/cycle with 60s recipes, a machine fully degrades
        -- after 200 cycles (~3.3h of active production). This makes
        -- maintenance an occasional chore, not a per-session task.
        wearPerCycle = 0.5,
        -- Machine blocks new cycles when condition drops to or below this
        -- threshold. Active cycles finish; no new cycle starts until
        -- maintenance restores condition above the threshold.
        blockThreshold = 20,
    },

    maintenance = {
        -- Condition restored per maintenance action. One maintenance brings
        -- a machine from the block threshold (20) to 60; two bring it to
        -- full (100). This means a degraded machine needs 1-2 maintenance
        -- actions, not a grind.
        conditionRestoration = 40,
        -- Item consumed per maintenance action.
        itemCost = { item = 'cz_maintenance_kit', amount = 1 },
        -- Money charged per maintenance action (debited from the player).
        moneyCost = 200,
        -- Which money account to charge: 'cash' or 'bank'.
        moneyAccount = 'bank',
    },

    -- =====================================================================
    -- Power
    -- =====================================================================
    power = {
        -- Maximum stored energy (0-100 scale). A new machine starts full.
        capacity = 100,
        -- Starting power level for new machines.
        start = 100,
        -- Energy consumed per cycle (at cycle start, same as inputs). At
        -- 5/cycle with 60s recipes, a full charge lasts 20 cycles (~20 min
        -- of active production). This makes recharging a planned activity,
        -- not a constant chore.
        consumptionPerCycle = 5,
        -- Machine blocks new cycles when power drops below this. Set equal
        -- to consumptionPerCycle so a cycle can always complete once started.
        blockThreshold = 5,
        -- Energy restored by inserting one power cell.
        cellCharge = 50,
        -- Purchase price of a power cell from the machine's NUI (debited
        -- from the player). Crafting via the recipe is the free alternative.
        cellPurchasePrice = 500,
        -- Which money account to charge for cell purchases.
        cellMoneyAccount = 'bank',
    },

    -- =====================================================================
    -- Upgrades
    -- =====================================================================
    upgrades = {
        -- Total upgrade points available per machine. Points are spent
        -- across tracks; once spent they cannot be recovered (a downgrade
        -- in checkpoint 3 will allow partial recovery). At 10 points vs
        -- a 27-point max-out, the player must choose 2-3 tracks to invest in.
        totalBudget = 10,

        -- Each track defines: level cap, points per level, effect per level,
        -- and cost per level (item + money).
        tracks = {
            speed = {
                maxLevel = 5,
                pointsPerLevel = 1,
                -- Cycle duration multiplier reduction per level: -5% per
                -- level, max -25% at level 5.
                durationMultiplierPerLevel = -0.05,
                itemCost = { item = 'cz_upgrade_module', amount = 1 },
                moneyCost = 500,
            },
            capacity = {
                maxLevel = 5,
                pointsPerLevel = 2,
                -- Stock capacity bonus per level: +10% per level, max +50%.
                capacityBonusPerLevel = 0.10,
                itemCost = { item = 'cz_upgrade_module', amount = 1 },
                moneyCost = 1000,
            },
            efficiency = {
                maxLevel = 3,
                pointsPerLevel = 2,
                -- Power consumption reduction per level: -10% per level,
                -- max -30% at level 3.
                powerConsumptionMultiplierPerLevel = -0.10,
                itemCost = { item = 'cz_upgrade_module', amount = 1 },
                moneyCost = 800,
            },
            durability = {
                maxLevel = 3,
                pointsPerLevel = 2,
                -- Wear-per-cycle reduction per level: -15% per level,
                -- max -45% at level 3.
                wearMultiplierPerLevel = -0.15,
                itemCost = { item = 'cz_upgrade_module', amount = 1 },
                moneyCost = 800,
            },
        },

        -- Money account for upgrade purchases.
        moneyAccount = 'bank',
    },

    -- =====================================================================
    -- Priority ordering
    -- =====================================================================
    -- Lower sort value = higher priority. The bills domain sorts
    -- candidates by priority ascending, then created_sequence ascending.
    -- These map to the `priority` VARCHAR column on czcraft_bills.
    priority = {
        HIGH = { sortValue = 1 },
        NORMAL = { sortValue = 2 },
        LOW = { sortValue = 3 },
    },

    -- =====================================================================
    -- UNTIL_X bill mode
    -- =====================================================================
    -- UNTIL_X is a stock-threshold variant of MAINTAIN_X: produce until
    -- stock + reserved >= threshold. Unlike MAINTAIN_X (which may overshoot
    -- by one batch), UNTIL_X stops exactly at the threshold because the
    -- threshold is validated against the batch size at creation time.
    -- This does NOT introduce v0.3's general condition language.
    untilX = {
        -- Minimum threshold a player can set (prevents trivial 1-unit bills).
        minThreshold = 1,
    },

    -- =====================================================================
    -- Sale events
    -- =====================================================================
    sales = {
        -- Default unit price multiplier applied to standard_unit_cost when
        -- a player sells produced items directly from the machine (quick
        -- sell). 1.0 = sell at cost; the economy is intended to reward
        -- crafting + transporting goods, not instant-selling from machines.
        quickSellPriceMultiplier = 1.0,
        -- Money account for sale proceeds (credited to the player).
        moneyAccount = 'bank',
    },

    -- =====================================================================
    -- Rollups / retention
    -- =====================================================================
    retention = {
        -- Production events older than this many days are aggregated into
        -- daily rollups and then deleted. Keeps the production_events table
        -- bounded.
        eventRetentionDays = 30,
        -- Audit events older than this many days are deleted (audit has no
        -- rollup — it's a raw journal).
        auditRetentionDays = 90,
    },
}

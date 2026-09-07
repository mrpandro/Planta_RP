-- qb-czcraft machine definitions
-- Four MVP machines with documented hardware prices, stock capacities (kg -> grams),
-- selected placeholder prop models, and resolved balance overrides for item weight
-- and placement clearance. Values are pre-gate defaults; production may override
-- before the v0.1 gate.

CZCraft.Config = CZCraft.Config or {}

CZCraft.Config.Machines = {
    {
        type = CZCraft.MachineType.WORKBENCH,
        displayKey = 'machine.workbench.name',
        item = 'cz_workbench_machine',
        price = 5000,
        -- 100 kg -> 100,000 g
        stockCapacity = 100000,
        prop = 'prop_tool_bench02',
        -- Packed item weight in grams (matches qb-core/shared/items.lua).
        itemWeight = 10000,
        -- Placement clearance in meters.
        placementClearance = 1.5,
    },
    {
        type = CZCraft.MachineType.REFINERY,
        displayKey = 'machine.refinery.name',
        item = 'cz_refinery_machine',
        price = 15000,
        -- 250 kg -> 250,000 g
        stockCapacity = 250000,
        prop = 'gr_prop_gr_bench_01a',
        itemWeight = 20000,
        placementClearance = 2.0,
    },
    {
        type = CZCraft.MachineType.FABRICATOR,
        displayKey = 'machine.fabricator.name',
        item = 'cz_fabricator_machine',
        price = 25000,
        -- 200 kg -> 200,000 g
        stockCapacity = 200000,
        prop = 'gr_prop_gr_bench_03a',
        itemWeight = 20000,
        placementClearance = 2.0,
    },
    {
        type = CZCraft.MachineType.ASSEMBLY,
        displayKey = 'machine.assembly.name',
        item = 'cz_assembly_machine',
        price = 40000,
        -- 300 kg -> 300,000 g
        stockCapacity = 300000,
        prop = 'prop_tool_bench02_ld',
        itemWeight = 30000,
        placementClearance = 2.5,
    },
}

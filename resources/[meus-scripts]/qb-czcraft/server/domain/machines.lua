-- qb-czcraft machine domain (pure)
-- Lifecycle state machine (PACKED|INSTALLED) and placement validation for
-- HOUSE and ORG locations. Side-effect-free: placement validation accepts the
-- machine config, plots config, house access result, and a bounds/injection
-- fixture so it runs under stock Lua 5.4 in tests.

CZCraft = CZCraft or {}

local Lifecycle = {
    PACKED = 'PACKED',
    INSTALLED = 'INSTALLED',
}

local OperationalStatus = {
    STOPPED = 'STOPPED',
    RUNNING = 'RUNNING',
}

-- Distance helpers (pure math; the api layer passes real ped/transform coords).
local function isFiniteNumber(value)
    return type(value) == 'number' and value == value and math.abs(value) ~= math.huge
end

local function distance2D(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function distance3D(ax, ay, az, bx, by, bz)
    local dx = ax - bx
    local dy = ay - by
    local dz = az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Validates a transform is finite and within an optional ped-proximity limit.
-- @param transform table { pos_x, pos_y, pos_z, heading }
-- @param pedCoords table|nil { x, y, z } when proximity must be re-checked
-- @param maxProximity number|nil meters the machine may be from the ped
-- @return boolean ok
-- @return string|nil reason
local function validateTransform(transform, pedCoords, maxProximity)
    if type(transform) ~= 'table' then
        return false, 'transform must be a table'
    end
    if not isFiniteNumber(transform.pos_x)
        or not isFiniteNumber(transform.pos_y)
        or not isFiniteNumber(transform.pos_z) then
        return false, 'transform position must be finite numbers'
    end
    if not isFiniteNumber(transform.heading) then
        return false, 'transform heading must be a finite number'
    end
    if pedCoords and maxProximity then
        if not isFiniteNumber(pedCoords.x) or not isFiniteNumber(pedCoords.y) or not isFiniteNumber(pedCoords.z) then
            return false, 'ped coords must be finite numbers'
        end
        local dist = distance3D(transform.pos_x, transform.pos_y, transform.pos_z, pedCoords.x, pedCoords.y, pedCoords.z)
        if dist > maxProximity then
            return false, ('machine must be within %.2fm of the player ped (was %.2fm)'):format(maxProximity, dist)
        end
    end
    return true
end

-- Finds the machine config entry for a machine type.
-- @param machinesConfig table ordered list from Config.Machines
-- @param machineType string
-- @return table|nil machineConfig
local function findMachineConfig(machinesConfig, machineType)
    if type(machinesConfig) ~= 'table' then return nil end
    for _, machine in ipairs(machinesConfig) do
        if machine and machine.type == machineType then
            return machine
        end
    end
    return nil
end

-- Point-in-polygon (ray casting). Pure, no natives.
-- @param polygon table ordered list of { x, y }
-- @param px, py number point to test
-- @return boolean inside
local function pointInPolygon(polygon, px, py)
    if type(polygon) ~= 'table' or #polygon < 3 then
        return false
    end
    local inside = false
    local j = #polygon
    for i = 1, #polygon do
        local pi = polygon[i]
        local pj = polygon[j]
        if (pi.y > py) ~= (pj.y > py) then
            local xIntersect = (pj.x - pi.x) * (py - pi.y) / (pj.y - pi.y) + pi.x
            if px < xIntersect then
                inside = not inside
            end
        end
        j = i
    end
    return inside
end

-- Finds the ORG plot containing a position, respecting polygon + z-range.
-- @param plotsConfig table Config.Plots
-- @param pos table { x, y, z }
-- @return table|nil plot
local function findPlotAt(plotsConfig, pos)
    if type(plotsConfig) ~= 'table' then return nil end
    for _, plot in ipairs(plotsConfig) do
        if type(plot) == 'table' and type(plot.polygon) == 'table' then
            if pointInPolygon(plot.polygon, pos.x, pos.y) then
                local zBounds = plot.zBounds
                if type(zBounds) == 'table'
                    and isFiniteNumber(zBounds.min) and isFiniteNumber(zBounds.max) then
                    if pos.z < zBounds.min or pos.z > zBounds.max then
                        goto continue
                    end
                end
                return plot
            end
        end
        ::continue::
    end
    return nil
end

-- Counts existing machines at a location (for cap enforcement).
-- @param existingMachines table list of { location_type, location_id }
-- @param locationType string
-- @param locationId string
-- @return number count
local function countMachinesAtLocation(existingMachines, locationType, locationId)
    if type(existingMachines) ~= 'table' then return 0 end
    local count = 0
    for _, machine in ipairs(existingMachines) do
        if machine and machine.location_type == locationType and machine.location_id == locationId then
            count = count + 1
        end
    end
    return count
end

-- Checks clearance: the proposed transform must be at least `clearance` meters
-- from every other installed machine at the same location.
-- @param existingMachines table list of { pos_x, pos_y, pos_z, location_type, location_id }
-- @param locationType string
-- @param locationId string
-- @param transform table { pos_x, pos_y, pos_z }
-- @param clearance number meters
-- @return boolean ok
-- @return string|nil reason
local function checkClearance(existingMachines, locationType, locationId, transform, clearance)
    if type(existingMachines) ~= 'table' then return true end
    for _, machine in ipairs(existingMachines) do
        if machine and machine.location_type == locationType and machine.location_id == locationId then
            if isFiniteNumber(machine.pos_x) and isFiniteNumber(machine.pos_y) then
                local dist = distance2D(transform.pos_x, transform.pos_y, machine.pos_x, machine.pos_y)
                if dist < clearance then
                    return false, ('machine too close to an existing machine (%.2fm < %.2fm clearance)'):format(dist, clearance)
                end
            end
        end
    end
    return true
end

-- Result builder for placement validation.
local function okResult(machineConfig, ownerRef, location)
    return {
        ok = true,
        machineConfig = machineConfig,
        ownerRef = ownerRef,
        location = location,
    }
end

local function failResult(reason)
    return { ok = false, reason = reason }
end

-- Validates a HOUSE placement request.
-- @param params table {
--   transform, machineType, machinesConfig, fixtureCaps,
--   houseAccess = { isOwner, isKeyholder, insideHouseId, shellBounds? },
--   existingMachines, pedCoords, maxProximity,
-- }
-- @return table { ok, reason?, machineConfig?, ownerRef?, location? }
local function validateHousePlacement(params)
    if type(params) ~= 'table' then return failResult('params must be a table') end
    local houseAccess = params.houseAccess
    if type(houseAccess) ~= 'table' then
        return failResult('houseAccess is required for HOUSE placement')
    end

    -- Must be inside the house.
    local insideHouseId = houseAccess.insideHouseId
    if type(insideHouseId) ~= 'string' or insideHouseId == '' then
        return failResult('player must be inside a house to place a HOUSE machine')
    end

    -- Owner or keyholder.
    if not houseAccess.isOwner and not houseAccess.isKeyholder then
        return failResult('only the house owner or a keyholder may place a machine')
    end

    -- Machine type allow-list.
    local machineConfig = findMachineConfig(params.machinesConfig, params.machineType)
    if not machineConfig then
        return failResult('machine type not in allow-list: ' .. tostring(params.machineType))
    end

    -- Transform + proximity.
    local transformOk, transformReason = validateTransform(params.transform, params.pedCoords, params.maxProximity)
    if not transformOk then
        return failResult(transformReason)
    end

    -- Shell bounds: if provided, the machine must lie within them. qb-houses
    -- does not expose exact shell bounds at v0.1; the api layer may pass a
    -- bounding box derived from the shell origin. When absent, the proximity
    -- check is the only spatial guard.
    local shellBounds = houseAccess.shellBounds
    if type(shellBounds) == 'table'
        and isFiniteNumber(shellBounds.minX) and isFiniteNumber(shellBounds.maxX)
        and isFiniteNumber(shellBounds.minY) and isFiniteNumber(shellBounds.maxY) then
        local t = params.transform
        if t.pos_x < shellBounds.minX or t.pos_x > shellBounds.maxX
            or t.pos_y < shellBounds.minY or t.pos_y > shellBounds.maxY then
            return failResult('machine transform is outside the house shell bounds')
        end
    end

    -- Cap.
    local cap = params.fixtureCaps and params.fixtureCaps[CZCraft.LocationType.HOUSE]
    if type(cap) ~= 'number' or cap < 1 then
        return failResult('HOUSE fixture cap is not configured')
    end
    local existing = countMachinesAtLocation(params.existingMachines, CZCraft.LocationType.HOUSE, insideHouseId)
    if existing >= cap then
        return failResult(('HOUSE machine cap reached (%d/%d)'):format(existing, cap))
    end

    -- Clearance.
    local clearanceOk, clearanceReason = checkClearance(
        params.existingMachines, CZCraft.LocationType.HOUSE, insideHouseId,
        params.transform, machineConfig.placementClearance
    )
    if not clearanceOk then
        return failResult(clearanceReason)
    end

    -- HOUSE owner is always the house owner (even when a keyholder places).
    -- The ownerRef is supplied by the caller; the api layer resolves it from
    -- the house owner's citizenid.
    local ownerRef = params.ownerRef
    local ownerValid, ownerReason = CZCraft.Owners.isValidOwnerRef(ownerRef)
    if not ownerValid then
        return failResult('invalid ownerRef: ' .. tostring(ownerReason))
    end

    return okResult(machineConfig, ownerRef, {
        type = CZCraft.LocationType.HOUSE,
        id = insideHouseId,
    })
end

-- Validates an ORG placement request.
-- @param params table {
--   transform, machineType, machinesConfig, plotsConfig, fixtureCaps,
--   ownerRef, orgAccess = { gradeKey, isStillMember }, existingMachines,
--   pedCoords, maxProximity,
-- }
-- @return table { ok, reason?, machineConfig?, ownerRef?, location? }
local function validateOrgPlacement(params)
    if type(params) ~= 'table' then return failResult('params must be a table') end

    -- Machine type allow-list.
    local machineConfig = findMachineConfig(params.machinesConfig, params.machineType)
    if not machineConfig then
        return failResult('machine type not in allow-list: ' .. tostring(params.machineType))
    end

    -- Transform + proximity.
    local transformOk, transformReason = validateTransform(params.transform, params.pedCoords, params.maxProximity)
    if not transformOk then
        return failResult(transformReason)
    end

    -- Plot must contain the transform.
    local t = params.transform
    local plot = findPlotAt(params.plotsConfig, { x = t.pos_x, y = t.pos_y, z = t.pos_z })
    if not plot then
        return failResult('transform is not inside any configured ORG plot')
    end

    -- Plot owner context must match the chosen ownerRef.
    local ownerRef = params.ownerRef
    local ownerValid, ownerReason = CZCraft.Owners.isValidOwnerRef(ownerRef)
    if not ownerValid then
        return failResult('invalid ownerRef: ' .. tostring(ownerReason))
    end
    if plot.ownerType ~= ownerRef.type or plot.ownerId ~= ownerRef.id then
        return failResult('plot owner context does not match the chosen ownerRef')
    end

    -- Membership still active.
    local orgAccess = params.orgAccess
    if type(orgAccess) ~= 'table' or not orgAccess.isStillMember then
        return failResult('actor is no longer a member of the owning organization')
    end

    -- Cap (per-plot machineCap takes precedence over the global ORG cap).
    local cap = plot.machineCap or (params.fixtureCaps and params.fixtureCaps[CZCraft.LocationType.ORG])
    if type(cap) ~= 'number' or cap < 1 then
        return failResult('ORG machine cap is not configured')
    end
    local existing = countMachinesAtLocation(params.existingMachines, CZCraft.LocationType.ORG, plot.id)
    if existing >= cap then
        return failResult(('ORG plot machine cap reached (%d/%d)'):format(existing, cap))
    end

    -- Clearance.
    local clearanceOk, clearanceReason = checkClearance(
        params.existingMachines, CZCraft.LocationType.ORG, plot.id,
        params.transform, machineConfig.placementClearance
    )
    if not clearanceOk then
        return failResult(clearanceReason)
    end

    return okResult(machineConfig, ownerRef, {
        type = CZCraft.LocationType.ORG,
        id = plot.id,
    })
end

-- Pickup preconditions. The machine must be stopped, have no active cycle,
-- no active/paused bills, and zero stock + reservations.
-- @param machine table { operational_status, active_cycle_id, lifecycle }
-- @param activeBillsCount number bills that are enabled or paused (not removed)
-- @param stockTotal number sum of quantity across stock rows
-- @param reservedTotal number sum of reserved_quantity across stock rows
-- @return boolean ok
-- @return string|nil reason
local function validatePickup(machine, activeBillsCount, stockTotal, reservedTotal)
    if type(machine) ~= 'table' then
        return false, 'machine must be a table'
    end
    if machine.lifecycle ~= Lifecycle.INSTALLED then
        return false, 'machine must be INSTALLED to pick up (was ' .. tostring(machine.lifecycle) .. ')'
    end
    if machine.operational_status == OperationalStatus.RUNNING then
        return false, 'machine is running; stop it before pickup'
    end
    if machine.active_cycle_id ~= nil then
        return false, 'machine has an active cycle; let it finish before pickup'
    end
    if (activeBillsCount or 0) > 0 then
        return false, 'machine has active or paused bills; pause/remove them before pickup'
    end
    if (stockTotal or 0) > 0 then
        return false, 'machine stock must be empty before pickup'
    end
    if (reservedTotal or 0) > 0 then
        return false, 'machine has reserved stock; clear reservations before pickup'
    end
    return true
end

CZCraft.Machines = {
    Lifecycle = Lifecycle,
    OperationalStatus = OperationalStatus,
    validateTransform = validateTransform,
    findMachineConfig = findMachineConfig,
    pointInPolygon = pointInPolygon,
    findPlotAt = findPlotAt,
    countMachinesAtLocation = countMachinesAtLocation,
    checkClearance = checkClearance,
    validateHousePlacement = validateHousePlacement,
    validateOrgPlacement = validateOrgPlacement,
    validatePickup = validatePickup,
    distance2D = distance2D,
    distance3D = distance3D,
}

return CZCraft.Machines

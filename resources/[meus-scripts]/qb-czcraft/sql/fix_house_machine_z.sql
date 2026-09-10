-- One-off data fix: correct pos_z of HOUSE machines placed before the
-- PlaceObjectOnGroundProperly fix.
--
-- Background: the placement ghost used PlaceObjectOnGroundProperly, which
-- snaps to the world terrain heightmap and ignores qb-houses shell interior
-- floors. Machines committed during that window stored the terrain z, so
-- streamed props rendered underground relative to the shell floor and were
-- invisible. The x/y are correct (the placement raycast hit the shell
-- floor); only z needs correction.
--
-- The shell interior floor sits at enter.z - Config.MinZOffset. MinZOffset
-- is 30 in qb-houses/config.lua. This sets every INSTALLED HOUSE machine's
-- pos_z to that floor height. It is exact for shells whose floor is at the
-- shell origin (the common case); if a particular shell floats/sinks a
-- machine by a fraction, pick it up and re-place it after deploying the
-- client fix so the raycast z is stored exactly.
--
-- Run the PREVIEW first, review the rows, then run the UPDATE.

-- PREVIEW: show affected machines and the z that will be written.
SELECT
    m.machine_uuid,
    m.location_id AS house,
    m.pos_x, m.pos_y, m.pos_z AS current_z,
    JSON_UNQUOTE(JSON_EXTRACT(h.coords, '$.enter.z')) - 30 AS new_z
FROM czcraft_machines m
JOIN houselocations h ON h.name = m.location_id
WHERE m.lifecycle = 'INSTALLED'
  AND m.location_type = 'HOUSE';

-- UPDATE: correct pos_z to the shell interior floor height.
UPDATE czcraft_machines m
JOIN houselocations h ON h.name = m.location_id
SET m.pos_z = JSON_UNQUOTE(JSON_EXTRACT(h.coords, '$.enter.z')) - 30
WHERE m.lifecycle = 'INSTALLED'
  AND m.location_type = 'HOUSE';

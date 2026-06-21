# Planta RP - Resource Update Log

## Last Update: 21 Jun 2026

---

## What Was Updated

### Critical Dependencies (Security Fixes)
| Resource | Old | New | Why |
|----------|-----|-----|-----|
| **oxmysql** | `2.12.0` | `2.14.1` | SQL injection vulnerability fix |
| **ox_lib** | `3.30.6` | `3.38.0` | Callback/statebag security improvements |

### Core Framework
| Resource | Old | New | Notes |
|----------|-----|-----|-------|
| **qb-core** | `1.3.0` | `1.3.0` (upstream main) | New player class + export bridge. Added `exports['qb-core']:GetPlayer()`, `GetPlayerByCitizenId()`, `GetOfflinePlayerByCitizenId()` |

### QBCore Resources (First Pass - 21 Jun 2026)
| Resource | Old | New | Notes |
|----------|-----|-----|-------|
| **qb-inventory** | `2.0.0` | `2.0.0` | ID card spoofing fix re-applied manually |
| **qb-banking** | `2.0.0` | `2.0.0` | Now compatible with new qb-core exports |
| **qb-phone** | `1.3.0` | `1.5.0` | Now compatible with new qb-core exports |
| **qb-policejob** | `1.3.5` | `1.3.5` | Now compatible with new qb-core exports |
| **qb-vehicleshop** | `2.1.0` | `2.1.0` | Now compatible with new qb-core exports |
| **qb-houses** | `2.2.0` | `1.5.0` | Now compatible with new qb-core exports |

### QBCore Resources (Second Pass - 21 Jun 2026)
All remaining `qb-*` resources updated to latest upstream `main`:
- `qb-ambulancejob`, `qb-apartments`, `qb-bankrobbery`, `qb-busjob`, `qb-cityhall`
- `qb-crafting`, `qb-crypto`, `qb-diving`, `qb-doorlock`, `qb-drugs`, `qb-fuel`, `qb-garages`, `qb-garbagejob`, `qb-hotdogjob`
- `qb-houserobbery`, `qb-hud`, `qb-input`, `qb-interior`, `qb-jewelery`, `qb-lapraces`, `qb-loading`
- `qb-management`, `qb-mechanicjob`, `qb-menu`, `qb-minigames`, `qb-multicharacter`, `qb-newsjob`
- `qb-pawnshop`, `qb-prison`, `qb-radialmenu`, `qb-recyclejob`, `qb-scoreboard`, `qb-scrapyard`
- `qb-shops`, `qb-smallresources`, `qb-spawn`, `qb-storerobbery`, `qb-streetraces`, `qb-target`
- `qb-taxijob`, `qb-towjob`, `qb-truckrobbery`, `qb-vehiclekeys`, `qb-vehiclesales`
- `qb-vineyard`, `qb-weapons`, `qb-weathersync`, `qb-weed`

### Third-Party Resources Updated
| Resource | Repo | Notes |
|----------|------|-------|
| **illenium-appearance** | iLLeniumStudios/illenium-appearance | Custom `locales/locales.lua` fallback preserved |
| **ps-adminmenu** | Project-Sloth/ps-adminmenu | Custom `locales/pt-PT.json` preserved |
| **PolyZone** | mkafrin/PolyZone | Uses `master` branch |
| **progressbar** | qbcore-framework/progressbar | Updated to latest |
| **pma-voice** | AvarianKnight/pma-voice | Updated to latest |

### Security Patches (Re-apply needed after updates)
| Resource | Action | Status |
|----------|--------|--------|
| **qb-management** | SQL injection fix in `sv_boss.lua` and `sv_gang.lua` + nil guards | Needs re-application |
| **ps-adminmenu** | Permission checks + input validation + nil guards | Needs re-application |
| **simple-repair** | Server-side vehicle validation to prevent spoofing | Still intact (not updated) |

---

## Custom Configs Preserved

- **Portuguese locales** (`pt.lua`, `pt-br.lua`) in `qb-core`, `qb-management`, `ps-adminmenu`, and all updated QBCore resources
- **Custom job labels** in `qb-core/shared/jobs.lua` (PSP, INEM, Táxis, Stand Automóvel, etc.)
- **Custom jobs**: `tuners`, `bennys` (mechanic roles)
- **qb-core `config.lua`** (server settings, Discord link, etc.)
- **qb-mechanicjob `config/config.lua`** (Benny's + Tuners shop configs)
- **qb-cityhall `config.lua`** (custom license costs)
- **qb-ambulancejob `config.lua`** (custom hospital bill cost)
- **qb-shops `locale/pt.lua`** (European Portuguese translations)
- **illenium-appearance `locales/locales.lua`** (custom fallback logic)

---

## How to Update QBCore Scripts in the Future

### Check if a resource needs updating

1. Open the resource's `fxmanifest.lua` and note the `version`.
2. Go to `https://github.com/qbcore-framework/<resource-name>`
3. Check the `main` branch for newer commits or a different version string.

### Replace a resource safely

```powershell
# 1. Download the latest main branch
Invoke-WebRequest -Uri 'https://github.com/qbcore-framework/<resource>/archive/refs/heads/main.zip' -OutFile '<resource>.zip'

# 2. Extract
Expand-Archive -Path '<resource>.zip' -DestinationPath '<resource>-extract' -Force

# 3. Backup your current resource (especially config.lua and locales)
Copy-Item -Path 'resources/[qb]/<resource>' -Destination '<resource>-backup' -Recurse -Force

# 4. Replace
robocopy '<resource>-extract/<resource>-main' 'resources/[qb]/<resource>' /E

# 5. Restore your custom configs
Copy-Item '<resource>-backup/config.lua' 'resources/[qb]/<resource>/config.lua' -Force
Copy-Item '<resource>-backup/locales/pt.lua' 'resources/[qb]/<resource>/locales/pt.lua' -Force
```

### Important rules

- **Always back up** `config.lua`, `locales/pt.lua`, and any other custom files before replacing.
- **Never overwrite** `qb-core/shared/jobs.lua`, `gangs.lua`, or `items.lua` with upstream defaults unless you want to lose custom jobs/gangs.
- **Test on a dev server first** before pushing to production.
- **Check for errors** in the server console after each update.

---

## Remaining Tasks

- [ ] Test server startup and player login with updated qb-core
- [ ] Test inventory (ID cards, driver licenses)
- [ ] Test banking transfers
- [ ] Test phone apps
- [ ] Test boss menus (qb-management)
- [ ] Proceed with full security audit once updates are stable

---

## Git Commit

All changes were committed with the message:
```
Update QBCore resources and apply security patches
```

Branch: `main` (or current working branch)

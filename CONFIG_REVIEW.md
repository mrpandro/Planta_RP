# Custom Config Review — Post-Update

Generated after updating all QBCore resources to latest upstream (21 Jun 2026).

---

## 1. Configs Successfully Preserved

These custom configs were backed up and restored during the update. They are **identical to your pre-update versions**.

| Resource | File | What You Customized |
|----------|------|---------------------|
| `qb-core` | `shared/jobs.lua` | Custom job labels (PSP, INEM, Táxis, Stand Automóvel, etc.) + custom jobs `tuners`, `bennys` |
| `qb-core` | `shared/gangs.lua` | Custom gang definitions |
| `qb-core` | `shared/items.lua` | Custom items |
| `qb-core` | `config.lua` | Server settings, Discord link, etc. |
| `qb-mechanicjob` | `config/config.lua` | Benny's Original + Tuners Underground shop configs, Portuguese labels |
| `qb-cityhall` | `config.lua` | Custom license costs (ID=50, Driver=50, Weapon=50) |
| `qb-ambulancejob` | `config.lua` | Custom hospital bill cost (2000 vs default 3500) |
| `qb-shops` | `locale/pt.lua` | European Portuguese translations |
| `illenium-appearance` | `shared/config.lua` | Custom appearance config |
| `illenium-appearance` | `locales/locales.lua` | Custom fallback logic for missing translations |
| `ps-adminmenu` | `shared/config.lua` | Custom admin menu config |
| `ps-adminmenu` | `locales/pt-PT.json` | European Portuguese translations |

**Verdict:** No action needed for these. They are safe.

---

## 2. Structural Changes — Action Required

### qb-target
**What changed:** Upstream completely restructured qb-target. It now uses a top-level `config.lua` instead of the old `client/config.lua` + `client/registration.lua` approach.

**What happened to your config:** Your old `qb-target/config.lua` was preserved (it existed in the old version too). However, upstream added a **new default `config.lua`** with many new options:
- `Config.MaxDistance = 7.0`
- `Config.Debug = false`
- `Config.EnableOutline = false`
- `Config.DrawSprite = true`
- `Config.DrawDistance = 10.0`
- `Config.DrawColor`, `Config.SuccessDrawColor`, `Config.OutlineColor`
- `Config.EnableDefaultOptions = true`
- `Config.DisableInVehicle = false`
- `Config.OpenKey = 'LMENU'`
- `Config.DisableControls = true`
- Plus empty zone tables: `CircleZones`, `BoxZones`, `PolyZones`, etc.

**Recommendation:**
- If you had custom target zones in your old config, **they are preserved**.
- If you want the new upstream features (debug outlines, sprite drawing, default vehicle options), **compare your current `qb-target/config.lua` with the upstream default** and merge the new options in.

---

### qb-input
**What changed:** Upstream deleted `qb-input/client/config.lua`. It now only has `qb-input/client/main.lua` with inline config.

**What happened to your config:** If you had custom values in `client/config.lua`, they are **lost**. The old file only contained:
```lua
Config = {}
Config.Style = 'default'
```

**Recommendation:** If you changed `Config.Style`, re-apply it in the new structure. Otherwise, no action.

---

### qb-newsjob
**What changed:** Upstream changed translation keys in the locale files:
- `weazel_news_vehicles` → `vehicle`
- `weazel_news_helicopters` → `heli`

**What happened to your config:** This resource did **not** have a Portuguese locale (`pt.lua` or `pt-br.lua`) before the update, so nothing was lost.

**Recommendation:** If you plan to add Portuguese translations for qb-newsjob in the future, use the **new key names** (`vehicle`, `heli`).

---

## 3. Resources That May Need Manual Config Review

These resources had significant upstream rewrites. Your custom config was preserved, but upstream may have added new config options that you're missing.

### qb-management
- **Status:** Your `config.lua` was preserved (boss menus, gang menus).
- **Risk:** Upstream may have added new config options in `config.lua` or changed the config structure.
- **Action:** Compare your current `qb-management/config.lua` with the upstream default. Look for new options like webhook URLs, commission rates, or new menu locations.

### qb-vehicleshop
- **Status:** Your config was preserved.
- **Risk:** This resource had significant upstream changes. New config options may exist (e.g., finance settings, test drive configs).
- **Action:** Review `qb-vehicleshop/config.lua` against upstream.

### qb-houses
- **Status:** Your config was preserved.
- **Risk:** Upstream version changed from `2.2.0` to `1.5.0` (version string reset, but code changed significantly).
- **Action:** Test thoroughly. Check `qb-houses/config.lua` for new furniture or housing options.

### qb-phone
- **Status:** Your config was preserved.
- **Risk:** Updated from `1.3.0` to `1.5.0`. Major rewrite likely added new app configs.
- **Action:** Check `qb-phone/config.lua` for new app settings (crypto, gallery, etc.).

---

## 4. Security Patches — MUST RE-APPLY

These resources were updated upstream, which **overwrote your manual security patches**.

### qb-management
**Previous patch:** SQL injection fix in `sv_boss.lua` and `sv_gang.lua` + nil guards.
**Status:** Overwritten by upstream update.
**Action:** Re-apply the SQL injection fixes. If upstream already fixed them, verify by checking for parameterized queries or `?` placeholders in SQL strings.

### ps-adminmenu
**Previous patch:** Permission checks + input validation + nil guards.
**Status:** Overwritten by upstream update.
**Action:** Re-apply permission checks. Check `server/main.lua`, `server/players.lua`, `server/misc.lua` for missing `QBCore.Functions.HasPermission` or input validation.

### simple-repair
**Previous patch:** Server-side vehicle validation.
**Status:** Not updated (still intact).
**Action:** None needed.

---

## 5. Recommended Next Steps

1. **Start the server in dev mode** and check console for missing config errors.
2. **Test these resources first:**
   - `qb-target` (new config structure)
   - `qb-phone` (major version bump)
   - `qb-houses` (version downgrade, test thoroughly)
   - `qb-management` (security patches missing)
   - `ps-adminmenu` (security patches missing)
3. **For each preserved config file, do a quick diff against upstream:**
   ```powershell
   # Example: compare qb-management config
   git diff HEAD~1 HEAD -- resources/[qb]/qb-management/config.lua
   ```
4. **Re-apply security patches** to `qb-management` and `ps-adminmenu` before going live.
5. **Review `qb-target/config.lua`** and decide if you want to adopt the new upstream options (debug, outlines, sprites).

---

## 6. Quick Reference: Custom Values You Set

```
qb-cityhall: license costs = 50 (was 300/750/15000 upstream)
qb-ambulancejob: bill cost = 2000 (was 3500 upstream)
qb-mechanicjob: shops = bennys + mechanic2 (Tuners Underground)
qb-shops: European Portuguese locale
illenium-appearance: custom locale fallback logic
ps-adminmenu: European Portuguese locale (pt-PT)
```

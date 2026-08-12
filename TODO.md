# KMProcsTracker — TODO (v0.3.46)

## DONE in v0.3.42 (this archive)
- **TestLab taint fix:** TestLab no longer calls `RegisterEvent()` / `UnregisterAllEvents()` (was triggering `[ADDON_ACTION_FORBIDDEN]`). All event registration lives in `Core.lua`.
- **Core → TestLab forwarders:** `UNIT_AURA`, `UNIT_SPELLCAST_SUCCEEDED`, `SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE`, and `COMBAT_LOG_EVENT_UNFILTERED` forward into TestLab when enabled.
- **CLEU availability:** `COMBAT_LOG_EVENT_UNFILTERED` is registered once in `Core.lua` (wrapped in `pcall`) and gated in the handler. TestLab CL logs only relevant events (KM aura events + spender casts) to avoid spam.
- **Secret-safe CDM candidates:** candidate texture building and matching avoid secret values (no secret comparisons).
- **Prevent false KM aura discovery:** persisted `db.kmAuraSpellId` is forcibly cleared on load (12.x can mis-bind unrelated auras under SecretValue rules).


## DONE in v0.3.43 (this archive)
- **CDM anti-freeze gates:** `ignoreZeroIfAuraPresent` and `ignoreHideConfirmIfAuraPresent` are now **debug-only flags** (default OFF).
- **CDM anti-double-count:** CDM stack-text SetText hooks are now **disabled by default** (`useTextHooks=false`).
- **CDM pulse tuning:** default `procMinInterval` lowered to **0.14s** to reduce missed fast procs while still deduping repaint spam.
- **Hybrid safety:** aura-driven overcap accounting is now **disabled for CDM backend** (CDM pulses own overcap accounting).

## CURRENTLY BROKEN / UNRELIABLE (root issues)
1) **Aura stacks/timers are secret**
   - `C_UnitAuras.GetAuraDataByAuraInstanceID()` returns `applications/name/spellId/duration/expirationTime` as `<secret>` for KM in 12.x.
   - Result: aura can be used only for **presence (on/off)** + **auraInstanceID binding**, but *not* as truth for stacks/timers.

2) **CDM truth depends on UI recycle**
   - CDM frame reuse/pooling can emit show/hide/text events not corresponding 1:1 to “KM gained/spent”.
   - In v0.3.43 CDM defaults move to pulse-based counting; remaining risk is false expirations from hide-confirm under heavy UI recycle.

## DONE in v0.3.44 (this archive)
- **Critical TOC fix:** restored file list in `KMProcsTracker.toc` so modules actually load (Core/UI/Minimap/Backends).
- **SavedVariables:** `KMProcsTrackerDB` now declared in TOC; DB persistence is deterministic (required for minimap icon state).
- **Minimap recovery command:** added `/kmpt minimap show|hide|toggle` to recover the LibDBIcon button if it was hidden in SavedVariables.


## DONE in v0.3.45 (this archive)
- **Lua syntax fix:** removed an extra `end` in `Core.lua` that caused `")" expected ... near "end"` and prevented the addon from loading.

## DONE in v0.3.46 (this archive)
- **Midnight CLEU restriction:** stopped registering `COMBAT_LOG_EVENT_UNFILTERED` by default. In 12.0+ this event path can trigger `[ADDON_ACTION_FORBIDDEN]` errors; KMPT now operates fully without CLEU.
- **/kmpt cltest:** now explains that the combat-log probe is disabled in Midnight.

## NEXT STEPS (priority order)
### P0 — stop stack freezing / double-counting (CDM)
- **DONE in v0.3.43:** aura-presence heuristics moved to debug-only flags (default OFF).
- **DONE in v0.3.43:** CDM stack-text SetText hooks disabled by default.
- Remaining:
  - Validate that `OnHide`/hide-confirm logic does not generate false expirations under heavy UI recycle.
  - If needed, add a stricter hide-confirm debounce keyed on spender-at + last-pulse-at.

### P0 — hybrid policy (final)
- Lock policy:
  - **Aura** = truth only for presence/bind/remove.
  - **SAO** = truth only for “gain window” when we believe stacks==0.
  - **Spender casts** = truth for decrement (1 stack by default; optional consume-all).
  - **Stacks** = internal counter reconciled by signals (not overwritten by any single source).

### P1 — DevTools calibration controls (what ты просил)
- Add sliders (DevTools):
  - CDM `procMinInterval`
  - signature dedup window
  - spender→remove debounce window
  - log rate limit
- Add live stats: accepted vs rejected pulses, pulses/min, overcap rate.

### P2 — evidence capture (structured)
- TestLab: “capture last N events” buffer and one-click export in its own scroll window.
- Optional: mark each proc as a single snapshot (SAO show, unit_aura bind, cdm pulse, spender, aura removed).

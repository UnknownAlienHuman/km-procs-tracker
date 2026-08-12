# Agent guide: KMProcsTracker

## Start here

[`KMProcsTracker.toc`](KMProcsTracker.toc) loads vendored LibStub/CallbackHandler/LibDataBroker/LibDBIcon, then `Core.lua`, `Backend_CooldownViewer.lua`, `UI.lua`, `Minimap.lua`, and development/TestLab files. `Core.lua` creates `Addon`, `EventFrame`, `Addon:ADDON_LOADED`, and `Addon:PLAYER_LOGIN`; the event frame is the only production event-registration owner.

## Runtime map

- `Core.lua` owns defaults, `KMProcsTrackerDB`, session state, counter state, secret-safe helpers, aura index/scans, proc/spender inference, overlay hooks, action-slot scans, and event routing.
- `UNIT_AURA` on `player` is the authoritative local stack signal (`Addon:SyncStacksFromAura`/`GetKMStacksFromAuras`). `SPELL_ACTIVATION_OVERLAY_*` signals proc glow lifecycle; `UNIT_SPELLCAST_SUCCEEDED` identifies player spenders and is used as a race/order hint. The `COMBAT_LOG_EVENT_UNFILTERED` handler remains in `Core.lua:3100` for compatibility, but `EventFrame` deliberately does not register CLEU in this snapshot (`Core.lua:2621-2623`); it is not a runtime truth source on Midnight.
- `Backend_CooldownViewer.lua` locates and hooks the Cooldown Viewer icon, samples stacks/cooldown, and offers a second backend. `Addon:SetBackend` and `Addon:SetHybridAuraTruth` define the policy; aura truth remains authoritative in hybrid mode.
- `UI.lua` renders stacks/counters, tooltip, movement/scale/context menu, and `/kmpt`; `Minimap.lua` owns the LDB launcher. `DevTools/*` and `TestLab.lua` are diagnostic/test surfaces and must not become production event owners.
- `Core.lua:164-180` also defines the global helper functions `KMPT_IsSecret`, `KMPT_SafeToString`, and `KMPT_SafeStacks`; treat them as narrow in-process helpers, not a stable cross-addon API.

## State and dependencies

`KMProcsTrackerDB` stores backend/hybrid policy, CDM/glow tuning, minimap and frame layout/scale/visibility, DevTools filters, and the debug settings/ring buffer. `Addon.state` (including manual pause/stacks) and `Addon.counters` are runtime/session structures restored or reset by `Core.lua`; tracking state and counters are not persisted. CDM icon references, aura indexes, proc budgets, timers, and hooks are transient. `LibStub`, `CallbackHandler-1.0`, `LibDataBroker-1.1`, and `LibDBIcon-1.0` are vendored and TOC-marked optional; there are no required external addons.

## Change routing

- Change DB schema/defaults/counter reset: `Core.lua` (`ApplyDefaults`, `GetDB`, `ResetCounters`) and the DB migration branch in `Addon:ADDON_LOADED`.
- Change stack truth or aura classification: `Core.lua` aura functions around `UpdateAuraIndex`, `FindKillingMachineAura`, `SyncStacksFromAura`; preserve the `UNIT_AURA` contract.
- Change CDM integration: `Backend_CooldownViewer.lua` only; preserve optional/no-op behavior and delayed scans.
- Change proc/spender/overcap accounting: `Core.lua` functions `Glow_OnProcSignal`, `Glow_OnSpenderCast`, `QueueOvercapConfirm`, and `SyncStacksFromAura`; update TestLab scenarios with any taxonomy change.
- Change display/settings/commands/minimap: `UI.lua`/`Minimap.lua` and `Core.lua:396-580` for the command grammar; read through `Addon:GetDB` and call core policy methods rather than mutating counters.
- Change diagnostics: `DevTools/DevTools.lua`, `DevToolsUI.lua`, and `TestLab.lua`; these may observe or hook production state but must not register competing event handlers.

## Invariants/risks

- Stack accounting must not double-count when aura, SAO, CDM, cast, and optional CLEU signals arrive in different orders. Keep aura authoritative and use deferred `C_Timer.After(0)` confirmation where the source explicitly does so.
- Midnight restricted/secret values make direct arithmetic/comparison unsafe. Preserve `KMPT_IsSecret`, safe conversion, and fallback behavior; never make CLEU required.
- CDM scanning and icon `OnUpdate` sampling are hot paths. Keep scans bounded and delayed; stop CDM ticker and hooks when the backend is disabled.
- `UI.lua` uses an `OnUpdate` for resize/interaction and timers for transient wasted feedback; do not move counter work into a per-frame render loop.
- Killing Machine IDs, spender IDs, and overlays are data contracts in `Core.lua`; update all detector paths and tests together.

## Verification

Static checks:

```powershell
Get-Content _Addons/KMProcsTracker/KMProcsTracker.toc
rg -n "KMProcsTrackerDB|UNIT_AURA|SyncStacksFromAura|SetBackend|CDM_|SPELL_ACTIVATION_OVERLAY|SlashCmdList" _Addons/KMProcsTracker
```

In-game: `/kmpt help`, `/kmpt backend glow|cdm|aura`, `/kmpt minimap show|hide|toggle|reset`, `/kmpt devtools`, `/kmpt secret`, `/kmpt lab ...`, `/kmpt cltest` (expected disabled on Midnight), `/kmpt auradump [pattern]`, `/kmpt cdm dump`, and `/kmpt debug ...`; use the UI controls for tracking start/stop/reset/toggle. Test aura/CDM/hybrid policy, one/two/three-stack gain/loss, expiration, spender consumption, overcap, spec/reload, CDM unavailable, and restricted combat-log builds. Check counters against a controlled aura observation and inspect the debug ring for duplicate classifications.

## Unknowns

Current Cooldown Viewer widget structure and exact aura/overlay event ordering are build-sensitive. The code has fallbacks, but backend confidence and overcap classification must be verified on the target Retail build.

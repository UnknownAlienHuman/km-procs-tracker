# Agent guide: KM Procs Tracker

## Start here

Read:

1. [`KMProcsTracker.toc`](KMProcsTracker.toc)
2. [`Core.lua`](Core.lua)
3. [`UI.lua`](UI.lua)
4. [`Minimap.lua`](Minimap.lua)
5. [`ARCHITECTURE.md`](ARCHITECTURE.md)
6. [`tests/test_evidence_model_12_1.lua`](tests/test_evidence_model_12_1.lua)

Target contract:

- Retail / Midnight `12.1.0`;
- Interface `120100`;
- addon version `0.4.0`;
- verified Blizzard source baseline `12.1.0.69497`;
- required Blizzard dependency `Blizzard_AuraContainer`;
- no GitHub Actions workflow.

## Product contract

The name is retained for continuity, but this addon is not allowed to fabricate exact Killing Machine statistics.

Three evidence classes exist:

1. **exact** — accessible successful player casts of Obliterate and Frostscythe;
2. **managed display** — Blizzard-owned Killing Machine aura icon/count/duration;
3. **unavailable** — proc count, KM-attributed consumption, expiration, overcap/waste, and current stacks.

Do not replace `unavailable` with zero, a best guess, a hidden debug metric, or an inferred counter.

## Hard prohibitions

Never reintroduce any of these as a counting/state backend:

```text
UNIT_AURA
C_UnitAuras
UnitAura
AuraUtil.ForEachAura
COMBAT_LOG_EVENT_UNFILTERED
SpellActivationOverlayFrame child/visibility counts
ShowOverlay / HideOverlay inference
ActionButton_ShowOverlayGlow / HideOverlayGlow inference
Cooldown Viewer frame identity, recycle, text, cooldown, alpha or visibility
GetChildren / GetNumChildren scans
simulated Killing Machine stacks
timing-window consumption/expiration matching
attack-speed credit/token buckets
Pillar/Empowered Rune Weapon proc budgets
duration-based GCD/proc guessing
```

Presentation signals are not equivalent to one proc application. Multiple action buttons can glow for one proc, frames can be recycled, events can be restricted or skipped, and managed aura state is intentionally opaque.

## Core ownership

`Core.lua` is the only DB/event/counter owner.

- schema v4 migrates only frame and minimap preferences;
- old approximate counters are intentionally discarded;
- exact counters live in `db.exact`;
- `UNIT_SPELLCAST_SUCCEEDED` is registered for `player`;
- a cast counts only when its spell ID is accessible and equals `49020` or `207230`;
- disabling the addon stops counting and disables managed display;
- `ResetCounters` resets exact counters only.

The access decision must precede any type check, comparison, conversion, formatting, logging, or persistence of a game-returned value. `pcall` is error containment, not authorization.

## Managed AuraContainer ownership

`UI:CreateManagedAura` creates one `CustomAuraContainerTemplate` outside combat:

```text
unit = player
slot key = killing_machine
filter = HELPFUL
candidateFilters.includeSpellIDs = { [51124]=true, [51128]=true }
```

The `initializeFrame` callback configures:

- icon Texture through `SetIcon`;
- application-count FontString through `SetApplicationCount`;
- duration Cooldown through `SetDurationCooldown`;
- static addon glow art.

Do not retain or query the managed AuraButton after initialization. Do not branch on its visibility, alpha, count, cooldown, layout, scripts, focus, parent, or children. Blizzard owns all aura state.

The background placeholder is static neutral art. It must not change based on managed-button state.

## UI and combat

The addon frame owns position, scale, lock, exact counter text, tooltip, and context menu. Managed AuraContainer creation and point/size application defer while `InCombatLockdown()` is true and complete on `PLAYER_REGEN_ENABLED`.

Do not add `OnUpdate` resizing or polling. Scale is changed by slash/context controls.

Tooltip/minimap wording must remain explicit:

- Obliterate/Frostscythe/total are exact successful casts;
- they are not labelled `used` or `consumed`;
- proc/use/expired/overcap/stacks are unavailable.

## Persistent state

Allowed durable keys:

```text
version
enabled
frame.*
minimap.*
exact.spenderCasts
exact.obliterateCasts
exact.frostscytheCasts
migration.retiredApproximateCounters
```

Do not persist raw event payloads, aura data, managed objects, frame references, spellcast GUIDs, inaccessible values, or diagnostic histories.

## Commands

```text
/kmpt
/kmpt show
/kmpt hide
/kmpt toggle
/kmpt reset
/kmpt lock
/kmpt unlock
/kmpt scale 0.60..3.00
/kmpt minimap show|hide
/kmpt status
```

Do not restore backend, aura-dump, combat-log, TestLab, DevTools, or secret-probe commands.

## Verification

Local review:

```text
texlua --luaconly Core.lua UI.lua Minimap.lua tests/test_evidence_model_12_1.lua
texlua tests/test_evidence_model_12_1.lua
```

Expected regression result:

```text
PASS: managed KM display is not queried; only accessible player spender casts become exact counters
```

Static review should find no raw aura, combat-log, overlay, action-button-glow, Cooldown Viewer, child-frame, ticker, or `OnUpdate` state backend.

Live-client gates:

- migration from representative 0.3.x SavedVariables;
- managed KM icon, count and duration;
- exact Obliterate/Frostscythe casts;
- inaccessible event payload behavior;
- enable/disable/reset, frame position/scale/lock and minimap;
- combat-time initialization/application deferral;
- reload, specialization/talent changes and real combat;
- no Lua error, taint, blocked/forbidden action, secret-value error or meaningful CPU/allocation load.

Mock/static evidence does not prove live managed aura behavior. Record the exact build and context for all client results.

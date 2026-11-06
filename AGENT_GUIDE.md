# Agent guide: KM Procs Tracker

## Read first

1. `KMProcsTracker.toc`
2. `Core.lua`
3. `UI.lua`
4. `Minimap.lua`
5. `ARCHITECTURE.md`
6. `tests/test_evidence_model_12_1_5.lua`
7. `UnknownAlienHuman/wow-addon-engineering-kb`

## Target contract

- Retail / Midnight `12.1.5`
- Interface `120105`
- addon version `0.5.0`
- verified client/source baseline `12.1.5.70783`
- source snapshot `Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`
- required Blizzard dependency `Blizzard_AuraContainer`
- no GitHub Actions workflow

## Product contract

The addon has three evidence classes:

1. **Exact:** accessible successful player casts of Obliterate (`49020`) and Frostscythe (`207230`).
2. **Managed display:** Blizzard-owned Killing Machine aura icon, count, and duration.
3. **Unavailable:** proc count, KM-attributed consumption, expiration, overcap/waste, and current stacks.

Never replace `unavailable` with zero, a best guess, or a hidden inferred counter.

## Ownership

`Core.lua` is the only SavedVariables, event, command, and exact-counter owner.

`UI.lua` is the only tracker-frame and managed AuraContainer owner.

`Minimap.lua` is the only LDB/LibDBIcon owner.

Blizzard owns aura assignment, visibility, stack count, duration, refresh, and secrecy.

## Hard prohibitions

Do not reintroduce these as state or counting backends:

```text
UNIT_AURA
C_UnitAuras / UnitAura / AuraUtil.ForEachAura
COMBAT_LOG_EVENT_UNFILTERED
SpellActivationOverlay or action-button glow inference
Cooldown Viewer frame scanning or hooks
GetChildren / GetNumChildren scans
simulated Killing Machine stacks
spender/proc timing windows
attack-speed credit buckets
Pillar/ERW proc budgets
OnUpdate or ticker polling
manual AuraContainer:UpdateAllAuras calls
```

Presentation signals are not exact proc evidence. Managed aura state remains opaque.

## Access boundary

The access decision must precede type checks, comparisons, conversion, formatting, indexing, or persistence of game-returned values. `pcall` contains errors; it does not authorize secret-value access.

`UNIT_SPELLCAST_SUCCEEDED` counts only when:

- `unit == "player"` is accessible;
- `spellID` is accessible, finite, integral, and equals a supported spender ID;
- the addon is enabled.

## SavedVariables

Schema v4 stores only:

```text
version
 enabled
frame.point / relativePoint / x / y / scale / shown / locked
minimap.hide / minimapPos
exact.obliterateCasts
exact.frostscytheCasts
exact.spenderCasts
migration.retiredApproximateCounters
```

`exact.spenderCasts` is derived from the two spell counters during sanitization and updates. Do not trust or mutate it independently.

Legacy approximate counters and backend state are intentionally discarded. Preserve only bounded frame/minimap preferences and `enabled`.

## Managed AuraContainer

`UI:CreateManagedAura` creates one `CustomAuraContainerTemplate` outside combat:

```text
unit = player
slot = killing_machine
filter = HELPFUL
candidateFilters.includeSpellIDs = { [51124]=true, [51128]=true }
```

The initialization callback configures only native sinks:

- `SetIcon`
- `SetApplicationCount`
- `SetDurationCooldown`
- static addon glow art

Do not retain or inspect the managed AuraButton after initialization.

Initialization is a one-shot state machine: `uninitialized -> pending|ready|failed`. A contract failure is retained as `failed` until `/reload`; repeated UI application must not allocate more containers.

Do not manually refresh the container. `SetUnit`, `AddAuraSlot`, `SetEnabled`, and Blizzard events own its lifecycle.

## Combat and UI

AuraContainer creation, managed enable-state changes, and tracker layout changes defer during `InCombatLockdown()` and flush on `PLAYER_REGEN_ENABLED`.

The addon frame may update exact cast text during combat because it does not inspect or mutate protected aura state.

## Commands

```text
/kmpt
/kmpt show|hide
/kmpt toggle
/kmpt reset
/kmpt lock|unlock
/kmpt scale 0.60..3.00
/kmpt minimap show|hide
/kmpt status
```

## Verification

```text
texlua --luaconly Core.lua
texlua --luaconly UI.lua
texlua --luaconly Minimap.lua
texlua --luaconly tests/test_evidence_model_12_1_5.lua
texlua tests/test_evidence_model_12_1_5.lua
```

Expected result:

```text
PASS: Retail 12.1.5 managed display stays opaque; only accessible player spender casts become exact counters
```

Static review must find no raw aura, combat-log, overlay, Cooldown Viewer, child-frame scan, polling, or manual `UpdateAllAuras` path.

Live-client gates remain mandatory for the named build: managed KM visuals, both candidate spell IDs, enable/disable, combat deferral, reload/migration, drag/scale/minimap, taint, Lua errors, and CPU/allocation behavior.

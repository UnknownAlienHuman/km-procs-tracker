# KM Procs Tracker architecture

## Target

Retail `12.1.5`, Interface `120105`, build/source baseline `12.1.5.70783` (`Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`).

## Ownership

`Core.lua` owns schema migration, sanitization, the secret-value access boundary, exact successful-cast counters, commands, and event routing.

`UI.lua` owns the addon frame, one Blizzard `CustomAuraContainer`, position/scale/lock state, tooltip/menu, and combat-deferred application.

`Minimap.lua` owns the LibDataBroker/LibDBIcon launcher.

Blizzard owns every Killing Machine aura fact: assignment, visibility, count, duration, refresh, and secret state.

## Load graph

```text
KMProcsTracker.toc
  -> bundled LibStub / CallbackHandler / LibDataBroker / LibDBIcon
  -> Core.lua
  -> UI.lua
  -> Minimap.lua
```

`Blizzard_AuraContainer` is required.

## Evidence model

### Exact

An accessible `UNIT_SPELLCAST_SUCCEEDED` event for `player` whose integral spell ID is Obliterate (`49020`) or Frostscythe (`207230`). The claim is only “successful player cast,” never “Killing Machine consumed.”

### Blizzard-managed display

One `CustomAuraContainerTemplate` slot filters player `HELPFUL` auras to `51124` and `51128`. The initialization callback binds icon, application-count, and duration-cooldown sinks. Addon code never reads the managed button afterward.

### Unavailable

Proc generation, KM-attributed use, expiration, overcap/waste, and current stacks. They are not inferred or represented as numeric zero.

## Persistent schema

Schema v4 stores bounded UI preferences, minimap state, enabled state, exact Obliterate/Frostscythe counts, their derived total, and the legacy-retirement marker.

Sanitization repairs invalid frame anchors, rejects inaccessible/non-finite values, clamps coordinates/scale/minimap angle, and recomputes the aggregate exact counter.

Legacy heuristic counters and backend state are discarded rather than relabelled as exact data.

## Managed lifecycle

```text
uninitialized
  -> pending   (combat lockdown)
  -> ready     (one container + one slot)
  -> failed    (contract unavailable; fail closed until reload)
```

A failed `AddAuraSlot` attempt retains its container reference and state so repeated enable/layout calls cannot leak frames. Disabling a pending display cancels its deferred creation.

The addon never calls `AuraContainer:UpdateAllAuras`; Blizzard event handling owns refresh.

## Combat boundary

Creation, managed enable-state changes, and layout mutation defer while `InCombatLockdown()` is true. `PLAYER_REGEN_ENABLED` flushes the coalesced pending state. Exact text updates remain addon-owned and do not touch protected aura state.

## Runtime cost

- one player `UNIT_SPELLCAST_SUCCEEDED` registration;
- one managed aura slot;
- no `OnUpdate`;
- no ticker;
- no raw aura or combat-log event;
- no frame-tree/action-bar scan;
- no manual refresh loop.

## Evidence limit

The deterministic harness proves migration, access rejection, event ownership, exact counting, combat deferral, native managed sinks, enable/disable behavior, aggregate reconciliation, and fail-closed initialization. It does not prove live client visuals, spell-ID matching, taint, or profiler results; those require the named Retail build.

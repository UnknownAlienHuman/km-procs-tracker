# KM Procs Tracker architecture

## Target

Retail `12.1.5`, Interface `120105`, inspected source baseline `12.1.5.70783` (`Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`). Client validation is **NOT-RUN**.

## Ownership

`Core.lua` owns schema migration, sanitization, the secret-value access boundary, exact successful-cast counters, shared icon lookup, commands, and event routing.

`UI.lua` owns the addon frame, one Blizzard `CustomAuraContainer`, position/scale/lock state, tooltip/menu, and combat-deferred application.

`Minimap.lua` owns the LibDataBroker/LibDBIcon launcher. An LDB launcher can exist without DBIcon; absent libraries do not affect the tracker or slash commands.

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

One `CustomAuraContainerTemplate` slot filters player `HELPFUL` auras to the proc aura `51124`, not passive talent `51128`. The initialization callback binds icon, application-count, and duration-cooldown sinks. Addon code never reads the managed button afterward.

### Unavailable

Proc generation, KM-attributed use, expiration, overcap/waste, and current stacks. They are not inferred or represented as numeric zero.

## Persistent schema

Schema v4 stores bounded UI preferences, minimap state, enabled state, exact Obliterate/Frostscythe counts, their derived total, and the legacy-retirement marker.

Sanitization repairs invalid frame anchors, rejects inaccessible/non-finite values, clamps coordinates/scale/minimap angle, and recomputes the aggregate exact counter.

Legacy heuristic counters and backend state are discarded rather than relabelled as exact data. A fresh install does not set the legacy-retirement marker.

## Managed lifecycle

```text
uninitialized
  -> pending   (combat lockdown)
  -> ready     (one container + one slot)
  -> failed    (contract unavailable; fail closed until reload)
```

A failed `AddAuraSlot` attempt retains its container reference and state so repeated enable/layout calls cannot leak frames. Disabling a pending display cancels its deferred creation.

The addon never calls `AuraContainer:UpdateAllAuras`; Blizzard event handling owns refresh.

## Combat and layout boundary

Tracker/managed creation, managed enable-state changes, and layout mutation defer while `InCombatLockdown()` is true. `PLAYER_REGEN_ENABLED` flushes the coalesced pending state. A drag ending in combat defers both `StopMovingOrSizing` and position capture; the applied scale, not a pending setting, determines its saved offsets.

The ordinary root scales its entire hierarchy. Stored offsets are in UIParent units and are divided by scale when applied. Exact cast text belongs to an ordinary sibling of the managed container at a higher frame level. It has no anchor to a managed object and never inspects adopted children. Exact text updates remain allowed during combat.

## Runtime cost

- one player `UNIT_SPELLCAST_SUCCEEDED` registration while enabled, removed while disabled;
- bootstrap event registrations removed after use;
- one managed aura slot;
- no per-cast snapshot allocation or unchanged counter-text writes;
- no `OnUpdate` or ticker;
- no raw aura or combat-log event;
- no frame-tree/action-bar scan;
- no manual refresh loop.

## Evidence limit

The deterministic harness loads all three runtime modules. It checks migration, access rejection, event ownership, exact counting, combat/drag deferral, scale-independent settings, native managed sinks, enable/disable behavior, aggregate reconciliation, fail-closed initialization, and the LDB/DBIcon consumer contract. Managed child methods deliberately fail after adoption in the harness.

This is not a WoW VM, renderer, or bundled-library integration test. Live visuals, spell-ID matching, taint, library behavior, and profiler results require the named Retail build.

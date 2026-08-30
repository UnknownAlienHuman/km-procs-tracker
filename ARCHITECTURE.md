# KM Procs Tracker architecture

## Ownership

`Core.lua` owns:

- schema/version migration and sanitization;
- the accessibility-before-use boundary;
- exact successful player-cast counters;
- slash commands and lifecycle events;
- the explicit list of unavailable Killing Machine metrics.

`UI.lua` owns:

- the addon frame and neutral placeholder;
- one Blizzard `CustomAuraContainer` / `AddAuraSlot` display;
- position, scale, lock, tooltip, context menu, and combat-deferred UI application;
- the small exact spender-cast total rendered on the frame.

`Minimap.lua` owns the LDB/LibDBIcon launcher and displays the same exact/unavailable evidence model.

Blizzard owns Killing Machine aura parsing, assignment, visibility, application count, duration, secrecy, refresh, and managed button state.

## Load order

```text
KMProcsTracker.toc
  -> bundled LibStub / CallbackHandler / LibDataBroker / LibDBIcon
  -> Core.lua
  -> UI.lua
  -> Minimap.lua
```

`Blizzard_AuraContainer` is a required Blizzard dependency. The 0.3.x Cooldown Viewer backend, DevTools, TestLab, and overlay/aura inference code are removed from the load graph and repository branch.

## Persistent schema

Schema version 4 stores:

```text
enabled
frame.point / relativePoint / x / y / scale / shown / locked
minimap.hide / minimapPos
exact.spenderCasts
exact.obliterateCasts
exact.frostscytheCasts
migration.retiredApproximateCounters
```

Legacy frame and minimap preferences are migrated. Legacy `procs`, `used`, `consumed`, `expired`, `wasted`, `overcap`, backend state, simulated stacks, timing windows, CDM state, glow state, and TestLab/DevTools values are not imported into exact counters. `retiredApproximateCounters=true` records that the old model was discarded.

## Evidence classes

### Exact

An accessible `UNIT_SPELLCAST_SUCCEEDED` event registered for `player`, where the accessible spell ID equals Obliterate or Frostscythe.

The exact claim is only:

```text
successful player cast of this spender spell
```

It does not prove that Killing Machine was active or consumed.

### Blizzard-managed display

One managed aura slot for player HELPFUL auras with spell IDs `51124` and `51128`. The addon configures icon, count, duration-cooldown, and static glow sinks during managed-button initialization and never retains or queries the button afterward.

### Unavailable

Proc generation, KM-attributed use, expiration, overcap/waste, and current stacks. These values are not represented by numeric zero and are not reconstructed from related presentation or timing signals.

## Removed inference paths

The runtime no longer uses:

- `UNIT_AURA`, raw aura reads, aura instance IDs, or AuraData caches;
- combat-log aura event ordering;
- SpellActivationOverlay child count, visibility, ShowOverlay/HideOverlay, or action-button glow hooks;
- Cooldown Viewer frame identity, icon recycling, text, cooldown pulses, visibility, or disappearance;
- attack-speed token buckets and local Pillar/ERW proc budgets;
- simulated stacks, loss/spend windows, refresh-at-cap logic, or duration heuristics.

Those signals are not equivalent to one exact Killing Machine application and cannot support the former exact-looking counters.

## Access and combat boundary

`Core.lua` calls `canaccessvalue` or `issecretvalue` before treating event/API values as ordinary Lua scalars. Raw inaccessible spell IDs are never compared, converted, formatted, logged, or stored.

Managed AuraContainer creation and frame point/size application are deferred when combat is active. `PLAYER_REGEN_ENABLED` completes pending initialization/application. The addon-owned frame may receive exact counter text updates during combat; this does not inspect or mutate Blizzard secure state.

## Performance

- no `OnUpdate`;
- no aura event;
- no combat-log event;
- no ticker or polling loop;
- no frame-tree or action-bar scan;
- one managed container handles Blizzard aura updates;
- one player unit spellcast event handles exact counters.

## Evidence boundary

The local mock regression checks the architecture contract but does not prove live managed AuraContainer behavior, candidate-filter spell IDs, protected-context object access, or visual/taint behavior. The PR remains draft until named-build client evidence exists.

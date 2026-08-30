# KM Procs Tracker

Retail 12.1 evidence-safe Killing Machine display for Frost Death Knights.

The addon keeps the original project name, but it no longer claims exact Killing Machine proc, consumption, expiration, stack, or overcap counts. Retail 12.1 does not expose those values as a reliable general-purpose addon data source. Instead, it combines:

- a Blizzard-managed Killing Machine aura display;
- exact successful player casts of Obliterate and Frostscythe;
- explicit `unavailable` labels for metrics that cannot be proven.

## Compatibility

- Game: World of Warcraft Retail / Midnight 12.1.0
- Interface: `120100`
- Version: `0.4.0`
- Verified Blizzard source baseline: `12.1.0.69497`
- SavedVariables: `KMProcsTrackerDB`
- Required Blizzard addon: `Blizzard_AuraContainer`
- Bundled libraries: LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0

## What is exact

`UNIT_SPELLCAST_SUCCEEDED` is registered for `player`. When its spell ID is accessible and equals:

- `49020` — Obliterate;
- `207230` — Frostscythe;

the corresponding cast counter increments. These are exact successful player-cast counts since the last reset. They are **not** labelled as Killing Machine consumption because the addon cannot legally correlate the cast with hidden managed aura state.

## Managed Killing Machine display

The tracker creates one `CustomAuraContainerTemplate` for `player` and one `AddAuraSlot` with `HELPFUL` filtering and `includeSpellIDs` for `51124` and `51128`.

The managed AuraButton receives Blizzard-supported display sinks:

- icon;
- application count;
- duration cooldown;
- static addon glow art.

The addon does not retain or query the managed button. Blizzard owns assignment, visibility, stacks, duration, refresh, secrecy, and private state. A dim static icon behind the managed button is only a neutral placeholder; it is not an inactive/active-state inference.

## Metrics intentionally unavailable

The UI and minimap tooltip explicitly mark these as unavailable rather than displaying guessed numbers:

- Killing Machine proc count;
- casts that actually consumed Killing Machine;
- expiration count;
- overcap/wasted count;
- current stack count.

The removed 0.3.x implementation attempted to derive those values from raw aura scans, combat-log ordering, SpellActivationOverlay frame counts, action-button glows, Cooldown Viewer recycling, timing windows, attack-speed credit and locally simulated stacks. Those paths could disagree, freeze, double-count, or expose restricted state. Legacy approximate counters are not migrated into the new exact counters.

## Commands

- `/kmpt` — show or hide the tracker;
- `/kmpt show` / `/kmpt hide`;
- `/kmpt toggle` — enable or disable managed display and counting;
- `/kmpt reset` — reset exact cast counters;
- `/kmpt lock` / `/kmpt unlock`;
- `/kmpt scale 0.60..3.00`;
- `/kmpt minimap show|hide`;
- `/kmpt status` — print exact cast counts and unavailable metric status.

Right-click the tracker for enable/disable, reset, lock, scale, and hide controls. Right-click the minimap icon resets exact counters.

## Combat and data safety

- no `UNIT_AURA`;
- no `C_UnitAuras`, `UnitAura`, raw AuraData, combat-log, action-button-glow, SpellActivationOverlay, Cooldown Viewer, child-frame, or visibility scans;
- inaccessible event values are rejected before comparison or conversion;
- managed AuraContainer initialization is deferred when combat is active;
- position/scale application is deferred to `PLAYER_REGEN_ENABLED`;
- no GitHub Actions workflow is added.

## Validation status

`tests/test_evidence_model_12_1.lua` is a local deterministic regression for:

- legacy approximate counters not entering exact data;
- combat-deferred AuraContainer creation;
- managed spell-ID candidate filters and display sinks;
- absence of `UNIT_AURA` and combat-log registration;
- exact accessible Obliterate/Frostscythe counting;
- inaccessible spell ID rejection;
- disabled-state and reset behavior.

The test is part of the repository but is not a substitute for live Retail validation. The current client still requires verification of the managed AuraContainer, aura visuals, casts, frame placement/scale, minimap behavior, reload migration, taint, errors, and CPU/allocation behavior.

## Developer documentation

- [Architecture](ARCHITECTURE.md)
- [Agent guide](AGENT_GUIDE.md)
- [Code index](CODE_INDEX.md)
- [Code graph](CODE_GRAPH.md)
- [WoW addon engineering knowledge base](https://github.com/UnknownAlienHuman/wow-addon-engineering-kb)

## License

Licensed under the [MIT License](LICENSE). Bundled third-party libraries retain their own notices.

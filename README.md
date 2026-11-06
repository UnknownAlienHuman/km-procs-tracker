# KM Procs Tracker

Evidence-safe Killing Machine display for Frost Death Knights on World of Warcraft Retail 12.1.5.

The addon combines:

- a Blizzard-managed Killing Machine aura display;
- exact successful player casts of Obliterate and Frostscythe;
- explicit `unavailable` labels for metrics the addon cannot prove.

## Compatibility

- Retail / Midnight `12.1.5`
- Interface `120105`
- addon version `0.5.1`
- inspected source baseline `12.1.5.70783`; live-client validation **NOT-RUN**
- source snapshot `Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`
- required Blizzard addon `Blizzard_AuraContainer`
- SavedVariables `KMProcsTrackerDB`

## Exact data

The addon counts accessible successful `player` casts of:

- Obliterate (`49020`)
- Frostscythe (`207230`)

These counters do **not** claim that Killing Machine was active or consumed.

## Managed aura display

One `CustomAuraContainerTemplate` slot filters player `HELPFUL` auras to the Killing Machine proc aura `51124`. Passive talent `51128` is not an alternate proc aura. Blizzard owns visibility, stack count, duration, refresh, and restricted state. The addon only supplies native icon, application-count, and duration-cooldown display sinks.

The managed button is never queried after initialization, and the addon does not manually call `UpdateAllAuras`.

## Intentionally unavailable

The addon does not fabricate numeric values for:

- Killing Machine proc count;
- KM-attributed consumption;
- expiration count;
- overcap/waste count;
- current stack count.

The removed 0.3.x model inferred these from aura scans, overlays, action-button glows, Cooldown Viewer frames, combat-log ordering, and timing windows. Those signals could freeze, double-count, or expose restricted state, so legacy approximate counters are not migrated into exact data.

## Controls

- `/kmpt` — show/hide the frame
- `/kmpt show|hide`
- `/kmpt toggle` — enable/disable display and counting
- `/kmpt reset` — reset exact cast counters
- `/kmpt lock|unlock`
- `/kmpt scale 0.60..3.00`
- `/kmpt minimap show|hide`
- `/kmpt status`

Right-click the tracker for enable/disable, reset, lock, scale, and hide controls. Left-click the minimap icon toggles the frame; right-click resets exact counters. Scaling applies to the icon, glow, cooldown, and text together; saved offsets remain independent of scale.

## Safety and performance

- inaccessible event values and unknown access decisions are rejected before comparison or conversion;
- invalid SavedVariables anchors and numeric values are repaired or clamped;
- exact aggregate counts are recomputed from per-spell counters;
- tracker creation, managed enable-state changes, and drag completion defer during combat;
- managed initialization fails closed without repeated frame allocation;
- disabled addons unsubscribe from cast events; bootstrap events unregister after initialization;
- exact cast text uses an independent addon-owned layer, skips unchanged writes, and does not allocate a snapshot per cast;
- no raw aura API, combat log, overlay, action-bar, Cooldown Viewer, frame-tree scan, ticker, `OnUpdate`, or manual managed refresh path.

## Validation

```text
texlua --luaconly Core.lua
texlua --luaconly UI.lua
texlua --luaconly Minimap.lua
texlua --luaconly tests/test_evidence_model_12_1_5.lua
texlua tests/test_evidence_model_12_1_5.lua
```

The regression loads all three runtime modules against a mocked WoW API. It checks migration, exact counts, access rejection, post-adoption object isolation, scale/drag deferral, coalesced changes, initialization failures, and the LDB/DBIcon consumer contract. Successful output begins:

```text
PASS: Retail 12.1.5 managed display stays opaque; only accessible player spender casts become exact counters
```

The offline regression does not replace live Retail validation of visuals, spell-ID matching, combat behavior, bundled-library behavior, taint, errors, and profiler results. No runtime performance or compatibility pass is claimed by the source-build metadata.

## Developer documentation

- [Architecture](ARCHITECTURE.md)
- [Agent guide](AGENT_GUIDE.md)
- [Code index](CODE_INDEX.md)
- [Code graph](CODE_GRAPH.md)
- [WoW addon engineering knowledge base](https://github.com/UnknownAlienHuman/wow-addon-engineering-kb)

## License

Licensed under the [MIT License](LICENSE). Bundled third-party libraries retain their own notices.

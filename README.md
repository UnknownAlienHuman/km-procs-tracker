# KM Procs Tracker

Evidence-safe Killing Machine display for Frost Death Knights on World of Warcraft Retail 12.1.5.

The addon combines:

- a Blizzard-managed Killing Machine aura display;
- exact successful player casts of Obliterate and Frostscythe;
- explicit `unavailable` labels for metrics the addon cannot prove.

## Compatibility

- Retail / Midnight `12.1.5`
- Interface `120105`
- addon version `0.5.0`
- verified build/source baseline `12.1.5.70783`
- source snapshot `Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`
- required Blizzard addon `Blizzard_AuraContainer`
- SavedVariables `KMProcsTrackerDB`

## Exact data

The addon counts accessible successful `player` casts of:

- Obliterate (`49020`)
- Frostscythe (`207230`)

These counters do **not** claim that Killing Machine was active or consumed.

## Managed aura display

One `CustomAuraContainerTemplate` slot filters player `HELPFUL` auras to Killing Machine candidates `51124` and `51128`. Blizzard owns visibility, stack count, duration, refresh, and restricted state. The addon only supplies native icon, application-count, and duration-cooldown display sinks.

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

Right-click the tracker for enable/disable, reset, lock, scale, and hide controls. Left-click the minimap icon toggles the frame; right-click resets exact counters.

## Safety and performance

- inaccessible event values are rejected before comparison or conversion;
- invalid SavedVariables anchors and numeric values are repaired or clamped;
- exact aggregate counts are recomputed from per-spell counters;
- managed creation and enable-state changes defer during combat and fail closed without repeated frame allocation;
- no raw aura API, combat log, overlay, action-bar, Cooldown Viewer, frame-tree scan, ticker, `OnUpdate`, or manual managed refresh path.

## Validation

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

The offline regression does not replace live Retail validation of visuals, candidate spell IDs, combat behavior, taint, errors, and profiler results.

## Developer documentation

- [Architecture](ARCHITECTURE.md)
- [Agent guide](AGENT_GUIDE.md)
- [Code index](CODE_INDEX.md)
- [Code graph](CODE_GRAPH.md)
- [WoW addon engineering knowledge base](https://github.com/UnknownAlienHuman/wow-addon-engineering-kb)

## License

Licensed under the [MIT License](LICENSE). Bundled third-party libraries retain their own notices.

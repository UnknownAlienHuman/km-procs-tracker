# KM Procs Tracker

Adaptive Killing Machine tracker for Frost Death Knights on World of Warcraft Retail 12.1.5.

## What it does

The addon always renders Killing Machine through one Blizzard-managed `CustomAuraContainer` slot for aura `51124`.

It then selects one observation mode at runtime:

- **readable public-aura observation** — when `C_Secrets.ShouldSpellAuraBeSecret(51124)` is accessible and false, the addon re-queries only `C_UnitAuras.GetPlayerAuraBySpellID(51124)` on player `UNIT_AURA` wake-ups;
- **managed display only** — when the aura is secret, inaccessible, or the required public API is unavailable. No heuristic fallback is used.

The mode and public maximum are refreshed automatically across world, combat, talent, and specialization transitions. Moving from a restricted interval back to readable data creates a fresh baseline, so an existing aura is not fabricated as a new proc.

## Counters

When exact observation is active:

- **Observed KM applications** = readable stack gains + readable expiration refreshes while already at the public maximum stack count;
- **Stack gains** = positive changes in the readable application count;
- **Refreshes while capped** = same-stack updates at cap with a later absolute expiration time;
- **Stack losses** = negative changes in readable applications, without claiming why they disappeared.

`Observed KM applications` is deliberately a lower bound. If multiple cap refreshes are coalesced into one `UNIT_AURA` wake-up, the addon records one observed refresh. Restricted intervals are not reconstructed later.

The addon also keeps exact successful player-cast counters for:

- Obliterate (`49020`);
- Frostscythe (`207230`).

A cast is not automatically labelled as Killing Machine consumption. Loss cause (`consumed`, `expired`, `dispelled`) remains unavailable because the public aura state alone does not prove causality or event ordering.

## Compatibility

- Retail / Midnight `12.1.5`
- Interface `120105`
- addon version `0.6.0`
- inspected Blizzard source baseline `12.1.5.70783`
- source snapshot `Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`
- required Blizzard addon `Blizzard_AuraContainer`
- SavedVariables `KMProcsTrackerDB`, schema 5

The source baseline is not a live-client PASS. `/kmpt status` prints the actual client build, Interface, current observation mode, reason, and counters.

## Controls

- `/kmpt` — show/hide;
- `/kmpt show|hide`;
- `/kmpt toggle` — enable/disable display and event ownership;
- `/kmpt reset` — reset observed applications, losses, and cast counters, then re-baseline the current aura;
- `/kmpt lock|unlock`;
- `/kmpt scale 0.60..3.00`;
- `/kmpt minimap show|hide`;
- `/kmpt status`.

Right-click the tracker for controls. Left-click the minimap icon toggles the tracker; right-click resets all counters.

## Safety and performance

- the secrecy predicate is evaluated before the raw aura getter;
- the getter is never called while the predicate says the aura is secret;
- the `UNIT_AURA` payload is ignored and used only as a wake-up;
- every consumed scalar/table/field is access-gated before comparison or arithmetic;
- a restriction/error clears the baseline and pauses observation instead of guessing;
- managed display creation and layout changes defer during combat;
- no combat log, action-button glow, overlay, Cooldown Viewer, child-frame scan, ticker, or tracker `OnUpdate`;
- disabled mode unregisters both `UNIT_AURA` and `UNIT_SPELLCAST_SUCCEEDED`;
- future-schema SavedVariables remain untouched on downgrade.

Vendored LibDBIcon uses `OnUpdate` only during minimap dragging and clears it on drag stop.

## Validation

```text
texluac -p Core.lua UI.lua Minimap.lua \
  tests/test_observation_12_1_5.lua \
  tests/test_bundled_libraries.lua
texlua tests/test_observation_12_1_5.lua
texlua tests/test_bundled_libraries.lua
texlua tests/test_bundled_libraries.lua library-first
python3 tests/run_mutation_probes.py
```

The main regression covers migration, access gating, readable/restricted transitions, stack gains, cap refreshes, losses, coalescing, combat deferral, managed initialization, future-schema preservation, minimap routing, and diagnostics against a mocked WoW API.

The bundled-library test loads the vendored LibStub, CallbackHandler, LibDataBroker, and LibDBIcon with mocked frames and tests both `PLAYER_LOGIN` orders.

Live Retail validation is still required for real KM payloads, native rendering, taint, errors, and profiler results.

## Developer documentation

- [Architecture](ARCHITECTURE.md)
- [Agent guide](AGENT_GUIDE.md)
- [Code index](CODE_INDEX.md)
- [Code graph](CODE_GRAPH.md)
- [WoW addon engineering knowledge base](https://github.com/UnknownAlienHuman/wow-addon-engineering-kb)

## License

Licensed under the [MIT License](LICENSE). Bundled third-party libraries retain their own notices.

# Agent guide: KM Procs Tracker

## Read first

1. `KMProcsTracker.toc`
2. `Core.lua`
3. `UI.lua`
4. `Minimap.lua`
5. `ARCHITECTURE.md`
6. `tests/test_observation_12_1_5.lua`
7. `tests/test_bundled_libraries.lua`
8. `UnknownAlienHuman/wow-addon-engineering-kb`: security, spell secrecy, auras, events, persistence, performance

## Target

- Retail / Midnight `12.1.5`
- Interface `120105`
- addon `0.6.0`, DB schema 5
- inspected source `12.1.5.70783` / `297d7aaaa736f346b3e036f38ee088eaf7f8c07f`
- client matrix **NOT-RUN**
- required Blizzard dependency `Blizzard_AuraContainer`
- no GitHub Actions workflow

## Product contract

1. Always provide a Blizzard-managed Killing Machine display for buff aura `51124`.
2. When the current public predicate confirms that `51124` is non-secret, observe its exact readable application transitions.
3. When it is restricted/inaccessible/unsupported, pause raw observation and retain managed display only.
4. Keep successful Obliterate/Frostscythe casts as separate exact evidence.
5. Never label a stack loss as consumed/expired without a source that proves causality.

## Required access order

```text
ShouldSpellAuraBeSecret(51124)
  -> gate returned bool
  -> only false permits GetPlayerAuraBySpellID(51124)
  -> gate returned value/table
  -> gate each consumed field
  -> normalize to ordinary scalars
  -> compare/persist/render
```

`UNIT_AURA` is a wake-up. Ignore its update payload. A failed `pcall` maps to unavailable and clears the baseline; it is not a capability probe or retry signal.

## Observation rules

- count positive application deltas as stack gains;
- count negative deltas as cause-independent stack losses;
- count a same-stack refresh only at the accessible public maximum and only when absolute expiration increases;
- derive `observed.procs = stackGains + capRefreshes`;
- describe it as observed/lower-bound data;
- re-baseline after any restricted/unsupported/unavailable interval, world entry, reset, or ambiguous live instance replacement;
- never bridge a hidden interval by subtraction.

## Managed display rules

One `CustomAuraContainerTemplate` slot:

```text
unit = player
slot = killing_machine
filter = HELPFUL
candidateFilters.includeSpellIDs = { [51124] = true }
```

`51128` is the passive/talent spell, not the displayed proc aura.

During `initializeFrame` configure only:

- `SetIcon`;
- `SetApplicationCount`;
- `SetDurationCooldown`;
- static glow art.

Do not retain/read/reparent/repool the managed AuraButton or descendants after adoption. Do not call `UpdateAllAuras` manually.

## Prohibited backends

```text
COMBAT_LOG_EVENT_UNFILTERED
SpellActivationOverlay/action-button glow inference
Cooldown Viewer or child-frame scans
GetChildren/GetNumChildren visibility inference
simulated stacks or proc budgets
spender timing attribution
attack-speed token buckets
polling, ticker, tracker OnUpdate
managed geometry/readback
```

## Persistence

Schema 5 aggregates are derived, never trusted independently. Migrate schema 4 exact cast counters; discard pre-v4 heuristic metrics. Preserve future-schema roots untouched.

## Verification

```text
texluac -p Core.lua UI.lua Minimap.lua \
  tests/test_observation_12_1_5.lua \
  tests/test_bundled_libraries.lua
texlua tests/test_observation_12_1_5.lua
texlua tests/test_bundled_libraries.lua
texlua tests/test_bundled_libraries.lua library-first
python3 tests/run_mutation_probes.py
```

Static review must find no combat-log, overlay, Cooldown Viewer, frame-scan, polling, or manual managed-refresh path in addon-owned runtime files.

Live gates: `/kmpt status`, readable and restricted contexts, 0→1→2 stack transitions, cap refresh, stack loss, combat/world transitions, reload/migration, drag/scale/minimap, taint/errors, and profiler results.

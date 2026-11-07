# KM Procs Tracker architecture

## Target

Retail `12.1.5`, Interface `120105`, addon `0.6.0`, inspected Blizzard source `12.1.5.70783` at `Gethe/wow-ui-source@297d7aaaa736f346b3e036f38ee088eaf7f8c07f`. Live-client matrix: **NOT-RUN**.

## Ownership

- `Core.lua`: SavedVariables schema/migration, access gates, runtime mode selection, exact normalized aura observations, successful-cast counters, commands, and event routing.
- `UI.lua`: addon root, one managed AuraContainer slot, ordinary counter layer, movement/scale/menu/tooltip, and combat-deferred UI mutations.
- `Minimap.lua`: LDB/LibDBIcon launcher.
- Blizzard: aura acquisition, filtering, managed assignment, current applications, duration, secrecy, and native refresh.

No addon code retains or reads the adopted AuraButton after initialization.

## Observation pipeline

```text
UNIT_AURA(player) / world, combat, talent or specialization transition
  -> discard payload
  -> ShouldSpellAuraBeSecret(51124)
       true/inaccessible/error -> managed-only mode + clear baseline
       false
         -> GetPlayerAuraBySpellID(51124)
         -> gate table and consumed fields
         -> normalize ordinary sample
         -> baseline or compare with previous ordinary sample
```

The raw getter is a narrow public adapter, not a generic aura scanner. It is never called when the current predicate says the aura is secret.

## Normalized sample

Only ordinary values survive the adapter:

```text
present
applications (0 normalized to one for a present aura)
expirationTime?
auraInstanceID?
maxStacks?  <- C_Spell.GetSpellMaxCumulativeAuraApplications(51124)
```

No AuraData table, event payload, duration object, secret value, or managed child is retained.

## Counter semantics

```text
stackGains     += max(0, newApplications - oldApplications)
stackLosses    += max(0, oldApplications - newApplications)
capRefreshes   += 1 when:
                  same applications
                  + applications >= public maxStacks
                  + later absolute expirationTime
observedProcs   = stackGains + capRefreshes
```

`observedProcs` is a readable lower bound, not reconstructed ground truth across restricted intervals. Multiple cap refreshes coalesced into one update remain one observed refresh.

A replacement `auraInstanceID` while both samples are present is ambiguous; it re-baselines without manufacturing a gain or loss.

Loss causality is intentionally separate. Obliterate/Frostscythe casts are exact successful casts, but they do not prove which readable loss they caused, especially across event ordering, refreshes, or multi-stack consumption mechanics.

## Mode state

```text
uninitialized
  -> exact       public predicate false and sample normalized
  -> restricted  predicate true
  -> unsupported required public symbol absent
  -> unavailable predicate/query/value inaccessible or failed
  -> disabled    addon disabled
```

Every transition into `exact` starts with a baseline. Every transition out clears the baseline. This prevents a hidden interval from being bridged by subtraction.

## Persistence

Schema 5 stores:

```text
version / enabled
frame.* / minimap.*
observed.stackGains / capRefreshes / stackLosses / derived procs
exact.obliterateCasts / frostscytheCasts / derived spenderCasts
migration.retiredApproximateCounters
```

Migration from schema 4 preserves UI/minimap preferences and exact cast counters. Older heuristic counters are discarded. A newer schema is never rewritten; the session uses detached defaults.

## Managed display lifecycle

```text
uninitialized -> pending (combat) -> ready
                             \-> failed (one attempt, fail closed until reload)
```

`initializeFrame` configures only icon, application-count, cooldown, and static glow descendants. Because Blizzard invokes it through `securecallfunction`, the addon records explicit callback completion instead of trusting `AddAuraSlot` alone.

## Runtime cost

- one player `UNIT_AURA` wake-up registration while enabled;
- one player `UNIT_SPELLCAST_SUCCEEDED` registration while enabled;
- one exact spell-specific re-query per wake-up while the predicate permits it;
- one managed aura slot;
- no polling/ticker/tracker `OnUpdate`;
- no raw combat log or frame scanning;
- counter text writes only when mode/value changes.

## Evidence limit

Offline tests prove deterministic addon logic against mocks. They do not prove the live value of `ShouldSpellAuraBeSecret(51124)`, client event coalescing, real rendering, protected execution, taint, or CPU/allocation behavior.

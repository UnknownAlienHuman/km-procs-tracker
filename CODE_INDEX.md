# KM Procs Tracker code index

| Path | Responsibility |
|---|---|
| `KMProcsTracker.toc` | Retail 12.1.5 metadata, dependency and load order |
| `Core.lua` | Schema 5, access gates, adaptive public-aura observer, normalized counters, casts, commands and events |
| `UI.lua` | Tracker frame, managed KM slot, ordinary observed-proc layer, tooltip/menu and combat deferral |
| `Minimap.lua` | LDB/LibDBIcon launcher and evidence wording |
| `tests/test_observation_12_1_5.lua` | Deterministic secrecy, transition, migration, UI and failure regression |
| `tests/test_evidence_model_12_1_5.lua` | Compatibility entry point forwarding to the observation regression |
| `tests/test_bundled_libraries.lua` | Vendored LibStub/CallbackHandler/LDB/DBIcon integration for both login orders |
| `tests/run_mutation_probes.py` | Eight targeted mutations for secrecy, baseline, cap, lifecycle, aggregate and aura identity invariants |
| `libs/` | Vendored third-party libraries; not aura-state providers |

Addon-owned runtime has no combat-log, overlay/glow, Cooldown Viewer, child-frame scan, simulated-stack, polling, or manual AuraContainer refresh backend.

# KM Procs Tracker code index

| Path | Responsibility |
|---|---|
| `KMProcsTracker.toc` | Retail 12.1.5 metadata, required Blizzard dependency, bundled libraries, load order |
| `Core.lua` | Schema v4 migration/sanitization, secret-value boundary, exact spender-cast counters, commands, lifecycle events |
| `UI.lua` | Tracker frame, neutral placeholder, one managed KM AuraContainer slot, fail-closed init state, combat deferral |
| `Minimap.lua` | LDB/LibDBIcon launcher and exact/unavailable evidence wording |
| `tests/test_evidence_model_12_1_5.lua` | Deterministic regression for migration, managed sinks, access rejection, exact casts, enable/disable, and failure containment |
| `libs/` | Vendored LibStub, CallbackHandler, LibDataBroker, and LibDBIcon |

The runtime intentionally has no raw aura, combat-log, overlay, action-button-glow, Cooldown Viewer, child-frame scan, polling, simulated-stack, or manual AuraContainer refresh backend.

# KM Procs Tracker code index

| Path | Responsibility |
|---|---|
| `KMProcsTracker.toc` | Retail 12.1 metadata, Blizzard_AuraContainer dependency, bundled library paths, and definitive load order |
| `Core.lua` | Schema v4 migration/sanitization, access boundary, exact spender-cast counters, lifecycle, slash commands, and unavailable metric contract |
| `UI.lua` | Addon frame, neutral placeholder, one managed KM AuraContainer slot, exact total text, tooltip/menu, position/scale/lock, and combat deferral |
| `Minimap.lua` | LDB/LibDBIcon launcher with the same exact/unavailable evidence wording |
| `tests/test_evidence_model_12_1.lua` | Mocked regression for legacy counter retirement, managed display sinks, event ownership, inaccessible spell IDs, exact casts, disable and reset |
| `libs/` | Vendored LibStub, CallbackHandler, LibDataBroker, and LibDBIcon |

Removed from the Retail 12.1 implementation:

- `Backend_CooldownViewer.lua`;
- `DevTools/`;
- `TestLab.lua`;
- raw aura, combat-log, overlay, action-button-glow, and simulated-stack backends.

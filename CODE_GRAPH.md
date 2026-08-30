# KM Procs Tracker code graph

```mermaid
flowchart LR
  T["KMProcsTracker.toc"] --> L["bundled LDB/DBIcon libraries"]
  T --> C["Core.lua"]
  T --> U["UI.lua"]
  T --> M["Minimap.lua"]
  C --> DB[("KMProcsTrackerDB v4")]
  E["UNIT_SPELLCAST_SUCCEEDED player"] --> C
  C --> X["exact Obliterate/Frostscythe counters"]
  X --> U
  X --> M
  U --> S["addon-owned neutral stable frame"]
  U --> A["Blizzard CustomAuraContainer"]
  A --> AS["AddAuraSlot HELPFUL 51124/51128"]
  AS --> D["managed icon/count/duration sinks"]
  R["PLAYER_REGEN_ENABLED"] --> U
  Z["tests/test_evidence_model_12_1.lua"] --> C
  Z --> U
```

The graph has no raw aura, combat-log, SpellActivationOverlay, action-button-glow, Cooldown Viewer, child-frame-scan, ticker, or simulated-stack path. Proc/use/expired/overcap/stacks are represented as unavailable, not inferred.

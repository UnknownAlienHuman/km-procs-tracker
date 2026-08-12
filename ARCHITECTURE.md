# Architecture

`Core.lua` owns the addon namespace, persisted counters/configuration, local session state, and proc/consumption inference. It can combine aura, overlay, and Cooldown Viewer-derived signals. `Backend_CooldownViewer.lua` supplies the Cooldown Viewer integration; `UI.lua` renders the tracker and menu; `Minimap.lua` exposes the LDB control.

`KMProcsTrackerDB` owns durable settings and counters. The `Addon.state` table in Core owns session-only detection state, timing windows, and backend selection. `DevTools/` and `TestLab.lua` support inspection and calibration.

The known risk is disagreement between backend signals, especially stack freezing or double-counting. Validate the P0 scenarios with DevTools/TestLab, normal combat activity, and the selected hybrid policy.

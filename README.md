# KM Procs Tracker

Tracks Frost Death Knight Killing Machine stacks, proc consumption, expiration, and overcap waste. The UI includes counters, a movable/resizable tracker, tooltip totals, and an LDB minimap button.

## Preview

![KM Procs Tracker counters](https://media.forgecdn.net/attachments/1443/93/screenshot-2025-12-29-051440-png.png)

Screenshot from the [CurseForge gallery](https://www.curseforge.com/wow/addons/km-procs-tracker).

## Installation

Copy the `KMProcsTracker` directory into `World of Warcraft/_retail_/Interface/AddOns/`, then restart the client or use `/reload`. The TOC vendors the optional LibStub, callback, data-broker, and minimap-button libraries.

## Compatibility and data

- Interface: `120000`, `120001`
- Version: `0.3.46`
- Saved variables: `KMProcsTrackerDB`

## Usage

Drag the tracker to move it and its corner to resize it. Right-click its icon for start/stop, reset, and hide controls. The minimap icon toggles the tracker with left-click and resets counters with right-click.

## Development status

The open P0 work is to eliminate stack freezing/double-counting in the Cooldown Viewer path and validate the final hybrid policy. Calibration controls and structured evidence capture remain lower-priority follow-up. See [TODO.md](TODO.md).

## Published addon

[CurseForge: KM Procs Tracker](https://www.curseforge.com/wow/addons/km-procs-tracker)

## Developer documentation

- [Architecture](ARCHITECTURE.md)
- [Code index](CODE_INDEX.md)
- [Code graph](CODE_GRAPH.md)

## License

Licensed under the [MIT License](LICENSE). Bundled third-party components remain under their own notices.

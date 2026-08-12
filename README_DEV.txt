KMProcsTracker (Midnight) — developer notes
=========================================

What this addon does
--------------------
Tracks *Killing Machine* proc generation and loss for Frost DK:
  - Procs: every time a KM proc is generated (including overcap refresh at 2 stacks)
  - Used: stacks consumed by Obliterate / Frostscythe (default: 1 stack per cast; optional consume-all mode)
  - Wasted: procs generated while already at 2 stacks, plus expired stacks
  - Expired: stacks that fell off without being consumed (counted into Wasted)

The UI is intentionally minimal: a single icon with stack count. Right-click opens a menu.


Code structure
--------------
  - Core.lua
      State machine, counters, event wiring, spender detection, and backend orchestration.

  - UI.lua
      Single-icon frame, stack text, wasted flash, right-click menu.

  - Minimap.lua
      LDB + LibDBIcon launcher.

  - Backend_CooldownViewer.lua
      Experimental backend that reads KM stacks from Blizzard's BuffIconCooldownViewer.

  - DevTools/DevTools.lua + DevToolsUI.lua (optional)
      External dev frame + log ring buffer + filter knobs.


Backend selection
-----------------
The addon supports multiple "backends" for detecting proc/stack state:

  1) glow (default)
     - Observes the spender button glow / SAO patterns and infers stack changes.
     - Best when ActionButtons are available (Blizzard bars) and SAO is stable.

  2) cdm (Cooldown Manager / Cooldown Viewer)
     - Reads the KM buff icon shown by Blizzard's Cooldown Manager (Buff Icon Viewer).
     - Detects overcap by looking at "refresh at 2" via cooldown swirl reset.
     - This is intended for Midnight where direct aura/combatlog data can be noisy/secret.

Change backend:
  - Right-click the main icon -> Backend
  - Or: /kmpt backend glow | cdm | aura

CDM requirements:
  - You must enable a KM *Buff Icon* in Blizzard Cooldown Manager.
  - The CDM backend locates that icon by matching its texture and then reads stack text + cooldown swirl.


Counting logic (high level)
---------------------------
We track an internal stack count (0..2).

Proc gained:
  - If stacks go 0->1 or 1->2: Procs += gained
  - If stacks stay at 2 but the buff "refreshes" (duration resets): Procs += 1, Wasted += 1

Consumption:
  - Obliterate (49020) and Frostscythe (207230) consume 1 stack per cast by default (config: spenders.consumeAllStacks=true for consume-all behavior).
  - We observe UNIT_SPELLCAST_SUCCEEDED and then classify the next stack drop as "Used".

Expiration:
  - Any drop of stacks to 0 without a recent spender cast is classified as Expired.
  - Expired stacks are also counted as Wasted.


DevTools
--------
DevTools are isolated under DevTools/ and are safe to delete.
They provide:
  - An external window with filters and a scrolling log
  - /kmpt devtools (toggle)


What still needs work
---------------------
  - Make CDM icon discovery more robust across Blizzard UI changes.
  - Improve glow backend deduping on some action-bar replacements.
  - Add a small in-game Options panel (if we decide we want one) instead of only menus/slash.

[0.3.23]
- Disabled COMBAT_LOG_EVENT_UNFILTERED registration (can be protected/forbidden in Midnight). Aura backend uses UNIT_SPELLCAST_SUCCEEDED tokenization + aura deltas.

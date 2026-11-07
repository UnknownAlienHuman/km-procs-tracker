-- KM Procs Tracker minimap launcher for Retail 12.1.5.

local ADDON_NAME, Addon = ...
Addon.Minimap = Addon.Minimap or {}
local MinimapModule = Addon.Minimap

local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)

local function AddObservationTooltip(tooltip, snapshot)
  if snapshot.mode == "exact" then
    tooltip:AddLine("Exact public-aura observation active", 0.45, 1, 0.45)
    tooltip:AddDoubleLine("Observed KM applications", tostring(snapshot.observedProcs), 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine("Stack gains", tostring(snapshot.stackGains), 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Refreshes while capped", tostring(snapshot.capRefreshes), 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Stack losses", tostring(snapshot.stackLosses), 0.8, 0.8, 0.8, 1, 1, 1)
  else
    tooltip:AddLine("Blizzard-managed display only", 1, 0.82, 0)
    tooltip:AddLine("Observation paused: " .. tostring(snapshot.reason), 0.75, 0.75, 0.75, true)
    tooltip:AddDoubleLine("Recorded before restriction", tostring(snapshot.observedProcs), 0.8, 0.8, 0.8, 1, 1, 1)
  end
end

function MinimapModule:CreateLauncher()
  if not LDB or self.launcher then return end
  self.launcher = LDB:NewDataObject(ADDON_NAME, {
    type = "launcher",
    text = "KM Procs Tracker",
    icon = Addon:GetIcon(),
    OnClick = function(_, button)
      if button == "LeftButton" then
        if Addon.UI and Addon.UI.ToggleShown then Addon.UI:ToggleShown() end
      elseif button == "RightButton" then
        Addon:ResetCounters()
      end
    end,
    OnTooltipShow = function(tooltip)
      if not tooltip or type(tooltip.AddLine) ~= "function" then return end
      local snapshot = Addon:GetEvidenceSnapshot()
      tooltip:AddLine("KM Procs Tracker")
      AddObservationTooltip(tooltip, snapshot)
      tooltip:AddLine(" ")
      tooltip:AddDoubleLine("Obliterate casts", tostring(snapshot.obliterateCasts), 1, 1, 1, 1, 1, 1)
      tooltip:AddDoubleLine("Frostscythe casts", tostring(snapshot.frostscytheCasts), 1, 1, 1, 1, 1, 1)
      tooltip:AddLine("Loss cause is not classified.", 0.75, 0.75, 0.75, true)
      tooltip:AddLine(" ")
      tooltip:AddLine("Left-click: show/hide", 0.8, 0.8, 0.8)
      tooltip:AddLine("Right-click: reset counters", 0.8, 0.8, 0.8)
    end,
  })
end

function MinimapModule:OnLogin()
  self:CreateLauncher()
  if not (DBIcon and self.launcher) then return end
  if not self.registered then
    DBIcon:Register(ADDON_NAME, self.launcher, Addon:GetDB().minimap)
    self.registered = true
  end
  self:Refresh()
end

function MinimapModule:Refresh()
  if not (DBIcon and self.launcher and self.registered) then return end
  DBIcon:Refresh(ADDON_NAME, Addon:GetDB().minimap)
end

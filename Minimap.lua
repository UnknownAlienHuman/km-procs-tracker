-- KM Procs Tracker minimap launcher for Retail 12.1.5.

local ADDON_NAME, Addon = ...
Addon.Minimap = Addon.Minimap or {}
local Minimap = Addon.Minimap

local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)

function Minimap:CreateLauncher()
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
      tooltip:AddLine("KM Procs Tracker — evidence-safe")
      tooltip:AddDoubleLine("Obliterate casts", tostring(snapshot.obliterateCasts), 1, 1, 1, 1, 1, 1)
      tooltip:AddDoubleLine("Frostscythe casts", tostring(snapshot.frostscytheCasts), 1, 1, 1, 1, 1, 1)
      tooltip:AddDoubleLine("Total spender casts", tostring(snapshot.spenderCasts), 1, 1, 1, 1, 1, 1)
      tooltip:AddLine("KM proc/use/expired/overcap counts: unavailable", 1, 0.82, 0, true)
      tooltip:AddLine(" ")
      tooltip:AddLine("Left-click: show/hide", 0.8, 0.8, 0.8)
      tooltip:AddLine("Right-click: reset exact counters", 0.8, 0.8, 0.8)
    end,
  })
end

function Minimap:OnLogin()
  self:CreateLauncher()
  if not (DBIcon and self.launcher) then return end
  if not self.registered then
    DBIcon:Register(ADDON_NAME, self.launcher, Addon:GetDB().minimap)
    self.registered = true
  end
  self:Refresh()
end

function Minimap:Refresh()
  if not (DBIcon and self.launcher and self.registered) then return end
  DBIcon:Refresh(ADDON_NAME, Addon:GetDB().minimap)
end

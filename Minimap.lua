-- Minimap.lua
-- KM Procs Tracker — minimap button using LDB + LibDBIcon

local ADDON_NAME, Addon = ...
Addon.Minimap = Addon.Minimap or {}
local Minimap = Addon.Minimap

local function GetDB()
	return Addon:GetDB()
end

local function SpellTexture(spellID)
	if C_Spell and C_Spell.GetSpellTexture then
		return C_Spell.GetSpellTexture(spellID)
	end
	if GetSpellTexture then
		return GetSpellTexture(spellID)
	end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local DBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)

function Minimap:OnLogin()
	if not (LDB and DBIcon) then return end

	if self.launcher then
		DBIcon:Refresh(ADDON_NAME, GetDB().minimap)
		return
	end

	self:CreateLauncher()
	DBIcon:Register(ADDON_NAME, self.launcher, GetDB().minimap)
	DBIcon:Refresh(ADDON_NAME, GetDB().minimap)
end

function Minimap:CreateLauncher()
	local iconTex = SpellTexture(Addon.KM_SPELL_ID)

	self.launcher = LDB:NewDataObject(ADDON_NAME, {
		type = "launcher",
		text = "KM Procs Tracker",
		icon = iconTex,

		OnClick = function(_, button)
			if button == "LeftButton" then
				if Addon.UI and Addon.UI.ToggleShown then
					Addon.UI:ToggleShown()
				end
			elseif button == "RightButton" then
				Addon:ResetCounters()
				if Addon.UI and Addon.UI.UpdateCounters then
					Addon.UI:UpdateCounters()
				end
			end
		end,

		OnTooltipShow = function(tooltip)
			if not tooltip or not tooltip.AddLine then return end
			tooltip:AddLine("KM Procs Tracker")
			tooltip:AddLine(("Procs: %d"):format(Addon.counters.procs), 1, 1, 1)
			tooltip:AddLine(("Consumed: %d"):format(Addon.counters.consumed), 1, 1, 1)
			tooltip:AddLine(("Wasted: %d"):format(Addon.counters.wasted), 1, 0.3, 0.3)
			tooltip:AddLine(" ")
			tooltip:AddLine("Left-click: show/hide", 0.8, 0.8, 0.8)
			tooltip:AddLine("Right-click: reset counters", 0.8, 0.8, 0.8)
		end,
	})
end

function Minimap:SetIconHidden(hidden)
	if not (DBIcon and self.launcher) then return end
	local db = GetDB()
	db.minimap.hide = hidden and true or false
	DBIcon:Refresh(ADDON_NAME, db.minimap)
end

-- UI.lua
-- KM Procs Tracker — icon-only UI (user-facing tooltip cleaned)
-- Tooltip shows: Procs / Used / Wasted (+ optional breakdown) / Current stacks
-- No user-visible math check.

local ADDON_NAME, Addon = ...
Addon.UI = Addon.UI or {}
local UI = Addon.UI

local BASE_ICON_SIZE = 44
local BASE_BORDER_SIZE = 70
local MIN_SCALE = 0.60
local MAX_SCALE = 3.00

local function GetDB() return Addon:GetDB() end
local function Clamp(x, a, b) if x < a then return a end if x > b then return b end return x end
local function Round(x) return math.floor(x + 0.5) end

local function SpellTexture(spellID)
	if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(spellID) end
	if GetSpellTexture then return GetSpellTexture(spellID) end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

function UI:ApplyVisualScale(scale)
	if not self.frame then return end
	scale = Clamp(scale or 1.0, MIN_SCALE, MAX_SCALE)

	local size = Round(BASE_ICON_SIZE * scale)
	self.frame:SetScale(1.0)
	self.frame:SetSize(size, size)

	if self.border then
		self.border:SetSize(Round(BASE_BORDER_SIZE * scale), Round(BASE_BORDER_SIZE * scale))
	end
	if self.stacksText then self.stacksText:SetScale(scale) end
	if self.wastedText then self.wastedText:SetScale(scale) end
end

function UI:GetCombatBaseAlpha()
	return UnitAffectingCombat("player") and 1.0 or 0.45
end

function UI:ComputeAlpha(stacks)
	local base = self:GetCombatBaseAlpha()
	if (stacks or 0) <= 0 then return base * 0.55 end
	return base
end

function UI:OnLogin()
	if not self.frame then self:CreateIconFrame() end
	self:ApplyDB()
	self:UpdateStacks(Addon.state.stacks or Addon:GetKMStacksFromAuras())
end

function UI:ShowTooltip(owner)
	if self.resizeGrabber and self.resizeGrabber.resizing then return end

	local stacks = Addon.state.stacks or Addon:GetKMStacksFromAuras()
	local procs  = Addon.counters.procs or 0
	local used   = Addon.counters.used or Addon.counters.consumed or 0
	local wasted = Addon.counters.wasted or 0
	local overcap = Addon.counters.overcap or 0
	local expired = Addon.counters.expired or 0

	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:AddLine("KM Procs Tracker")
	GameTooltip:AddLine(("Procs: %d"):format(procs), 1, 1, 1)
	GameTooltip:AddLine(("Used: %d"):format(used), 1, 1, 1)
	GameTooltip:AddLine(("Wasted: %d"):format(wasted), 1, 0.3, 0.3)
	GameTooltip:AddLine(("  - Overcap: %d"):format(overcap), 0.8, 0.8, 0.8)
	GameTooltip:AddLine(("  - Expired: %d"):format(expired), 0.8, 0.8, 0.8)
	GameTooltip:AddLine(("Current stacks: %d"):format(stacks), 0.8, 0.8, 0.8)

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-drag: move", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: menu", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag corner: resize", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

function UI:MaybeHideTooltip()
	local f = self.frame
	local g = self.resizeGrabber
	if not f then return end
	if g and g.resizing then return end
	if (f and f:IsMouseOver()) or (g and g:IsMouseOver()) then return end
	GameTooltip:Hide()
	if g then g:Hide() end
end

function UI:ToggleStartStop()
	if Addon:IsTrackingEnabled() then Addon:SetManualPaused(true) else Addon:SetManualPaused(false) end
end

function UI:ShowContextMenu()
	local startStopLabel = Addon:IsTrackingEnabled() and "Stop" or "Start"

	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(self.frame, function(_, root)
			root:CreateTitle("KM Procs Tracker")
			root:CreateButton(startStopLabel, function() UI:ToggleStartStop() end)
			root:CreateButton("Reset", function() Addon:ResetCounters() end)
			root:CreateButton("Close", function() UI:SetShown(false) end)
				root:CreateDivider()
				root:CreateTitle("Backend")
				local cur = Addon:GetBackend()
				local function Mark(mode, label)
					if cur == mode then return "\226\128\162 " .. label end -- •
					return label
				end
				root:CreateButton(Mark("glow", "Glow (spell activations)"), function() Addon:SetBackend("glow") end)
				root:CreateButton(Mark("cdm",  "Cooldown Manager"), function() Addon:SetBackend("cdm") end)
				root:CreateButton(Mark("aura", "Auras (UNIT_AURA)"), function() Addon:SetBackend("aura") end)
				if Addon.DevToolsUI and Addon.DevToolsUI.Toggle then
					root:CreateDivider()
					root:CreateButton("DevTools", function() Addon.DevToolsUI:Toggle() end)
				end
		end)
		return
	end

	if not self.menuFrame then
		self.menuFrame = CreateFrame("Frame", ADDON_NAME .. "_MenuFrame", UIParent, "UIDropDownMenuTemplate")
	end
	if not EasyMenu then return end

	local menu = {
		{ text = "KM Procs Tracker", isTitle = true, notCheckable = true },
		{ text = startStopLabel, notCheckable = true, func = function() UI:ToggleStartStop() end },
		{ text = "Reset", notCheckable = true, func = function() Addon:ResetCounters() end },
		{ text = "Close", notCheckable = true, func = function() UI:SetShown(false) end },
			{ text = " ", isTitle = true, notCheckable = true },
			{ text = "Backend", isTitle = true, notCheckable = true },
			{ text = (Addon:GetBackend()=="glow" and "• " or "") .. "Glow (spell activations)", notCheckable = true, func = function() Addon:SetBackend("glow") end },
			{ text = (Addon:GetBackend()=="cdm"  and "• " or "") .. "Cooldown Manager", notCheckable = true, func = function() Addon:SetBackend("cdm") end },
			{ text = (Addon:GetBackend()=="aura" and "• " or "") .. "Auras (UNIT_AURA)", notCheckable = true, func = function() Addon:SetBackend("aura") end },
	}
		if Addon.DevToolsUI and Addon.DevToolsUI.Toggle then
			table.insert(menu, { text = "DevTools", notCheckable = true, func = function() Addon.DevToolsUI:Toggle() end })
		end

	if CloseDropDownMenus then CloseDropDownMenus() end
	EasyMenu(menu, self.menuFrame, "cursor", 0, 0, "MENU")
end

function UI:CreateIconFrame()
	local f = CreateFrame("Button", ADDON_NAME .. "_IconFrame", UIParent)
	self.frame = f

	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:RegisterForClicks("AnyUp")

	local icon = f:CreateTexture(nil, "ARTWORK")
	self.icon = icon
	icon:SetAllPoints()
	icon:SetTexture(SpellTexture(Addon.KM_SPELL_ID))

	local border = f:CreateTexture(nil, "OVERLAY")
	self.border = border
	border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	border:SetBlendMode("ADD")
	border:SetPoint("CENTER", f, "CENTER", 0, 0)
	border:Hide()

	local stacksText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	self.stacksText = stacksText
	stacksText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -2, -2)
	stacksText:SetJustifyH("LEFT")
	stacksText:SetText("0")
	stacksText:SetDrawLayer("OVERLAY", 6)

	local wastedText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	self.wastedText = wastedText
	wastedText:SetPoint("CENTER", f, "CENTER", 0, 0)
	wastedText:SetTextColor(1, 0.1, 0.1, 1)
	wastedText:SetText("Wasted")
	wastedText:SetDrawLayer("OVERLAY", 7)
	wastedText:Hide()

	f:SetScript("OnEnter", function()
		UI:ShowTooltip(f)
		if UI.resizeGrabber and not UI.resizeGrabber.resizing then UI.resizeGrabber:Show() end
	end)
	f:SetScript("OnLeave", function()
		C_Timer.After(0, function() if UI then UI:MaybeHideTooltip() end end)
	end)

	f:SetScript("OnDragStart", function()
		local g = UI.resizeGrabber
		if g and g.resizing then return end
		local db = GetDB()
		if db.frame.locked then return end
		f:StartMoving()
	end)
	f:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		UI:SavePosition()
	end)

	f:SetScript("OnClick", function(_, button)
		if button == "RightButton" then UI:ShowContextMenu() end
	end)

	local g = CreateFrame("Button", nil, f)
	self.resizeGrabber = g
	g:SetSize(14, 14)
	g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	g:Hide()

	g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")

	g:SetScript("OnEnter", function()
		UI:ShowTooltip(f)
		g:Show()
	end)
	g:SetScript("OnLeave", function()
		C_Timer.After(0, function() if UI then UI:MaybeHideTooltip() end end)
	end)

	g:SetScript("OnMouseDown", function()
		g.resizing = true
		GameTooltip:Hide()

		local db = GetDB()
		g.startScale = db.frame.scale or 1.0

		local uiScale = UIParent:GetEffectiveScale()
		g.startCursorX = (select(1, GetCursorPosition())) / uiScale

		g.pinLeft = f:GetLeft()
		g.pinTop = f:GetTop()

		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", g.pinLeft, g.pinTop)
	end)

	g:SetScript("OnMouseUp", function()
		g.resizing = false
		UI:SaveScale()
		UI:SavePosition()

		C_Timer.After(0, function()
			if UI and UI.frame and (UI.frame:IsMouseOver() or g:IsMouseOver()) then
				UI:ShowTooltip(UI.frame)
				g:Show()
			else
				UI:MaybeHideTooltip()
			end
		end)
	end)

	g:SetScript("OnUpdate", function()
		if not g.resizing then return end
		local db = GetDB()
		local uiScale = UIParent:GetEffectiveScale()
		local cx = (select(1, GetCursorPosition())) / uiScale
		local deltaX = cx - (g.startCursorX or cx)

		local newScale = (g.startScale or 1.0) + (deltaX / BASE_ICON_SIZE)
		newScale = Clamp(newScale, MIN_SCALE, MAX_SCALE)

		db.frame.scale = newScale
		UI:ApplyVisualScale(newScale)
	end)
		-- Core.lua already handles combat state changes and stack refresh.
	SLASH_KMPROCSTRACKER1 = "/kmpt"
	SlashCmdList["KMPROCSTRACKER"] = function(msg)
		msg = (msg or ""):gsub("^%s+",""):gsub("%s+$","")
		if msg ~= "" and Addon and Addon.SlashCommand then
			Addon:SlashCommand(msg)
		else
			UI:ToggleShown()
		end
	end
end

function UI:ApplyDB()
	if not self.frame then return end
	local db = GetDB()

	self.frame:ClearAllPoints()
	self.frame:SetPoint(
		db.frame.point or "CENTER",
		UIParent,
		db.frame.relativePoint or "CENTER",
		db.frame.x or 0,
		db.frame.y or 0
	)

	self:ApplyVisualScale(db.frame.scale or 1.0)
	if db.frame.shown then self.frame:Show() else self.frame:Hide() end
end

function UI:SavePosition()
	if not self.frame then return end
	local db = GetDB()
	local point, _, relativePoint, x, y = self.frame:GetPoint(1)
	db.frame.point = point or "CENTER"
	db.frame.relativePoint = relativePoint or "CENTER"
	db.frame.x = x or 0
	db.frame.y = y or 0
end

function UI:SaveScale()
	local db = GetDB()
	db.frame.scale = Clamp(db.frame.scale or 1.0, MIN_SCALE, MAX_SCALE)
end

function UI:SetShown(shown)
	local db = GetDB()
	db.frame.shown = shown and true or false
	if not self.frame then return end
	if db.frame.shown then self.frame:Show() else self.frame:Hide() end
end

function UI:ToggleShown()
	local db = GetDB()
	self:SetShown(not db.frame.shown)
end

function UI:UpdateStacks(stacks)
	if not (self.icon and self.stacksText and self.border) then return end
	stacks = stacks or 0
	self.stacksText:SetText(tostring(stacks))

	local a = self:ComputeAlpha(stacks)
	self.icon:SetAlpha(a)
	self.stacksText:SetAlpha(a)

	if stacks >= 2 then
		self.border:SetAlpha(a)
		self.border:Show()
	else
		self.border:Hide()
	end
end

function UI:UpdateCounters()
	-- icon-only UI; tooltip reads counters live
end

function UI:ShowWasted()
	if not (self.icon and self.wastedText) then return end
	self.wastedText:Show()
	self.icon:SetDesaturated(true)
	self.icon:SetVertexColor(0.75, 0.75, 0.75)

	if self._wastedTimer and self._wastedTimer.Cancel then self._wastedTimer:Cancel() end
	self._wastedTimer = C_Timer.NewTimer(1.0, function()
		if not UI or not UI.icon then return end
		UI.wastedText:Hide()
		UI.icon:SetDesaturated(false)
		UI.icon:SetVertexColor(1, 1, 1)
		UI:UpdateStacks(Addon.state.stacks or Addon:GetKMStacksFromAuras())
	end)
end

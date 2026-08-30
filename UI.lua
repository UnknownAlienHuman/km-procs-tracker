-- KM Procs Tracker UI for Retail 12.1.
-- The Killing Machine state is rendered by Blizzard's managed AuraContainer.
-- This file never queries aura assignment, visibility, stacks, duration, or
-- managed-button state.

local ADDON_NAME, Addon = ...
Addon.UI = Addon.UI or {}
local UI = Addon.UI
local Access = Addon.Access

local BASE_SIZE = 44
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local SLOT_KEY = "killing_machine"

local function GetDB()
  return Addon:GetDB()
end

local function GetKMTexture()
  if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
    for _, spellID in ipairs(Addon.KM_AURA_IDS) do
      local ok, value = pcall(C_Spell.GetSpellTexture, spellID)
      if ok and Access.CanAccess(value) then
        local valueType = type(value)
        if valueType == "number" or valueType == "string" then return value end
      end
    end
  end
  return QUESTION_ICON
end

local function InitializeManagedButton(button, container)
  button:SetAllPoints(container)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(button)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  button:SetIcon(icon)

  local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
  button:SetApplicationCount(count, {})

  local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
  cooldown:SetAllPoints(button)
  button:SetDurationCooldown(cooldown)

  local glow = button:CreateTexture(nil, "OVERLAY", nil, 2)
  glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  glow:SetBlendMode("ADD")
  glow:SetPoint("CENTER", button, "CENTER", 0, 0)
  glow:SetSize(BASE_SIZE * 1.45, BASE_SIZE * 1.45)
  glow:SetAlpha(0.85)
end

function UI:CreateManagedAura()
  if self.auraContainer then return true end
  if InCombatLockdown() then
    self.pendingInit = true
    return false
  end
  if not self.frame then return false end

  local ok, container = pcall(CreateFrame, "AuraContainer", nil, self.frame, "CustomAuraContainerTemplate")
  if not ok or not container then
    self.auraUnavailable = true
    return false
  end

  container:SetAllPoints(self.frame)
  container:SetUnit("player")

  local includeSpellIDs = {}
  for _, spellID in ipairs(Addon.KM_AURA_IDS) do includeSpellIDs[spellID] = true end

  local options = {
    initializeFrame = function(button)
      InitializeManagedButton(button, container)
    end,
    candidateFilters = {
      includeSpellIDs = includeSpellIDs,
    },
    sortMethod = AuraContainerSortMethod and AuraContainerSortMethod.Default or nil,
    sortDirection = AuraContainerSortDirection and AuraContainerSortDirection.Normal or nil,
  }

  local added = pcall(container.AddAuraSlot, container, SLOT_KEY, "HELPFUL", options)
  if not added then
    container:Hide()
    self.auraUnavailable = true
    return false
  end

  self.auraContainer = container
  self.auraUnavailable = false
  self.pendingInit = false
  container:SetEnabled(Addon:IsEnabled())
  container:Show()
  if type(container.UpdateAllAuras) == "function" then container:UpdateAllAuras() end
  return true
end

function UI:CreateFrame()
  if self.frame then return end

  local frame = CreateFrame("Button", ADDON_NAME .. "_IconFrame", UIParent, "BackdropTemplate")
  self.frame = frame
  frame:SetFrameStrata("MEDIUM")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:RegisterForClicks("AnyUp")
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  frame:SetBackdropColor(0, 0, 0, 0.55)
  frame:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

  local placeholder = frame:CreateTexture(nil, "BACKGROUND")
  self.placeholder = placeholder
  placeholder:SetAllPoints(frame)
  placeholder:SetTexture(GetKMTexture())
  placeholder:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  placeholder:SetAlpha(0.20)
  placeholder:SetDesaturated(true)

  local exactText = frame:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  self.exactText = exactText
  exactText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  exactText:SetText("0")

  frame:SetScript("OnEnter", function() UI:ShowTooltip(frame) end)
  frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  frame:SetScript("OnDragStart", function(self)
    local db = GetDB()
    if not db or db.frame.locked or InCombatLockdown() then return end
    self:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    UI:SavePosition()
  end)
  frame:SetScript("OnClick", function(_, button)
    if button == "RightButton" then UI:ShowContextMenu() end
  end)
end

function UI:OnLogin()
  self:CreateFrame()
  self:ApplyDB()
  self:CreateManagedAura()
  self:UpdateCounters()
end

function UI:SavePosition()
  if not self.frame or InCombatLockdown() then return end
  local point, _, relativePoint, x, y = self.frame:GetPoint(1)
  point = Access.SafeString(point)
  relativePoint = Access.SafeString(relativePoint)
  x = Access.SafeNumber(x)
  y = Access.SafeNumber(y)
  if not point or not relativePoint or not x or not y then return end

  local db = GetDB()
  db.frame.point = point
  db.frame.relativePoint = relativePoint
  db.frame.x = math.floor(x + 0.5)
  db.frame.y = math.floor(y + 0.5)
end

function UI:ApplyDB()
  if not self.frame then return end
  if InCombatLockdown() then
    self.pendingApply = true
    return
  end

  local db = GetDB()
  self.pendingApply = false
  self.frame:ClearAllPoints()
  self.frame:SetPoint(db.frame.point, UIParent, db.frame.relativePoint, db.frame.x, db.frame.y)
  self.frame:SetScale(1)
  local size = math.floor(BASE_SIZE * db.frame.scale + 0.5)
  self.frame:SetSize(size, size)
  self.frame:EnableMouse(not db.frame.locked or db.frame.shown)
  self.frame:SetShown(db.frame.shown)
  self:SetAuraEnabled(db.enabled)
end

function UI:FlushPending()
  if InCombatLockdown() then return end
  if self.pendingInit then self:CreateManagedAura() end
  if self.pendingApply then self:ApplyDB() end
end

function UI:SetAuraEnabled(enabled)
  if self.placeholder then self.placeholder:SetShown(enabled == true) end
  if self.auraContainer then
    self.auraContainer:SetEnabled(enabled == true)
    self.auraContainer:SetShown(enabled == true)
    if enabled and type(self.auraContainer.UpdateAllAuras) == "function" then
      self.auraContainer:UpdateAllAuras()
    end
  elseif enabled then
    self:CreateManagedAura()
  end
end

function UI:UpdateCounters()
  if not self.exactText then return end
  local snapshot = Addon:GetEvidenceSnapshot()
  self.exactText:SetText(tostring(snapshot.spenderCasts))
end

function UI:SetShown(shown)
  local db = GetDB()
  db.frame.shown = shown == true
  if self.frame then self.frame:SetShown(db.frame.shown) end
end

function UI:ToggleShown()
  self:SetShown(not GetDB().frame.shown)
end

function UI:AdjustScale(delta)
  local db = GetDB()
  local value = db.frame.scale + delta
  if value < 0.60 then value = 0.60 elseif value > 3.00 then value = 3.00 end
  db.frame.scale = value
  self:ApplyDB()
end

function UI:ShowTooltip(owner)
  if not GameTooltip then return end
  local snapshot = Addon:GetEvidenceSnapshot()
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:AddLine("KM Procs Tracker — evidence-safe")
  GameTooltip:AddLine("Exact successful player casts", 0.7, 0.9, 1)
  GameTooltip:AddDoubleLine("Obliterate", tostring(snapshot.obliterateCasts), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Frostscythe", tostring(snapshot.frostscytheCasts), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddDoubleLine("Total spender casts", tostring(snapshot.spenderCasts), 1, 1, 1, 1, 1, 1)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Killing Machine aura: Blizzard-managed display", 0.7, 0.9, 1)
  if self.auraUnavailable then
    GameTooltip:AddLine("Managed AuraContainer unavailable on this client", 1, 0.3, 0.3)
  end
  GameTooltip:AddLine("Not observable as exact addon metrics:", 1, 0.82, 0)
  GameTooltip:AddLine("proc count, KM-attributed use, expiration, overcap, stacks", 0.75, 0.75, 0.75, true)
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Right-click: menu  •  drag while unlocked", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end

function UI:ShowContextMenu()
  local db = GetDB()
  if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
    MenuUtil.CreateContextMenu(self.frame, function(_, root)
      root:CreateTitle("KM Procs Tracker")
      root:CreateButton(Addon:IsEnabled() and "Disable" or "Enable", function()
        Addon:SetEnabled(not Addon:IsEnabled())
      end)
      root:CreateButton("Reset exact cast counters", function() Addon:ResetCounters() end)
      root:CreateButton(db.frame.locked and "Unlock movement" or "Lock movement", function()
        db.frame.locked = not db.frame.locked
        UI:ApplyDB()
      end)
      root:CreateButton("Scale +", function() UI:AdjustScale(0.10) end)
      root:CreateButton("Scale -", function() UI:AdjustScale(-0.10) end)
      root:CreateButton("Hide frame", function() UI:SetShown(false) end)
    end)
  end
end

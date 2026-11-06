-- KM Procs Tracker UI for Retail 12.1.5.
-- The Killing Machine state is rendered by Blizzard's managed AuraContainer.
-- This file never queries aura assignment, visibility, stacks, duration, or
-- managed-button state.

local ADDON_NAME, Addon = ...
Addon.UI = Addon.UI or {}
local UI = Addon.UI
local Access = Addon.Access

local BASE_SIZE = 44
local SLOT_KEY = "killing_machine"
local AURA_INIT_UNINITIALIZED = "uninitialized"
local AURA_INIT_PENDING = "pending"
local AURA_INIT_READY = "ready"
local AURA_INIT_FAILED = "failed"

local function FailManagedAura(ui, container)
  if container and type(container.Hide) == "function" then pcall(container.Hide, container) end
  ui.pendingInit = false
  ui.pendingAuraEnabled = nil
  ui.auraInitState = AURA_INIT_FAILED
  ui.auraUnavailable = true
  ui.appliedAuraEnabled = nil
end

local function GetDB()
  return Addon:GetDB()
end

local function Round(value)
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
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
  self.auraInitState = self.auraInitState or AURA_INIT_UNINITIALIZED
  if self.auraInitState == AURA_INIT_READY and self.auraContainer then return true end
  if self.auraInitState == AURA_INIT_FAILED then return false end

  if InCombatLockdown() then
    self.pendingInit = true
    self.auraInitState = AURA_INIT_PENDING
    return false
  end
  if not self.frame then return false end

  local ok, container = pcall(CreateFrame, "AuraContainer", nil, self.frame, "CustomAuraContainerTemplate")
  if not ok or not container then
    FailManagedAura(self)
    return false
  end

  -- Retain the one attempted container before AddAuraSlot. If the API contract
  -- is unavailable, later enable/apply calls fail closed instead of leaking a
  -- new frame on every retry.
  self.auraContainer = container
  local configured = pcall(function()
    container:SetAllPoints(self.frame)
    container:SetUnit("player")
  end)
  if not configured then
    FailManagedAura(self, container)
    return false
  end

  -- Blizzard invokes this callback through securecallfunction. Its errors do
  -- not reliably escape AddAuraSlot, so track our own setup result explicitly.
  local initialized = false
  local options = {
    initializeFrame = function(button)
      initialized = pcall(InitializeManagedButton, button, container)
    end,
    candidateFilters = {
      -- 51128 is the passive talent, not the timed proc aura.
      includeSpellIDs = { [Addon.KM_SPELL_ID] = true },
    },
    sortMethod = AuraContainerSortMethod and AuraContainerSortMethod.Default or nil,
    sortDirection = AuraContainerSortDirection and AuraContainerSortDirection.Normal or nil,
  }

  local added, auraFrame = pcall(container.AddAuraSlot, container, SLOT_KEY, "HELPFUL", options)
  if not added or not auraFrame or not initialized then
    FailManagedAura(self, container)
    return false
  end

  local enabled = Addon:IsEnabled()
  local applied = pcall(container.SetEnabled, container, enabled)
  if not applied then
    FailManagedAura(self, container)
    return false
  end

  self.pendingInit = false
  self.auraInitState = AURA_INIT_READY
  self.auraUnavailable = false
  self.appliedAuraEnabled = enabled
  return true
end

function UI:CreateFrame()
  if self.frame then return end
  if InCombatLockdown() then
    self.pendingApply = true
    return
  end

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
  placeholder:SetTexture(Addon:GetIcon())
  placeholder:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  placeholder:SetAlpha(0.20)
  placeholder:SetDesaturated(true)

  -- An ordinary sibling of the managed container keeps cast text above its
  -- icon/cooldown without retaining or mutating any adopted aura child.
  local counterFrame = CreateFrame("Frame", nil, frame)
  counterFrame:SetAllPoints(frame)
  counterFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
  counterFrame:EnableMouse(false)
  local exactText = counterFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
  self.exactText = exactText
  exactText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  exactText:SetText("0")

  frame:SetScript("OnEnter", function() UI:ShowTooltip(frame) end)
  frame:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  frame:SetScript("OnDragStart", function(self)
    local db = GetDB()
    if not db or db.frame.locked or InCombatLockdown() then return end
    self:StartMoving()
    UI.isDragging = true
  end)
  frame:SetScript("OnDragStop", function() UI:StopMoving() end)
  frame:SetScript("OnClick", function(_, button)
    if button == "RightButton" then UI:ShowContextMenu() end
  end)
end

function UI:OnLogin()
  self:ApplyDB()
end

function UI:StopMoving()
  if not self.isDragging then return end
  if InCombatLockdown() then
    self.pendingDragStop = true
    return
  end
  self.frame:StopMovingOrSizing()
  self.isDragging = false
  self.pendingDragStop = false
  self:SavePosition()
end

function UI:SavePosition()
  if not self.frame or InCombatLockdown() then return end
  local point, _, relativePoint, x, y = self.frame:GetPoint(1)
  point = Access.SafePoint(point)
  relativePoint = Access.SafePoint(relativePoint)
  x = Access.SafeNumber(x)
  y = Access.SafeNumber(y)
  if not point or not relativePoint or not x or not y then return end

  local db = GetDB()
  db.frame.point = point
  db.frame.relativePoint = relativePoint
  -- Persist offsets in UIParent units, independent of the current icon scale.
  -- Use the applied scale: a combat-deferred setting may already have changed.
  local scale = self.appliedScale or 1
  db.frame.x = Round(x * scale)
  db.frame.y = Round(y * scale)
end

function UI:ApplyDB()
  if InCombatLockdown() then
    self.pendingApply = true
    return
  end

  self:CreateFrame()
  self:StopMoving()
  local db = GetDB()
  self.pendingApply = false
  self.appliedScale = db.frame.scale
  self.frame:SetScale(self.appliedScale)
  self.frame:ClearAllPoints()
  self.frame:SetPoint(db.frame.point, UIParent, db.frame.relativePoint,
    db.frame.x / self.appliedScale, db.frame.y / self.appliedScale)
  self.frame:SetSize(BASE_SIZE, BASE_SIZE)
  self.frame:EnableMouse(true)
  self.frame:SetShown(db.frame.shown)
  self:SetAuraEnabled(db.enabled)
  self:UpdateCounters()
end

function UI:FlushPending()
  if InCombatLockdown() then return end
  if self.pendingDragStop then self:StopMoving() end

  if self.pendingInit then
    if Addon:IsEnabled() then
      self:CreateManagedAura()
    else
      self.pendingInit = false
      if self.auraInitState == AURA_INIT_PENDING then
        self.auraInitState = AURA_INIT_UNINITIALIZED
      end
    end
  end

  if self.pendingApply then
    self:ApplyDB()
  elseif self.pendingAuraEnabled ~= nil then
    local enabled = self.pendingAuraEnabled
    self.pendingAuraEnabled = nil
    self:SetAuraEnabled(enabled)
  end
end

function UI:SetAuraEnabled(enabled)
  enabled = enabled == true
  if self.placeholder then self.placeholder:SetShown(enabled) end

  if InCombatLockdown() then
    self.pendingAuraEnabled = enabled
    if enabled and self.auraInitState ~= AURA_INIT_READY and self.auraInitState ~= AURA_INIT_FAILED then
      self.pendingInit = true
      self.auraInitState = AURA_INIT_PENDING
    elseif not enabled and self.auraInitState == AURA_INIT_PENDING then
      self.pendingInit = false
      self.auraInitState = AURA_INIT_UNINITIALIZED
    end
    return
  end

  self.pendingAuraEnabled = nil
  if not enabled and self.auraInitState == AURA_INIT_PENDING then
    self.pendingInit = false
    self.auraInitState = AURA_INIT_UNINITIALIZED
  end

  if self.auraInitState == AURA_INIT_READY and self.auraContainer then
    if self.appliedAuraEnabled ~= enabled then
      local applied = pcall(self.auraContainer.SetEnabled, self.auraContainer, enabled)
      if not applied then
        FailManagedAura(self, self.auraContainer)
        return
      end
      self.appliedAuraEnabled = enabled
    end
  elseif enabled and self.auraInitState ~= AURA_INIT_FAILED then
    self:CreateManagedAura()
  end
end

function UI:UpdateCounters()
  if not self.exactText then return end
  local total = GetDB().exact.spenderCasts
  if self.displayedCastCount == total then return end
  self.displayedCastCount = total
  self.exactText:SetText(tostring(total))
end

function UI:SetShown(shown)
  local db = GetDB()
  db.frame.shown = shown == true
  if not self.frame then return end
  if InCombatLockdown() then
    self.pendingApply = true
    return
  end
  if not db.frame.shown then self:StopMoving() end
  self.frame:SetShown(db.frame.shown)
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

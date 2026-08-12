-- DevTools/DevToolsUI.lua
-- Optional developer UI: external frame with filter knobs and a scrolling log.

local ADDON_NAME, Addon = ...

Addon.DevToolsUI = Addon.DevToolsUI or {}
local UI = Addon.DevToolsUI

local function DB()
  return Addon:GetDB().devtools
end

local function MakeBackdrop(f)
  f.backdropInfo = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  }
end

local function CreateLabeledEditBox(parent, labelText, width, onEnter)
  local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  label:SetText(labelText)

  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, 20)
  eb:SetAutoFocus(false)
  eb:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if onEnter then onEnter(self) end
  end)
  eb:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    if UI.Refresh then UI:Refresh() end
  end)

  return label, eb
end

function UI:Create()
  if self.frame then return end

  local f = CreateFrame("Frame", ADDON_NAME .. "_DevToolsFrame", UIParent, "BackdropTemplate")
  self.frame = f
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetSize(520, 430)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  MakeBackdrop(f)
  f:ApplyBackdrop()


-- Allow ESC to close the DevTools window (even if an EditBox has focus)
if UISpecialFrames and f.GetName then
  local name = f:GetName()
  local exists = false
  for i = 1, #UISpecialFrames do
    if UISpecialFrames[i] == name then
      exists = true
      break
    end
  end
  if not exists then
    UISpecialFrames[#UISpecialFrames + 1] = name
  end
end

f:SetScript("OnHide", function()
  if UI and UI.edit then
    UI.edit:ClearFocus()
  end
end)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
  title:SetText("KMPT DevTools")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() f:Hide() end)


-- Quick backend switching (aka "testers")
local lblBackend = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
lblBackend:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -14)
lblBackend:SetText("Backend")
self.lblBackend = lblBackend

local btnAura = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
btnAura:SetSize(52, 20)
btnAura:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -44)
btnAura:SetText("Aura")
btnAura:SetScript("OnClick", function()
  if Addon and Addon.SetBackend then Addon:SetBackend("aura") end
  UI:RefreshBackendButtons()
end)
self.btnAura = btnAura

local btnGlow = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
btnGlow:SetSize(52, 20)
btnGlow:SetPoint("RIGHT", btnAura, "LEFT", -6, 0)
btnGlow:SetText("Glow")
btnGlow:SetScript("OnClick", function()
  if Addon and Addon.SetBackend then Addon:SetBackend("glow") end
  UI:RefreshBackendButtons()
end)
self.btnGlow = btnGlow

local btnCDM = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
btnCDM:SetSize(52, 20)
btnCDM:SetPoint("RIGHT", btnGlow, "LEFT", -6, 0)
btnCDM:SetText("CDM")
btnCDM:SetScript("OnClick", function()
  if Addon and Addon.SetBackend then Addon:SetBackend("cdm") end
  UI:RefreshBackendButtons()
end)
self.btnCDM = btnCDM


-- Hybrid toggle (Aura truth while running glow/CDM backends)
local chkHybrid = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
chkHybrid:SetPoint("RIGHT", btnCDM, "LEFT", -10, 0)
chkHybrid:SetScale(0.90)
chkHybrid.text = chkHybrid.text or chkHybrid:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
chkHybrid.text:SetPoint("LEFT", chkHybrid, "RIGHT", 4, 0)
chkHybrid.text:SetText("Aura truth")
chkHybrid:SetScript("OnClick", function(self)
  if Addon and Addon.SetHybridAuraTruth then
    Addon:SetHybridAuraTruth(self:GetChecked())
  end
  if UI and UI.RefreshBackendButtons then UI:RefreshBackendButtons() end
end)
self.chkHybrid = chkHybrid

-- Quick probe buttons
local btnSecret = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
btnSecret:SetSize(76, 20)
btnSecret:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -68)
btnSecret:SetText("Secret")
btnSecret:SetScript("OnClick", function()
  if Addon and Addon.TestKillingMachineSecret then Addon:TestKillingMachineSecret() end
end)

local btnAuraDump = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
btnAuraDump:SetSize(76, 20)
btnAuraDump:SetPoint("RIGHT", btnSecret, "LEFT", -6, 0)
btnAuraDump:SetText("AuraDump")
btnAuraDump:SetScript("OnClick", function()
  if Addon and Addon.AuraDumpPlayer then
    local patt
    if Addon._GetSpellNameSafe then
      patt = Addon:_GetSpellNameSafe(51124)
    end
    Addon:AuraDumpPlayer(patt)
  elseif Addon and Addon.DevLog then
    Addon:DevLog("AURA_DUMP: AuraDumpPlayer not available")
  end
  if UI and UI.RefreshLog then UI:RefreshLog() end
end)

local btnCDMDump = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
btnCDMDump:SetSize(76, 20)
btnCDMDump:SetPoint("RIGHT", btnAuraDump, "LEFT", -6, 0)
btnCDMDump:SetText("CDM Dump")
btnCDMDump:SetScript("OnClick", function()
  if Addon and Addon.CDM_DebugDump then Addon:CDM_DebugDump() end
end)

  -- Enable + verbose checkboxes
  local cbEnable = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  cbEnable:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -44)
  cbEnable.Text:SetText("Enable DevTools")
  cbEnable:SetScript("OnClick", function(btn)
    Addon:DevSetEnabled(btn:GetChecked())
  end)
  self.cbEnable = cbEnable

  local cbVerbose = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  cbVerbose:SetPoint("TOPLEFT", cbEnable, "BOTTOMLEFT", 0, -6)
  cbVerbose.Text:SetText("Verbose")
  cbVerbose:SetScript("OnClick", function(btn)
    Addon:DevSetVerbose(btn:GetChecked())
  end)
  self.cbVerbose = cbVerbose

  -- Signals TestLab controls (combat-safe; avoids chat spam)
  local labBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
  labBox:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -92)
  labBox:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -92)
  labBox:SetHeight(34)
  labBox.backdropInfo = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  }
  labBox:ApplyBackdrop()
  labBox:SetBackdropColor(0, 0, 0, 0.30)
  self.labBox = labBox

  local labTitle = labBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  labTitle:SetPoint("LEFT", labBox, "LEFT", 10, 0)
  labTitle:SetText("Signals")

  local function LabSet(which, on)
    if not (Addon and Addon.TestLab) then return end
    if which == "enabled" then
      Addon.TestLab:SetEnabled(on)
    elseif which == "aura" then
      Addon.TestLab:SetAura(on)
    elseif which == "sao" then
      Addon.TestLab:SetSAO(on)
    elseif which == "cdm" then
      Addon.TestLab:SetCDM(on)
    elseif which == "cl" then
      Addon.TestLab:SetCombatLog(on)
    end
    if UI and UI.RefreshLabControls then UI:RefreshLabControls() end
  end

  local cbLab = CreateFrame("CheckButton", nil, labBox, "UICheckButtonTemplate")
  cbLab:SetPoint("LEFT", labTitle, "RIGHT", 16, 0)
  cbLab.Text:SetText("Lab")
  cbLab:SetScript("OnClick", function(self) LabSet("enabled", self:GetChecked()) end)
  self.cbLab = cbLab

  local cbAura = CreateFrame("CheckButton", nil, labBox, "UICheckButtonTemplate")
  cbAura:SetPoint("LEFT", cbLab, "RIGHT", 50, 0)
  cbAura.Text:SetText("Aura")
  cbAura:SetScript("OnClick", function(self) LabSet("aura", self:GetChecked()) end)
  self.cbLabAura = cbAura

  local cbSAO = CreateFrame("CheckButton", nil, labBox, "UICheckButtonTemplate")
  cbSAO:SetPoint("LEFT", cbAura, "RIGHT", 55, 0)
  cbSAO.Text:SetText("SAO")
  cbSAO:SetScript("OnClick", function(self) LabSet("sao", self:GetChecked()) end)
  self.cbLabSAO = cbSAO

  local cbCDM = CreateFrame("CheckButton", nil, labBox, "UICheckButtonTemplate")
  cbCDM:SetPoint("LEFT", cbSAO, "RIGHT", 55, 0)
  cbCDM.Text:SetText("CDM")
  cbCDM:SetScript("OnClick", function(self) LabSet("cdm", self:GetChecked()) end)
  self.cbLabCDM = cbCDM

  local cbCL = CreateFrame("CheckButton", nil, labBox, "UICheckButtonTemplate")
  cbCL:SetPoint("LEFT", cbCDM, "RIGHT", 55, 0)
  cbCL.Text:SetText("CL")
  cbCL:SetScript("OnClick", function(self) LabSet("cl", self:GetChecked()) end)
  self.cbLabCL = cbCL

  local btnProbe = CreateFrame("Button", nil, labBox, "UIPanelButtonTemplate")
  btnProbe:SetSize(64, 20)
  btnProbe:SetPoint("RIGHT", labBox, "RIGHT", -10, 0)
  btnProbe:SetText("Probe")
  btnProbe:SetScript("OnClick", function()
    if Addon and Addon.TestKillingMachineSecret then Addon:TestKillingMachineSecret() end
    if UI and UI.RefreshLog then UI:RefreshLog() end
  end)
  self.btnLabProbe = btnProbe

  -- Log view
  local scroll = CreateFrame("ScrollFrame", ADDON_NAME .. "_DevLogScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", labBox, "BOTTOMLEFT", 0, -10)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 46)
  self.scroll = scroll

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(460)
  edit:SetAutoFocus(false)
  edit:EnableMouse(true)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); if UI and UI.frame then UI.frame:Hide() end end)
  scroll:SetScrollChild(edit)
  self.edit = edit

  local btnClear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnClear:SetSize(90, 22)
  btnClear:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
  btnClear:SetText("Clear")
  btnClear:SetScript("OnClick", function() Addon:DevClearLog() end)

  local btnCopy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnCopy:SetSize(90, 22)
  btnCopy:SetPoint("LEFT", btnClear, "RIGHT", 8, 0)
  btnCopy:SetText("Copy")
  btnCopy:SetScript("OnClick", function()
    if not UI.edit then return end
    UI.edit:SetText(Addon:DevGetLogText())
    UI.edit:HighlightText(0)
    UI.edit:SetFocus()
  end)

  local btnRefresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  btnRefresh:SetSize(90, 22)
  btnRefresh:SetPoint("LEFT", btnCopy, "RIGHT", 8, 0)
  btnRefresh:SetText("Refresh")
  btnRefresh:SetScript("OnClick", function() UI:RefreshLog() end)

  self:Refresh()
  self:RefreshLog()
  f:Hide()
end

function UI:Refresh()
  if not self.frame then return end
  local dt = DB()
  if not dt then return end

  self.cbEnable:SetChecked(dt.enabled and true or false)
  self.cbVerbose:SetChecked(dt.verbose and true or false)

  if self.RefreshBackendButtons then self:RefreshBackendButtons() end
  if self.RefreshLabControls then self:RefreshLabControls() end
end

function UI:RefreshLabControls()
  if not self.frame then return end
  if not (Addon and Addon.TestLab and Addon.TestLab.GetState) then return end
  local st = Addon.TestLab:GetState()
  if self.cbLab then self.cbLab:SetChecked(st.enabled) end
  if self.cbLabAura then self.cbLabAura:SetChecked(st.aura) end
  if self.cbLabSAO then self.cbLabSAO:SetChecked(st.sao) end
  if self.cbLabCDM then self.cbLabCDM:SetChecked(st.cdm) end
  if self.cbLabCL then self.cbLabCL:SetChecked(st.cl) end

  -- Convenience: if Lab is off, gray out sub-toggles (still clickable if user turns Lab on first).
  local subEnabled = st.enabled
  if self.cbLabAura then self.cbLabAura:SetEnabled(subEnabled) end
  if self.cbLabSAO then self.cbLabSAO:SetEnabled(subEnabled) end
  if self.cbLabCDM then self.cbLabCDM:SetEnabled(subEnabled) end
  if self.cbLabCL then self.cbLabCL:SetEnabled(subEnabled) end
end

function UI:RefreshLog()
  if not self.edit then return end
  self.edit:SetText(Addon:DevGetLogText())
  self.edit:HighlightText(0, 0)
end

function UI:AppendLine(line)
  if not (self.frame and self.frame:IsShown() and self.edit) then return end

  -- Queue lines and flush on a short throttle to avoid rebuilding the full text every event.
  self._pending = self._pending or {}
  self._pending[#self._pending + 1] = line

  if self._flushAttached then return end
  self._flushAttached = true
  local accum = 0
  self.frame:HookScript("OnUpdate", function(_, dt)
    if not (UI and UI._pending and #UI._pending > 0) then return end
    accum = accum + (dt or 0)
    if accum < 0.12 then return end
    accum = 0

    if not (UI.frame and UI.frame:IsShown() and UI.edit) then
      UI._pending = {}
      return
    end

    local scroll = UI.scroll
    local atBottom = true
    if scroll and scroll.GetVerticalScroll and scroll.GetVerticalScrollRange then
      local y = scroll:GetVerticalScroll()
      local range = scroll:GetVerticalScrollRange()
      atBottom = (range - y) < 30
    end

    local log = Addon and Addon._devlog
    local head = log and tonumber(log.head or 0) or 0
    local wrapped = (UI._lastHead ~= nil) and (head < UI._lastHead)
    UI._lastHead = head

    -- If the ring buffer wrapped, or too many lines queued, do a full refresh.
    if wrapped or #UI._pending > 40 then
      UI.edit:SetText(Addon:DevGetLogText())
      UI._pending = {}
    else
      local txt = UI.edit:GetText() or ""
      -- Hard cap to prevent huge strings in the widget (keep it responsive).
      if #txt > 180000 then
        UI.edit:SetText(Addon:DevGetLogText())
        UI._pending = {}
      else
        for i = 1, #UI._pending do
          txt = txt .. "\n" .. UI._pending[i]
        end
        UI._pending = {}
        UI.edit:SetText(txt)
      end
    end

    if atBottom and scroll then
      scroll:SetVerticalScroll(scroll:GetVerticalScrollRange())
    end
  end)
end


function UI:RefreshBackendButtons()
  if not self.frame then return end
  if not (self.btnAura and self.btnGlow and self.btnCDM) then return end
  if not (Addon and Addon.GetBackend) then return end

  local mode = Addon:GetBackend()
  -- Disable the currently active backend button (acts as a visual indicator)
  self.btnAura:SetEnabled(mode ~= "aura")
  self.btnGlow:SetEnabled(mode ~= "glow")
  self.btnCDM:SetEnabled(mode ~= "cdm")

  if self.lblBackend then
    self.lblBackend:SetText(string.format("Backend: %s", tostring(mode)))
  end

  if self.chkHybrid and Addon and Addon.GetHybridAuraTruth then
    self.chkHybrid:SetChecked(Addon:GetHybridAuraTruth())
  end
end

function UI:Toggle()
  if not self.frame then self:Create() end
  if not self.frame then return end
  if self.frame:IsShown() then
    self.frame:Hide()
  else
    self:Refresh()
    self:RefreshLog()
    self.frame:Show()
  end
end

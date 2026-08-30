-- KM Procs Tracker runtime owner for Retail 12.1.
--
-- Evidence contract:
--   * exact: successful player casts with accessible spell IDs;
--   * managed display: Blizzard-owned Killing Machine aura button;
--   * unavailable: proc generation, KM-attributed consumption, expiration,
--     stack count, and overcap. The addon does not infer these from aura data,
--     cooldown-viewer recycling, action-button glows, or overlay frame counts.

local ADDON_NAME, Addon = ...
_G[ADDON_NAME] = Addon

Addon.VERSION = "0.4.0"
Addon.DB_VERSION = 4
Addon.DB_NAME = "KMProcsTrackerDB"
Addon.KM_AURA_IDS = { 51124, 51128 }
Addon.KM_SPELL_ID = 51124

Addon.SPENDERS = {
  [49020] = "Obliterate",
  [207230] = "Frostscythe",
}

Addon.UNAVAILABLE_METRICS = {
  "Killing Machine proc count",
  "casts that actually consumed Killing Machine",
  "expired Killing Machine applications",
  "overcap/wasted Killing Machine applications",
  "current Killing Machine stack count",
}

local DEFAULT_DB = {
  version = Addon.DB_VERSION,
  enabled = true,
  frame = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
    scale = 1.0,
    shown = true,
    locked = false,
  },
  minimap = {
    hide = false,
    minimapPos = 220,
  },
  exact = {
    spenderCasts = 0,
    obliterateCasts = 0,
    frostscytheCasts = 0,
  },
  migration = {
    retiredApproximateCounters = false,
  },
}

local function CanAccess(value)
  if type(canaccessvalue) == "function" then
    local ok, accessible = pcall(canaccessvalue, value)
    return ok and accessible == true
  end
  if type(issecretvalue) == "function" then
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret ~= true
  end
  return true
end

local function SafeBoolean(value)
  if not CanAccess(value) or type(value) ~= "boolean" then return nil end
  return value
end

local function SafeNumber(value)
  if not CanAccess(value) or type(value) ~= "number" or value ~= value then return nil end
  return value
end

local function SafeString(value)
  if not CanAccess(value) or type(value) ~= "string" then return nil end
  return value
end

local function SafeTable(value)
  if not CanAccess(value) or type(value) ~= "table" then return nil end
  if type(issecrettable) == "function" then
    local ok, secret = pcall(issecrettable, value)
    if not ok or secret == true then return nil end
  end
  return value
end

local function SafeText(value, fallback)
  if not CanAccess(value) then return fallback or "<inaccessible>" end
  local valueType = type(value)
  if valueType == "string" then return value end
  if valueType == "number" or valueType == "boolean" then return tostring(value) end
  return fallback or "<unavailable>"
end

local function MergeDefaults(destination, source)
  destination = SafeTable(destination) or {}
  for key, value in pairs(source) do
    if type(value) == "table" then
      destination[key] = MergeDefaults(destination[key], value)
    elseif type(destination[key]) ~= type(value) then
      destination[key] = value
    end
  end
  return destination
end

local function ClampNumber(value, fallback, minimum, maximum)
  value = SafeNumber(value)
  if not value then return fallback end
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function SanitizeDB(db)
  db.version = Addon.DB_VERSION
  db.enabled = SafeBoolean(db.enabled) ~= false

  db.frame = SafeTable(db.frame) or {}
  db.frame.point = SafeString(db.frame.point) or "CENTER"
  db.frame.relativePoint = SafeString(db.frame.relativePoint) or "CENTER"
  db.frame.x = ClampNumber(db.frame.x, 0, -4000, 4000)
  db.frame.y = ClampNumber(db.frame.y, 0, -4000, 4000)
  db.frame.scale = ClampNumber(db.frame.scale, 1.0, 0.60, 3.00)
  db.frame.shown = SafeBoolean(db.frame.shown) ~= false
  db.frame.locked = SafeBoolean(db.frame.locked) == true

  db.minimap = SafeTable(db.minimap) or {}
  db.minimap.hide = SafeBoolean(db.minimap.hide) == true
  db.minimap.minimapPos = ClampNumber(db.minimap.minimapPos, 220, 0, 360)

  db.exact = SafeTable(db.exact) or {}
  db.exact.spenderCasts = math.max(0, math.floor((SafeNumber(db.exact.spenderCasts) or 0) + 0.5))
  db.exact.obliterateCasts = math.max(0, math.floor((SafeNumber(db.exact.obliterateCasts) or 0) + 0.5))
  db.exact.frostscytheCasts = math.max(0, math.floor((SafeNumber(db.exact.frostscytheCasts) or 0) + 0.5))

  db.migration = SafeTable(db.migration) or {}
  db.migration.retiredApproximateCounters = SafeBoolean(db.migration.retiredApproximateCounters) == true
end

local function MigrateLegacy(db)
  local version = SafeNumber(db.version)
  if version == Addon.DB_VERSION then return db end

  local migrated = MergeDefaults({}, DEFAULT_DB)
  local legacyFrame = SafeTable(db.frame)
  local legacyMinimap = SafeTable(db.minimap)
  if legacyFrame then
    migrated.frame.point = SafeString(legacyFrame.point) or migrated.frame.point
    migrated.frame.relativePoint = SafeString(legacyFrame.relativePoint) or migrated.frame.relativePoint
    migrated.frame.x = SafeNumber(legacyFrame.x) or migrated.frame.x
    migrated.frame.y = SafeNumber(legacyFrame.y) or migrated.frame.y
    migrated.frame.scale = SafeNumber(legacyFrame.scale) or migrated.frame.scale
    migrated.frame.shown = SafeBoolean(legacyFrame.shown)
    if migrated.frame.shown == nil then migrated.frame.shown = true end
    migrated.frame.locked = SafeBoolean(legacyFrame.locked) == true
  end
  if legacyMinimap then
    migrated.minimap.hide = SafeBoolean(legacyMinimap.hide) == true
    migrated.minimap.minimapPos = SafeNumber(legacyMinimap.minimapPos) or migrated.minimap.minimapPos
  end

  -- Previous Procs/Used/Expired/Overcap values were derived from raw aura,
  -- overlay, cooldown-viewer, and timing heuristics. They are deliberately not
  -- copied into the new exact counters.
  migrated.migration.retiredApproximateCounters = true
  return migrated
end

function Addon:GetDB()
  return self.db
end

function Addon:Chat(message)
  local text = SafeText(message, "<unavailable>")
  if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  elseif type(print) == "function" then
    print(text)
  end
end

function Addon:Chatf(formatString, ...)
  local safeFormat = SafeString(formatString)
  if not safeFormat then return end
  local ok, text = pcall(string.format, safeFormat, ...)
  self:Chat(ok and text or safeFormat)
end

function Addon:InitDB()
  local db = SafeTable(_G[self.DB_NAME]) or {}
  db = MigrateLegacy(db)
  db = MergeDefaults(db, DEFAULT_DB)
  SanitizeDB(db)
  _G[self.DB_NAME] = db
  self.db = db
end

function Addon:IsEnabled()
  return self.db and self.db.enabled == true
end

function Addon:SetEnabled(enabled)
  if not self.db then return end
  self.db.enabled = enabled == true
  if self.UI and self.UI.ApplyDB then self.UI:ApplyDB() end
  if self.UI and self.UI.SetAuraEnabled then self.UI:SetAuraEnabled(self.db.enabled) end
end

function Addon:GetEvidenceSnapshot()
  local exact = self.db and self.db.exact or DEFAULT_DB.exact
  return {
    spenderCasts = exact.spenderCasts or 0,
    obliterateCasts = exact.obliterateCasts or 0,
    frostscytheCasts = exact.frostscytheCasts or 0,
  }
end

function Addon:ResetCounters()
  if not self.db then return end
  self.db.exact.spenderCasts = 0
  self.db.exact.obliterateCasts = 0
  self.db.exact.frostscytheCasts = 0
  if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
  self:Chat("|cff8bc34aKMPT|r exact spender-cast counters reset.")
end

function Addon:RecordSuccessfulCast(spellID)
  spellID = SafeNumber(spellID)
  if not spellID or not self:IsEnabled() then return false end
  spellID = math.floor(spellID + 0.5)
  local spender = self.SPENDERS[spellID]
  if not spender then return false end

  local exact = self.db.exact
  exact.spenderCasts = exact.spenderCasts + 1
  if spellID == 49020 then
    exact.obliterateCasts = exact.obliterateCasts + 1
  elseif spellID == 207230 then
    exact.frostscytheCasts = exact.frostscytheCasts + 1
  end

  if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
  return true
end

function Addon:SetMinimapHidden(hidden)
  if not self.db then return end
  self.db.minimap.hide = hidden == true
  if self.Minimap and self.Minimap.Refresh then self.Minimap:Refresh() end
end

function Addon:SlashCommand(message)
  message = SafeString(message) or ""
  message = message:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local command, argument = message:match("^(%S+)%s*(.-)$")
  command = command or ""
  argument = argument or ""

  if command == "" then
    if self.UI and self.UI.ToggleShown then self.UI:ToggleShown() end
  elseif command == "show" then
    if self.UI then self.UI:SetShown(true) end
  elseif command == "hide" then
    if self.UI then self.UI:SetShown(false) end
  elseif command == "toggle" then
    self:SetEnabled(not self:IsEnabled())
    self:Chat("|cff8bc34aKMPT|r " .. (self:IsEnabled() and "enabled" or "disabled"))
  elseif command == "reset" then
    self:ResetCounters()
  elseif command == "lock" then
    self.db.frame.locked = true
    if self.UI then self.UI:ApplyDB() end
  elseif command == "unlock" then
    self.db.frame.locked = false
    if self.UI then self.UI:ApplyDB() end
  elseif command == "scale" then
    local value = tonumber(argument)
    if value then
      self.db.frame.scale = ClampNumber(value, self.db.frame.scale, 0.60, 3.00)
      if self.UI then self.UI:ApplyDB() end
    else
      self:Chat("KMPT: /kmpt scale 0.60..3.00")
    end
  elseif command == "minimap" then
    if argument == "show" then self:SetMinimapHidden(false)
    elseif argument == "hide" then self:SetMinimapHidden(true)
    else self:SetMinimapHidden(not self.db.minimap.hide) end
  elseif command == "status" then
    local snapshot = self:GetEvidenceSnapshot()
    self:Chatf(
      "KMPT exact casts: total=%d obliterate=%d frostscythe=%d; proc/consume/expired/overcap=unavailable",
      snapshot.spenderCasts,
      snapshot.obliterateCasts,
      snapshot.frostscytheCasts
    )
  else
    self:Chat("KMPT: /kmpt show|hide|toggle|reset|lock|unlock|scale N|minimap show|hide|status")
  end
end

Addon.Access = {
  CanAccess = CanAccess,
  SafeBoolean = SafeBoolean,
  SafeNumber = SafeNumber,
  SafeString = SafeString,
  SafeTable = SafeTable,
  SafeText = SafeText,
}

local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
if type(EventFrame.RegisterUnitEvent) == "function" then
  EventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
else
  EventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

EventFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local loadedAddon = ...
    if SafeString(loadedAddon) ~= ADDON_NAME then return end
    Addon:InitDB()
    SLASH_KMPROCSTRACKER1 = "/kmpt"
    SlashCmdList.KMPROCSTRACKER = function(message) Addon:SlashCommand(message) end
  elseif event == "PLAYER_LOGIN" then
    if not Addon.db then Addon:InitDB() end
    if Addon.UI and Addon.UI.OnLogin then Addon.UI:OnLogin() end
    if Addon.Minimap and Addon.Minimap.OnLogin then Addon.Minimap:OnLogin() end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if Addon.UI and Addon.UI.FlushPending then Addon.UI:FlushPending() end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if SafeString(unit) == "player" then Addon:RecordSuccessfulCast(spellID) end
  end
end)

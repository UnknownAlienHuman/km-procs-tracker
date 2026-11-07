-- KM Procs Tracker runtime owner for Retail 12.1.5.
--
-- Evidence contract:
--   * observed KM applications: exact stack gains and observed refreshes at cap,
--     but only while the concrete KM aura is public and readable;
--   * exact casts: successful player Obliterate/Frostscythe events;
--   * managed display: Blizzard owns icon, applications and duration;
--   * unavailable: exact loss cause and any aura interval hidden by restrictions.

local ADDON_NAME, Addon = ...
_G[ADDON_NAME] = Addon

Addon.VERSION = "0.6.0"
Addon.DB_VERSION = 5
Addon.DB_NAME = "KMProcsTrackerDB"
Addon.KM_SPELL_ID = 51124

local COUNTER_BY_SPELL = {
  [49020] = "obliterateCasts",
  [207230] = "frostscytheCasts",
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
  observed = {
    procs = 0,
    stackGains = 0,
    capRefreshes = 0,
    stackLosses = 0,
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

local VALID_POINTS = {
  TOPLEFT = true,
  TOP = true,
  TOPRIGHT = true,
  LEFT = true,
  CENTER = true,
  RIGHT = true,
  BOTTOMLEFT = true,
  BOTTOM = true,
  BOTTOMRIGHT = true,
}

local MAX_EXACT_INTEGER = 9007199254740991
local EXPIRATION_EPSILON = 0.05
local EventFrame
local runtimeEventsRegistered = false

local function CanAccess(value)
  if type(canaccessvalue) == "function" then
    local ok, accessible = pcall(canaccessvalue, value)
    return ok and accessible == true
  end
  if type(issecretvalue) == "function" then
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret == false
  end
  return false
end

local function CanAccessTable(value)
  if not CanAccess(value) or type(value) ~= "table" then return false end
  if type(canaccesstable) == "function" then
    local ok, accessible = pcall(canaccesstable, value)
    return ok and accessible == true
  end
  if type(issecrettable) == "function" then
    local ok, secret = pcall(issecrettable, value)
    return ok and secret == false
  end
  return false
end

local function SafeBoolean(value)
  if not CanAccess(value) or type(value) ~= "boolean" then return nil end
  return value
end

local function SafeNumber(value)
  if not CanAccess(value) or type(value) ~= "number" then return nil end
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function SafeInteger(value)
  value = SafeNumber(value)
  if not value or value ~= math.floor(value) then return nil end
  return value
end

local function SafeString(value)
  if not CanAccess(value) or type(value) ~= "string" then return nil end
  return value
end

local function SafeTable(value)
  if not CanAccessTable(value) then return nil end
  return value
end

local function SafeOptionalNumber(value)
  if not CanAccess(value) then return false, nil end
  if value == nil then return true, nil end
  value = SafeNumber(value)
  if value == nil then return false, nil end
  return true, value
end

local function SafeOptionalInteger(value)
  if not CanAccess(value) then return false, nil end
  if value == nil then return true, nil end
  value = SafeInteger(value)
  if value == nil then return false, nil end
  return true, value
end

local function SafeText(value, fallback)
  if not CanAccess(value) then return fallback or "<inaccessible>" end
  local valueType = type(value)
  if valueType == "string" then return value end
  if valueType == "number" or valueType == "boolean" then return tostring(value) end
  return fallback or "<unavailable>"
end

local function SafePoint(value, fallback)
  value = SafeString(value)
  if value and VALID_POINTS[value] then return value end
  return fallback
end

local function SaturatingAdd(left, right)
  if left >= MAX_EXACT_INTEGER or right >= MAX_EXACT_INTEGER - left then
    return MAX_EXACT_INTEGER
  end
  return left + right
end

local function IncrementCounter(value, amount)
  amount = amount or 1
  return SaturatingAdd(value, amount)
end

local function MergeDefaults(destination, source)
  destination = SafeTable(destination) or {}
  for key, value in pairs(source) do
    if type(value) == "table" then
      destination[key] = MergeDefaults(destination[key], value)
    else
      local current = destination[key]
      if not CanAccess(current) or type(current) ~= type(value) then
        destination[key] = value
      end
    end
  end
  return destination
end

local function ClampNumber(value, fallback, minimum, maximum)
  value = SafeNumber(value)
  if value == nil then return fallback end
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function SanitizeCounter(value)
  value = SafeNumber(value)
  if not value or value <= 0 then return 0 end
  if value > MAX_EXACT_INTEGER then value = MAX_EXACT_INTEGER end
  return math.floor(value)
end

local function CopyPreferences(source, destination)
  local enabled = SafeBoolean(source.enabled)
  local frame = SafeTable(source.frame)
  local minimap = SafeTable(source.minimap)

  if enabled ~= nil then destination.enabled = enabled end
  if frame then
    destination.frame.point = SafePoint(frame.point, destination.frame.point)
    destination.frame.relativePoint = SafePoint(frame.relativePoint, destination.frame.relativePoint)
    destination.frame.x = SafeNumber(frame.x) or destination.frame.x
    destination.frame.y = SafeNumber(frame.y) or destination.frame.y
    destination.frame.scale = SafeNumber(frame.scale) or destination.frame.scale
    local shown = SafeBoolean(frame.shown)
    if shown ~= nil then destination.frame.shown = shown end
    destination.frame.locked = SafeBoolean(frame.locked) == true
  end
  if minimap then
    destination.minimap.hide = SafeBoolean(minimap.hide) == true
    destination.minimap.minimapPos = SafeNumber(minimap.minimapPos) or destination.minimap.minimapPos
  end
end

local function SanitizeDB(db)
  db.version = Addon.DB_VERSION
  db.enabled = SafeBoolean(db.enabled) ~= false

  db.frame = SafeTable(db.frame) or {}
  db.frame.point = SafePoint(db.frame.point, "CENTER")
  db.frame.relativePoint = SafePoint(db.frame.relativePoint, "CENTER")
  db.frame.x = ClampNumber(db.frame.x, 0, -4000, 4000)
  db.frame.y = ClampNumber(db.frame.y, 0, -4000, 4000)
  db.frame.scale = ClampNumber(db.frame.scale, 1.0, 0.60, 3.00)
  db.frame.shown = SafeBoolean(db.frame.shown) ~= false
  db.frame.locked = SafeBoolean(db.frame.locked) == true

  db.minimap = SafeTable(db.minimap) or {}
  db.minimap.hide = SafeBoolean(db.minimap.hide) == true
  db.minimap.minimapPos = ClampNumber(db.minimap.minimapPos, 220, 0, 360)

  db.observed = SafeTable(db.observed) or {}
  db.observed.stackGains = SanitizeCounter(db.observed.stackGains)
  db.observed.capRefreshes = SanitizeCounter(db.observed.capRefreshes)
  db.observed.stackLosses = SanitizeCounter(db.observed.stackLosses)
  db.observed.procs = SaturatingAdd(db.observed.stackGains, db.observed.capRefreshes)

  db.exact = SafeTable(db.exact) or {}
  db.exact.obliterateCasts = SanitizeCounter(db.exact.obliterateCasts)
  db.exact.frostscytheCasts = SanitizeCounter(db.exact.frostscytheCasts)
  db.exact.spenderCasts = SaturatingAdd(db.exact.obliterateCasts, db.exact.frostscytheCasts)

  db.migration = SafeTable(db.migration) or {}
  db.migration.retiredApproximateCounters = SafeBoolean(db.migration.retiredApproximateCounters) == true
end

local function MigrateDB(db)
  local version = SafeNumber(db.version)
  if version == Addon.DB_VERSION then return db end

  local migrated = MergeDefaults({}, DEFAULT_DB)
  CopyPreferences(db, migrated)

  if version == 4 then
    local exact = SafeTable(db.exact)
    if exact then
      migrated.exact.obliterateCasts = SanitizeCounter(exact.obliterateCasts)
      migrated.exact.frostscytheCasts = SanitizeCounter(exact.frostscytheCasts)
    end
    local migration = SafeTable(db.migration)
    if migration then
      migrated.migration.retiredApproximateCounters =
        SafeBoolean(migration.retiredApproximateCounters) == true
    end
  else
    -- Schemas before v4 used heuristic aura/glow/combat-log counters. They are
    -- intentionally not promoted into the new observed or exact namespaces.
    migrated.migration.retiredApproximateCounters = true
  end

  return migrated
end

Addon.observation = {
  mode = "uninitialized",
  reason = "not-started",
  hasBaseline = false,
  present = false,
  stacks = 0,
  expirationTime = nil,
  auraInstanceID = nil,
  maxStacks = nil,
}

local function NotifyCountersChanged()
  if Addon.UI and Addon.UI.UpdateCounters then Addon.UI:UpdateCounters() end
end

local function ClearObservationBaseline()
  local observation = Addon.observation
  observation.hasBaseline = false
  observation.present = false
  observation.stacks = 0
  observation.expirationTime = nil
  observation.auraInstanceID = nil
  observation.maxStacks = nil
end

local function SetObservationMode(mode, reason)
  local observation = Addon.observation
  local changed = observation.mode ~= mode or observation.reason ~= reason
  observation.mode = mode
  observation.reason = reason
  if mode ~= "exact" then ClearObservationBaseline() end
  if changed then NotifyCountersChanged() end
end

local function ReadMaximumStacks()
  if not C_Spell or type(C_Spell.GetSpellMaxCumulativeAuraApplications) ~= "function" then
    return nil
  end
  local ok, value = pcall(C_Spell.GetSpellMaxCumulativeAuraApplications, Addon.KM_SPELL_ID)
  if not ok then return nil end
  value = SafeInteger(value)
  if not value or value < 1 or value > 255 then return nil end
  return value
end

local function NormalizeAuraSample(aura)
  local safeAura = SafeTable(aura)
  if not safeAura then return nil, nil, nil, "aura-table-inaccessible" end

  local applications = SafeInteger(safeAura.applications)
  if applications == nil or applications < 0 or applications > 255 then
    return nil, nil, nil, "applications-inaccessible"
  end
  if applications < 1 then applications = 1 end

  local expirationOK, expirationTime = SafeOptionalNumber(safeAura.expirationTime)
  if not expirationOK then return nil, nil, nil, "expiration-inaccessible" end

  local instanceOK, auraInstanceID = SafeOptionalInteger(safeAura.auraInstanceID)
  if not instanceOK or (auraInstanceID and auraInstanceID < 0) then
    return nil, nil, nil, "instance-id-inaccessible"
  end

  return applications, expirationTime, auraInstanceID, nil
end

local function ReadAuraSample()
  if not C_Secrets or type(C_Secrets.ShouldSpellAuraBeSecret) ~= "function" then
    return "unsupported", "missing-secrecy-predicate"
  end
  if not C_UnitAuras or type(C_UnitAuras.GetPlayerAuraBySpellID) ~= "function" then
    return "unsupported", "missing-player-aura-reader"
  end

  local predicateOK, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, Addon.KM_SPELL_ID)
  if not predicateOK then return "unavailable", "secrecy-predicate-error" end
  secret = SafeBoolean(secret)
  if secret == nil then return "unavailable", "secrecy-predicate-inaccessible" end
  if secret then return "restricted", "aura-secret" end

  local queryOK, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, Addon.KM_SPELL_ID)
  if not queryOK then return "unavailable", "aura-query-error" end
  if not CanAccess(aura) then return "unavailable", "aura-result-inaccessible" end

  if aura == nil then
    return "exact", "readable", false, 0, nil, nil
  end

  -- The secrecy predicate and table gate establish the public path. pcall only
  -- contains a restriction race during field extraction; it grants no access.
  local extractOK, stacks, expirationTime, auraInstanceID, failureReason =
    pcall(NormalizeAuraSample, aura)
  if not extractOK then return "unavailable", "aura-field-error" end
  if not stacks then return "unavailable", failureReason end
  return "exact", "readable", true, stacks, expirationTime, auraInstanceID
end

local function StoreObservationBaseline(present, stacks, expirationTime, auraInstanceID)
  local observation = Addon.observation
  observation.hasBaseline = true
  observation.present = present
  observation.stacks = stacks
  observation.expirationTime = expirationTime
  observation.auraInstanceID = auraInstanceID
end

function Addon:ObserveKillingMachine(forceBaseline)
  if not self.db or not self:IsEnabled() then
    SetObservationMode("disabled", "addon-disabled")
    return false
  end

  local mode, reason, present, stacks, expirationTime, auraInstanceID = ReadAuraSample()
  if mode ~= "exact" then
    SetObservationMode(mode, reason)
    return false
  end

  local observation = self.observation
  local enteringExact = observation.mode ~= "exact"
  observation.mode = "exact"
  observation.reason = "readable"
  if enteringExact then
    ClearObservationBaseline()
    observation.mode = "exact"
    observation.reason = "readable"
  end
  if forceBaseline or observation.maxStacks == nil then
    observation.maxStacks = ReadMaximumStacks()
  end

  if forceBaseline or not observation.hasBaseline then
    StoreObservationBaseline(present, stacks, expirationTime, auraInstanceID)
    NotifyCountersChanged()
    return true
  end

  -- A replacement instance while continuously present can represent several
  -- coalesced transitions. Re-baseline rather than manufacture a gain/loss.
  if observation.present and present
      and observation.auraInstanceID ~= nil and auraInstanceID ~= nil
      and observation.auraInstanceID ~= auraInstanceID then
    StoreObservationBaseline(present, stacks, expirationTime, auraInstanceID)
    NotifyCountersChanged()
    return true
  end

  local observed = self.db.observed
  local changed = false
  local delta = stacks - observation.stacks

  if delta > 0 then
    observed.stackGains = IncrementCounter(observed.stackGains, delta)
    changed = true
  elseif delta < 0 then
    observed.stackLosses = IncrementCounter(observed.stackLosses, -delta)
    changed = true
  elseif present and observation.present and stacks > 0
      and observation.maxStacks and stacks >= observation.maxStacks
      and expirationTime and observation.expirationTime
      and expirationTime > observation.expirationTime + EXPIRATION_EPSILON then
    -- At cap, a later absolute expiration time is an observable refresh. This
    -- records a lower bound: multiple refreshes coalesced into one UNIT_AURA
    -- wake-up remain one observed refresh.
    observed.capRefreshes = IncrementCounter(observed.capRefreshes)
    changed = true
  end

  if changed then
    observed.procs = SaturatingAdd(observed.stackGains, observed.capRefreshes)
  end
  StoreObservationBaseline(present, stacks, expirationTime, auraInstanceID)
  if changed then NotifyCountersChanged() end
  return true
end

local function UpdateRuntimeRegistration()
  local enabled = Addon.db and Addon.db.enabled == true
  if enabled == runtimeEventsRegistered then return end
  if enabled then
    EventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    EventFrame:RegisterUnitEvent("UNIT_AURA", "player")
  else
    EventFrame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    EventFrame:UnregisterEvent("UNIT_AURA")
  end
  runtimeEventsRegistered = enabled
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

function Addon:GetIcon()
  if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
    local ok, value = pcall(C_Spell.GetSpellTexture, self.KM_SPELL_ID)
    if ok and CanAccess(value) then
      local valueType = type(value)
      if valueType == "number" or valueType == "string" then return value end
    end
  end
  return "Interface\\Icons\\INV_Misc_QuestionMark"
end

function Addon:InitDB()
  local db = SafeTable(_G[self.DB_NAME])
  local version = db and SafeNumber(db.version)
  self.dbReadOnly = version ~= nil and version > self.DB_VERSION

  if self.dbReadOnly then
    db = nil
  elseif db then
    db = MigrateDB(db)
  end
  db = MergeDefaults(db, DEFAULT_DB)
  SanitizeDB(db)
  if not self.dbReadOnly then _G[self.DB_NAME] = db end
  self.db = db
  UpdateRuntimeRegistration()

  if self.dbReadOnly then
    self:Chat("KMPT: saved data belongs to a newer version; using temporary settings and counters without overwriting it.")
  end
end

function Addon:IsEnabled()
  return self.db and self.db.enabled == true
end

function Addon:SetEnabled(enabled)
  if not self.db then return end
  enabled = enabled == true
  if self.db.enabled == enabled then return end
  self.db.enabled = enabled
  UpdateRuntimeRegistration()
  if self.UI and self.UI.SetAuraEnabled then self.UI:SetAuraEnabled(enabled) end
  if enabled then
    self:ObserveKillingMachine(true)
  else
    SetObservationMode("disabled", "addon-disabled")
  end
end

function Addon:GetEvidenceSnapshot()
  local db = self.db or DEFAULT_DB
  local observation = self.observation
  return {
    mode = observation.mode,
    reason = observation.reason,
    maxStacks = observation.maxStacks,
    hasBaseline = observation.hasBaseline,
    observedProcs = db.observed.procs or 0,
    stackGains = db.observed.stackGains or 0,
    capRefreshes = db.observed.capRefreshes or 0,
    stackLosses = db.observed.stackLosses or 0,
    spenderCasts = db.exact.spenderCasts or 0,
    obliterateCasts = db.exact.obliterateCasts or 0,
    frostscytheCasts = db.exact.frostscytheCasts or 0,
  }
end

function Addon:ResetCounters()
  if not self.db then return end
  local observed = self.db.observed
  observed.procs = 0
  observed.stackGains = 0
  observed.capRefreshes = 0
  observed.stackLosses = 0

  local exact = self.db.exact
  exact.spenderCasts = 0
  exact.obliterateCasts = 0
  exact.frostscytheCasts = 0

  ClearObservationBaseline()
  if self:IsEnabled() then self:ObserveKillingMachine(true) end
  NotifyCountersChanged()
  self:Chat("|cff8bc34aKMPT|r counters reset.")
end

function Addon:RecordSuccessfulCast(spellID)
  spellID = SafeInteger(spellID)
  if not spellID or not self:IsEnabled() then return false end
  local counter = COUNTER_BY_SPELL[spellID]
  if not counter then return false end

  local exact = self.db.exact
  exact[counter] = IncrementCounter(exact[counter])
  exact.spenderCasts = SaturatingAdd(exact.obliterateCasts, exact.frostscytheCasts)
  NotifyCountersChanged()
  return true
end

function Addon:SetMinimapHidden(hidden)
  if not self.db then return end
  self.db.minimap.hide = hidden == true
  if self.Minimap and self.Minimap.Refresh then self.Minimap:Refresh() end
end

local MODE_TEXT = {
  exact = "readable aura observation",
  restricted = "managed display only (aura restricted)",
  unsupported = "managed display only (API unavailable)",
  unavailable = "managed display only (read failed/inaccessible)",
  disabled = "disabled",
  uninitialized = "not initialized",
}

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
    if argument == "show" then
      self:SetMinimapHidden(false)
    elseif argument == "hide" then
      self:SetMinimapHidden(true)
    else
      self:SetMinimapHidden(not self.db.minimap.hide)
    end
  elseif command == "status" then
    self:ObserveKillingMachine(false)
    local snapshot = self:GetEvidenceSnapshot()
    local build, interfaceVersion = "?", "?"
    if type(GetBuildInfo) == "function" then
      local _, rawBuild, _, rawInterface = GetBuildInfo()
      build = SafeText(rawBuild, "?")
      interfaceVersion = SafeText(rawInterface, "?")
    end
    local maxStacks = snapshot.maxStacks and tostring(snapshot.maxStacks) or "?"
    self:Chatf(
      "KMPT %s (reason=%s, max=%s, build=%s, interface=%s): observedProcs=%d gains=%d capRefreshes=%d losses=%d; casts=%d",
      MODE_TEXT[snapshot.mode] or snapshot.mode,
      snapshot.reason,
      maxStacks,
      build,
      interfaceVersion,
      snapshot.observedProcs,
      snapshot.stackGains,
      snapshot.capRefreshes,
      snapshot.stackLosses,
      snapshot.spenderCasts
    )
  else
    self:Chat("KMPT: /kmpt show|hide|toggle|reset|lock|unlock|scale N|minimap show|hide|status")
  end
end

Addon.Access = {
  CanAccess = CanAccess,
  CanAccessTable = CanAccessTable,
  SafeBoolean = SafeBoolean,
  SafeNumber = SafeNumber,
  SafeInteger = SafeInteger,
  SafeString = SafeString,
  SafeTable = SafeTable,
  SafeText = SafeText,
  SafePoint = SafePoint,
}

EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
EventFrame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
EventFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local loadedAddon = ...
    if SafeString(loadedAddon) ~= ADDON_NAME then return end
    Addon:InitDB()
    EventFrame:UnregisterEvent("ADDON_LOADED")
    SLASH_KMPROCSTRACKER1 = "/kmpt"
    SlashCmdList.KMPROCSTRACKER = function(message) Addon:SlashCommand(message) end
  elseif event == "PLAYER_LOGIN" then
    EventFrame:UnregisterEvent("PLAYER_LOGIN")
    if not Addon.db then Addon:InitDB() end
    if Addon.UI and Addon.UI.OnLogin then Addon.UI:OnLogin() end
    if Addon.Minimap and Addon.Minimap.OnLogin then Addon.Minimap:OnLogin() end
    Addon:ObserveKillingMachine(true)
  elseif event == "PLAYER_ENTERING_WORLD" then
    if Addon.db then Addon:ObserveKillingMachine(true) end
  elseif event == "PLAYER_REGEN_DISABLED" then
    if Addon.db then Addon:ObserveKillingMachine(false) end
  elseif event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
    if Addon.db then Addon:ObserveKillingMachine(true) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if Addon.UI and Addon.UI.FlushPending then Addon.UI:FlushPending() end
    if Addon.db then Addon:ObserveKillingMachine(false) end
  elseif event == "UNIT_AURA" then
    local unit = ...
    if SafeString(unit) == "player" then Addon:ObserveKillingMachine(false) end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if SafeString(unit) == "player" then Addon:RecordSuccessfulCast(spellID) end
  end
end)

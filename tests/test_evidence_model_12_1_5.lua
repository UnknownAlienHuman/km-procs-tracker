local unpackValues = table.unpack or unpack
local combat = false
local coreEventFrame
local auraContainers = {}
local registeredEvents = {}
local registeredUnitEvents = {}
local failAuraSlot = false
local nilAuraSlot = false

local SECRET = setmetatable({}, {
  __tostring = function() error("inaccessible spell ID was stringified") end,
  __index = function() error("inaccessible spell ID was indexed") end,
  __eq = function() error("inaccessible spell ID was compared") end,
  __lt = function() error("inaccessible spell ID was compared") end,
  __add = function() error("inaccessible spell ID was added") end,
})

local function assertEq(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function newRegion(objectType, parent)
  local region = {
    objectType = objectType or "Frame",
    parent = parent,
    shown = true,
    point = { "CENTER", parent, "CENTER", 0, 0 },
    scripts = {},
    setShownCalls = 0,
  }
  function region:SetFrameStrata(value) self.strata = value end
  function region:SetClampedToScreen(value) self.clamped = value end
  function region:SetMovable(value) self.movable = value end
  function region:EnableMouse(value) self.mouse = value end
  function region:RegisterForDrag(value) self.drag = value end
  function region:RegisterForClicks(value) self.clicks = value end
  function region:SetBackdrop(value) self.backdrop = value end
  function region:SetBackdropColor(...) self.backdropColor = { ... } end
  function region:SetBackdropBorderColor(...) self.backdropBorderColor = { ... } end
  function region:SetPoint(...) self.point = { ... } end
  function region:GetPoint() return unpackValues(self.point) end
  function region:ClearAllPoints() self.point = {} end
  function region:SetAllPoints(value) self.allPoints = value end
  function region:SetSize(width, height) self.width, self.height = width, height end
  function region:SetScale(value) self.scale = value end
  function region:SetScript(name, callback) self.scripts[name] = callback end
  function region:SetShown(value)
    self.setShownCalls = self.setShownCalls + 1
    self.shown = value == true
  end
  function region:Show() self.shown = true end
  function region:Hide() self.shown = false end
  function region:IsShown() return self.shown end
  function region:StartMoving() self.moving = true end
  function region:StopMovingOrSizing() self.moving = false end
  function region:SetTexture(value) self.texture = value end
  function region:SetTexCoord(...) self.texCoord = { ... } end
  function region:SetAlpha(value) self.alpha = value end
  function region:SetDesaturated(value) self.desaturated = value end
  function region:SetBlendMode(value) self.blend = value end
  function region:SetText(value) self.text = value end
  function region:CreateTexture()
    return newRegion("Texture", self)
  end
  function region:CreateFontString()
    return newRegion("FontString", self)
  end
  return region
end

local function newAuraContainer(parent)
  local container = newRegion("AuraContainer", parent)
  container.setEnabledCalls = 0
  container.addAuraSlotCalls = 0

  function container:SetUnit(unit) self.unit = unit end
  function container:SetEnabled(value)
    self.setEnabledCalls = self.setEnabledCalls + 1
    self.enabled = value == true
  end
  function container:UpdateAllAuras()
    error("addon must not manually call AuraContainer:UpdateAllAuras")
  end
  function container:AddAuraSlot(key, filter, options)
    self.addAuraSlotCalls = self.addAuraSlotCalls + 1
    if failAuraSlot then error("simulated AddAuraSlot contract failure") end
    if nilAuraSlot then return nil end
    self.key, self.filter, self.options = key, filter, options
    local button = newRegion("AuraButton", self)
    function button:SetIcon(icon) self.icon = icon end
    function button:SetApplicationCount(count, settings) self.count, self.countSettings = count, settings end
    function button:SetDurationCooldown(cooldown) self.cooldown = cooldown end
    options.initializeFrame(button)
    self.button = button
    return button
  end

  auraContainers[#auraContainers + 1] = container
  return container
end

function canaccessvalue(value) return not rawequal(value, SECRET) end
function issecretvalue(value) return rawequal(value, SECRET) end
function issecrettable() return false end
function InCombatLockdown() return combat end

AuraContainerSortMethod = { Default = 0 }
AuraContainerSortDirection = { Normal = 0 }
NumberFontNormal = "NumberFontNormal"
NumberFontNormalSmall = "NumberFontNormalSmall"
UIParent = newRegion("Frame")
SlashCmdList = {}
MenuUtil = nil
GameTooltip = nil

C_Spell = {
  GetSpellTexture = function() return 135305 end,
}

DEFAULT_CHAT_FRAME = {
  lines = {},
  AddMessage = function(self, message) self.lines[#self.lines + 1] = message end,
}

function CreateFrame(objectType, _, parent)
  local frame
  if objectType == "AuraContainer" then
    frame = newAuraContainer(parent)
  else
    frame = newRegion(objectType, parent)
  end
  function frame:RegisterEvent(event)
    registeredEvents[event] = true
  end
  function frame:RegisterUnitEvent(event, unit)
    registeredUnitEvents[event] = unit
  end
  if not parent and objectType == "Frame" and not coreEventFrame then coreEventFrame = frame end
  return frame
end

KMProcsTrackerDB = {
  enabled = true,
  frame = { point = "TOP", relativePoint = "TOP", x = 10, y = -20, scale = 1.25, shown = true, locked = false },
  minimap = { hide = true, minimapPos = 90 },
  counters = { procs = 999, used = 888, expired = 777, overcap = 666 },
}

local Addon = {}
assert(loadfile("Core.lua"))("KMProcsTracker", Addon)
assert(loadfile("UI.lua"))("KMProcsTracker", Addon)

local onEvent = assert(coreEventFrame.scripts.OnEvent)
onEvent(coreEventFrame, "ADDON_LOADED", "KMProcsTracker")
assertEq(Addon:GetDB().version, 4, "DB version")
assertEq(Addon:GetDB().exact.spenderCasts, 0, "legacy approximate counter leaked into exact data")
assertEq(Addon:GetDB().migration.retiredApproximateCounters, true, "legacy retirement marker")
assertEq(Addon:GetDB().frame.point, "TOP", "frame migration")
assertEq(Addon:GetDB().minimap.hide, true, "minimap migration")

-- Current-schema corruption is sanitized without trusting a stale aggregate.
Addon:GetDB().frame.point = "NOT_A_POINT"
Addon:GetDB().exact.spenderCasts = 999
Addon:GetDB().exact.obliterateCasts = 2
Addon:GetDB().exact.frostscytheCasts = 3
Addon:InitDB()
assertEq(Addon:GetDB().frame.point, "CENTER", "invalid anchor was not repaired")
assertEq(Addon:GetDB().exact.spenderCasts, 5, "exact aggregate was not reconciled")

local maxExactInteger = 9007199254740991
Addon:GetDB().exact.obliterateCasts = maxExactInteger
Addon:GetDB().exact.frostscytheCasts = maxExactInteger
Addon:GetDB().exact.spenderCasts = 0
Addon:InitDB()
assertEq(Addon:GetDB().exact.spenderCasts, maxExactInteger, "exact aggregate did not saturate safely")
Addon:RecordSuccessfulCast(49020)
assertEq(Addon:GetDB().exact.obliterateCasts, maxExactInteger, "exact counter exceeded the safe integer bound")
assertEq(Addon:GetDB().exact.spenderCasts, maxExactInteger, "exact aggregate exceeded the safe integer bound")
Addon:ResetCounters()

combat = true
onEvent(coreEventFrame, "PLAYER_LOGIN")
assertEq(#auraContainers, 0, "managed AuraContainer created in combat")
assertEq(Addon.UI.pendingInit, true, "managed initialization was not deferred")
assertEq(Addon.UI.pendingApply, true, "layout application was not deferred")

combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(#auraContainers, 1, "managed AuraContainer not created after combat")
local container = auraContainers[1]
assertEq(container.unit, "player", "managed unit")
assertEq(container.filter, "HELPFUL", "managed filter")
assertEq(container.options.candidateFilters.includeSpellIDs[51124], true, "primary KM ID")
assertEq(container.options.candidateFilters.includeSpellIDs[51128], true, "alternate KM ID")
assert(container.button.icon, "managed icon sink missing")
assert(container.button.count, "managed count sink missing")
assert(container.button.cooldown, "managed cooldown sink missing")
assertEq(container.enabled, true, "managed display not enabled")

combat = true
Addon.UI:SetShown(false)
assertEq(Addon.UI.frame.shown, true, "tracker visibility changed during combat")
assertEq(Addon:GetDB().frame.shown, false, "deferred tracker visibility was not persisted")
combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(Addon.UI.frame.shown, false, "deferred tracker visibility was not applied")
Addon.UI:SetShown(true)
assertEq(Addon.UI.frame.shown, true, "tracker visibility did not restore")

assertEq(registeredEvents.UNIT_AURA, nil, "UNIT_AURA must not be registered")
assertEq(registeredEvents.COMBAT_LOG_EVENT_UNFILTERED, nil, "combat log must not be registered")
assertEq(registeredUnitEvents.UNIT_SPELLCAST_SUCCEEDED, "player", "exact cast event owner")

onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 49020, 101)
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 207230)
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-3", 12345)
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "target", "cast-4", 49020)
local ok, err = pcall(onEvent, coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-5", SECRET)
assert(ok, err)

local evidence = Addon:GetEvidenceSnapshot()
assertEq(evidence.spenderCasts, 2, "exact spender total")
assertEq(evidence.obliterateCasts, 1, "exact Obliterate total")
assertEq(evidence.frostscytheCasts, 1, "exact Frostscythe total")
assertEq(Addon.UI.exactText.text, "2", "UI exact counter")

local enabledCalls = container.setEnabledCalls
combat = true
Addon:SetEnabled(false)
assertEq(container.setEnabledCalls, enabledCalls, "managed state changed during combat")
assertEq(Addon.UI.pendingAuraEnabled, false, "combat disable was not deferred")
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-6", 49020)
assertEq(Addon:GetEvidenceSnapshot().spenderCasts, 2, "disabled addon counted a cast")
combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(container.setEnabledCalls, enabledCalls + 1, "deferred disable was not applied exactly once")
assertEq(container.enabled, false, "managed display remained enabled")
local callsAfterDisable = container.setEnabledCalls
Addon.UI:ApplyDB()
assertEq(container.setEnabledCalls, callsAfterDisable, "ApplyDB redundantly reapplied managed enable state")

Addon:SetEnabled(true)
assertEq(container.enabled, true, "managed display did not re-enable")
Addon:ResetCounters()
assertEq(Addon:GetEvidenceSnapshot().spenderCasts, 0, "reset exact total")

local function resetManagedState()
  Addon.UI.auraContainer = nil
  Addon.UI.auraInitState = nil
  Addon.UI.auraUnavailable = false
  Addon.UI.appliedAuraEnabled = nil
  Addon.UI.pendingInit = false
  Addon.UI.pendingAuraEnabled = nil
end

-- A nil AddAuraSlot result is a contract failure, not a usable managed slot.
resetManagedState()
nilAuraSlot = true
local containersBeforeNil = #auraContainers
local nilFailure = Addon.UI:CreateManagedAura()
assertEq(nilFailure, false, "nil AddAuraSlot result was accepted")
assertEq(#auraContainers, containersBeforeNil + 1, "nil-slot failure did not create exactly one container")
assertEq(Addon.UI.auraInitState, "failed", "nil-slot failure state not retained")
local containersAfterNil = #auraContainers
assertEq(Addon.UI:CreateManagedAura(), false, "nil-slot failure unexpectedly retried")
assertEq(#auraContainers, containersAfterNil, "nil-slot failure leaked another AuraContainer")
nilAuraSlot = false

-- A thrown AuraContainer contract failure also fails once without leaking frames.
resetManagedState()
failAuraSlot = true
local containersBeforeFailure = #auraContainers
local firstFailure = Addon.UI:CreateManagedAura()
assertEq(firstFailure, false, "simulated AddAuraSlot failure was accepted")
assertEq(#auraContainers, containersBeforeFailure + 1, "failed init did not create exactly one container")
assertEq(Addon.UI.auraInitState, "failed", "failed init state not retained")
assertEq(Addon.UI.auraUnavailable, true, "failed init not exposed to tooltip state")
local containersAfterFailure = #auraContainers
local secondFailure = Addon.UI:CreateManagedAura()
assertEq(secondFailure, false, "failed init unexpectedly retried")
assertEq(#auraContainers, containersAfterFailure, "failed init leaked another AuraContainer")

print("PASS: Retail 12.1.5 managed display stays opaque; only accessible player spender casts become exact counters")

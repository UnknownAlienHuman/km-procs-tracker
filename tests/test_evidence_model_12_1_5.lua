local unpackValues = table.unpack or unpack
local combat = false
local coreEventFrame
local auraContainers = {}
local registeredEvents = {}
local registeredUnitEvents = {}
local failAuraSlot = false
local nilAuraSlot = false
local failCreate = false
local nilCreate = false
local failSetUnit = false
local failSetEnabled = false
local failInitialize = false
local assertions = 0

local SECRET = setmetatable({}, {
  __tostring = function() error("inaccessible spell ID was stringified") end,
  __index = function() error("inaccessible spell ID was indexed") end,
  __eq = function() error("inaccessible spell ID was compared") end,
  __lt = function() error("inaccessible spell ID was compared") end,
  __add = function() error("inaccessible spell ID was added") end,
})

local function assertEq(actual, expected, message)
  assertions = assertions + 1
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
    textWrites = 0,
    level = parent and parent.level + 1 or 0,
    children = {},
  }
  if parent then parent.children[#parent.children + 1] = region end
  function region:GetFrameLevel() return self.level end
  function region:SetFrameLevel(value) self.level = value end
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
  function region:StopMovingOrSizing()
    assert(not combat, "StopMovingOrSizing called during combat")
    self.moving = false
  end
  function region:SetTexture(value) self.texture = value end
  function region:SetTexCoord(...) self.texCoord = { ... } end
  function region:SetAlpha(value) self.alpha = value end
  function region:SetDesaturated(value) self.desaturated = value end
  function region:SetBlendMode(value) self.blend = value end
  function region:SetText(value)
    self.textWrites = self.textWrites + 1
    self.text = value
  end
  function region:CreateTexture()
    return newRegion("Texture", self)
  end
  function region:CreateFontString()
    return newRegion("FontString", self)
  end
  return region
end

-- Model the adoption boundary: every managed child method becomes inaccessible
-- after initializeFrame. This is an ownership regression, not a WoW VM emulator.
local function restrictManagedObject(region)
  for name, value in pairs(region) do
    if type(value) == "function" then
      region[name] = function() error("post-adoption managed access: " .. name) end
    end
  end
  for _, child in ipairs(region.children) do restrictManagedObject(child) end
end

local function newAuraContainer(parent)
  local container = newRegion("AuraContainer", parent)
  container.setEnabledCalls = 0
  container.addAuraSlotCalls = 0

  function container:SetUnit(unit)
    assert(not combat, "managed unit changed during combat")
    if failSetUnit then error("simulated SetUnit failure") end
    self.unit = unit
  end
  function container:SetEnabled(value)
    assert(not combat, "managed enable changed during combat")
    if failSetEnabled then error("simulated SetEnabled failure") end
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
    function button:SetApplicationCount(count, settings)
      if failInitialize then error("simulated initializeFrame failure") end
      self.count, self.countSettings = count, settings
    end
    function button:SetDurationCooldown(cooldown) self.cooldown = cooldown end
    options.initializeFrame(button)
    restrictManagedObject(button)
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
  GetSpellTexture = function(spellID)
    assertEq(spellID, 51124, "texture must use the proc aura ID")
    return 135305
  end,
}

DEFAULT_CHAT_FRAME = {
  lines = {},
  AddMessage = function(self, message) self.lines[#self.lines + 1] = message end,
}

function CreateFrame(objectType, _, parent)
  local frame
  if objectType == "AuraContainer" then
    assert(not combat, "managed container created during combat")
    if failCreate then error("simulated CreateFrame failure") end
    if nilCreate then return nil end
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
  function frame:UnregisterEvent(event)
    registeredEvents[event] = nil
    registeredUnitEvents[event] = nil
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

local brokerObjects = {}
local dbIcon = { registerCalls = 0, refreshCalls = 0 }
function dbIcon:Register(name, launcher, settings)
  self.registerCalls = self.registerCalls + 1
  self.name, self.launcher, self.settings = name, launcher, settings
end
function dbIcon:Refresh(name, settings)
  assertEq(name, self.name, "minimap refresh owner")
  self.refreshCalls = self.refreshCalls + 1
  self.settings = settings
end
local libraries = {
  ["LibDataBroker-1.1"] = {
    NewDataObject = function(_, name, object)
      assert(not brokerObjects[name], "duplicate broker launcher")
      brokerObjects[name] = object
      return object
    end,
  },
  ["LibDBIcon-1.0"] = dbIcon,
}
LibStub = { GetLibrary = function(_, name) return libraries[name] end }

local Addon = {}
assert(loadfile("Core.lua"))("KMProcsTracker", Addon)
assert(loadfile("UI.lua"))("KMProcsTracker", Addon)
assert(loadfile("Minimap.lua"))("KMProcsTracker", Addon)

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
assertEq(Addon.UI.frame, nil, "tracker was created during combat login")
assertEq(Addon.UI.pendingApply, true, "layout application was not deferred")

combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(#auraContainers, 1, "managed AuraContainer not created after combat")
local container = auraContainers[1]
assertEq(container.unit, "player", "managed unit")
assertEq(container.filter, "HELPFUL", "managed filter")
assertEq(container.options.candidateFilters.includeSpellIDs[51124], true, "primary KM ID")
assertEq(container.options.candidateFilters.includeSpellIDs[51128], nil, "passive talent must not be an aura candidate")
local candidates = 0
for _ in pairs(container.options.candidateFilters.includeSpellIDs) do candidates = candidates + 1 end
assertEq(candidates, 1, "exactly one proc aura candidate")
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

-- Bootstrap events are one-shot; disabled addons do not receive cast traffic.
assertEq(registeredEvents.ADDON_LOADED, nil, "ADDON_LOADED registration retained")
assertEq(registeredEvents.PLAYER_LOGIN, nil, "PLAYER_LOGIN registration retained")
Addon:SetEnabled(false)
assertEq(registeredUnitEvents.UNIT_SPELLCAST_SUCCEEDED, nil, "disabled cast subscription retained")
Addon:SetEnabled(true)
assertEq(registeredUnitEvents.UNIT_SPELLCAST_SUCCEEDED, "player", "cast subscription did not resume")

-- Scale the whole hierarchy, including adopted art, instead of only resizing
-- the icon and leaving its glow/fonts at an unrelated fixed physical size.
assertEq(Addon.UI.frame.scale, 1.25, "root scale")
assertEq(Addon.UI.frame.width, 44, "logical icon width")
assertEq(Addon.UI.frame.point[4] * 1.25, Addon:GetDB().frame.x, "scale-independent x")
assertEq(Addon.UI.exactText.parent.parent, Addon.UI.frame, "counter frame ownership")
assert(Addon.UI.exactText.parent.level > container.button.cooldown.level,
  "exact counter is underneath the managed icon/cooldown")
assertEq(Addon.UI.exactText.parent.mouse, false, "counter layer captures input")

local writesBefore = Addon.UI.exactText.textWrites
local getSnapshot = Addon.GetEvidenceSnapshot
Addon.GetEvidenceSnapshot = function() error("hot counter update allocated a snapshot") end
Addon.UI:ApplyDB()
assertEq(Addon.UI.exactText.textWrites, writesBefore, "unchanged counter text was rewritten")
Addon:RecordSuccessfulCast(49020)
Addon.GetEvidenceSnapshot = getSnapshot
assertEq(Addon.UI.exactText.textWrites, writesBefore + 1, "cast text was not updated")
Addon:ResetCounters()

-- A drag that ends in combat must not mutate or inspect tracker geometry until
-- the post-combat flush. A pending scale must not corrupt the saved offsets.
local frame = Addon.UI.frame
frame.scripts.OnDragStart(frame)
assertEq(frame.moving, true, "unlocked drag did not start")
frame.point = { "CENTER", UIParent, "CENTER", 12, -6 }
combat = true
Addon:SlashCommand("scale 2")
frame.scripts.OnDragStop(frame)
frame.scripts.OnDragStop(frame)
assertEq(frame.scale, 1.25, "scale changed during combat")
assertEq(Addon.UI.pendingDragStop, true, "drag stop was not deferred")
assertEq(frame.moving, true, "drag was stopped during combat")
combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(frame.moving, false, "deferred drag did not stop")
assertEq(Addon.UI.pendingDragStop, false, "drag pending flag retained")
assertEq(Addon:GetDB().frame.x, 15, "drag x used deferred scale instead of applied scale")
assertEq(Addon:GetDB().frame.y, -8, "drag y rounding")
assertEq(frame.scale, 2, "deferred scale was not applied")
assertEq(frame.point[4], 7.5, "scaled x anchor drift")
assertEq(frame.point[5], -4, "scaled y anchor drift")
Addon:SlashCommand("lock")
frame.scripts.OnDragStart(frame)
assertEq(frame.moving, false, "locked tracker moved")
Addon:SlashCommand("unlock")
frame.scripts.OnDragStart(frame)
Addon.UI:SetShown(false)
assertEq(frame.moving, false, "hidden tracker kept moving")
Addon.UI:SetShown(true)
Addon:SlashCommand("scale 99")
assertEq(frame.scale, 3, "maximum scale clamp")
Addon:SlashCommand("scale 0.01")
assertEq(frame.scale, 0.6, "minimum scale clamp")

-- Coalesce combat toggles/visibility/scale to the final ordinary desired state.
local beforeToggle = container.setEnabledCalls
combat = true
Addon:SetEnabled(false)
Addon:SetEnabled(true)
Addon:SetEnabled(false)
Addon.UI:SetShown(false)
Addon.UI:SetShown(true)
Addon:SlashCommand("scale 1")
combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(container.setEnabledCalls, beforeToggle + 1, "combat toggles were not coalesced")
assertEq(container.enabled, false, "final combat toggle was lost")
assertEq(frame.shown, true, "final visibility was lost")
assertEq(frame.scale, 1, "final scale was lost")
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(container.setEnabledCalls, beforeToggle + 1, "empty flush changed managed state")
Addon:SetEnabled(true)

-- Missing/failing access predicates are not permission to inspect game values.
local access, secret = canaccessvalue, issecretvalue
canaccessvalue = function() error("simulated access failure") end
assertEq(Addon:RecordSuccessfulCast(49020), false, "failed access predicate accepted a cast")
canaccessvalue = nil
assertEq(Addon:RecordSuccessfulCast(SECRET), false, "fallback accepted a secret")
assertEq(Addon:RecordSuccessfulCast(49020), true, "ordinary fallback rejected a cast")
issecretvalue = function() return nil end
assertEq(Addon:RecordSuccessfulCast(49020), false, "unknown secrecy result accepted a cast")
issecretvalue = nil
assertEq(Addon:RecordSuccessfulCast(49020), false, "missing predicates accepted a cast")
canaccessvalue, issecretvalue = access, secret
local beforeInvalid = Addon:GetEvidenceSnapshot().spenderCasts
for _, invalid in ipairs({ 49020.5, 207230.25, -1, 0, math.huge, -math.huge, 0/0, "49020", true, {}, SECRET }) do
  assertEq(Addon:RecordSuccessfulCast(invalid), false, "invalid spell ID was accepted")
end
assertEq(Addon:RecordSuccessfulCast(nil), false, "nil spell ID was accepted")
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", SECRET, SECRET, 49020)
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "target", SECRET, SECRET)
assertEq(Addon:GetEvidenceSnapshot().spenderCasts, beforeInvalid, "invalid events changed counters")
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, 49020)
assertEq(Addon:GetEvidenceSnapshot().spenderCasts, beforeInvalid + 1, "opaque cast GUID was consumed")

local getTexture = C_Spell.GetSpellTexture
C_Spell.GetSpellTexture = function() return SECRET end
assertEq(Addon:GetIcon(), "Interface\\Icons\\INV_Misc_QuestionMark", "inaccessible icon fallback")
C_Spell.GetSpellTexture = function() error("unavailable texture") end
assertEq(Addon:GetIcon(), "Interface\\Icons\\INV_Misc_QuestionMark", "failed icon fallback")
C_Spell.GetSpellTexture = getTexture

-- Exercise the actual minimap module against the LDB/DBIcon consumer contract.
local launcher = assert(brokerObjects.KMProcsTracker)
assertEq(dbIcon.registerCalls, 1, "minimap registration count")
Addon.Minimap:OnLogin()
assertEq(dbIcon.registerCalls, 1, "minimap registered twice")
Addon:SlashCommand("minimap hide")
assertEq(dbIcon.settings.hide, true, "minimap hide did not reach DBIcon")
Addon:SlashCommand("minimap show")
assertEq(dbIcon.settings.hide, false, "minimap show did not reach DBIcon")
local wasShown = Addon:GetDB().frame.shown
launcher.OnClick(nil, "LeftButton")
assertEq(Addon:GetDB().frame.shown, not wasShown, "minimap frame toggle")
launcher.OnClick(nil, "RightButton")
assertEq(Addon:GetEvidenceSnapshot().spenderCasts, 0, "minimap reset")
local tooltip = { lines = {} }
function tooltip:AddLine(text) self.lines[#self.lines + 1] = text end
function tooltip:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. ": " .. right end
launcher.OnTooltipShow(tooltip)
assert(table.concat(tooltip.lines, "\n"):find("unavailable", 1, true), "unavailable metrics missing from tooltip")

libraries["LibDBIcon-1.0"] = nil
local withoutDBIcon = { GetIcon = function() return 135305 end }
assert(loadfile("Minimap.lua"))("KMPTWithoutDBIcon", withoutDBIcon)
withoutDBIcon.Minimap:OnLogin()
assert(withoutDBIcon.Minimap.launcher, "LDB launcher missing without DBIcon")
assertEq(withoutDBIcon.Minimap.registered, nil, "missing DBIcon was registered")
libraries["LibDBIcon-1.0"] = dbIcon
local savedLibStub = LibStub
LibStub = nil
local withoutLibraries = {}
assert(loadfile("Minimap.lua"))("KMPTWithoutLibraries", withoutLibraries)
withoutLibraries.Minimap:OnLogin()
assertEq(withoutLibraries.Minimap.launcher, nil, "missing libraries were not tolerated")
LibStub = savedLibStub

-- Fresh installs must not claim that old heuristic counters were retired.
KMProcsTrackerDB = nil
Addon:InitDB()
assertEq(Addon:GetDB().migration.retiredApproximateCounters, false, "fresh install marked as legacy migration")
assertEq(Addon:GetDB().exact.spenderCasts, 0, "fresh counters")
Addon.UI:ApplyDB()

-- Reject inaccessible table contents and repair malformed current-schema data.
local SECRET_TABLE = setmetatable({}, { __index = function() error("secret-key table was read") end })
local secretTablePredicate = issecrettable
issecrettable = function(value) return rawequal(value, SECRET_TABLE) end
KMProcsTrackerDB = {
  version = 4, enabled = SECRET, frame = SECRET_TABLE, minimap = SECRET,
  exact = { obliterateCasts = 3.9, frostscytheCasts = math.huge, spenderCasts = SECRET },
  migration = { retiredApproximateCounters = SECRET },
}
Addon:InitDB()
assertEq(Addon:GetDB().enabled, true, "corrupt enabled state")
assertEq(Addon:GetDB().frame.point, "CENTER", "secret-key frame preferences were inspected")
assertEq(Addon:GetDB().minimap.hide, false, "secret minimap preferences were inspected")
assertEq(Addon:GetDB().exact.obliterateCasts, 3, "fractional saved count was not normalized")
assertEq(Addon:GetDB().exact.spenderCasts, 3, "non-finite/inaccessible aggregate was trusted")
assertEq(Addon:GetDB().migration.retiredApproximateCounters, false, "secret migration flag was consumed")
issecrettable = secretTablePredicate
Addon:ResetCounters()

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

failAuraSlot = false

local function expectFailedInit(label, configure)
  resetManagedState()
  configure(true)
  assertEq(Addon.UI:CreateManagedAura(), false, label .. " was accepted")
  assertEq(Addon.UI.auraInitState, "failed", label .. " failure was not retained")
  local count = #auraContainers
  Addon.UI:ApplyDB()
  assertEq(#auraContainers, count, label .. " retried on ApplyDB")
  assertEq(Addon.UI:CreateManagedAura(), false, label .. " retried explicitly")
  assertEq(#auraContainers, count, label .. " leaked another container")
  if Addon.UI.auraContainer then
    assertEq(Addon.UI.auraContainer.shown, false, label .. " container was not hidden")
  end
  configure(false)
end
expectFailedInit("CreateFrame exception", function(value) failCreate = value end)
expectFailedInit("CreateFrame nil", function(value) nilCreate = value end)
expectFailedInit("SetUnit exception", function(value) failSetUnit = value end)
expectFailedInit("initializeFrame exception", function(value) failInitialize = value end)
expectFailedInit("SetEnabled exception", function(value) failSetEnabled = value end)

-- Cancel a deferred initialization without allocating a native container.
resetManagedState()
Addon:SetEnabled(false)
combat = true
Addon:SetEnabled(true)
assertEq(Addon.UI.pendingInit, true, "combat enable did not queue initialization")
Addon:SetEnabled(false)
assertEq(Addon.UI.pendingInit, false, "combat disable did not cancel initialization")
local beforeCancel = #auraContainers
combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
assertEq(#auraContainers, beforeCancel, "cancelled initialization allocated a container")
Addon:SetEnabled(true)
assertEq(#auraContainers, beforeCancel + 1, "ordinary re-enable did not initialize")
local readyContainer = Addon.UI.auraContainer
failSetEnabled = true
Addon:SetEnabled(false)
assertEq(Addon.UI.auraInitState, "failed", "runtime enable failure was not retained")
assertEq(readyContainer.shown, false, "failed running container was not hidden")
failSetEnabled = false
Addon:SetEnabled(true)
assertEq(#auraContainers, beforeCancel + 1, "runtime failure leaked another container")
assertEq(Addon:RecordSuccessfulCast(49020), true, "display failure broke exact counters")

print("PASS: Retail 12.1.5 managed display stays opaque; only accessible player spender casts become exact counters")
print("PASS: " .. assertions .. " deterministic checks (mocked WoW API)")

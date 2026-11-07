local unpackValues = table.unpack or unpack
local checks, combat = 0, false
local coreEventFrame
local registeredEvents, registeredUnitEvents, auraContainers = {}, {}, {}
local auraSecret, auraResult, auraQueryCalls, maxStacksResult = false, nil, 0, 2
local skipInitialize, failInitialize = false, false

local SECRET = setmetatable({}, {
  __tostring = function() error("secret stringified") end,
  __eq = function() error("secret compared") end,
  __index = function() error("secret indexed") end,
})
local SECRET_TABLE = setmetatable({}, { __index = function() error("secret table indexed") end })

local function check(actual, expected, message)
  checks = checks + 1
  if actual ~= expected then
    error((message or "check failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function truth(value, message)
  checks = checks + 1
  if not value then error(message or "assertion failed", 2) end
end

local function region(kind, parent)
  local object = {
    kind = kind or "Frame", parent = parent, children = {}, scripts = {}, shown = true,
    point = { "CENTER", parent, "CENTER", 0, 0 }, level = parent and ((parent.level or 0) + 1) or 0,
    textWrites = 0,
  }
  if parent then parent.children[#parent.children + 1] = object end
  function object:GetFrameLevel() return self.level end
  function object:SetFrameLevel(v) self.level = v end
  function object:SetFrameStrata(v) self.strata = v end
  function object:SetClampedToScreen(v) self.clamped = v end
  function object:SetMovable(v) self.movable = v end
  function object:EnableMouse(v) self.mouse = v end
  function object:RegisterForDrag(v) self.drag = v end
  function object:RegisterForClicks(v) self.clicks = v end
  function object:SetBackdrop(v) self.backdrop = v end
  function object:SetBackdropColor(...) self.backdropColor = { ... } end
  function object:SetBackdropBorderColor(...) self.borderColor = { ... } end
  function object:SetPoint(...) self.point = { ... } end
  function object:GetPoint() return unpackValues(self.point) end
  function object:ClearAllPoints() self.point = {} end
  function object:SetAllPoints(v) self.allPoints = v end
  function object:SetSize(w, h) self.width, self.height = w, h end
  function object:SetScale(v) self.scale = v end
  function object:SetScript(name, fn) self.scripts[name] = fn end
  function object:SetShown(v) self.shown = v == true end
  function object:Show() self.shown = true end
  function object:Hide() self.shown = false end
  function object:IsShown() return self.shown end
  function object:StartMoving() self.moving = true end
  function object:StopMovingOrSizing() assert(not combat, "movement stopped in combat"); self.moving = false end
  function object:SetTexture(v) self.texture = v end
  function object:SetTexCoord(...) self.texCoord = { ... } end
  function object:SetAlpha(v) self.alpha = v end
  function object:SetDesaturated(v) self.desaturated = v end
  function object:SetBlendMode(v) self.blend = v end
  function object:SetText(v) self.text, self.textWrites = v, self.textWrites + 1 end
  function object:CreateTexture() return region("Texture", self) end
  function object:CreateFontString() return region("FontString", self) end
  return object
end

local function restrict(object)
  for key, value in pairs(object) do
    if type(value) == "function" then object[key] = function() error("managed access: " .. key) end end
  end
  for _, child in ipairs(object.children) do restrict(child) end
end

local function auraContainer(parent)
  local container = region("AuraContainer", parent)
  container.setEnabledCalls = 0
  function container:SetUnit(unit) assert(not combat); self.unit = unit end
  function container:SetEnabled(value) assert(not combat); self.setEnabledCalls = self.setEnabledCalls + 1; self.enabled = value == true end
  function container:UpdateAllAuras() error("manual managed refresh") end
  function container:AddAuraSlot(key, filter, options)
    self.key, self.filter, self.options = key, filter, options
    local button = region("AuraButton", self)
    function button:SetIcon(icon) self.icon = icon end
    function button:SetApplicationCount(count) if failInitialize then error("init failure") end; self.count = count end
    function button:SetDurationCooldown(cooldown) self.cooldown = cooldown end
    if not skipInitialize then pcall(options.initializeFrame, button) end
    self.button = button
    restrict(button)
    return button
  end
  auraContainers[#auraContainers + 1] = container
  return container
end

function canaccessvalue(v) return not rawequal(v, SECRET) and not rawequal(v, SECRET_TABLE) end
function canaccesstable(v) return not rawequal(v, SECRET) and not rawequal(v, SECRET_TABLE) end
function issecretvalue(v) return rawequal(v, SECRET) end
function issecrettable(v) return rawequal(v, SECRET_TABLE) end
function InCombatLockdown() return combat end
function GetBuildInfo() return "12.1.5", "70783", "Nov 2026", 120105 end

AuraContainerSortMethod, AuraContainerSortDirection = { Default = 0 }, { Normal = 0 }
NumberFontNormal, NumberFontNormalSmall = "NumberFontNormal", "NumberFontNormalSmall"
UIParent, SlashCmdList, MenuUtil, GameTooltip = region("Frame"), {}, nil, nil

C_Secrets = { ShouldSpellAuraBeSecret = function(id) check(id, 51124, "predicate id"); return auraSecret end }
C_UnitAuras = { GetPlayerAuraBySpellID = function(id) check(id, 51124, "query id"); auraQueryCalls = auraQueryCalls + 1; return auraResult end }
C_Spell = {
  GetSpellTexture = function(id) check(id, 51124, "texture id"); return 135305 end,
  GetSpellMaxCumulativeAuraApplications = function(id) check(id, 51124, "max id"); return maxStacksResult end,
}
DEFAULT_CHAT_FRAME = { lines = {}, AddMessage = function(self, message) self.lines[#self.lines + 1] = message end }

function CreateFrame(kind, _, parent)
  local frame = kind == "AuraContainer" and auraContainer(parent) or region(kind, parent)
  function frame:RegisterEvent(event) registeredEvents[event] = true end
  function frame:RegisterUnitEvent(event, unit) registeredUnitEvents[event] = unit end
  function frame:UnregisterEvent(event) registeredEvents[event], registeredUnitEvents[event] = nil, nil end
  if not parent and kind == "Frame" and not coreEventFrame then coreEventFrame = frame end
  return frame
end

local launchers = {}
local dbIcon = { registerCalls = 0 }
function dbIcon:Register(name, launcher, settings) self.registerCalls = self.registerCalls + 1; self.name, self.launcher, self.settings = name, launcher, settings end
function dbIcon:Refresh(name, settings) check(name, self.name, "DBIcon owner"); self.settings = settings end
local libraries = {
  ["LibDataBroker-1.1"] = { NewDataObject = function(_, name, object) launchers[name] = object; return object end },
  ["LibDBIcon-1.0"] = dbIcon,
}
LibStub = { GetLibrary = function(_, name) return libraries[name] end }

local function aura(applications, expirationTime, auraInstanceID)
  return { applications = applications, expirationTime = expirationTime, auraInstanceID = auraInstanceID }
end

-- Active aura at login proves the first readable sample is only a baseline.
auraResult = aura(1, 10, 100)
KMProcsTrackerDB = {
  version = 4, enabled = true,
  frame = { point = "TOP", relativePoint = "TOP", x = 10, y = -20, scale = 1.25, shown = true },
  minimap = { hide = true, minimapPos = 90 },
  exact = { obliterateCasts = 7, frostscytheCasts = 3, spenderCasts = 999 },
}

local Addon = {}
assert(loadfile("Core.lua"))("KMProcsTracker", Addon)
assert(loadfile("UI.lua"))("KMProcsTracker", Addon)
assert(loadfile("Minimap.lua"))("KMProcsTracker", Addon)
local onEvent = assert(coreEventFrame.scripts.OnEvent)

onEvent(coreEventFrame, "ADDON_LOADED", "KMProcsTracker")
check(Addon.VERSION, "0.6.0", "version")
check(Addon:GetDB().version, 5, "migration")
check(Addon:GetDB().exact.spenderCasts, 10, "cast aggregate")
check(Addon:GetDB().observed.procs, 0, "legacy leakage")
check(registeredUnitEvents.UNIT_AURA, "player", "aura owner")

combat = true
onEvent(coreEventFrame, "PLAYER_LOGIN")
check(Addon.UI.frame, nil, "combat create")
combat = false
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
check(Addon.observation.mode, "exact", "readable mode")
check(Addon:GetDB().observed.procs, 0, "baseline counted")
check(Addon.UI.auraInitState, "ready", "managed ready")
local managed = auraContainers[1]
check(managed.options.candidateFilters.includeSpellIDs[51124], true, "KM candidate")
check(managed.options.candidateFilters.includeSpellIDs[51128], nil, "passive candidate")

-- Stack gain, sub-cap refresh suppression, cap refresh, and aggregate derivation.
auraResult = aura(2, 10, 100)
onEvent(coreEventFrame, "UNIT_AURA", "player", SECRET)
check(Addon:GetEvidenceSnapshot().stackGains, 1, "stack gain")
local lossesBefore = Addon:GetEvidenceSnapshot().stackLosses
auraResult = aura(1, 20, 100)
onEvent(coreEventFrame, "UNIT_AURA", "player")
check(Addon:GetEvidenceSnapshot().capRefreshes, 0, "sub-cap refresh")
auraResult = aura(2, 20, 100)
onEvent(coreEventFrame, "UNIT_AURA", "player")
auraResult = aura(2, 30, 100)
onEvent(coreEventFrame, "UNIT_AURA", "player")
local snapshot = Addon:GetEvidenceSnapshot()
check(snapshot.capRefreshes, 1, "cap refresh")
check(snapshot.observedProcs, snapshot.stackGains + snapshot.capRefreshes, "derived observed aggregate")
truth(snapshot.stackLosses > lossesBefore, "loss not observed")

-- A live replacement instance is ambiguous and must re-baseline.
local procsBefore, replacementLosses = snapshot.observedProcs, snapshot.stackLosses
auraResult = aura(1, 40, 101)
onEvent(coreEventFrame, "UNIT_AURA", "player")
snapshot = Addon:GetEvidenceSnapshot()
check(snapshot.observedProcs, procsBefore, "replacement fabricated proc")
check(snapshot.stackLosses, replacementLosses, "replacement fabricated loss")

-- Predicate must gate the getter, and recovery must baseline rather than bridge.
local queriesBefore = auraQueryCalls
auraSecret = true
onEvent(coreEventFrame, "UNIT_AURA", "player", SECRET_TABLE)
check(Addon.observation.mode, "restricted", "restricted mode")
check(auraQueryCalls, queriesBefore, "restricted getter call")
check(Addon.UI.observedText.text, "-", "restricted marker")
auraSecret, auraResult = false, aura(2, 50, 200)
onEvent(coreEventFrame, "PLAYER_REGEN_ENABLED")
check(Addon:GetEvidenceSnapshot().observedProcs, procsBefore, "recovery bridge")

-- Unknown public maximum keeps gains but disables cap-refresh attribution.
maxStacksResult = SECRET
Addon:ObserveKillingMachine(true)
local capBefore = Addon:GetEvidenceSnapshot().capRefreshes
auraResult = aura(2, 60, 200)
Addon:ObserveKillingMachine(false)
check(Addon:GetEvidenceSnapshot().capRefreshes, capBefore, "refresh without max")
maxStacksResult = 2

-- Exact casts remain independent.
local castsBefore = Addon:GetEvidenceSnapshot().spenderCasts
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 49020)
onEvent(coreEventFrame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 207230)
check(Addon:GetEvidenceSnapshot().spenderCasts, castsBefore + 2, "casts")

-- Disabled runtime owns no hot events.
Addon:SetEnabled(false)
check(registeredUnitEvents.UNIT_AURA, nil, "disabled aura event")
check(registeredUnitEvents.UNIT_SPELLCAST_SUCCEEDED, nil, "disabled cast event")
Addon:SetEnabled(true)
check(registeredUnitEvents.UNIT_AURA, "player", "aura event resume")

-- Failed managed initialization is one-shot.
Addon.UI.auraContainer, Addon.UI.auraInitState, Addon.UI.auraUnavailable = nil, nil, false
skipInitialize = true
local containersBefore = #auraContainers
check(Addon.UI:CreateManagedAura(), false, "missing initializer accepted")
check(Addon.UI:CreateManagedAura(), false, "failed initializer retried")
check(#auraContainers, containersBefore + 1, "failed initializer leaked")
skipInitialize = false

-- Stored aggregates are derived, and future schemas are untouched.
KMProcsTrackerDB = {
  version = 5,
  observed = { procs = 999, stackGains = 2, capRefreshes = 3, stackLosses = 4 },
  exact = { spenderCasts = 999, obliterateCasts = 5, frostscytheCasts = 6 },
}
Addon:InitDB()
check(Addon:GetDB().observed.procs, 5, "observed reconciliation")
check(Addon:GetDB().exact.spenderCasts, 11, "cast reconciliation")
local future = { version = 99, future = { keep = true } }
KMProcsTrackerDB = future
Addon:InitDB()
check(KMProcsTrackerDB, future, "future root replaced")
truth(Addon:GetDB() ~= future, "future root aliased")

-- Minimap and diagnostics use the normalized model.
local launcher = launchers.KMProcsTracker
truth(launcher, "launcher missing")
check(dbIcon.registerCalls, 1, "minimap registration")
Addon:SlashCommand("status")
truth(DEFAULT_CHAT_FRAME.lines[#DEFAULT_CHAT_FRAME.lines]:find("build=70783", 1, true), "status build")

print("PASS: " .. checks .. " adaptive KM observation checks (mocked WoW API)")
return { region = region, Addon = Addon, check = check }

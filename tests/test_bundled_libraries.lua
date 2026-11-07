-- Run from the addon root. Real vendored libraries; mocked WoW frames only.
local harness = dofile("tests/test_observation_12_1_5.lua")
local oldCreateFrame = CreateFrame
local frames, callbackErrors = {}, {}
local checks = 0
local function check(actual, expected, message)
  checks = checks + 1
  assert(actual == expected, message or "library integration check failed")
end

local function extend(object)
  function object:GetParent() return self.parent end
  function object:GetWidth() return self.width or 1920 end
  function object:GetHeight() return self.height or 1080 end
  function object:GetCenter() return 1000, 800 end
  function object:GetEffectiveScale() return 1 end
  function object:SetFixedFrameStrata(value) self.fixedStrata = value end
  function object:SetFixedFrameLevel(value) self.fixedLevel = value end
  function object:SetHighlightTexture(value) self.highlight = value end
  function object:LockHighlight() self.highlightLocked = true end
  function object:UnlockHighlight() self.highlightLocked = false end
  function object:GetVertexColor()
    local color = self.color or { 1, 1, 1 }
    return color[1], color[2], color[3]
  end
  function object:SetVertexColor(...) self.color = { ... } end
  function object:HookScript(name, callback)
    local previous = self.scripts[name]
    self.scripts[name] = function(...)
      if previous then previous(...) end
      callback(...)
    end
  end
  function object:CreateTexture() return extend(harness.region("Texture", self)) end
  function object:SetOwner(owner) self.owner, self.lines = owner, {} end
  function object:AddLine(text) self.lines[#self.lines + 1] = text end
  function object:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. ": " .. right end
  function object:CreateAnimationGroup()
    local group = {}
    function group:Stop() self.playing = false end
    function group:Play() self.playing = true end
    function group:SetToFinalAlpha(value) self.toFinalAlpha = value end
    function group:CreateAnimation()
      local animation = {}
      function animation:SetOrder(value) self.order = value end
      function animation:SetDuration(value) self.duration = value end
      function animation:SetFromAlpha(value) self.fromAlpha = value end
      function animation:SetToAlpha(value) self.toAlpha = value end
      function animation:SetStartDelay(value) self.delay = value end
      return animation
    end
    return group
  end
  return object
end

function CreateFrame(kind, name, parent, template)
  local frame = extend(oldCreateFrame(kind, name, parent, template))
  frame.events = {}
  function frame:RegisterEvent(event) self.events[event] = true end
  function frame:RegisterUnitEvent(event, unit) self.events[event] = unit end
  function frame:UnregisterEvent(event) self.events[event] = nil end
  if name then _G[name] = frame end
  frames[#frames + 1] = frame
  return frame
end

local function emit(event, ...)
  if arg and arg[1] == "library-first" then
    for i = 1, #frames do
      local frame = frames[i]
      if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
    end
  else
    for i = #frames, 1, -1 do
      local frame = frames[i]
      if frame.events[event] and frame.scripts.OnEvent then frame.scripts.OnEvent(frame, event, ...) end
    end
  end
end

LibStub = nil
strmatch = string.match
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
function securecallfunction(callback, ...)
  local ok, result = pcall(callback, ...)
  if not ok then callbackErrors[#callbackErrors + 1] = result end
  return result
end
function GetCursorPosition() return 1100, 800 end
Minimap = extend(harness.region("Minimap", UIParent))
Minimap:SetSize(140, 140)
extend(UIParent)
WOW_PROJECT_MAINLINE, WOW_PROJECT_ID = 1, 1

local libraryPaths = {
  "libs/LibStub/LibStub.lua",
  "libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
  "libs/LibDataBroker-1.1/LibDataBroker-1.1.lua",
  "libs/LibDBIcon-1.0/LibDBIcon-1.0.lua",
}
for _, path in ipairs(libraryPaths) do dofile(path) end
local ldb = LibStub("LibDataBroker-1.1")
local dbIcon = LibStub("LibDBIcon-1.0")
local Addon = {}
for _, path in ipairs({ "Core.lua", "UI.lua", "Minimap.lua" }) do
  assert(loadfile(path))("KMProcsTracker", Addon)
end
KMProcsTrackerDB = { version = 5, minimap = { hide = true, minimapPos = 90 } }
emit("ADDON_LOADED", "KMProcsTracker")
emit("PLAYER_LOGIN")

local launcher = ldb:GetDataObjectByName("KMProcsTracker")
local button = dbIcon:GetMinimapButton("KMProcsTracker")
check(launcher, Addon.Minimap.launcher, "module lost the real LDB proxy")
check(launcher.type, "launcher", "LDB proxy lost attributes")
check(getmetatable(launcher), "access denied", "test did not load real LDB")
check(dbIcon.loggedIn, true, "library login did not run")
check(button.db, Addon:GetDB().minimap, "DBIcon does not own current minimap settings")
check(button.shown, false, "hidden-at-login preference lost")
check(Addon.UI.auraInitState, "ready", "UI failed with real libraries loaded")
check(Addon.observation.mode, "exact", "observation did not initialize with real libraries")

Addon:SlashCommand("minimap show")
check(button.shown, true, "minimap show did not show the real button")
check(math.floor(button.point[5] + 0.5), 75, "minimap angle not applied")
Addon:SlashCommand("minimap hide")
check(button.shown, false, "minimap hide did not hide the real button")
Addon:SlashCommand("minimap show")
Addon.Minimap:OnLogin()
check(dbIcon:GetMinimapButton("KMProcsTracker"), button, "duplicate minimap registration")
check(#dbIcon:GetButtonList(), 1, "duplicate minimap object")

local wasShown = Addon:GetDB().frame.shown
button.scripts.OnClick(button, "LeftButton")
check(Addon:GetDB().frame.shown, not wasShown, "real library left-click routing")
Addon:GetDB().observed.stackGains = 2
Addon:GetDB().observed.procs = 2
Addon:RecordSuccessfulCast(49020)
button.scripts.OnClick(button, "RightButton")
check(Addon:GetEvidenceSnapshot().observedProcs, 0, "real library observed reset")
check(Addon:GetEvidenceSnapshot().spenderCasts, 0, "real library cast reset")
button.scripts.OnEnter(button)
check(dbIcon.tooltip.owner, button, "real tooltip owner")
check(dbIcon.tooltip.shown, true, "real tooltip did not show")
check(table.concat(dbIcon.tooltip.lines, "\n"):find("observation", 1, true) ~= nil, true,
  "tooltip lost observation mode")
button.scripts.OnLeave(button)
check(dbIcon.tooltip.shown, false, "real tooltip did not hide")

-- Attribute changes traverse LDB -> CallbackHandler -> DBIcon.
launcher.icon = 135306
check(button.icon.texture, 135306, "LDB callback did not update the icon")
check(#callbackErrors, 0, "a library callback raised an error")

check(button.scripts.OnUpdate, nil, "idle minimap is polling")
button.scripts.OnDragStart(button)
check(type(button.scripts.OnUpdate), "function", "library drag loop not installed")
button.scripts.OnUpdate(button)
check(Addon:GetDB().minimap.minimapPos, 0, "library drag did not persist its angle")
button.scripts.OnDragStop(button)
check(button.scripts.OnUpdate, nil, "library drag loop not removed")
check(button.highlightLocked, false, "drag highlight remained locked")
check(button.isMouseDown, false, "drag input state remained active")

-- Re-embedding unchanged libraries preserves objects and callback ownership.
local frameCount = #frames
for _, path in ipairs(libraryPaths) do dofile(path) end
check(#frames, frameCount, "same-version library embedding allocated more frames")
check(ldb:GetDataObjectByName("KMProcsTracker"), launcher, "re-embedding replaced the proxy")
check(dbIcon:GetMinimapButton("KMProcsTracker"), button, "re-embedding replaced the button")
launcher.icon = 135307
check(button.icon.texture, 135307, "callbacks broke after re-embedding")
check(#callbackErrors, 0, "a library callback failed after re-embedding")

print("PASS: " .. checks .. " bundled-library integration checks (mocked frames; " ..
  (arg and arg[1] or "addon-first") .. ")")

-- Run from the addon root. Real vendored libraries; mocked WoW frames only.
local harness = dofile("tests/test_evidence_model_12_1_5.lua")
local oldCreateFrame = CreateFrame
local frames, callbackErrors = {}, {}
local checks = 0
local function check(actual, expected, message)
  checks = checks + 1
  assert(actual == expected, message or "library integration check failed")
end

local function extend(region)
  function region:GetParent() return self.parent end
  function region:GetWidth() return self.width or 1920 end
  function region:GetHeight() return self.height or 1080 end
  function region:GetCenter() return 1000, 800 end
  function region:GetEffectiveScale() return 1 end
  function region:SetFixedFrameStrata(value) self.fixedStrata = value end
  function region:SetFixedFrameLevel(value) self.fixedLevel = value end
  function region:SetHighlightTexture(value) self.highlight = value end
  function region:LockHighlight() self.highlightLocked = true end
  function region:UnlockHighlight() self.highlightLocked = false end
  function region:GetVertexColor()
    local color = self.color or { 1, 1, 1 }
    return color[1], color[2], color[3]
  end
  function region:SetVertexColor(...) self.color = { ... } end
  function region:HookScript(name, callback)
    local previous = self.scripts[name]
    self.scripts[name] = function(...)
      if previous then previous(...) end
      callback(...)
    end
  end
  function region:CreateTexture() return extend(harness.newRegion("Texture", self)) end
  function region:SetOwner(owner) self.owner, self.lines = owner, {} end
  function region:AddLine(text) self.lines[#self.lines + 1] = text end
  function region:AddDoubleLine(left, right) self.lines[#self.lines + 1] = left .. ": " .. right end
  function region:CreateAnimationGroup()
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
  return region
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
  -- Exercise both possible login orders; addon-first must also be safe.
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
Minimap = extend(harness.newRegion("Minimap", UIParent))
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
KMProcsTrackerDB = { version = 4, minimap = { hide = true, minimapPos = 90 } }
emit("ADDON_LOADED", "KMProcsTracker")
emit("PLAYER_LOGIN")

local launcher = ldb:GetDataObjectByName("KMProcsTracker")
local button = dbIcon:GetMinimapButton("KMProcsTracker")
check(launcher, Addon.Minimap.launcher, "module lost the real LDB proxy")
check(launcher.type, "launcher", "LDB proxy lost attributes")
check(getmetatable(launcher), "access denied", "test did not load real LDB")
check(dbIcon.loggedIn, true, "library login did not run")
check(button.db, Addon:GetDB().minimap, "DBIcon does not own the current minimap settings")
check(button.shown, false, "hidden-at-login preference lost")
check(Addon.UI.auraInitState, "ready", "UI failed with real libraries loaded")

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
Addon:RecordSuccessfulCast(49020)
button.scripts.OnClick(button, "RightButton")
check(Addon:GetEvidenceSnapshot().spenderCasts, 0, "real library right-click routing")
button.scripts.OnEnter(button)
check(dbIcon.tooltip.owner, button, "real tooltip owner")
check(dbIcon.tooltip.shown, true, "real tooltip did not show")
check(table.concat(dbIcon.tooltip.lines, "\n"):find("unavailable", 1, true) ~= nil, true, "tooltip lost evidence labels")
button.scripts.OnLeave(button)
check(dbIcon.tooltip.shown, false, "real tooltip did not hide")

-- Attribute changes traverse LDB -> CallbackHandler -> DBIcon, not a fake map.
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

-- Re-embedding unchanged libraries must preserve objects and callback ownership.
local frameCount = #frames
for _, path in ipairs(libraryPaths) do dofile(path) end
check(#frames, frameCount, "same-version library embedding allocated more frames")
check(ldb:GetDataObjectByName("KMProcsTracker"), launcher, "re-embedding replaced the proxy")
check(dbIcon:GetMinimapButton("KMProcsTracker"), button, "re-embedding replaced the button")
launcher.icon = 135307
check(button.icon.texture, 135307, "callbacks broke after re-embedding")
check(#callbackErrors, 0, "a library callback failed after re-embedding")

print("PASS: " .. checks .. " bundled-library integration checks (mocked frames; " .. (arg and arg[1] or "addon-first") .. ")")

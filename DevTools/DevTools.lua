-- DevTools/DevTools.lua
-- Optional developer tools: log buffer + filter knobs.
-- Safe to remove (also remove the two DevTools lines in the .toc).

local ADDON_NAME, Addon = ...

-- Lua compatibility: WoW's Lua environment can differ (unpack/table.unpack may be nil).
local t_unpack
do
  if type(table) == "table" and type(table.unpack) == "function" then
    t_unpack = table.unpack
  elseif type(unpack) == "function" then
    t_unpack = unpack
  else
    -- Fallback unpack (recursive; fine for small argument lists used in this addon).
    local function rec(t, i, j)
      i = i or 1; j = j or #t
      if i > j then return end
      return t[i], rec(t, i + 1, j)
    end
    t_unpack = rec
  end
end

local DEFAULT_FILTER = {
  -- Glow backend filters
  microDedup = 0.020,
  creditThreshold = 0.99,
  secondaryDedup = 0.12,
  -- If true, allow SAO ShowOverlay to count procs even at 0 stacks.
  -- Usually disabled to avoid spam; first stack is best counted by SpellActivationAlert.
  saoAtZero = false,
  -- Force-enable SAO tick source even when SpellActivationAlert hooks exist.
  forceSAO = false,
}

local DEFAULT_DB = {
  enabled = false,
  verbose = false,
  filter = DEFAULT_FILTER,
  maxLines = 800,
}

local function EnsureDB()
  local db = Addon:GetDB()
  db.devtools = db.devtools or {}
  for k, v in pairs(DEFAULT_DB) do
    if db.devtools[k] == nil then
      if type(v) == "table" then
        local t = {}
        for k2, v2 in pairs(v) do t[k2] = v2 end
        db.devtools[k] = t
      else
        db.devtools[k] = v
      end
    end
  end
  db.devtools.filter = db.devtools.filter or {}
  for k, v in pairs(DEFAULT_FILTER) do
    if db.devtools.filter[k] == nil then db.devtools.filter[k] = v end
  end
  return db.devtools
end


-- Secret-safe string helpers (Midnight)
local function IsSecret(v)
  return (type(issecretvalue) == "function") and issecretvalue(v)
end

local function SafeToString(v)
  if v == nil then return "nil" end
  if IsSecret(v) then return "<secret>" end
  local tv = type(v)
  if tv == "string" then return v end
  if tv == "number" or tv == "boolean" then return tostring(v) end
  local ok, s = pcall(tostring, v)
  if ok and (not IsSecret(s)) and type(s) == "string" then return s end
  return "<" .. tv .. ">"
end

local function SafeFormat(fmt, ...)
  if select('#', ...) == 0 then
    return SafeToString(fmt)
  end
  local args = { ... }
  for i = 1, #args do
    args[i] = SafeToString(args[i])
  end
	local ok, s = pcall(string.format, fmt, t_unpack(args))
  if ok and (not IsSecret(s)) and type(s) == "string" then return s end
  -- Fallback: avoid throwing, keep logs usable
  local out = { SafeToString(fmt) }
  for i = 1, #args do out[#out + 1] = args[i] end
  return table.concat(out, " ")
end

Addon._devlog = Addon._devlog or { buf = {}, head = 0, count = 0 }

function Addon:DevToolsEnabled()
  local dt = EnsureDB()
  return dt.enabled and true or false
end

function Addon:DevToolsVerbose()
  local dt = EnsureDB()
  return dt.verbose and true or false
end

function Addon:DevToolsFilter()
  local dt = EnsureDB()
  return dt.filter
end

function Addon:DevSetEnabled(v)
  local dt = EnsureDB()
  dt.enabled = v and true or false
  if self.DevToolsUI and self.DevToolsUI.Refresh then
    self.DevToolsUI:Refresh()
  end
end

function Addon:DevSetVerbose(v)
  local dt = EnsureDB()
  dt.verbose = v and true or false
  if self.DevToolsUI and self.DevToolsUI.Refresh then
    self.DevToolsUI:Refresh()
  end
end

function Addon:DevLog(fmt, ...)
  if not self:DevToolsEnabled() then return end
  return self:DevLogForce(fmt, ...)
end

-- Force-log even if DevTools are disabled.
-- Use for interactive diagnostic modules (TestLab) where chat output is unreliable in combat.
function Addon:DevLogForce(fmt, ...)
  local dt = EnsureDB()
  local maxLines = tonumber(dt.maxLines or 800) or 800
  if maxLines < 100 then maxLines = 100 end

  local line
  line = SafeFormat(fmt, ...)
  local ts = date("%H:%M:%S")
  line = string.format("[%s] %s", ts, line)
  -- Ensure the log buffer contains only plain strings (never secret values).
  line = SafeToString(line)
  if type(line) ~= "string" then line = tostring(line) end

  local log = self._devlog
  log.head = (log.head % maxLines) + 1
  log.buf[log.head] = line
  log.count = math.min((log.count or 0) + 1, maxLines)

  if self.DevToolsUI and self.DevToolsUI.AppendLine then
    self.DevToolsUI:AppendLine(line)
  end
end

function Addon:DevClearLog()
  local log = self._devlog
  log.buf = {}
  log.head = 0
  log.count = 0
  if self.DevToolsUI and self.DevToolsUI.RefreshLog then
    self.DevToolsUI:RefreshLog()
  end
end

function Addon:DevGetLogText()
  local log = self._devlog
  local n = log.count or 0
  local max = tonumber((EnsureDB().maxLines or 800)) or 800
  if n <= 0 then return "" end
  local out = {}
  local start = log.head - n + 1
  if start < 1 then start = start + max end
  for i = 0, n - 1 do
    local idx = start + i
    if idx > max then idx = idx - max end
    local line = log.buf[idx]
    if line ~= nil then out[#out + 1] = SafeToString(line) end
  end
  return table.concat(out, "\n")
end

function Addon:ToggleDevToolsUI()
  if self.DevToolsUI and self.DevToolsUI.Toggle then
    self.DevToolsUI:Toggle()
  end
end

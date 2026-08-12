-- Core.lua
-- KM Procs Tracker — robust hybrid
-- Stacks truth: UNIT_AURA (reliable local state)
-- Overcap procs: COMBAT_LOG aura refresh/dose at cap, confirmed next tick to avoid race
--
-- Definitions:
--  Procs   = all proc events in window (stack gains + overcap procs)
--  Used    = stacks consumed by Obliterate/Frostscythe
--  Expired = stack losses not attributed to spender
--  Wasted  = Expired + Overcap
--
-- Flash "Wasted" on: Overcap AND Expired.

local ADDON_NAME, Addon = ...
_G[ADDON_NAME] = Addon

-- Killing Machine spell/aura identifiers.
--
-- In multiple Retail builds the *buff aura* has historically been 51124.
-- Some internal overlays / tooltips may reference nearby IDs (e.g. 51128).
-- To keep the addon resilient across builds, we treat KM as a *set* of IDs.
Addon.KM_AURA_IDS = { 51124, 51128 }
Addon.KM_SPELL_ID = 51124 -- legacy/compat: primary aura id
Addon.DB_NAME = "KMProcsTrackerDB"

local KM_SPENDERS = {
	[49020]  = true, -- Obliterate
	[207230] = true, -- Frostscythe
}

-- Extra KM sources / context (Frost DK)
-- Note: spellIDs here are stable across Retail; update if Blizzard changes them.
local SPELL_EMPOWERED_RUNE_WEAPON = 47568
local SPELL_PILLAR_OF_FROST       = 51271
local SPELL_FROST_STRIKE          = 49143
local SPELL_HOWLING_BLAST         = 49184
local SPELL_GLACIAL_ADVANCE       = 194913

-- Pillar of Frost duration (seconds). We track it locally to avoid aura-secret pitfalls.
-- If your build modifies PoF duration, you can bump this value.
local POF_DURATION = 18.0

-- window for matching stack drop to spender cast (latency/order tolerant)
local SPEND_WINDOW = 1.40

-- overcap dedup + race filter windows
local OVERCAP_DEDUP = 0.10
local GAIN_RACE_WINDOW = 0.20

Addon.state = {
	playerGUID = nil,

	inCombat = false,
	sessionActive = false,
	manualPaused = false,

	stacks = 0,

	-- backend: "aura", "glow", or "cdm"
	backend = "aura",

	-- glow backend state
	glowPrimarySpellId = nil,
	glowActive = false,
	-- Hybrid mode: keep UNIT_AURA as authoritative even when backend is not "aura".
	-- Midnight often makes proc auras SECRET/unreadable; default is OFF.
	hybridAuraTruth = false,
	-- Swing-credit filter (token bucket). Can reduce SAO spam but may drop valid signals; default OFF.
	useCreditFilter = false,
	lastProcSignalAt = 0,
	lastGlowHideAt = 0,

	-- attack speed cache (for proc-signal filtering; dual-wield aware)
	attackSpeedMH = 0,
	attackSpeedOH = 0,
	attackSpeedAt = 0,

	-- local Pillar of Frost window + cast-trigger budget for extra KM sources
	pofUntil = 0,
	procBudget = 0,
	procBudgetUntil = 0,
	procBudgetReason = nil,

	-- optional action-bar fallback (slot->spellId), only used if enabled
	actionSlotToSpell = nil,	-- [slot]=spellId

	-- spender inference
	spendTokens = 0,
	lastSpenderAt = 0,

	-- retro-fix if aura loss arrives before cast log
	pendingLoss = 0,
	pendingLossAt = 0,

	-- stack gain timestamp for overcap disambiguation
	lastStackGainAt = 0,

	-- overcap handling
	lastOvercapAt = 0,
	overcapPending = false,
}

-- Helper: membership test for KM aura/spell identifiers.
function Addon:IsKMAuraSpellId(spellId)
	if spellId == nil then return false end
	-- Avoid touching secret values (Midnight). If it is secret, we can't use it safely.
	if type(issecretvalue) == "function" and issecretvalue(spellId) then
		return false
	end
	local n = tonumber(spellId)
	if not n then return false end
	for _, id in ipairs(self.KM_AURA_IDS or {}) do
		if id == n then return true end
	end
	return false
end

Addon.counters = {
	procs = 0,
	used = 0,
	expired = 0,
	wasted = 0,
	overcap = 0,

	-- compatibility alias
	consumed = 0, -- == used
}

-- ----------------------------
-- SavedVariables defaults
-- ----------------------------
local function ApplyDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then dst[k] = {} end
			ApplyDefaults(dst[k], v)
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end


-- ----------------------------
-- Chat output helper (prints reliably to the default chat frame)
-- ----------------------------
function Addon:Chat(msg)
	msg = tostring(msg or "")
	if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage(msg)
	else
		print(msg)
	end
end

function Addon:Chatf(fmt, ...)
	self:Chat(string.format(fmt, ...))
end

-- ----------------------------
-- Secret Value helpers (Midnight)
-- Keep these global and minimal so other modules can use them without requiring dependencies.
-- ----------------------------
function KMPT_IsSecret(v)
	return (type(issecretvalue) == "function") and issecretvalue(v)
end

function KMPT_SafeToString(v)
	if KMPT_IsSecret(v) then return "<secret>" end
	return tostring(v)
end

function KMPT_SafeStacks(v)
	-- If stacks are secret, we can only say "present" (1). We cap to [0..2] because KM max is 2.
	if v == nil then return 0 end
	if KMPT_IsSecret(v) then return 1 end
	local n = tonumber(v) or 0
	if n < 0 then n = 0 end
	if n > 2 then n = 2 end
	return n
end

-- Convert to a plain Lua number only if it is safe.
-- Returns nil when the value is secret (or non-numeric), so callers can fall back to a non-secret source.
local function KMPT_TryNumber(v)
	if v == nil then return nil end
	if KMPT_IsSecret(v) then return nil end
	local n = tonumber(v)
	if type(n) ~= "number" then return nil end
	return n
end

-- ----------------------------
-- Debug (ring buffer in SavedVariables)
-- ----------------------------
local function DBG_GetStore()
	local db = _G[Addon.DB_NAME]
	if type(db) ~= "table" then return nil end
	if type(db.debug) ~= "table" then
		db.debug = { enabled = false, verbose = false, max = 600, buf = {}, head = 1, count = 0 }
	end
	db.debug.max = db.debug.max or 600
	db.debug.buf = db.debug.buf or {}
	db.debug.head = db.debug.head or 1
	db.debug.count = db.debug.count or 0
	return db.debug
end

function Addon:DbgEnabled()
	local dbg = DBG_GetStore()
	return dbg and dbg.enabled
end

function Addon:DbgVerbose()
	local dbg = DBG_GetStore()
	return dbg and dbg.verbose
end

function Addon:DbgAdd(line)
	local dbg = DBG_GetStore()
	if not dbg or not dbg.enabled then return end
	local max = dbg.max or 600
	local buf = dbg.buf
	local head = dbg.head or 1

	buf[head] = line
	head = head + 1
	if head > max then head = 1 end
	dbg.head = head
	dbg.count = math.min(max, (dbg.count or 0) + 1)
	-- Optional: echo debug lines to chat (can be noisy).
	if dbg.chat then
		-- Basic throttle to avoid client spam protection
		local now = GetTime()
		local last = tonumber(self.state._dbgChatLastAt or 0) or 0
		if (now - last) > 0.02 then
			self.state._dbgChatLastAt = now
			self:Chat("|cff8bc34aKMPT|r " .. line)
		end
	end
end

function Addon:Dbg(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	if not ok then msg = tostring(fmt) end
	self:DbgAdd(string.format("[%.3f] %s", GetTime(), msg))
end

-- Rate-limited counters for very spammy hooks
function Addon:DbgRate(tag, spellId)
	local dbg = DBG_GetStore()
	if not dbg or not dbg.enabled then return end

	self.state._dbgRate = self.state._dbgRate or {}
	local rt = self.state._dbgRate[tag]
	if type(rt) ~= "table" then
		rt = { sec = 0, total = 0, by = {} }
		self.state._dbgRate[tag] = rt
	end

	local sec = math.floor(GetTime())
	if rt.sec ~= 0 and sec ~= rt.sec then
		-- flush previous second summary
		local parts = {}
		for id, n in pairs(rt.by) do
			parts[#parts+1] = tostring(id) .. ":" .. tostring(n)
		end
		table.sort(parts)
		self:DbgAdd(string.format("[%.3f] %s/sec=%d total=%d spells={%s}", GetTime(), tag, rt.sec, rt.total, table.concat(parts, ",")))
		rt.total = 0
		rt.by = {}
	end

	rt.sec = sec
	rt.total = rt.total + 1
	if spellId then
		rt.by[spellId] = (rt.by[spellId] or 0) + 1
	end
end

function Addon:DbgClear()
	local dbg = DBG_GetStore()
	if not dbg then return end
	dbg.buf = {}
	dbg.head = 1
	dbg.count = 0
	self:Dbg("debug cleared")
end

function Addon:DbgDump(n)
	local dbg = DBG_GetStore()
	if not dbg then return end
	-- flush pending rate buckets
	if type(self.state._dbgRate) == "table" then
		for tag, rt in pairs(self.state._dbgRate) do
			if type(rt) == "table" and rt.sec and rt.total and rt.total > 0 then
				local parts = {}
				for id, n2 in pairs(rt.by or {}) do
					parts[#parts+1] = tostring(id) .. ":" .. tostring(n2)
				end
				table.sort(parts)
				self:DbgAdd(string.format("[%.3f] %s/sec=%d total=%d spells={%s}", GetTime(), tag, rt.sec, rt.total, table.concat(parts, ",")))
				rt.total = 0
				rt.by = {}
			end
		end
	end
	n = tonumber(n) or 60
	local count = math.min(dbg.count or 0, n)
	if count <= 0 then
		self:Chat("KMPT: debug buffer empty")
		return
	end

	local max = dbg.max or 600
	local head = dbg.head or 1
	local start = head - count
	while start <= 0 do start = start + max end

	self:Chat(string.format("KMPT: dumping last %d debug lines", count))
	for i = 0, count-1 do
		local idx = start + i
		if idx > max then idx = idx - max end
		local line = dbg.buf[idx]
		if line then self:Chat(line) end
	end
end

-- Debug hooks (never used for counting; only for diagnostics)
function Addon:InitDebugHooks()
	if self.state._dbgHooksInited then return end
	self.state._dbgHooksInited = true

	-- ActionButton overlay glow hooks (can be very spammy; only rate-log unless verbose)
	if type(ActionButton_ShowOverlayGlow) == "function" then
		hooksecurefunc("ActionButton_ShowOverlayGlow", function(btn)
			if not Addon:DbgEnabled() then return end
			local spellId
			local action = btn and (btn.action or (btn.GetAttribute and btn:GetAttribute("action")))
			if action then
				local t, id = GetActionInfo(action)
				if t == "spell" then
					spellId = id
				elseif t == "macro" and id then
					spellId = GetMacroSpell(id)
				end
			end
			Addon:DbgRate("AB_SHOW", spellId)
			if Addon:DbgVerbose() then
				Addon:Dbg("AB_SHOW action=%s spellId=%s btn=%s", tostring(action), tostring(spellId), btn and (btn.GetName and btn:GetName() or tostring(btn)) or "nil")
			end
		end)
	end

	if type(ActionButton_HideOverlayGlow) == "function" then
		hooksecurefunc("ActionButton_HideOverlayGlow", function(btn)
			if not Addon:DbgEnabled() then return end
			local spellId
			local action = btn and (btn.action or (btn.GetAttribute and btn:GetAttribute("action")))
			if action then
				local t, id = GetActionInfo(action)
				if t == "spell" then
					spellId = id
				elseif t == "macro" and id then
					spellId = GetMacroSpell(id)
				end
			end
			Addon:DbgRate("AB_HIDE", spellId)
			if Addon:DbgVerbose() then
				Addon:Dbg("AB_HIDE action=%s spellId=%s btn=%s", tostring(action), tostring(spellId), btn and (btn.GetName and btn:GetName() or tostring(btn)) or "nil")
			end
		end)
	end

	-- SpellActivationOverlayFrame method hooks (if available)
	if SpellActivationOverlayFrame and type(SpellActivationOverlayFrame.ShowOverlay) == "function" then
		hooksecurefunc(SpellActivationOverlayFrame, "ShowOverlay", function(_, spellId)
			if not Addon:DbgEnabled() then return end
			Addon:DbgRate("SAO_ShowOverlay", spellId)
			if Addon:DbgVerbose() then
				Addon:Dbg("SAO_ShowOverlay spellId=%s", tostring(spellId))
			end
		end)
	end
	if SpellActivationOverlayFrame and type(SpellActivationOverlayFrame.HideOverlay) == "function" then
		hooksecurefunc(SpellActivationOverlayFrame, "HideOverlay", function(_, spellId)
			if not Addon:DbgEnabled() then return end
			Addon:DbgRate("SAO_HideOverlay", spellId)
			if Addon:DbgVerbose() then
				Addon:Dbg("SAO_HideOverlay spellId=%s", tostring(spellId))
			end
		end)
	end
end

function Addon:SlashCommand(msg)
	msg = (msg or ""):lower()
	local a, b = msg:match("^(%S+)%s*(.*)$")
	a = a or ""
	b = b or ""

	-- help / empty
	if a == "" or a == "help" then
		self:Chat("KMPT commands:")
		self:Chat("  /kmpt backend glow|cdm|aura")
		self:Chat("  /kmpt devtools")
		self:Chat("  /kmpt secret")
		self:Chat("  /kmpt lab ...    (test module / probes)")
		self:Chat("  /kmpt cltest     (disabled in Midnight)")
			self:Chat("  /kmpt debug ...")
		return
	end


	if a == "minimap" or a == "icon" then
		local want = (b or ""):match("^(%S+)") or ""
		local mm = self.Minimap
		local db = self:GetDB()
		if not (mm and mm.SetIconHidden and db and db.minimap) then
			self:Chat("KMPT: minimap module not ready.")
			return
		end

		if want == "" or want == "toggle" then
			mm:SetIconHidden(not (db.minimap.hide and true or false))
		elseif want == "show" then
			mm:SetIconHidden(false)
		elseif want == "hide" then
			mm:SetIconHidden(true)
		elseif want == "reset" then
			db.minimap.hide = false
			if type(db.minimap.minimapPos) ~= "number" then db.minimap.minimapPos = 220 end
			mm:OnLogin()
		else
			self:Chat("KMPT: /kmpt minimap show|hide|toggle|reset")
			return
		end

		self:Chat("KMPT: minimap hide=" .. tostring(db.minimap.hide))
		return
	end

	if a == "backend" or a == "mode" then
		local want = (b or ""):match("^(%S+)") or ""
		if want == "" then
			self:Chat("KMPT: backend is " .. tostring(self:GetBackend()))
			self:Chat("KMPT: available: glow, cdm, aura")
			return
		end
		-- aliases
		if want == "cooldown" or want == "cooldownmanager" or want == "cd" then want = "cdm" end
		if want ~= "glow" and want ~= "cdm" and want ~= "aura" then
			self:Chat("KMPT: unknown backend: " .. tostring(want))
			return
		end
		self:SetBackend(want)
		self:Chat("KMPT: backend set to " .. tostring(want))
		return
	end

	if a == "secret" or a == "test" then
		if self.TestKillingMachineSecret then
			self:TestKillingMachineSecret()
		else
			self:Chat("KMPT: secret probe not available")
		end
		return
	end

	if a == "lab" or a == "testlab" or a == "testmodule" then
		if self.TestLab and self.TestLab.Slash then
			self.TestLab:Slash(b)
		else
			self:Chat("KMPT: TestLab not loaded (TestLab.lua missing)")
		end
		return
	end

	if a == "cltest" or a == "cl" then
		-- Midnight (12.0+): COMBAT_LOG_EVENT_UNFILTERED is restricted and cannot be used safely.
		-- We keep the probe toggle for compatibility with older builds, but on Midnight we
		-- treat it as a no-op and explain why.
		self:Chat("KMPT: combat log (CLEU) is restricted in Midnight (12.0+) — cltest is disabled.")
		return
	end

	if a == "auradump" or a == "auras" then
		local patt = (b or ""):gsub("^%s+",""):gsub("%s+$","")
		if patt == "" then patt = nil end
		if self.AuraDumpPlayer then
			self:AuraDumpPlayer(patt)
		else
			self:Chat("KMPT: AuraDump not available")
		end
		return
	end

	if a == "devtools" or a == "dev" then
		if self.DevToolsUI and self.DevToolsUI.Toggle then
			self.DevToolsUI:Toggle()
		else
			self:Chat("KMPT: DevTools UI not available.")
		end
		return
	end


	-- Cooldown Viewer helpers
	if a == "cdm" or a == "cooldownviewer" then
		local cmd = (b or ""):match("^(%S+)") or ""
		if cmd == "dump" then
			if self.CDM_DebugDump then
				self:CDM_DebugDump()
			else
				self:Chat("KMPT: CDM backend not loaded.")
			end
			return
		end
		self:Chat("KMPT: /kmpt cdm dump")
		return
	end

	if a == "debug" or a == "dbg" then
		local dbg = DBG_GetStore()
		if not dbg then return end

		local cmd, rest = b:match("^(%S+)%s*(.*)$")
		cmd = cmd or ""

		if cmd == "" or cmd == "toggle" then
			dbg.enabled = not dbg.enabled
				dbg.chat = dbg.enabled and true or false
			self:Chat("KMPT: debug " .. (dbg.enabled and "ON" or "OFF"))
			if dbg.enabled then self:InitDebugHooks() end
			return
		end
		if cmd == "on" then
			dbg.enabled = true
				dbg.chat = true
			self:Chat("KMPT: debug ON")
			self:InitDebugHooks()
			return
		end
		if cmd == "off" then
			dbg.enabled = false
				dbg.chat = false
			self:Chat("KMPT: debug OFF")
			return
		end
		if cmd == "verbose" then
			if rest == "" or rest == "toggle" then
				dbg.verbose = not dbg.verbose
			elseif rest == "on" then
				dbg.verbose = true
			elseif rest == "off" then
				dbg.verbose = false
			end
			self:Chat("KMPT: debug verbose " .. (dbg.verbose and "ON" or "OFF"))
			return
		end
		if cmd == "dump" then
			self:DbgDump(rest)
			return
		end
		if cmd == "clear" then
			self:DbgClear()
			return
		end
		if cmd == "status" then
			self:Chat(string.format("KMPT: debug=%s verbose=%s max=%d count=%d",
				tostring(dbg.enabled), tostring(dbg.verbose), tonumber(dbg.max or 0), tonumber(dbg.count or 0)))
			return
		end

		self:Chat("KMPT debug commands: on|off|toggle, verbose [on|off|toggle], dump [N], clear, status")
		return
	end

	self:Chat("KMPT: unknown command. Try: /kmpt help")
end

local DEFAULT_DB = {
	backend = "aura",
	hybridAuraTruth = false,
	spenders = {
		-- If true, spenders consume ALL available KM stacks in one cast (some builds/talents).
		-- Default is one stack per cast (standard 2-charge KM behavior).
		consumeAllStacks = false,
	},
	glow = {
		-- Enable only for investigation; may produce proc spam on some clients.
		allowAltOverlay438833 = false,
	},
	cdm = {
		-- How often we try to locate the KM icon inside BuffIconCooldownViewer until it is found.
		scanInterval = 0.50,
		-- Dedup window for per-proc UI pulses (Cooldown:SetCooldown can fire multiple times per single proc).
		procMinInterval = 0.14,
		-- Dedup window for cap-refresh pulses (overcap detection) coming from Cooldown:SetCooldown().
		overcapMinInterval = 0.18,
		-- Debug-only assist flags (default OFF).
		-- Text hooks can double-count because CDM icons are recycled and stack text can be secret/missing.
		useTextHooks = false,
		-- These two heuristics can cause stacks to freeze if aura presence is misdetected.
		ignoreZeroIfAuraPresent = false,
		ignoreHideConfirmIfAuraPresent = false,
	},
	minimap = { hide = false, minimapPos = 220 },
	frame = {
		point = "CENTER",
		relativeTo = nil,
		relativePoint = "CENTER",
		x = 0, y = 0,
		scale = 1.0,
		shown = true,
		locked = false,
	},
	devtools = {
		enabled = false,
		verbose = false,
		maxLines = 600,
		filter = {
			microDedup = 0.020,
			creditThreshold = 0.99,
			secondaryDedup = 0.12,
			saoAtZero = false,
		},
	},
}

function Addon:GetDB()
	return _G[self.DB_NAME]
end


-- ----------------------------
-- DevTools filter tuning (optional module)
-- ----------------------------
function Addon:GetDevFilterValue(key, default)
	if type(key) ~= "string" then return default end
	if self.DevToolsFilter then
		local f = self:DevToolsFilter()
		if type(f) == "table" then
			local v = f[key]
			if type(default) == "boolean" then
				if v == nil then return default end
				return v and true or false
			else
				local n = tonumber(v)
				if n ~= nil then return n end
			end
		end
	end
	return default
end

-- ----------------------------
-- Control
-- ----------------------------
function Addon:IsCountingGains()
	return self.state.inCombat and (not self.state.manualPaused)
end

function Addon:IsCountingLosses()
	return self.state.sessionActive and (not self.state.manualPaused)
end

function Addon:IsTrackingEnabled()
	return self:IsCountingGains()
end

function Addon:SetManualPaused(paused)
	self.state.manualPaused = paused and true or false
end

function Addon:GetBackend()
	local db = self:GetDB()
	local defaultMode = "aura"
	local iface = select(4, GetBuildInfo())
	if type(iface) == "number" and iface >= 120000 then defaultMode = "glow" end
	-- NOTE: Do NOT auto-migrate user choice on every login. Default only applies when no setting exists.
	local mode = (db and db.backend) or self.state.backend or defaultMode
	if mode ~= "aura" and mode ~= "glow" and mode ~= "cdm" then mode = defaultMode end
	self.state.backend = mode
	return mode
end


function Addon:GetHybridAuraTruth()
	local db = self:GetDB()
	if db and db.hybridAuraTruth ~= nil then
		return db.hybridAuraTruth and true or false
	end
	return (self.state and self.state.hybridAuraTruth) and true or false
end

function Addon:SetHybridAuraTruth(enabled)
	enabled = enabled and true or false
	local db = self:GetDB()
	if db then db.hybridAuraTruth = enabled end
	if self.state then
		self.state.hybridAuraTruth = enabled
		self.state._hybridChecked = false
	end
	-- Re-wire polling/backends to match the new mode.
	self:ApplyBackend(true)
	-- Refresh display
	if self.UI and self.UI.UpdateStacks then
		self.UI:UpdateStacks(self.state and self.state.stacks or 0)
	end
end

function Addon:SetBackend(mode)
	local db = self:GetDB()
	if mode ~= "aura" and mode ~= "glow" and mode ~= "cdm" then return end
	if db then db.backend = mode end
	self.state.backend = mode

	-- Reset runtime state for the new backend
	self.state.glowActive = false
	self.state.lastProcSignalAt = 0
	self.state.lastGlowHideAt = 0
	self.state.spendTokens = 0
	self.state.pendingLoss = 0

	-- Keep UI stable
	self.state.stacks = 0
	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(0) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end

	if self.ApplyBackend then
		self:ApplyBackend(true)
	end

	-- Immediate resync when switching to aura/hybrid (prevents UI showing 0 until next UNIT_AURA)
	if (mode == "aura") or (self.state and self.state.hybridAuraTruth) then
		if self.SyncStacksFromAura then self:SyncStacksFromAura() end
	end
end

-- Apply backend runtime wiring. This is intentionally lightweight and idempotent.
-- Some hooks (UseAction, SAO hooksecurefunc) are global and cheap; we keep them installed
-- once and gate behavior on self:GetBackend() to avoid taint/protected calls.
function Addon:ApplyBackend(_hard)
	local mode = self:GetBackend()
	-- SAO overlay hooks are required for secret-safe aura binding even when backend is "aura"/"cdm".
	-- Hooks are installed once and gated internally; safe to call repeatedly.
	if self.InitGlowHooks then self:InitGlowHooks() end
	-- Ensure aura sync remains reliable (UNIT_AURA can be skipped on some edge cases).
	if (self.state and self.state.hybridAuraTruth) or mode == "aura" then
		if self.AuraPollStart then self:AuraPollStart() end
	else
		if self.AuraPollStop then self:AuraPollStop() end
	end

	-- Cooldown Viewer backend ticker
	if mode == "cdm" then
		if self.CDM_Start then self:CDM_Start() end
	else
		if self.CDM_Stop then self:CDM_Stop() end
	end

	-- Glow backend global hooks + alert scan
	if mode == "glow" then
		self:InitActionScan()
		self:InitGlowHooks()
		if self.Glow_ScanSpellActivationAlerts then
			self:Glow_ScanSpellActivationAlerts(true)
		end
	end

end

-- ----------------------------
-- Aura poll (failsafe)
-- ----------------------------
function Addon:AuraPollStart()
	if self.state._auraTicker then return end
	if not (C_Timer and C_Timer.NewTicker) then return end

	self.state._auraTicker = C_Timer.NewTicker(0.15, function()
		if not Addon or not Addon.state then return end
		if Addon.state.manualPaused then return end

		-- Keep it cheap outside combat: only tick if we currently show stacks/session.
		if not Addon.state.inCombat and (tonumber(Addon.state.stacks or 0) <= 0) and (not Addon.state.sessionActive) then
			return
		end

		Addon:SyncStacksFromAura()
	end)
end

function Addon:AuraPollStop()
	local t = self.state._auraTicker
	if t and t.Cancel then
		t:Cancel()
	end
	self.state._auraTicker = nil
end

-- ----------------------------
-- Aura scan (UNIT_AURA truth)
-- ----------------------------

-- Modern slot-based aura iterator (11.0+). Avoids UnitAura and stays resilient when Blizzard changes internals.
-- We keep this small and self-contained because aura APIs have been moving a lot since 11.0.
function Addon:_ForEachPlayerAura(filter, cb)
	filter = filter or "HELPFUL"

	if C_UnitAuras and type(C_UnitAuras.GetAuraSlots) == "function" and type(C_UnitAuras.GetAuraDataBySlot) == "function" then
		local continuationToken = nil
		repeat
			-- NOTE: GetAuraSlots signature varies across builds:
			--  A) returns: continuationToken, slot1, slot2, ...
			--  B) returns: slotsTable, continuationToken
			--  C) returns: continuationToken, slotsTable
			local t = { pcall(C_UnitAuras.GetAuraSlots, "player", filter, 200, continuationToken) }
			if not t[1] then break end

			local slots
			local r2, r3 = t[2], t[3]

			if type(r2) == "table" then
				slots = r2
				continuationToken = r3
			elseif type(r3) == "table" and (#t <= 4) then
				continuationToken = r2
				slots = r3
			else
				continuationToken = r2
				slots = {}
				for i = 3, #t do
					slots[#slots + 1] = t[i]
				end
			end

			if type(slots) == "table" then
				for i = 1, #slots do
					local slot = slots[i]
					if slot then
						local ok2, aura = pcall(C_UnitAuras.GetAuraDataBySlot, "player", slot)
						if ok2 and aura then
							if cb(aura, slot) then return true end
						end
					end
				end
			end
		until not continuationToken or continuationToken == 0

		return false
	end

	-- Fallback: AuraUtil
	if AuraUtil and type(AuraUtil.ForEachAura) == "function" then
		local ok, ret = pcall(AuraUtil.ForEachAura, "player", filter, nil, function(aura)
			return cb(aura)
		end, true)
		return ok and ret or false
	end

	return false
end

-- Maintain an index of current player HELPFUL auras by auraInstanceID.
-- This is used as a fallback when Blizzard marks aura fields (name/spellId/icon) as secret values in 12.x.
-- Key design rule: we only use auraInstanceID (plain number) as the table key to avoid "table index is secret" errors.
function Addon:UpdateAuraIndex(now)
	now = now or GetTime()

	if not (self and self.state) then return end
	local idx = self.state._auraIndex
	if type(idx) ~= "table" then
		idx = {}
		self.state._auraIndex = idx
	end

	-- Baseline build: on first scan we mark all existing auras as "baseline" so we do not
	-- accidentally bind KM to unrelated auras (overlay timing bind only considers NEW changes).
	if not self.state._auraBaselineBuilt then
		self.state._auraBaselineBuilt = true
		self:_ForEachPlayerAura("HELPFUL", function(aura)
			local aid = aura and aura.auraInstanceID
			if aid ~= nil and KMPT_IsSecret and KMPT_IsSecret(aid) then return end
			aid = tonumber(aid)
			if not aid then return end
			idx[aid] = { addedAt = 0, lastSeenAt = now, baseline = true }
		end)
		return
	end

	local seen = {}
	self:_ForEachPlayerAura("HELPFUL", function(aura)
		local aid = aura and aura.auraInstanceID
		if aid ~= nil and KMPT_IsSecret and KMPT_IsSecret(aid) then return end
		aid = tonumber(aid)
		if not aid then return end

		seen[aid] = true
		local rec = idx[aid]
		if not rec then
			idx[aid] = { addedAt = now, lastSeenAt = now }
		else
			rec.lastSeenAt = now
		end
	end)

	-- Purge auras that are no longer present (keeps idx bounded and resets KM instance binding).
	for aid in pairs(idx) do
		if not seen[aid] then
			idx[aid] = nil
			if self.state._kmAuraInstanceID == aid then
				self.state._kmAuraInstanceID = nil
			end
		end
	end
end


function Addon:_GetSpellNameSafe(spellID)
	spellID = tonumber(spellID)

	if not spellID then return nil end
	if C_Spell and type(C_Spell.GetSpellName) == "function" then
		local ok, n = pcall(C_Spell.GetSpellName, spellID)
		if ok and type(n) == "string" and n ~= "" then return n end
	end
	if GetSpellInfo then
		local ok, n = pcall(GetSpellInfo, spellID)
		if ok and type(n) == "string" and n ~= "" then return n end
	end
	return nil
end

-- Lightweight CDM stack snapshot for hybrid logic.
-- We do NOT require the CDM backend to be selected; we only opportunistically read stacks when available.
function Addon:CDM_SnapshotStacks(now)
	now = now or (GetTime and GetTime()) or 0
	local st = self.state or {}
	self.state = st

	-- CDM module always loads (Backend_CooldownViewer.lua), but CDM frames may not exist / may be disabled.
	if type(self.CDM_ReadKMState) ~= "function" or type(self.CDM_LocateKMIcon) ~= "function" then
		return nil
	end

	-- Rate-limit expensive viewer scans when we are not on the CDM backend.
	local backend = self:GetBackend()
	local scanInterval = (backend == "cdm") and 0 or 0.50
	if (not st._cdmIcon) or (not st._cdmIcon.__kmptHooked) then
		local last = st._cdmSnapLastScan or 0
		if scanInterval > 0 and (now - last) < scanInterval then
			return st._cdmSnapLastVal
		end
		st._cdmSnapLastScan = now
		local ok, icon = pcall(self.CDM_LocateKMIcon, self)
		if ok and icon then
			-- Attach hooks (they early-out unless backend==cdm), but this gives us a stable icon reference.
			pcall(self.CDM_AttachHooks, self, icon)
			st._cdmIcon = icon
		end
	end

	local ok2, val = pcall(self.CDM_ReadKMState, self)
	if ok2 and type(val) == "number" then
		st._cdmSnapLastVal = val
		return val
	end
	return nil
end

function Addon:_GetSpellIconSafe(spellID)
	spellID = tonumber(spellID)
	if not spellID then return nil end
	if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
		local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
		if ok then return tex end
	end
	if GetSpellInfo then
		local ok, _, _, tex = pcall(GetSpellInfo, spellID)
		if ok then return tex end
	end
	return nil
end

-- Find the *actual* KM proc aura by scanning player buffs and matching by spellId (preferred), name (safe), then icon.
-- This self-heals across patches where Blizzard changes which spellId represents the proc aura.
function Addon:FindKillingMachineAura()
	local function isSecret(v)
		return (type(issecretvalue) == "function") and issecretvalue(v)
	end
	local now = GetTime()
	local st = self.state
	local overlayAt = tonumber(st and st._kmOverlayAt or 0) or 0
	local auraIdx = st and st._auraIndex


	-- Candidate IDs (Blizzard historically used multiple IDs for passive vs proc; we keep a small superset).
	local base = (type(self.KM_AURA_IDS) == "table" and self.KM_AURA_IDS) or { 51124, 51128, 51130 }
	local db = self:GetDB()
	-- NOTE: kmAuraSpellId persistence disabled (12.x can mis-discover unrelated auras)
	local persisted = nil

	local idSet = {}
	local ids = {}
	for _, id in ipairs(base) do
		id = tonumber(id)
		if id and not idSet[id] then
			idSet[id] = true
			ids[#ids + 1] = id
		end
	end

	local nameSet, iconSet = {}, {}
	for _, id in ipairs(ids) do
		local n = self:_GetSpellNameSafe(id)
		if type(n) == "string" and n ~= "" then nameSet[n] = true end
		local ico = self:_GetSpellIconSafe(id)
		if ico ~= nil and (not isSecret(ico)) then iconSet[ico] = true end
	end

	local bestAura, bestVia, bestScore

	self:_ForEachPlayerAura("HELPFUL", function(aura)
		if type(aura) ~= "table" then return end
		local sid = aura.spellId or aura.spellID
		local name = aura.name
		local icon = aura.icon

		local matchType
		local sidNum

-- Defensive matching: even when issecretvalue is unavailable/buggy, avoid indexing tables with secret keys.
if sid ~= nil and (not isSecret(sid)) then
	local okNum, num = pcall(tonumber, sid)
	if okNum and num then
		sidNum = num
		local okIdx, inSet = pcall(function() return idSet[num] end)
		if okIdx and inSet then
			matchType = "spellId"
		end
	end
end


if not matchType and type(name) == "string" and (not isSecret(name)) then
	local okIdx, inSet = pcall(function() return nameSet[name] end)
	if okIdx and inSet then
		matchType = "name"
	end
end


if not matchType and icon ~= nil and (not isSecret(icon)) then
	local okIdx, inSet = pcall(function() return iconSet[icon] end)
	if okIdx and inSet then
		matchType = "icon"
	end
end

if not matchType then
	-- Fallback (12.x): spellId/name/icon may be returned as secret values.
	-- If we recently observed the KM overlay pulse, try to bind the KM aura by auraInstanceID timing.
	local aid = aura and aura.auraInstanceID
	if aid ~= nil and (not isSecret(aid)) then
		aid = tonumber(aid)
	else
		aid = nil
	end

	if aid and st then
		-- Sticky binding: once we discover the auraInstanceID, reuse it until the aura disappears.
		if st._kmAuraInstanceID and aid == st._kmAuraInstanceID then
			matchType = "instance"
		elseif overlayAt > 0 and (now - overlayAt) < 2.00 then
			local rec = (type(auraIdx) == "table") and auraIdx[aid] or nil
			local addedAt = rec and tonumber(rec.addedAt or 0) or 0
			local baseline = rec and rec.baseline
			-- Secret-safe timing bind: only consider *new* auras (baseline=false) close to the last KM overlay show.
			if (not baseline) and addedAt > 0 and math.abs(addedAt - overlayAt) < 1.00 then
				matchType = "overlay"
				st._kmAuraInstanceID = aid
			end
		end
	end
end

if not matchType then return end

		local stacks = aura.applications or aura.charges or aura.stackCount or aura.stacks or aura.count
		local n = KMPT_SafeStacks(stacks)

		-- If stacks are secret, try the UI-safe application count helper (returns a formatted string).
		-- This can restore the real 1/2 value on some clients/builds.
		if n <= 1 and stacks ~= nil and isSecret(stacks) and st and not st._svNoAuraDisplayCount and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
			local aid2 = aura and aura.auraInstanceID
			if aid2 ~= nil and (not isSecret(aid2)) then
				local ok, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, "player", aid2, 1, 2)
				if ok and cnt ~= nil and (not isSecret(cnt)) then
					local v = cnt
					if type(v) ~= "number" then
						local ok2, vv = pcall(tonumber, v)
						if ok2 then v = vv end
					end
					if type(v) == "number" and v > 0 then
						n = math.min(v, 2)
					end
				elseif not ok then
					-- Disable this path if the call signature isn't supported on this build.
					st._svNoAuraDisplayCount = true
				end
			end
		end

		local score = (n * 10)
		if matchType == "spellId" then score = score + 3
		elseif matchType == "name" then score = score + 2
		else score = score + 1 end

		if (not bestScore) or score > bestScore then
			bestAura = aura
			bestScore = score
			bestVia = "scan:" .. matchType
		end

	end)

	return bestAura, bestVia
end

-- Developer helper: dump player helpful auras into DevTools log (or chat if DevTools is disabled).
-- Developer helper: dump player helpful auras into DevTools log (or chat if DevTools is disabled).
-- Notes (Midnight/12.0+): aura fields like name/spellId/stacks/duration can be SecretValues; do not index/compare them.
function Addon:AuraDumpPlayer(pattern)
	pattern = (pattern and tostring(pattern) ~= "" and tostring(pattern)) or nil
	local now = GetTime()
	if self.UpdateAuraIndex then self:UpdateAuraIndex(now) end

	local pl = pattern and string.lower(tostring(pattern)) or nil
	local pattNum = pattern and tonumber(pattern) or nil

	local dumpAll = (pl == nil) or (pl == "all")
	local dumpRaw = (pl == "raw" or pl == "ids")
	local dumpKM = (pl == "km" or pl == "killing machine")
	if pl and not dumpKM and (pl:find("killing") or pl:find("machine")) then dumpKM = true end
	-- Numeric alias: '/kmpt auradump 51124' is treated as KM debug mode (spellId filtering is often impossible under SecretValues).
	if pattNum and (pattNum == (self.KM_SPELL_ID or 51124)) then dumpKM = true end

	local st = self.state or {}
	local idx = st._auraIndex or {}
	local overlayAt = st._kmOverlayAt
	local boundAid = st._kmAuraInstanceID

	local shown = 0
	local warned = false

	self:_ForEachPlayerAura("HELPFUL", function(aura)
		local aid = aura and aura.auraInstanceID
		if not aid or (type(KMPT_IsSecret) == "function" and KMPT_IsSecret(aid)) then return false end

		if dumpKM then
			local tag = nil
			if boundAid and aid == boundAid then
				tag = "BOUND"
			else
				local rec = idx[aid]
				if rec and type(rec.addedAt) == "number" and type(overlayAt) == "number" then
					local dt = math.abs(rec.addedAt - overlayAt)
					if (now - overlayAt) <= 2.0 and dt <= 0.90 then
						tag = "overlay hot"
					end
				end
			end
			if tag then
				shown = shown + 1
				local stacks = KMPT_SafeToString and KMPT_SafeToString(aura.applications) or tostring(aura.applications)
				self:ChatLimited(string.format("AURA_DUMP: KM candidate (%s) aid=%d stacks=%s", tag, aid, stacks))
			end
			return false
		end

		-- RAW / ALL listing (best-effort; values may be secret).
		if dumpAll or dumpRaw then
			local sid = aura and (aura.spellId or aura.spellID or aura.spellId)
			if (type(KMPT_IsSecret) == "function" and KMPT_IsSecret(sid)) then sid = nil end
			local sidNum = sid and tonumber(sid) or nil
			local name = aura and aura.name
			local nameStr = KMPT_SafeToString and KMPT_SafeToString(name) or tostring(name)
			local stacks = KMPT_SafeToString and KMPT_SafeToString(aura.applications) or tostring(aura.applications)
			self:ChatLimited(string.format("AURA_DUMP: aid=%d sid=%s name=%s stacks=%s", aid, sidNum and tostring(sidNum) or "<secret>", nameStr, stacks))
			shown = shown + 1
			return false
		end

		-- Text / numeric filtering (limited under SecretValues).
		if pattNum then
			local sid = aura and (aura.spellId or aura.spellID or aura.spellId)
			if sid and not (type(KMPT_IsSecret) == "function" and KMPT_IsSecret(sid)) then
				local sidNum = tonumber(sid)
				if sidNum and sidNum == pattNum then
					local nameStr = KMPT_SafeToString and KMPT_SafeToString(aura.name) or tostring(aura.name)
					local stacks = KMPT_SafeToString and KMPT_SafeToString(aura.applications) or tostring(aura.applications)
					self:ChatLimited(string.format("AURA_DUMP: match aid=%d sid=%d name=%s stacks=%s", aid, sidNum, nameStr, stacks))
					shown = shown + 1
				end
			end
		else
			if pl then
				local name = aura and aura.name
				if type(name) == "string" and not (type(KMPT_IsSecret) == "function" and KMPT_IsSecret(name)) then
					if string.find(string.lower(name), pl, 1, true) then
						local stacks = KMPT_SafeToString and KMPT_SafeToString(aura.applications) or tostring(aura.applications)
						self:ChatLimited(string.format("AURA_DUMP: match aid=%d name=%s stacks=%s", aid, name, stacks))
						shown = shown + 1
					end
				else
					if not warned then
						warned = true
						self:Chatf("AURA_DUMP: aura.name is SECRET; cannot filter by text. For KM use: /kmpt auradump km")
					end
				end
			end
		end
		return false
	end)

	if shown == 0 then
		self:Chatf("AURA_DUMP: (no matches)")
	end
end
function Addon:_AuraBySpellID(spellID)
	spellID = tonumber(spellID)
	if not spellID then return nil end

	local function isSecret(v)
		return (type(issecretvalue) == "function") and issecretvalue(v)
	end

	-- Fast path: modern helpers (player-only, avoids full scans)
	if C_UnitAuras and type(C_UnitAuras.GetAuraDataBySpellID) == "function" then
		local ok, aura = pcall(C_UnitAuras.GetAuraDataBySpellID, "player", spellID)
		if ok and aura then return aura, "C_UnitAuras.GetAuraDataBySpellID" end
	end

	if C_UnitAuras and type(C_UnitAuras.GetPlayerAuraBySpellID) == "function" then
		local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
		if ok and aura then return aura, "C_UnitAuras.GetPlayerAuraBySpellID" end
	end

	-- AuraUtil helper (legacy). May return nil for some filtered auras.
	if AuraUtil and type(AuraUtil.FindAuraBySpellId) == "function" then
		local ok, name, icon, count, dispelType, duration, expirationTime, source, isStealable, nameplateShowPersonal, sid =
			pcall(AuraUtil.FindAuraBySpellId, spellID, "player", "HELPFUL")
		if ok and name then
			return {
				name = name,
				icon = icon,
				applications = count,
				duration = duration,
				expirationTime = expirationTime,
				sourceUnit = source,
				spellId = sid,
			}, "AuraUtil.FindAuraBySpellId"
		end
	end

	-- Resolve localized name once (for safe fallback when spellId fields are secret)
	local desiredName
	if GetSpellInfo then
		local ok, n = pcall(GetSpellInfo, spellID)
		if ok then desiredName = n end
	end

	-- Recommended scan: AuraUtil.ForEachAura
	if AuraUtil and type(AuraUtil.ForEachAura) == "function" then
		local found

		local function captureFromAuraData(aura)
			if not aura then return end
			local sid = aura.spellId or aura.spellID
			local name = aura.name
			local count = aura.applications or aura.charges or aura.stackCount or aura.stacks or aura.count
			if sid ~= nil and (not isSecret(sid)) and tonumber(sid) == spellID then
				found = aura
				return true
			end
			if desiredName and name and (not isSecret(name)) and name == desiredName then
				found = aura
				return true
			end
		end

		local function cb(...)
			local first = ...
			if type(first) == "table" then
				-- Packed aura info (retail)
				if captureFromAuraData(first) then return true end
			else
				-- Unpacked legacy signature
				local name, icon, count, dispelType, duration, expirationTime, source, isStealable, nameplateShowPersonal, sid = ...
				-- Match by spellId if non-secret
				if sid ~= nil and (not isSecret(sid)) and tonumber(sid) == spellID then
					found = {
						name = name,
						icon = icon,
						applications = count,
						duration = duration,
						expirationTime = expirationTime,
						sourceUnit = source,
						spellId = sid,
					}
					return true
				end
				-- Fallback by name (safe)
				if desiredName and name and (not isSecret(name)) and name == desiredName then
					found = {
						name = name,
						icon = icon,
						applications = count,
						duration = duration,
						expirationTime = expirationTime,
						sourceUnit = source,
						spellId = sid,
					}
					return true
				end
			end
		end

		-- Try packed first (retail). If it errors or finds nothing, try legacy variants.
		pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, cb, true)
		if found then return found, "AuraUtil.ForEachAura(packed)" end
		pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, cb, false)
		if found then return found, "AuraUtil.ForEachAura(unpacked)" end
		pcall(AuraUtil.ForEachAura, "player", "HELPFUL", nil, cb)
		if found then return found, "AuraUtil.ForEachAura(legacy)" end
	end

	-- Final fallback: index scan via UnitAura
	if UnitAura then
		for i = 1, 80 do
			local name, icon, count, dispelType, duration, expirationTime, source, isStealable, nameplateShowPersonal, sid = UnitAura("player", i, "HELPFUL")
			if not name then break end

			if sid ~= nil and (not isSecret(sid)) and tonumber(sid) == spellID then
				return {
					name = name,
					icon = icon,
					applications = count,
					duration = duration,
					expirationTime = expirationTime,
					sourceUnit = source,
					spellId = sid,
				}, "UnitAura(spellId)"
			end

			if desiredName and name and (not isSecret(name)) and name == desiredName then
				return {
					name = name,
					icon = icon,
					applications = count,
					duration = duration,
					expirationTime = expirationTime,
					sourceUnit = source,
					spellId = sid,
				}, "UnitAura(name)"
			end
		end
	end

	return nil
end

-- Scan the default Blizzard SpellActivationOverlayFrame to count active KM overlays (Left/Right).
-- Frost DK KM procs create up to 2 overlays dynamically.
function Addon:CountKMOverlays()
	local saoFrame = _G.SpellActivationOverlayFrame
	if not saoFrame then return 0 end
	
	local count = 0
	-- SAO frame manages its overlays globally as children
	local children = { saoFrame:GetChildren() }
	for i, child in ipairs(children) do
		if child and child:IsShown() then
			local sId = child.spellID
			if type(sId) == "number" and self:IsKMAuraSpellId(sId) then
				count = count + 1
			end
		end
	end
	
	if count > 2 then count = 2 end
	if count < 0 then count = 0 end
	return count
end

-- Return current Killing Machine stacks using auras as the source of truth.
-- In Midnight, aura fields (including stacks) can be secret values; in that case we fall back to Overlay/CDM/Glow.
function Addon:GetKMStacksFromAuras()
	local aura, via = self:FindKillingMachineAura()
	if not aura then
		-- If Blizzard hides KM as a "non-aura" state, this will legitimately be 0.
		return 0
	end

	local raw = aura.applications or aura.charges or aura.stackCount or aura.stacks or aura.count
	local n = KMPT_TryNumber(raw)
	if type(n) == "number" then
		if n < 0 then n = 0 end
		if n > 2 then n = 2 end
	else
		-- Stacks are secret: keep aura presence as truth, but infer the count from safe channels.
		-- Priority:
		--  1) Internal hint stacks (built from SAO timing + UNIT_AURA updateInfo)
		--  2) CDM snapshot (if it exposes a non-secret numeric stack text)
		--  3) Preserve current state, but never drop below 1 while aura is present.
		local saoStacks = self:CountKMOverlays()
		if saoStacks > 0 then
			n = saoStacks
			-- Synchronize hint
			if self.state then self.state._kmHintStacks = n end
		else
			local hs = (KMPT_TryNumber(self.state and self.state._kmHintStacks) or 0)
			if hs > 0 then
				n = hs
		else
			local snap = self:CDM_SnapshotStacks(GetTime())
			if type(snap) == "number" and snap > 0 then
				n = snap
			else
				n = (KMPT_TryNumber(self.state and self.state.stacks) or 0)
				if n < 1 then n = 1 end
				if n > 2 then n = 2 end
			end
		end
	end
	end

	if self.DevToolsEnabled and self:DevToolsEnabled() and self:DevToolsVerbose() then
		local sid = aura.spellId or aura.spellID
		self:DevLog("AURA km stacks=%s via=%s spellId=%s name=%s rawStacks=%s", tostring(n), tostring(via), KMPT_SafeToString(sid), KMPT_SafeToString(aura.name), KMPT_SafeToString(raw))
	end

	return n
end
function Addon:TestKillingMachineSecret()
	self:Chat("KMPT: Killing Machine secret-value probe")
	if type(issecretvalue) ~= "function" then
		self:Chat("  issecretvalue() not available on this client")
		return
	end

	local now = GetTime()
	if self.UpdateAuraIndex then self:UpdateAuraIndex(now) end

	local db = self:GetDB()
	local persisted = db and db.kmAuraSpellId
	if persisted then
		self:Chat(string.format("  persisted kmAuraSpellId=%s", tostring(persisted)))
	end

	local aura, via = self:FindKillingMachineAura()
	if not aura then
		local st = self.state or {}
		self:Chat("  KM aura present=no (not found in player helpful auras)")
		self:Chat(string.format("  debug: boundAid=%s overlayAge=%.3f", tostring(st._kmAuraInstanceID), (type(st._kmOverlayAt)=="number") and (now - st._kmOverlayAt) or -1))
		self:Chat("  Tip: proc KM once, then run: /kmpt auradump km")
		return
	end

	local function flag(v)
		return (type(KMPT_IsSecret) == "function" and KMPT_IsSecret(v)) and "SECRET" or "plain"
	end

	local stacks = aura.applications or aura.charges or aura.stackCount or aura.stacks or aura.count
	local sid = aura.spellId or aura.spellID
	local exp = aura.expirationTime or aura.expiration or aura.expirationtime
	local dur = aura.duration
	local icon = aura.icon
	local name = aura.name
	local aid = aura.auraInstanceID

	self:Chat(string.format(
		"  present=yes aid=%s (%s) name=%s (%s) stacks=%s (%s) spellId=%s (%s) exp=%s (%s) dur=%s (%s) icon=%s (%s) via=%s",
		KMPT_SafeToString(aid), flag(aid),
		KMPT_SafeToString(name), flag(name),
		KMPT_SafeToString(stacks), flag(stacks),
		KMPT_SafeToString(sid), flag(sid),
		KMPT_SafeToString(exp), flag(exp),
		KMPT_SafeToString(dur), flag(dur),
		KMPT_SafeToString(icon), flag(icon),
		tostring(via)
	))

	-- Extra probes (12.x+): try helper APIs that may expose UI-safe values even when the raw aura fields are secret.
	if C_UnitAuras then
		if C_UnitAuras.DoesAuraHaveExpirationTime then
			local okHas, hasExp = pcall(C_UnitAuras.DoesAuraHaveExpirationTime, "player", aid)
			if okHas then
				self:Chat(string.format("  api: DoesAuraHaveExpirationTime=%s (%s)", KMPT_SafeToString(hasExp), flag(hasExp)))
			else
				self:Chat("  api: DoesAuraHaveExpirationTime=ERROR")
			end
		end

		if C_UnitAuras.GetAuraApplicationDisplayCount then
			local function TryDisplay(minCount, maxCount)
				local ok, cnt
				if minCount == nil and maxCount == nil then
					ok, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, "player", aid)
				else
					ok, cnt = pcall(C_UnitAuras.GetAuraApplicationDisplayCount, "player", aid, minCount, maxCount)
				end
				if ok then
					self:Chat(string.format("  api: GetAuraApplicationDisplayCount(%s,%s)=%s (%s)",
						minCount == nil and "-" or tostring(minCount),
						maxCount == nil and "-" or tostring(maxCount),
						KMPT_SafeToString(cnt), flag(cnt)
					))
				else
					self:Chat(string.format("  api: GetAuraApplicationDisplayCount(%s,%s)=ERROR",
						minCount == nil and "-" or tostring(minCount),
						maxCount == nil and "-" or tostring(maxCount)
					))
				end
			end
			TryDisplay(nil, nil)
			TryDisplay(1, 2)
			TryDisplay(2, 2)
		end

		if C_UnitAuras.GetAuraDataByAuraInstanceID then
			local okData, data = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", aid)
			if okData and data then
				local stacks2 = data.applications or data.charges or data.stackCount or data.stacks or data.count
				local sid2 = data.spellId or data.spellID
				local exp2 = data.expirationTime or data.expiration or data.expirationtime
				local dur2 = data.duration
				local name2 = data.name
				self:Chat(string.format(
					"  api: GetAuraDataByAuraInstanceID name=%s (%s) stacks=%s (%s) spellId=%s (%s) exp=%s (%s) dur=%s (%s)",
					KMPT_SafeToString(name2), flag(name2),
					KMPT_SafeToString(stacks2), flag(stacks2),
					KMPT_SafeToString(sid2), flag(sid2),
					KMPT_SafeToString(exp2), flag(exp2),
					KMPT_SafeToString(dur2), flag(dur2)
				))
			else
				self:Chat("  api: GetAuraDataByAuraInstanceID=ERROR")
			end
		end
	end
end
function Addon:BeginWindowSeed()
	local backend = self:GetBackend()
	local cur = 0
	if backend == "aura" then
		cur = self:GetKMStacksFromAuras()
		-- Seed aura expiration so first refresh at cap is not miscounted as overcap.
		local aura = self:FindKillingMachineAura()
		if aura then
			local exp = aura.expirationTime or aura.expiration or aura.expirationtime
			if exp and (not KMPT_IsSecret or not KMPT_IsSecret(exp)) then
				self.state.lastAuraExp = exp
			end
		end
	elseif backend == "cdm" and self.CDM_ReadKMState then
		local stacks = select(1, self:CDM_ReadKMState(GetTime()))
		cur = (KMPT_TryNumber(stacks) or 0)
	end
	self.state.stacks = cur

	self.counters.procs = cur
	self.counters.used = 0
	self.counters.expired = 0
	self.counters.wasted = 0
	self.counters.overcap = 0
	self.counters.consumed = 0

	self.state.spendTokens = 0
	self.state.lastSpenderAt = 0
	self.state.pendingLoss = 0
	self.state.pendingLossAt = 0

	self.state.lastStackGainAt = 0
	self.state.lastOvercapAt = 0
	self.state.overcapPending = false

	-- Glow-backend session state
	if backend == "glow" then
		self.state.glowActive = false
		self.state.lastProcSignalAt = 0
		self.state.lastGlowHideAt = 0
		self.state.lastSpenderAt = 0
		-- Proc tick token-bucket (see Glow_ApplyProcTick)
		-- Seed with 1 credit so the first real proc is never dropped at pull.
		self.state._kmProcCredit = (self:GetDevFilterValue("seedCredit", 1.0) or 1.0)
		self.state._kmProcCreditAt = GetTime()
		self.state._kmLastProcTickAt = 0
		self.state._kmLastSwingGatedTickAt = 0
		if self.Glow_ResetPrimary then self:Glow_ResetPrimary() end
	end

	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(cur) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

function Addon:ResetCounters()
	-- Reset defines a new accounting window "now".
	local backend = self:GetBackend()
	if backend == "aura" then
		local cur = self:GetKMStacksFromAuras()
		self.state.sessionActive = self.state.inCombat or (cur > 0)
	elseif backend == "cdm" and self.CDM_ReadKMState then
		local cur = (KMPT_TryNumber(select(1, self:CDM_ReadKMState(GetTime()))) or 0)
		self.state.sessionActive = self.state.inCombat or (cur > 0)
	else
		-- Glow backend cannot trust aura stacks in combat; only track while in-combat.
		self.state.sessionActive = self.state.inCombat
	end
	self:BeginWindowSeed()
end

-- ----------------------------
-- Retro-fix: expired -> used if late spender arrives
-- ----------------------------
function Addon:TryRetroFixSpent(now)
	local pend = self.state.pendingLoss or 0
	local tokens = self.state.spendTokens or 0
	if pend <= 0 or tokens <= 0 then return end
	if (now - (self.state.pendingLossAt or 0)) > SPEND_WINDOW then return end

	local fix = math.min(pend, tokens)
	if fix <= 0 then return end

	self.state.pendingLoss = pend - fix
	self.state.spendTokens = tokens - fix

	self.counters.expired = math.max(0, self.counters.expired - fix)
	self.counters.wasted  = math.max(0, self.counters.wasted  - fix)

	self.counters.used = self.counters.used + fix
	self.counters.consumed = self.counters.used
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

-- ----------------------------
-- Glow backend (Midnight-friendly)
--
-- Constraints / assumptions (Midnight):
--  - COMBAT_LOG_EVENT_UNFILTERED may be blocked.
--  - Aura stack counts may be secret/unstable in combat.
--
-- Signal sources:
--  - Lifecycle (when glow is ON/OFF): SPELL_ACTIVATION_OVERLAY_GLOW_SHOW/HIDE for
--    spender spells (Obliterate/Frostscythe). These events usually fire only on the
--    first show and final hide.
--  - Proc ticks (including 2nd stack while glow already visible): ActionButton SpellActivationAlert
--    "ProcStart" flipbook play on the spender buttons. This avoids over-counting from
--    SpellActivationOverlayFrame:ShowOverlay() maintenance spam.
--
-- Accounting model (glow backend):
--  - Each SHOW/refresh signal increments "Procs" by 1.
--  - We maintain internal stacks [0..2]. If a proc arrives at 2 stacks -> Overcap/Wasted.
--  - Obliterate / Frostscythe consume ALL available stacks at once.
--  - If the glow hides while stacks > 0 and we did NOT just cast a spender -> Expired/Wasted.
-- ----------------------------

local KM_SPENDER_SPELL_IDS = {
	[49020]  = true, -- Obliterate
	[207230] = true, -- Frostscythe
}

-- Fallback: overlay ids observed for KM in some builds.
-- IMPORTANT: keep this list tight; incorrect ids cause proc spam.
-- 51128 is the primary value observed in 12.0 testing.
-- 438833 is kept as an optional alternate seen on some builds.
local KM_PROC_OVERLAY_IDS = {
	-- Common spell/aura IDs that can appear in SAO paths.
	[51124] = true,
	[51128] = true,
}

-- Some clients have been observed firing a very noisy SAO id (438833). By default we ignore it.
-- It can be enabled for investigation via DevTools (db.glow.allowAltOverlay438833=true).
local ALT_NOISY_OVERLAY_ID = 438833

local function IsKMProcOverlayId(spellId)
	-- overlaySpellId can be a secret value on some builds; never index tables with secrets
	if spellId == nil then return false end
	if type(issecretvalue) == "function" and issecretvalue(spellId) then return false end
	local sid = tonumber(spellId)
	if not sid then return false end

	if KM_PROC_OVERLAY_IDS[sid] == true then return true end
	if sid == ALT_NOISY_OVERLAY_ID then
		local db = Addon and Addon.GetDB and Addon:GetDB()
		return db and db.glow and db.glow.allowAltOverlay438833 == true
	end
	return false
end

local function IsKMSpenderSpellID(spellId)
	if spellId == nil then return false end
	if type(issecretvalue) == "function" and issecretvalue(spellId) then return false end
	local sid = tonumber(spellId) or spellId
	if type(sid) ~= "number" then return false end
	return KM_SPENDER_SPELL_IDS[sid] == true
end

-- Action button families to scan for SpellActivationAlert.
-- We intentionally avoid any protected/secure operations; we only *hook* already-created frames.
local ACTION_BUTTON_FAMILIES = {
	{ "ActionButton", 12 },
	{ "MultiBarBottomLeftButton", 12 },
	{ "MultiBarBottomRightButton", 12 },
	{ "MultiBarRightButton", 12 },
	{ "MultiBarLeftButton", 12 },
	{ "MultiBar5Button", 12 },
	{ "MultiBar6Button", 12 },
	{ "MultiBar7Button", 12 },
	{ "OverrideActionBarButton", 12 },
}

local function GetButtonActionSlot(btn)
	if not btn then return nil end
	local a = btn.action
	if type(a) == "number" and a > 0 then return a end
	if btn.GetAttribute then
		a = btn:GetAttribute("action")
		if type(a) == "number" and a > 0 then return a end
	end
	return nil
end

local function GetActionSpellId(slot)
	if not slot then return nil end
	local t, id = GetActionInfo(slot)
	if t == "spell" then
		return id
	elseif t == "macro" and id then
		return GetMacroSpell(id)
	end
	return nil
end

function Addon:Glow_ApplyProcTick(now, source, forced)
	now = now or GetTime()
	if not self.state.inCombat then return end
	if self.state.manualPaused then return end
	if self:GetBackend() ~= "glow" then return end
	-- Hybrid mode: procs/stacks derived from aura truth; glow ticks are hints.
	-- In Midnight, KM auras may be SECRET/hidden; hybrid would freeze tracking.
	-- On the first real proc signal in combat, if KM stacks are still unreadable from auras, auto-disable hybrid.
	if self.state and self.state.hybridAuraTruth then
		if (not self.state._hybridChecked) and self.state.inCombat then
			self.state._hybridChecked = true
			local auraStacks = 0
			if self.GetKMStacksFromAuras then
				local ok, n = pcall(self.GetKMStacksFromAuras, self)
				if ok then auraStacks = tonumber(n) or 0 end
			end
			if auraStacks <= 0 then
				local db = self:GetDB()
				if db then db.hybridAuraTruth = false end
				self.state.hybridAuraTruth = false
				if self.DevToolsEnabled and self:DevToolsEnabled() then
					self:DevLog("AUTO: hybridAuraTruth disabled (KM aura unreadable; using glow)")
				end
			end
		end
		if self.state.hybridAuraTruth then return end
	end

	-- When we synthesize procs from known spell-casts (ERW / PoF spells),
	-- the UI overlay may still flash for the same proc. Suppress double-count.
	if not forced then
		local supUntil = tonumber(self.state.suppressAlertUntil or 0) or 0
		if now < supUntil then
			if self:DbgEnabled() then self:Dbg("PROC_TICK drop suppressed source=%s", tostring(source)) end
			return
		end
	end

	-- Micro-dedup (multiple buttons/flipbooks can fire in the same frame)
	local dtAny = now - (self.state._kmLastProcTickAt or 0)
	local micro = self:GetDevFilterValue("microDedup", 0.020) or 0.020
	if dtAny < micro and (not forced) then
		if self.DevToolsEnabled and self:DevToolsEnabled() then self:DevLog("PROC_TICK drop micro dt=%.3f", dtAny) end
		if self:DbgEnabled() then self:Dbg("PROC_TICK drop micro dt=%.3f < %.3f source=%s", dtAny, micro, tostring(source)) end
		return
	end

	local stacksBefore = tonumber(self.state.stacks or 0) or 0

	-- Proc signal filtering for non-forced signals (anti-spam).
	--
	-- IMPORTANT: SpellActivationOverlayFrame:ShowOverlay() may be called repeatedly for UI maintenance.
	-- A simple minInterval gate is too permissive (can overcount by ~20–30% with slow weapons).
	--
	-- We use a *token bucket* tied to real attack speed:
	--  - credits replenish at "pps" (combined swings/sec for dual-wield)
	--  - each accepted proc consumes 1 credit
	--  - credit caps at 2 (matches KM stack cap)
	--
	-- Forced proc sources (ERW/PoF synthetic ticks) bypass this.
	if (not forced) and (self.state and self.state.useCreditFilter) and (self.DevToolsEnabled and self:DevToolsEnabled() and self:DevToolsVerbose()) then
		local _, _, _, pps = self:Glow_GetAttackSpeedParams(now)
		pps = tonumber(pps) or 0
		if pps <= 0 then
			-- Fallback: assume ~2.6s weapon if API returns nil/0
			pps = 1 / 2.6
		end

		local credit = tonumber(self.state._kmProcCredit or 0) or 0
		local lastAt = tonumber(self.state._kmProcCreditAt or 0) or now
		local dt = now - lastAt
		if dt < 0 then dt = 0 end
		credit = credit + dt * pps
		local cap = self:GetDevFilterValue("creditCap", 2.0) or 2.0
		if credit > cap then credit = cap end
		self.state._kmProcCredit = credit
		self.state._kmProcCreditAt = now

		-- Require a near-full swing credit to count a proc.
		-- (0.99 keeps us close to the physical "1 proc per swing" ceiling, while still tolerating minor jitter.)
		local thr = self:GetDevFilterValue("creditThreshold", 0.99) or 0.99
		if credit < thr then
			if self.DevToolsEnabled and self:DevToolsEnabled() then
				self:DevLog("PROC_TICK drop credit=%.2f thr=%.3f pps=%.2f", credit, thr, tonumber(pps) or 0)
			end
			if self:DbgEnabled() then
				self:Dbg("PROC_TICK drop credit=%.2f < %.3f pps=%.2f stacksBefore=%d", credit, thr, tonumber(pps), tonumber(stacksBefore or 0))
			end
			return
		end
		self.state._kmProcCredit = credit - 1.0
	end

	self.state._kmLastProcTickAt = now

	-- Accounting
	self.counters.procs = (self.counters.procs or 0) + 1
	if stacksBefore < 2 then
		self.state.stacks = stacksBefore + 1
	else
		self.counters.overcap = (self.counters.overcap or 0) + 1
		self.counters.wasted  = (self.counters.wasted  or 0) + 1
		if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
	end

	if self.DevToolsEnabled and self:DevToolsEnabled() then self:DevLog("PROC_TICK apply source=%s forced=%s stacksAfter=%d", tostring(source), tostring(forced and true or false), tonumber(self.state.stacks or 0) or 0) end
	if self:DbgEnabled() then
		self:Dbg("PROC_TICK apply source=%s forced=%s stacksAfter=%d procs=%d overcap=%d wasted=%d",
			tostring(source), tostring(forced and true or false),
			tostring(self.state.stacks or 0), tostring(self.counters.procs or 0), tostring(self.counters.overcap or 0), tostring(self.counters.wasted or 0))
	end

	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(self.state.stacks or 0) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

function Addon:Glow_AttachSpellActivationAlert(btn, spenderSpellId)
	if not btn then return end
	if not spenderSpellId then return end
	local name = (btn.GetName and btn:GetName()) or tostring(btn)
	self.state._glowAlertHooked = self.state._glowAlertHooked or {}
	if self.state._glowAlertHooked[name] then return end

	local alert = btn.SpellActivationAlert
	if not alert then return end
	local start = alert.ProcStartFlipbook
	if not (start and start.Play) then
		-- Some skins may rename the object; fail silently.
		return
	end

	-- Count proc-ticks on ProcStart animation. This is far less spammy than SAO:ShowOverlay.
	hooksecurefunc(start, "Play", function()
		if not Addon or not Addon.state then return end
		if Addon.state.manualPaused then return end
		if Addon:GetBackend() ~= "glow" then return end
		if not Addon.state.inCombat then return end
		-- The button can be remapped dynamically (paging/override/macros). Re-resolve every time.
		local slot = GetButtonActionSlot(btn)
		local sid = GetActionSpellId(slot)
		if not (sid and IsKMSpenderSpellID(sid)) then return end
		Addon:Glow_ApplyProcTick(GetTime(), "ALERT:" .. tostring(sid), false)
	end)

	self.state._glowAlertHooked[name] = true
	if self:DbgEnabled() then self:Dbg("ALERT hook ok button=%s spell=%s", tostring(name), tostring(spenderSpellId)) end
end

function Addon:Glow_ScanSpellActivationAlerts()
	if self:GetBackend() ~= "glow" then return end
	for _, fam in ipairs(ACTION_BUTTON_FAMILIES) do
		local prefix, n = fam[1], fam[2]
		for i = 1, n do
			local btn = _G[prefix .. i]
			if btn then
				local slot = GetButtonActionSlot(btn)
				local sid = GetActionSpellId(slot)
				if sid and IsKMSpenderSpellID(sid) then
					self:Glow_AttachSpellActivationAlert(btn, sid)
				end
			end
		end
	end
end

function Addon:Glow_ResetPrimary()
	-- We no longer lock to a single "primary" spell, because Blizzard can refresh glow
	-- on either Obliterate or Frostscythe while the other stays lit. Primary-locking
	-- causes missed proc signals (2nd stack not captured).
	self.state.glowPrimarySpellId = nil
	self.state.glowActiveSpells = {}
end

function Addon:Glow_SetSpellActive(spellId, isActive)
	local t = self.state.glowActiveSpells
	if type(t) ~= "table" then
		t = {}
		self.state.glowActiveSpells = t
	end
	if isActive then
		t[spellId] = true
	else
		t[spellId] = nil
	end

	-- Return whether ANY spender glow is still active.
	for _ in pairs(t) do
		return true
	end
	return false
end

function Addon:Glow_OnGlowShowSpell(spellId, now)
	now = now or GetTime()
	self.state.glowActive = true
	self.state.lastGlowSignalSpellId = spellId
	self:Glow_SetSpellActive(spellId, true)
	-- IMPORTANT: do NOT count procs from this. In Midnight, SHOW often fires only once.
end

function Addon:Glow_OnGlowHideSpell(spellId, now)
	now = now or GetTime()
	self.state.lastGlowSignalSpellId = spellId
	local anyActive = self:Glow_SetSpellActive(spellId, false)
	if anyActive then
		-- Other spender still glowing; do not finalize expiration.
		return
	end
	self:Glow_OnGlowHide(now)
end

function Addon:InitGlowHooks()
	-- In Midnight the UI may repaint spell activation overlays repeatedly.
	-- We hook SpellActivationOverlayFrame (stateful) and apply strict swing-cadence gating
	-- inside Glow_ApplyProcTick() to avoid spam while still capturing the 2nd stack.
	if self.state.glowHooksInited then return end
	self.state.glowHooksInited = true
	self:Glow_InitSAOHooks(true)
end

function Addon:Glow_InitSAOHooks(withRetry)
	if self.state._saoHooksInited then return end
	if not (SpellActivationOverlayFrame and type(SpellActivationOverlayFrame.ShowOverlay) == "function") then
		if withRetry then
			C_Timer.After(0.5, function() if Addon then Addon:Glow_InitSAOHooks(false) end end)
			C_Timer.After(1.5, function() if Addon then Addon:Glow_InitSAOHooks(false) end end)
		end
		return
	end
	self.state._saoHooksInited = true
	self.state._kmOverlayActive = self.state._kmOverlayActive or {}

	hooksecurefunc(SpellActivationOverlayFrame, "ShowOverlay", function(_, overlaySpellId)
		if not Addon or not Addon.state then return end
		if Addon.state.manualPaused then return end
local backend = Addon:GetBackend()
overlaySpellId = tonumber(overlaySpellId) or overlaySpellId
if not IsKMProcOverlayId(overlaySpellId) then return end

local now = GetTime()
Addon.state._kmOverlayAt = now

if backend == "glow" then
	if not Addon.state.inCombat then return end
	if Addon.state._kmOverlayActive[overlaySpellId] then return end
	Addon.state._kmOverlayActive[overlaySpellId] = true
	Addon:Glow_ApplyProcTick(now, "SAO:" .. tostring(overlaySpellId), false)
else
	-- Aura/CDM: use the overlay only as a *timing hint* for secret-safe aura binding and stack direction.
	-- We do NOT count stacks directly from SAO here (too noisy on some builds).
	local st = Addon.state
	if backend == "aura" or backend == "cdm" or (st and st.hybridAuraTruth) then
		st._kmPendingBindUntil = now + 1.00
		st._kmLastOverlayHintAt = now
		if Addon.UpdateAuraIndex then Addon:UpdateAuraIndex(now) end
		-- Try to bind fast; UNIT_AURA may fire before/after SAO depending on build.
		if C_Timer and C_Timer.After and Addon.FindKillingMachineAura then
			C_Timer.After(0.05, function()
				if Addon and Addon.state and Addon.FindKillingMachineAura then
					Addon:FindKillingMachineAura()
				end
			end)
		end
	end
end
	end)

	if type(SpellActivationOverlayFrame.HideOverlay) == "function" then
		hooksecurefunc(SpellActivationOverlayFrame, "HideOverlay", function(_, overlaySpellId)
			if not Addon or not Addon.state then return end
			if Addon.state.manualPaused then return end
			if Addon:GetBackend() ~= "glow" then return end
			if not Addon.state.inCombat then return end
			overlaySpellId = tonumber(overlaySpellId) or overlaySpellId
			if not IsKMProcOverlayId(overlaySpellId) then return end
			-- IMPORTANT: HideOverlay is NOT a reliable "buff ended" signal in Midnight.
			-- The overlay may briefly flash and hide immediately while the KM buff remains active.
			-- Expiration is handled by SPELL_ACTIVATION_OVERLAY_GLOW_HIDE on spender spells.
			Addon.state._kmOverlayActive[overlaySpellId] = nil
		end)
	end

	if type(SpellActivationOverlayFrame.HideAllOverlays) == "function" then
		hooksecurefunc(SpellActivationOverlayFrame, "HideAllOverlays", function()
			if not Addon or not Addon.state then return end
			if Addon:GetBackend() ~= "glow" then return end
			if not Addon.state.inCombat then return end
			-- Same rationale as HideOverlay: do not treat this as expiration.
			Addon.state._kmOverlayActive = {}
		end)
	end

	if self:DbgEnabled() then self:Dbg("SAO hooks enabled") end
end



-- ----------------------------
-- Action-bar fallback: map slots -> spellIDs and listen to UseAction()
--
-- Rationale: if a client build stops firing UNIT_SPELLCAST_SUCCEEDED reliably,
-- we can still create narrow proc-budget windows by observing which action-slot
-- the player clicked/pressed. This is a fallback only; cast events remain primary.
-- ----------------------------

function Addon:InitActionScan()
	if self.state._actionScanInited then return end
	self.state._actionScanInited = true

	-- Build initial map once.
	self:RescanActionSlots()

	-- Post-hook UseAction (safe). We do NOT call protected functions from the hook.
	if type(hooksecurefunc) == "function" and type(UseAction) == "function" then
		hooksecurefunc("UseAction", function(slot)
			if Addon and Addon.GetBackend and Addon:GetBackend() == "glow" then
				Addon:OnUseAction(slot)
			end
		end)
	end

	-- Rescan when bars change (cheap; 120 slots)
	local f = CreateFrame("Frame")
	f:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	f:RegisterEvent("UPDATE_BINDINGS")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")
	f:SetScript("OnEvent", function()
		if not Addon then return end
		Addon:RescanActionSlots()
	end)
	self.state._actionScanFrame = f
end

function Addon:RescanActionSlots()
	-- Only map the handful of spells we care about (fast lookup)
	local wanted = {
		[SPELL_EMPOWERED_RUNE_WEAPON] = true,
		[SPELL_PILLAR_OF_FROST] = true,
		[SPELL_FROST_STRIKE] = true,
		[SPELL_HOWLING_BLAST] = true,
		[SPELL_GLACIAL_ADVANCE] = true,
		[49020] = true,
		[207230] = true,
	}

	local map = {}
	for slot = 1, 120 do
		local t, id = GetActionInfo(slot)
		local spellId
		if t == "spell" then
			spellId = id
		elseif t == "macro" and id then
			spellId = GetMacroSpell(id)
		end
		if spellId and wanted[spellId] then
			map[slot] = spellId
		end
	end
	self.state.actionSlotToSpell = map
	if self:DbgEnabled() then
		local n = 0
		for _ in pairs(map) do n = n + 1 end
		self:Dbg("ACTIONSCAN mapped slots=%d", n)
	end
end

function Addon:OnUseAction(slot)
	-- UseAction fires for everything; we only care about mapped slots.
	local map = self.state.actionSlotToSpell
	if type(map) ~= "table" then return end
	local spellId = map[tonumber(slot) or -1]
	if not spellId then return end
	if self.state.manualPaused then return end
	if self:GetBackend() ~= "glow" then return end

	local now = GetTime()
	if self:DbgEnabled() then
		self:Dbg("USEACTION slot=%s spellId=%s", tostring(slot), tostring(spellId))
	end
	self:Glow_HandlePlayerSpell(spellId, now, "useaction")
	if IsKMSpenderSpellID(spellId) then
		self:Glow_OnSpenderCast(spellId, now)
	end
end




-- ----------------------------
-- Glow backend helpers: attack-speed filter + extra KM sources
--
-- Problem (Midnight): SpellActivationOverlayFrame:ShowOverlay() can be called for UI refresh,
-- not only for real procs. We therefore gate accepted proc-signals using:
--  1) A dual-wield aware rate limit derived from UnitAttackSpeed("player")
--  2) Short "force windows" after player actions that can directly grant KM (ERW / PoF spells)
--
-- This keeps counts stable while still capturing the legitimate 2nd stack.
-- ----------------------------

function Addon:Glow_UpdateAttackSpeed(now)
	now = now or GetTime()
	-- update at most ~3 times/sec
	if (now - (self.state.attackSpeedAt or 0)) < 0.33 then return end
	local mh, oh = UnitAttackSpeed("player")
	-- Ensure numeric types (avoid secret wrappers if any)
	if type(mh) ~= "number" then mh = nil end
	if type(oh) ~= "number" then oh = nil end
	self.state.attackSpeedMH = mh or (self.state.attackSpeedMH or 2.6)
	self.state.attackSpeedOH = oh or 0
	self.state.attackSpeedAt = now
end

function Addon:Glow_GetAttackSpeedParams(now)
	self:Glow_UpdateAttackSpeed(now)
	local mh = tonumber(self.state.attackSpeedMH) or 2.6
	local oh = tonumber(self.state.attackSpeedOH) or 0
	if oh <= 0 then oh = nil end

	-- minSwing: fastest individual hand
	-- pps: combined swings per second across hands
	local minSwing = mh
	local pps = 1 / mh
	if oh then
		minSwing = math.min(mh, oh)
		pps = pps + (1 / oh)
	end

	-- anySwing: expected interval between swings from either hand (harmonic for DW)
	local anySwing = 1 / pps
	self.state._attackPPS = pps
	return mh, oh, minSwing, pps, anySwing
end

function Addon:Glow_AddProcBudget(n, now, window, reason)
	now = now or GetTime()
	n = tonumber(n) or 1
	window = tonumber(window) or 0.45
	local untilTs = now + window
	if untilTs > (self.state.procBudgetUntil or 0) then
		self.state.procBudgetUntil = untilTs
	end
	self.state.procBudget = math.min(8, (self.state.procBudget or 0) + n)
	self.state.procBudgetReason = reason
	if self:DbgEnabled() then
		self:Dbg("PROC_BUDGET +%d reason=%s budget=%d until=%.3f", n, tostring(reason), tonumber(self.state.procBudget or 0), tonumber(self.state.procBudgetUntil or 0))
	end
end

function Addon:Glow_HasProcBudget(now)
	local b = tonumber(self.state.procBudget or 0) or 0
	if b <= 0 then return false end
	local untilTs = tonumber(self.state.procBudgetUntil or 0) or 0
	if now > untilTs then
		self.state.procBudget = 0
		return false
	end
	return true
end

function Addon:Glow_ConsumeProcBudget()
	local b = tonumber(self.state.procBudget or 0) or 0
	if b <= 0 then return end
	self.state.procBudget = b - 1
end

function Addon:Glow_HandlePlayerSpell(spellId, now, source)
	now = now or GetTime()
	source = source or "cast"

	-- Track Pillar of Frost locally (avoid aura reads)
	if spellId == SPELL_PILLAR_OF_FROST then
		self.state.pofUntil = now + POF_DURATION
		if self:DbgEnabled() then self:Dbg("POF start via %s until=%.3f", tostring(source), tonumber(self.state.pofUntil or 0)) end
		return
	end

	-- Empowered Rune Weapon: immediate KM stack (force window)
	if spellId == SPELL_EMPOWERED_RUNE_WEAPON then
		-- ERW gives an immediate KM stack in your build.
		self:Glow_ApplyProcTick(now, "ERW", true)
		-- Suppress a potential overlay flash for the same proc.
		self.state.suppressAlertUntil = now + 0.20
		return
	end

	-- During Pillar of Frost, these spells can grant KM in your build.
	if now <= (tonumber(self.state.pofUntil or 0) or 0) then
		if spellId == SPELL_FROST_STRIKE or spellId == SPELL_GLACIAL_ADVANCE or spellId == SPELL_HOWLING_BLAST then
			-- During Pillar, these spells can grant KM (per your rules).
			self:Glow_ApplyProcTick(now, "POF:" .. tostring(spellId), true)
			-- Suppress a potential overlay flash for the same proc.
			self.state.suppressAlertUntil = now + 0.20
			return
		end
	end
end


function Addon:Glow_OnProcSignal(now)
	now = now or GetTime()
	-- Count procs only while in combat (matches the addon definition/window).
	if not self.state.inCombat then return end

	local srcSpellID = self.state.lastGlowSignalSpellId
	if self.DevToolsEnabled and self:DevToolsEnabled() and self:DevToolsVerbose() then self:DevLog("PROC_SIGNAL spellId=%s stacks=%d", tostring(srcSpellID), tonumber(self.state.stacks or 0) or 0) end
	local stacksBefore = tonumber(self.state.stacks or 0) or 0

	-- Primary/secondary SAO signal dedup:
	-- Some clients call ShowOverlay for both 51124 and 438833 for the same proc tick.
	-- Treat 51124/51128 as primary; accept 438833 only if no primary arrived recently.
	if srcSpellID == 438833 then
		local lp = self.state._kmLastPrimaryOverlayAt or 0
		local sd = self:GetDevFilterValue("secondaryDedup", 0.12) or 0.12
		if (now - lp) < sd then
			if self:DbgEnabled() then
				self:Dbg("PROC_SIGNAL drop secondary-near-primary dt=%.3f < %.3f srcSpell=%s", (now - lp), sd, tostring(srcSpellID))
			end
			return
		end
	elseif srcSpellID == 51124 or srcSpellID == 51128 then
		self.state._kmLastPrimaryOverlayAt = now
	end

	-- 2) Hard micro-dedup (multiple calls inside the same UI tick)
	local dtAny = now - (self.state._kmLastAnySignalAt or 0)
	local micro = self:GetDevFilterValue("microDedup", 0.008) or 0.008
	if dtAny < micro then
		if self:DbgEnabled() then
			self:Dbg("PROC_SIGNAL drop micro-dedup dt=%.3f srcSpell=%s", dtAny, tostring(srcSpellID))
		end
		return
	end
	self.state._kmLastAnySignalAt = now

	-- 3) Dual-wield aware gates derived from attack speed (filters UI refresh spam)
	local _, _, minSwing, pps, anySwing = self:Glow_GetAttackSpeedParams(now)
	-- pps = theoretical max swings/sec. We use it as a loose upper bound for KM signal acceptance.
	local sec = math.floor(now)
	if self.state._kmProcSec ~= sec then
		self.state._kmProcSec = sec
		self.state._kmProcSecCount = 0
	end

	local capPerSec
	if stacksBefore >= 2 then
		-- At cap, ShowOverlay() may be called for UI maintenance. Gate strictly by swing rate.
		-- Use combined swing rate (pps) to allow realistic overcap procs without spam.
		capPerSec = math.max(1, math.min(3, math.floor((pps or 0) * 1.25) + 1))
	else
		-- Below cap we must be permissive to catch fast back-to-back procs (DW/haste).
		capPerSec = math.max(3, math.min(8, math.floor((pps or 0) * 2.0) + 2))
	end

	-- 4) Force window after specific player actions (ERW / PoF spells)
	local forced = self:Glow_HasProcBudget(now)

	-- 5) Time gate (stack-aware)
	local last = self.state.lastProcSignalAt or 0
	local dt = now - last

	-- Base interval derived from minSwing but intentionally permissive for 0->1 and 1->2.
	-- We only tighten hard at 2 stacks to suppress maintenance spam.
	local baseInterval = (minSwing or 2.6) * 0.14
	if baseInterval < 0.07 then baseInterval = 0.07 end
	if baseInterval > 0.22 then baseInterval = 0.22 end

	local minInterval
	if stacksBefore <= 0 then
		minInterval = baseInterval * 0.65
		if minInterval < 0.05 then minInterval = 0.05 end
	elseif stacksBefore == 1 then
		minInterval = baseInterval * 0.85
		if minInterval < 0.06 then minInterval = 0.06 end
	else
		-- At 2 stacks, ShowOverlay() is often called for UI maintenance.
		-- Gate by swing rate: allow at most ~1 proc per combined swing interval.
		-- Use anySwing (combined MH/OH interval). Spells that grant KM bypass via procBudget (forced=true).
		minInterval = (anySwing or (minSwing or 2.6)) * 0.85
		if minInterval < 0.90 then minInterval = 0.90 end
		-- Avoid extreme delays on very slow weapons; forced windows still bypass.
		if minInterval > 3.00 then minInterval = 3.00 end
	end

	-- Burst allowance for true back-to-back procs (dual-wield alignment / haste).
	local burstAllowed = false
	if (not forced) and (stacksBefore <= 1) and dt < minInterval then
		if dt <= 0.25 and (now - (self.state._kmLastBurstAt or 0)) > ((minSwing or 2.6) * 0.25) then
			burstAllowed = true
		end
	end

	-- Per-second cap gate
	if (not forced) and (self.state._kmProcSecCount or 0) >= capPerSec then
		if self:DbgEnabled() then
			self:Dbg("PROC_SIGNAL drop cap/sec=%d stacksBefore=%d srcSpell=%s pps=%.2f", tonumber(capPerSec), tonumber(stacksBefore), tostring(srcSpellID), tonumber(pps or 0))
		end
		return
	end

	-- Time gate
	if (not forced) and (not burstAllowed) and dt < minInterval then
		if self:DbgEnabled() then
			self:Dbg("PROC_SIGNAL drop throttle dt=%.3f < %.2f stacksBefore=%d srcSpell=%s minSwing=%.2f", dt, tonumber(minInterval), tonumber(stacksBefore), tostring(srcSpellID), tonumber(minSwing or 0))
		end
		return
	end

	-- Accept signal
	self.state.lastProcSignalAt = now
	self.state._kmProcSecCount = (self.state._kmProcSecCount or 0) + 1
	if burstAllowed then self.state._kmLastBurstAt = now end
	if forced then self:Glow_ConsumeProcBudget() end

	if self:DbgEnabled() then
		self:Dbg("PROC_SIGNAL accepted srcSpell=%s stacksBefore=%d forced=%s burst=%s minInterval=%.2f capPerSec=%d", tostring(srcSpellID), tonumber(stacksBefore), tostring(forced), tostring(burstAllowed), tonumber(minInterval), tonumber(capPerSec))
	end

	-- Apply accounting
	self.counters.procs = (self.counters.procs or 0) + 1

	if stacksBefore < 2 then
		self.state.stacks = stacksBefore + 1
	else
		-- Overcap proc (proc arrived while already at 2 stacks)
		self.counters.overcap = (self.counters.overcap or 0) + 1
		self.counters.wasted  = (self.counters.wasted  or 0) + 1
		if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
	end

	if self:DbgEnabled() then
		self:Dbg("PROC_APPLY stacksAfter=%d procs=%d overcap=%d wasted=%d",
			tonumber(self.state.stacks or 0),
			tonumber(self.counters.procs or 0),
			tonumber(self.counters.overcap or 0),
			tonumber(self.counters.wasted or 0)
		)
	end

	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(self.state.stacks) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

function Addon:Glow_OnGlowHide(now)
	now = now or GetTime()
	-- Dedup hide spam from multiple buttons
	if (now - (self.state.lastGlowHideAt or 0)) < 0.05 then return end
	self.state.lastGlowHideAt = now

	self.state.glowActive = false

	-- Defer classification to let UNIT_SPELLCAST_SUCCEEDED run first (event ordering)
	C_Timer.After(0, function()
		if not Addon or not Addon.state then return end
		if Addon.state.manualPaused then return end
		if Addon:GetBackend() ~= "glow" then return end

		local stacks = Addon.state.stacks or 0
		if stacks <= 0 then return end

		-- If we just spent, do not treat as expired
		if (GetTime() - (Addon.state.lastSpenderAt or 0)) <= 0.25 then
			if Addon:DbgEnabled() then Addon:Dbg("GLOW_HIDE suppressed (recent spender) stacks=%d", tonumber(stacks or 0)) end
			return
		end

		-- Expired => wasted
		Addon.counters.expired = (Addon.counters.expired or 0) + stacks
		Addon.counters.wasted  = (Addon.counters.wasted  or 0) + stacks
		Addon.state.stacks = 0
		if Addon:DbgEnabled() then Addon:Dbg("EXPIRED stacks=%d expired=%d wasted=%d", tonumber(stacks or 0), tonumber(Addon.counters.expired or 0), tonumber(Addon.counters.wasted or 0)) end

		if Addon.UI and Addon.UI.ShowWasted then Addon.UI:ShowWasted() end
		if Addon.UI and Addon.UI.UpdateStacks then Addon.UI:UpdateStacks(0) end
		if Addon.UI and Addon.UI.UpdateCounters then Addon.UI:UpdateCounters() end
	end)
end

function Addon:Glow_OnSpenderCast(spellId, now)
	now = now or GetTime()
	local stacks = tonumber(self.state.stacks or 0) or 0
	-- Always mark spender time to suppress immediate hide->expired
	self.state.lastSpenderAt = now

	if stacks <= 0 then
		return
	end

	-- In retail, KM can stack; different talents may consume 1 or all.
	-- In this build, Obliterate/Frostscythe consume ALL current KM stacks (Killing Streak).
	-- We apply the spend immediately so glow-hide does not misclassify the drop as expiry.
	local consumed = stacks
	if consumed < 0 then consumed = 0 end
	if consumed > stacks then consumed = stacks end

	if self:DbgEnabled() then
		self:Dbg("SPENDER spellId=%s consume=%d stacksBefore=%d usedBefore=%d", tostring(spellId), consumed, stacks, tonumber(self.counters.used or 0))
	end

	self.counters.used = (self.counters.used or 0) + consumed
	self.counters.consumed = self.counters.used
	self.state.stacks = stacks - consumed

	if self:DbgEnabled() then
		self:Dbg("SPENDER applied usedAfter=%d stacksAfter=%d", tonumber(self.counters.used or 0), tonumber(self.state.stacks or 0))
	end

	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(self.state.stacks or 0) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

-- ----------------------------
-- Overcap confirmation (next tick to avoid CL/UNIT_AURA race)
-- ---------------------------- (next tick to avoid CL/UNIT_AURA race)
-- ----------------------------
function Addon:QueueOvercapConfirm()
	if self.state.overcapPending then return end
	self.state.overcapPending = true

	C_Timer.After(0, function()
		if not Addon or not Addon.state then return end
		Addon.state.overcapPending = false

		if not Addon:IsCountingGains() then return end

		local now = GetTime()
		local curStacks = Addon:GetKMStacksFromAuras()
		if curStacks < 2 then return end

		-- If we just gained a stack (1->2) around this time, this is NOT overcap.
		if (now - (Addon.state.lastStackGainAt or 0)) <= GAIN_RACE_WINDOW then
			return
		end

		-- dedup
		if (now - (Addon.state.lastOvercapAt or 0)) <= OVERCAP_DEDUP then
			return
		end

		Addon.state.lastOvercapAt = now

		Addon.counters.procs = Addon.counters.procs + 1
		Addon.counters.overcap = Addon.counters.overcap + 1
		Addon.counters.wasted = Addon.counters.wasted + 1

		if Addon.UI and Addon.UI.ShowWasted then
			Addon.UI:ShowWasted()
		end
		if Addon.UI and Addon.UI.UpdateCounters then
			Addon.UI:UpdateCounters()
		end
	end)
end

-- ----------------------------
-- Stack sync + accounting (UNIT_AURA)
-- ----------------------------
function Addon:SyncStacksFromAura()
	local old = self.state.stacks
	local now = GetTime()
	local new = self:GetKMStacksFromAuras()

	-- Track aura expiration to detect overcap refresh (KM refresh while already at cap).
	local exp
if self:GetBackend() == "aura" or (self.state and self.state.hybridAuraTruth) then
	-- Prefer the same selector as stacks (supports secret-safe fallback via auraInstanceID).
	local aura = self:FindKillingMachineAura()
	if aura then
		exp = aura.expirationTime or aura.expiration or aura.expirationtime
	end
	if KMPT_IsSecret and KMPT_IsSecret(exp) then exp = nil end
end

	-- Same stack count: still may be an overcap refresh if expiration time jumps while stacks==2.
	if new == old then
		if exp then
			local lastExp = self.state.lastAuraExp
			self.state.lastAuraExp = exp

			if self:IsCountingGains() and self.state.inCombat and self.state.sessionActive and new == 2 and lastExp then
				-- Refresh will increase expirationTime; ignore near-instant races after a real stack gain.
				if exp > (lastExp + 0.20) and (now - (self.state.lastStackGainAt or 0)) > GAIN_RACE_WINDOW then
					if (now - (self.state.lastOvercapAt or 0)) > OVERCAP_DEDUP then
						self.state.lastOvercapAt = now
						self.counters.procs = self.counters.procs + 1
						self.counters.overcap = self.counters.overcap + 1
						self.counters.wasted = self.counters.wasted + 1
						if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
						if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
					end
				end
			end
		end

		if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(new) end
		if (not self.state.inCombat) and self.state.sessionActive and new == 0 then
			self.state.sessionActive = false
			self.state.spendTokens = 0
			self.state.pendingLoss = 0
		end
		return
	end

	-- If stacks changed, keep lastAuraExp in sync.
	if exp then self.state.lastAuraExp = exp end

	self.state.stacks = new
	local delta = new - old

	-- Gains: real stack increases
	if self:IsCountingGains() and delta > 0 then
		self.counters.procs = self.counters.procs + delta
		self.state.lastStackGainAt = now
	end

	-- Losses: split spent vs expired
	if self:IsCountingLosses() and delta < 0 then
		local lost = -delta

		-- expire stale tokens
		local tokens = self.state.spendTokens or 0
		if tokens > 0 and (now - (self.state.lastSpenderAt or 0)) > SPEND_WINDOW then
			self.state.spendTokens = 0
			tokens = 0
		end

		local spent = 0
		if tokens > 0 then
			spent = math.min(lost, tokens)
			self.state.spendTokens = tokens - spent
		end

		if spent > 0 then
			self.counters.used = self.counters.used + spent
			self.counters.consumed = self.counters.used
		end

		local expLost = lost - spent
		if expLost > 0 then
			self.counters.expired = self.counters.expired + expLost
			self.counters.wasted  = self.counters.wasted  + expLost

			self.state.pendingLoss = (self.state.pendingLoss or 0) + expLost
			self.state.pendingLossAt = now

			if self.UI and self.UI.ShowWasted then
				self.UI:ShowWasted()
			end
		end
	end

	if (not self.state.inCombat) and self.state.sessionActive and new == 0 then
		self.state.sessionActive = false
		self.state.spendTokens = 0
		self.state.pendingLoss = 0
	end

	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(new) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

-- ----------------------------
-- Events
-- ----------------------------
local EventFrame = CreateFrame("Frame")
EventFrame:SetScript("OnEvent", function(_, event, ...)
	if Addon[event] then Addon[event](Addon, ...) end
end)

EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterUnitEvent("UNIT_AURA", "player")
EventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
-- Midnight (12.0+): COMBAT_LOG_EVENT_UNFILTERED is restricted.
-- Attempting to register it can trigger [ADDON_ACTION_FORBIDDEN] errors and/or taint cascades.
-- We keep the handler for development/reference but do not register CLEU by default.
-- (If Blizzard re-opens CLEU, re-enable registration behind an explicit opt-in flag.)
EventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
EventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
EventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_SHOW")
EventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_HIDE")

function Addon:ADDON_LOADED(name)
	if name ~= ADDON_NAME then return end
	_G[self.DB_NAME] = _G[self.DB_NAME] or {}
	local db = _G[self.DB_NAME]
	ApplyDefaults(db, DEFAULT_DB)

		-- 12.x: disable persisted kmAuraSpellId (can mis-bind unrelated auras under SecretValue rules)
		db.kmAuraSpellId = nil


	-- Midnight migration: the original defaults assumed aura truth, but in 12.0 many proc auras become secret/hidden.
	-- Do a one-time migration so fresh installs (and old SavedVariables that never set a backend) behave correctly.
	local iface = select(4, GetBuildInfo())
	if type(iface) == "number" and iface >= 120000 then
		if db._kmpt_migrated120_backend ~= true then
			-- If the user never intentionally selected a backend, force the safer default once.
			if db.backend == nil or db.backend == "aura" then
				db.backend = "glow"
			end
			db._kmpt_migrated120_backend = true
		end
		if db.hybridAuraTruth == nil then db.hybridAuraTruth = false end
		if type(db.cdm) == "table" then
			-- One-time defaults refresh: older builds used 0.25s and could miss fast proc pulses.
			if db.cdm.procMinInterval == nil or db.cdm.procMinInterval == 0.25 then db.cdm.procMinInterval = 0.14 end
			if db.cdm.overcapMinInterval == nil then db.cdm.overcapMinInterval = 0.18 end
			if db.cdm.scanInterval == nil then db.cdm.scanInterval = 0.50 end
			if db.cdm.useTextHooks == nil then db.cdm.useTextHooks = false end
			if db.cdm.ignoreZeroIfAuraPresent == nil then db.cdm.ignoreZeroIfAuraPresent = false end
			if db.cdm.ignoreHideConfirmIfAuraPresent == nil then db.cdm.ignoreHideConfirmIfAuraPresent = false end
		end
	end
end

function Addon:PLAYER_LOGIN()
	-- Init debug hooks early (safe; hooks are no-ops unless enabled)
	if self:DbgEnabled() then self:InitDebugHooks() end
	self.state.playerGUID = UnitGUID("player")

	self.state.inCombat = UnitAffectingCombat("player") and true or false
	local db = self:GetDB()
	self.state.hybridAuraTruth = (db and db.hybridAuraTruth) and true or false
	-- Safety: disable experimental proc credit filter (can cause false drops/spam).
	self.state.useCreditFilter = false
	self.state._kmProcCredit = 0
	self.state._kmProcCreditAt = GetTime()

	local backend = self:GetBackend()
	if backend == "aura" then
		self.state.stacks = self:GetKMStacksFromAuras()
	elseif backend == "cdm" and self.CDM_ReadKMState then
		local stacks = select(1, self:CDM_ReadKMState(GetTime()))
		self.state.stacks = (KMPT_TryNumber(stacks) or 0)
	else
		self.state.stacks = 0
	end
	self.state.sessionActive = self.state.inCombat or (self.state.stacks > 0)

	-- load backend setting
	self:GetBackend()

	if self.UI and self.UI.OnLogin then self.UI:OnLogin() end
	if self.Minimap and self.Minimap.OnLogin then self.Minimap:OnLogin() end

	-- Apply current backend wiring (glow / cdm / aura)
	self:ApplyBackend(true)

	if self.UI and self.UI.UpdateStacks then
		self.UI:UpdateStacks(self.state.stacks)
	end

	-- If we login in combat, start fresh fight window
	if self.state.inCombat and not self.state.manualPaused then
		self.state.sessionActive = true
		self:BeginWindowSeed()
	end
end

function Addon:PLAYER_REGEN_DISABLED()
	-- Start fight window automatically
	self.state.inCombat = true
	self.state.sessionActive = true
	self.state._hybridChecked = false

	-- Sync stacks once without counting deltas (BeginWindowSeed seeds procs with current stacks)
	if not self.state.manualPaused then
		self:BeginWindowSeed()
	else
		self:SyncStacksFromAura()
	end
end

function Addon:PLAYER_REGEN_ENABLED()
	self.state.inCombat = false
	-- keep sessionActive until stacks drop to 0 (so expirations post-combat are counted)
	if (self.state.stacks or 0) <= 0 then
		self.state.sessionActive = false
		self.state.spendTokens = 0
		self.state.pendingLoss = 0
	end
end

-- Infer KM stack direction using UNIT_AURA updateInfo + Spender timing hints (secret-safe).
-- We DO NOT read aura.applications when it is a secret value.
function Addon:_AuraUpdateInfoHandleKM(now, updateInfo)
	if type(updateInfo) ~= "table" then return end
	local st = self.state
	local backend = self:GetBackend()
	if not st or st.manualPaused then return end

	local function IsSecret(v)
		return (type(issecretvalue) == "function") and issecretvalue(v)
	end

	local function GetAid(aura)
		if not aura then return nil end
		local aid = aura.auraInstanceID
		if aid ~= nil and IsSecret(aid) then return nil end
		return tonumber(aid) or aid
	end

	-- ----------------------------
	-- Binding: parse removing, adding, updating.
	-- ----------------------------
	local oldAidKM = st._kmAuraInstanceID
	local isOldRemoved = false
	local removed = updateInfo.removedAuraInstanceIDs
	if type(removed) == "table" and oldAidKM then
		for _, rid in ipairs(removed) do
			if rid ~= nil and IsSecret(rid) then rid = nil end
			rid = tonumber(rid) or rid
			if rid == oldAidKM then
				isOldRemoved = true
				break
			end
		end
	end

	local added = updateInfo.addedAuras
	local newKMAdded = false
	local newKMAid = nil
	if type(added) == "table" then
		for _, a in ipairs(added) do
			local aid = GetAid(a)
			if aid then
				local sid = a.spellId or a.spellID
				if sid ~= nil and not IsSecret(sid) then
					local sidNum = tonumber(sid)
					if sidNum and self:IsKMAuraSpellId(sidNum) then
						newKMAdded = true
						newKMAid = aid
						break
					end
				end
			end
		end
		
		-- 1->2 or 0->1 Replacement: if old was removed, and exactly 1 new secret aura arrived simultaneously
		if isOldRemoved and (not newKMAdded) and #added == 1 then
			local newAid = GetAid(added[1])
			if newAid then
				newKMAdded = true
				newKMAid = newAid
			end
		end
	end

	local isOldUpdated = false
	if oldAidKM and not isOldRemoved then
		local updated = updateInfo.updatedAuras
		if type(updated) == "table" then
			for _, a in ipairs(updated) do
				if GetAid(a) == oldAidKM then
					isOldUpdated = true
					break
				end
			end
		end
	end

	-- ----------------------------
	-- Direction logic:
	-- newly added -> gain! (handles 0->1, 1->2, 2->2 replacements)
	-- updated -> duration updates (ignore for gaining). Spenders are predicted.
	-- removed -> 0 stacks (unless instantly replaced by a new KM aura)
	-- ----------------------------

	local function ApplyGainOnce()
		local hs = (KMPT_TryNumber(st._kmHintStacks) or KMPT_TryNumber(st.stacks) or 0)
		if hs < 0 then hs = 0 end

		if hs < 2 then
			hs = hs + 1
			st._kmHintStacks = hs
		else
			-- Overcap gain while already at cap (dedup)
			local last = (KMPT_TryNumber(st._kmLastOvercapHintAt) or 0)
			if (now - last) > 0.60 then
				st._kmLastOvercapHintAt = now
				if backend ~= "cdm" and (backend == "aura" or (st and st.hybridAuraTruth)) and self:IsCountingGains() and st.inCombat and st.sessionActive then
					self.counters.procs = self.counters.procs + 1
					self.counters.overcap = self.counters.overcap + 1
					self.counters.wasted = self.counters.wasted + 1
					if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
					if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
				end
			end
			st._kmHintStacks = 2
		end
	end

	if newKMAdded then
		-- Gained an aura!
		st._kmAuraInstanceID = newKMAid
		if st._kmSpendHintUntil and now <= st._kmSpendHintUntil then
			local hs = KMPT_TryNumber(st._kmHintStacks) or 0
			if hs == 0 then
				-- We predicted 1->0, but a new aura appeared. It's a rapid back-to-back proc!
				ApplyGainOnce()
				st._kmSpendHintUntil = 0
			else
				-- Predicted 2->1, stacked dropped, and aura ID was replaced simultaneously?
				-- Don't gain. Ensure we land at least at 1.
				st._kmHintStacks = math.max(1, hs)
				st._kmSpendHintUntil = 0
			end
		else
			ApplyGainOnce()
		end

	elseif isOldUpdated then
		if st._kmSpendHintUntil and now <= st._kmSpendHintUntil then
			-- Expected stack loss happened without tearing down the aura ID (just an update).
			-- We already decremented stacks predictively. Consume the hint.
			st._kmSpendHintUntil = 0
		else
			-- If an update occurred, it might be a duration sync OR a 1->2 proc (secret).
			-- Cross-validate precisely with the screen-center HUD overlays (SAO).
			local saoStacks = self:CountKMOverlays()
			if saoStacks == 2 and (KMPT_TryNumber(st._kmHintStacks) or 0) == 1 then
				-- We got an aura update right when the UI shows 2 screen-center overlays!
				ApplyGainOnce()
			elseif saoStacks == 1 and (KMPT_TryNumber(st._kmHintStacks) or 0) == 0 then
				ApplyGainOnce()
			end
		end

	elseif isOldRemoved then
		-- Aura fully destroyed.
		st._kmHintStacks = 0
		st._kmAuraInstanceID = nil
		st._kmSpendHintUntil = 0

		if self:GetBackend() == "cdm" and self.CDM_OnStacksChanged then
			self.state._cdmStacks = 0
			self:CDM_OnStacksChanged(0, now, "aura-removed")
		end
	end
end

function Addon:UNIT_AURA(unit, updateInfo)
	if unit ~= "player" then return end
	if self.state.manualPaused then return end

	local backend = self:GetBackend()
	local now = GetTime()

	-- Always consume updateInfo to maintain KM auraInstanceID binding and detect removals (secret-safe).
	-- This does NOT read aura.applications/name/spellId directly.
	if updateInfo and type(updateInfo) == "table" then
		self:_AuraUpdateInfoHandleKM(now, updateInfo)
	end

	-- Only sync stack counts from aura tables when explicitly requested (backend==aura) OR hybrid is enabled.
	-- This prevents aura reads (often secret/hidden in Midnight) from clobbering other backends.
	if backend == "aura" or (self.state and self.state.hybridAuraTruth) then
		if self.UpdateAuraIndex then self:UpdateAuraIndex(now) end
		self:SyncStacksFromAura()
	end

	-- TestLab forwarding (no extra event registration; safe in combat)
	local lab = self.TestLab
	if lab and lab.OnUnitAura and (lab.IsAuraEnabled and lab:IsAuraEnabled()) then
		lab:OnUnitAura(now, updateInfo, self.state and self.state._kmAuraInstanceID, self.state and self.state.stacks)
	end
end


function Addon:UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellId)
	if unit ~= "player" then return end
	if self.state.manualPaused then return end

	local backend = self:GetBackend()
	local now = GetTime()
	spellId = tonumber(spellId) or spellId

	-- TestLab forwarder
	local lab = self.TestLab
	if lab and lab.OnCastSucceeded and (lab.IsCastEnabled and lab:IsCastEnabled()) then
		lab:OnCastSucceeded(now, spellId)
	end

	if self:DbgEnabled() then
		self:Dbg("EVT_CAST_SUCCEEDED spellId=%s backend=%s stacks=%s", tostring(spellId), tostring(backend), tostring(self.state.stacks or 0))
	end

	-- Glow backend: track extra KM sources via player spells (budget windows)
	if backend == "glow" then
		self:Glow_HandlePlayerSpell(spellId, now, "cast")
	end

	-- Spenders: mark spend time for all backends.
	if IsKMSpenderSpellID(spellId) then
		self.state.lastSpenderAt = now

		if backend == "glow" then
			self:Glow_OnSpenderCast(spellId, now)
			-- Hybrid mode still needs spender tokenization for correct "spent vs expired" accounting.
			if self.state and self.state.hybridAuraTruth then
				-- Fallback tokenization in case COMBAT_LOG is throttled/blocked.
				-- Tokenize spender as consuming ONE charge.
				local stacksNow = (KMPT_TryNumber(self.state._kmHintStacks) or KMPT_TryNumber(self.state.stacks) or 0)
				local pending = (KMPT_TryNumber(self.state.pendingLoss) or 0)
				if stacksNow > 0 or pending > 0 then
					self.state.lastSpenderAt = now
					self.state._kmSpendHintUntil = now + 0.60
					self.state.spendTokens = math.min(2, (self.state.spendTokens or 0) + 1)
					self:TryRetroFixSpent(now)
					if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
				end
			end
		elseif backend == "cdm" then
			-- Predictive spend: CDM stack text can be secret/unreliable. We therefore decrement our internal counter on the spender cast.
			local stacksNow = (KMPT_TryNumber(self.state._cdmStacks) or KMPT_TryNumber(self.state.stacks) or 0)
			if stacksNow > 0 then
				self.state._cdmRecentSpenderAt = now
				local consumeAll = false
				local db = self:GetDB()
				if db and type(db.spenders) == "table" then consumeAll = db.spenders.consumeAllStacks and true or false end
				local newStacks = consumeAll and 0 or math.max(0, stacksNow - 1)
				self.state._cdmStacks = newStacks
				if self.CDM_OnStacksChanged then
					self:CDM_OnStacksChanged(newStacks, now, "spender-predict")
				else
					self.state.stacks = newStacks
					if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(newStacks) end
					if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
				end
			end
		elseif backend == "aura" or (self.state and self.state.hybridAuraTruth) then
			-- Fallback tokenization in case COMBAT_LOG is throttled/blocked.
			-- KM is a 2-charge buff in modern Frost DK: each spender consumes ONE charge.
			local stacksNow = (KMPT_TryNumber(self.state._kmHintStacks) or KMPT_TryNumber(self.state.stacks) or 0)
			local pending = (KMPT_TryNumber(self.state.pendingLoss) or 0)
			local add = 0
			if stacksNow > 0 or pending > 0 then add = 1 end

			if add > 0 then
				self.state.lastSpenderAt = now
				self.state._kmSpendHintUntil = now + 0.60
				-- Predict the loss immediately for UI responsiveness (will be reconciled by aura sync).
				if stacksNow > 0 then
					self.state._kmHintStacks = math.max(0, stacksNow - 1)
				end

				self.state.spendTokens = math.min(2, (self.state.spendTokens or 0) + 1)
				self:TryRetroFixSpent(now)
				if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
			end
		end
	end
end


function Addon:SPELL_ACTIVATION_OVERLAY_GLOW_SHOW(spellId, ...)
	if self:DbgEnabled() then self:Dbg("EVT_GLOW_SHOW spellId=%s backend=%s stacks=%s", tostring(spellId), tostring(self:GetBackend()), tostring(self.state.glowStacks or self.state.stacks)) end
	if self.DevToolsEnabled and self:DevToolsEnabled() and self:DevToolsVerbose() then self:DevLog("EVT_GLOW_SHOW spellId=%s stacks=%s", tostring(spellId), tostring(self.state.glowStacks or self.state.stacks)) end
	if self.state.manualPaused then return end
	-- Lifecycle signal comes as the *highlighted spell* (Obliterate/Frostscythe), not the KM overlay id.
	if not IsKMSpenderSpellID(spellId) then return end

	local now = GetTime()

	-- Always record overlay timing. This is used for secret-safe auraInstanceID binding
	-- even when backend is not "glow".
	self.state._kmOverlayAt = now
	self.state._kmPendingBindUntil = now + 1.00

	-- Only treat this as a *gain hint* when we currently believe stacks are 0.
	-- (SAO may re-show for layout reasons while KM is already active.)
	local cur = KMPT_TryNumber(self.state._kmHintStacks) or KMPT_TryNumber(self.state._cdmStacks) or KMPT_TryNumber(self.state.stacks) or 0
	if cur <= 0 then
		self.state._kmHintStacks = 1 -- Trust the glow immediately for 0->1
		
		local be = self:GetBackend()
		if be ~= "cdm" and (be == "aura" or (self.state and self.state.hybridAuraTruth)) and self:IsCountingGains() and self.state.inCombat and self.state.sessionActive then
			self.counters.procs = (self.counters.procs or 0) + 1
			if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
		end
	end

	-- TestLab forwarder
	local lab = self.TestLab
	if lab and lab.OnSAOShow and (lab.IsSAOEnabled and lab:IsSAOEnabled()) then
		lab:OnSAOShow(now, spellId)
	end
	if self:GetBackend() == "glow" then
		self:Glow_OnGlowShowSpell(spellId, now)
	end
end

-- Screen-center HUD overlay handling
function Addon:SPELL_ACTIVATION_OVERLAY_SHOW(spellId)
	if self.state.manualPaused then return end
	if type(spellId) == "number" and self:IsKMAuraSpellId(spellId) then
		-- Evaluated safely on next frame when SAO frame has fully processed its children collection
		C_Timer.After(0, function() self:SAO_EvaluateGain() end)
	end
end

function Addon:SPELL_ACTIVATION_OVERLAY_HIDE(spellId)
	if self.state.manualPaused then return end
	if type(spellId) == "number" and self:IsKMAuraSpellId(spellId) then
		C_Timer.After(0, function() self:SAO_EvaluateGain() end)
	end
end

function Addon:SAO_EvaluateGain()
	local saoStacks = self:CountKMOverlays()
	local hs = (KMPT_TryNumber(self.state and self.state._kmHintStacks) or 0)
	
	if saoStacks > hs then
		self.state._kmHintStacks = saoStacks
		
		-- Only apply gain counters if we are using aura/hybrid
		local be = self:GetBackend()
		if be ~= "cdm" and (be == "aura" or (self.state and self.state.hybridAuraTruth)) and self:IsCountingGains() and self.state.inCombat and self.state.sessionActive then
			local diff = saoStacks - hs
			self.counters.procs = self.counters.procs + diff
			if hs >= 2 then
				-- Overcap
				self.counters.overcap = self.counters.overcap + diff
				self.counters.wasted = self.counters.wasted + diff
				if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
			end
			if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
		end
		if self.DevToolsEnabled and self:DevToolsEnabled() and self:DevToolsVerbose() then
			self:DevLog("SAO evaluated gain: %d -> %d", hs, saoStacks)
		end
	elseif saoStacks < hs then
		-- Spenders or duration expires naturally decrement this normally, but SAO acts as a safety net.
		self.state._kmHintStacks = saoStacks
	end
end

function Addon:SPELL_ACTIVATION_OVERLAY_GLOW_HIDE(spellId, ...)
	if self:DbgEnabled() then self:Dbg("EVT_GLOW_HIDE spellId=%s backend=%s stacks=%s", tostring(spellId), tostring(self:GetBackend()), tostring(self.state.glowStacks or self.state.stacks)) end
	if self.DevToolsEnabled and self:DevToolsEnabled() and self:DevToolsVerbose() then self:DevLog("EVT_GLOW_HIDE spellId=%s stacks=%s", tostring(spellId), tostring(self.state.glowStacks or self.state.stacks)) end
	if self.state.manualPaused then return end
	if not IsKMSpenderSpellID(spellId) then return end
	local now = GetTime()
	local lab = self.TestLab
	if lab and lab.OnSAOHide and (lab.IsSAOEnabled and lab:IsSAOEnabled()) then
		lab:OnSAOHide(now, spellId)
	end
	if self:GetBackend() ~= "glow" then return end
	self:Glow_OnGlowHideSpell(spellId, GetTime())
end

function Addon:COMBAT_LOG_EVENT_UNFILTERED()
	if self.state.manualPaused then return end

	-- Fast gate: do nothing unless TestLab wants CLEU and/or the (optional) CLEU logic is enabled.
	local lab = self.TestLab
	local labOn = (lab and lab.IsCLEUEnabled and lab:IsCLEUEnabled()) and true or false
	local db = self:GetDB()
	local logicOn = (db and db.cleu and db.cleu.enableLogic) and true or false
	if not labOn and not logicOn then return end

	local _, subevent, _, sourceGUID, _, _, _, destGUID, _, _, _, spellId, spellName, _, auraType, amount =
		CombatLogGetCurrentEventInfo()
	if not subevent then return end

	local pg = self.state.playerGUID
	if not pg then pg = UnitGUID("player"); self.state.playerGUID = pg end
	if not pg then return end

	-- TestLab: log only relevant events (avoid spam)
	if labOn and lab and lab.OnCLEU then
		local logIt = false
		if destGUID == pg and self.IsKMAuraSpellId and self:IsKMAuraSpellId(spellId) then
			-- aura lifecycle/dose/refresh/remove
			if type(subevent) == "string" and subevent:find("AURA_", 1, true) then
				logIt = true
			end
		elseif sourceGUID == pg and subevent == "SPELL_CAST_SUCCESS" and IsKMSpenderSpellID(spellId) then
			logIt = true
		end
		if logIt then
			lab:OnCLEU(GetTime(), subevent, sourceGUID, destGUID, spellId, spellName, auraType, amount)
		end
	end

	-- Optional future: CLEU-backed truth engine (disabled by default)
	if not logicOn then return end
	-- reserved
end

-- (Slash command is registered in UI.lua: /kmpt)
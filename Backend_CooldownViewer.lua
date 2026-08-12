-- Backend_CooldownViewer.lua
-- Experimental backend: read Killing Machine (KM) stacks from Blizzard's Cooldown Viewer (Buff Icon viewer).
--
-- Core idea:
--  1) Locate the KM buff icon frame inside BuffIconCooldownViewer.
--  2) Read stacks from childFrame.Applications.Applications (FontString).
--  3) Track stack changes (0->1, 1->2, 2->0, ...).
--  4) Detect overcap (refresh at 2 stacks) by hooking the icon's Cooldown:SetCooldown().
--
-- Constraints (Midnight / 12.x):
--  - Some cooldown APIs return secret values; never do arithmetic / comparisons on them.
--  - We therefore avoid GetCooldownTimes/GetCooldownDuration, and only use SetCooldown as a pulse.

local ADDON_NAME, Addon = ...

-- ----------------------------
-- Small utilities
-- ----------------------------
local function DevLog(fmt, ...)
	if not Addon then return end
	if not (Addon.DevToolsEnabled and Addon:DevToolsEnabled()) then return end
	if Addon.DevLog then Addon:DevLog(fmt, ...) end
end

-- SecretValue safety (12.x): never compare, tonumber(), gsub(), etc. on secret values.
local function IsSecret(v)
	if v == nil then return false end
	if type(issecretvalue) ~= "function" then return false end
	local ok, r = pcall(issecretvalue, v)
	return ok and r == true
end

local function NormalizeTex(t)
	if t == nil then return nil end
	if IsSecret(t) then return nil end
	if type(t) == "number" then return t end
	if type(t) ~= "string" then return nil end
	-- normalize path-ish textures
	local ok, s = pcall(function()
		local v = t:gsub("\\", "/")
		v = v:lower()
		return v
	end)
	if not ok or s == nil then return nil end
	return s
end

local function BuildCandidateTextures()
	local out = {}
	local seen = {}

	local ids = {}
	if Addon and type(Addon.KM_AURA_IDS) == "table" then
		for _, id in ipairs(Addon.KM_AURA_IDS) do
			if type(id) == "number" then ids[#ids + 1] = id end
		end
	end
	if #ids == 0 then
		ids = { 51124, 51128 }
	end

	for _, id in ipairs(ids) do
		local tex = nil
		if C_Spell and C_Spell.GetSpellTexture then
			tex = C_Spell.GetSpellTexture(id)
		elseif GetSpellTexture then
			tex = GetSpellTexture(id)
		end
		local n = NormalizeTex(tex)
		if n ~= nil and not seen[n] then
			seen[n] = true
			out[#out + 1] = n
		end
	end

	return out
end

local function TextureMatches(tex, candidates)
	if tex == nil then return false end
	local n = NormalizeTex(tex)
	if n == nil or IsSecret(n) then return false end
	for i = 1, #candidates do
		local c = candidates[i]
		if c ~= nil and not IsSecret(c) and n == c then return true end
	end
	return false
end

local function SafeGetTexture(texObj)
	if not (texObj and texObj.GetTexture) then return nil end
	local ok, v = pcall(texObj.GetTexture, texObj)
	if ok then return v end
	return nil
end

local function ParseCountText(fs)
	if not (fs and fs.GetText) then return nil end
	local ok, t = pcall(fs.GetText, fs)
	if not ok then return nil end
	if IsSecret(t) then return nil end
	if t == nil or t == "" then return nil end

	-- Note (12.x): count strings can become SecretValue strings. Never call tonumber() without pcall.
	local n = nil
	if type(t) == "number" then
		if IsSecret(t) then return nil end
		n = t
	else
		local ok2, v = pcall(tonumber, t)
		if ok2 then n = v end
	end
	if IsSecret(n) then return nil end
	if type(n) ~= "number" then return nil end
	return n
end


local function FindCountFontString(icon)
	-- Blizzard_CooldownViewer buff icons typically use childFrame.Applications.Applications
	if icon and icon.Applications and icon.Applications.Applications then
		local fs = icon.Applications.Applications
		if fs and fs.GetText then return fs end
	end
	-- Fallback heuristics
	if icon and icon.Count and icon.Count.GetText then return icon.Count end
	if icon and icon.count and icon.count.GetText then return icon.count end
	if icon and icon.StackCount and icon.StackCount.GetText then return icon.StackCount end
	if icon and icon.GetRegions then
		for _, r in ipairs({ icon:GetRegions() }) do
			if r and r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
				return r
			end
		end
	end
	return nil
end

local function FindAllFontStrings(root)
	local out = {}
	local seen = {}
	local stack = { root }

	while #stack > 0 do
		local f = stack[#stack]
		stack[#stack] = nil

		if f and not seen[f] then
			seen[f] = true

			-- Regions (FontStrings)
			if f.GetRegions then
				local ok, regions = pcall(function() return { f:GetRegions() } end)
				if ok and regions then
					for _, r in ipairs(regions) do
						if r and r.GetObjectType and r:GetObjectType() == "FontString" and r.GetText then
							if not seen[r] then
								seen[r] = true
								out[#out + 1] = r
							end
						end
					end
				end
			end

			-- Children (Frames)
			if f.GetChildren then
				local ok2, children = pcall(function() return { f:GetChildren() } end)
				if ok2 and children then
					for _, c in ipairs(children) do
						if c and not seen[c] then
							stack[#stack + 1] = c
						end
					end
				end
			end
		end
	end

	return out
end

local function FindCooldown(icon)
	if not icon then return nil end
	if icon.Cooldown then return icon.Cooldown end
	if icon.cooldown then return icon.cooldown end
	if icon.GetChildren then
		for _, c in ipairs({ icon:GetChildren() }) do
			if c and c.GetObjectType and c:GetObjectType() == "Cooldown" then
				return c
			end
			if c and (c.SetCooldown and c.GetObjectType == nil) then
				-- very defensive
				return c
			end
		end
	end
	return nil
end

local function TryGetSpellIdFromIcon(icon)
	if not icon then return nil end
	-- Prefer the API provided by Blizzard's Cooldown Viewer buttons (most robust).
	if type(icon.GetSpellID) == "function" then
		local ok, v = pcall(icon.GetSpellID, icon)
		if ok and v ~= nil then
			if not (type(issecretvalue) == "function" and issecretvalue(v)) then
				local n = tonumber(v)
				if n then return n end
			end
		end
	end
	local candidates = {
		icon.spellID,
		icon.spellId,
		icon.SpellID,
		icon.SpellId,
	}
	for _, v in ipairs(candidates) do
		if v ~= nil then
			if type(issecretvalue) == "function" and issecretvalue(v) then
				-- cannot use
			else
				local n = tonumber(v)
				if n then return n end
			end
		end
	end
	-- Some frames store info nested
	if icon.data and (icon.data.spellID or icon.data.spellId) then
		local v = icon.data.spellID or icon.data.spellId
		if not (type(issecretvalue) == "function" and issecretvalue(v)) then
			local n = tonumber(v)
			if n then return n end
		end
	end
	if icon.cooldownInfo and (icon.cooldownInfo.spellID or icon.cooldownInfo.spellId) then
		local v = icon.cooldownInfo.spellID or icon.cooldownInfo.spellId
		if not (type(issecretvalue) == "function" and issecretvalue(v)) then
			local n = tonumber(v)
			if n then return n end
		end
	end
	return nil
end

local function IconLooksLikeKM(icon, texCandidates, idCandidates)
	if not icon then return false end
	local sid = TryGetSpellIdFromIcon(icon)
	if sid then
		for _, id in ipairs(idCandidates) do
			if sid == id then return true end
		end
	end
	local texObj = icon.Icon or icon.icon or icon.IconTexture or icon.iconTexture
	local tex = SafeGetTexture(texObj)
	if texCandidates and TextureMatches(tex, texCandidates) then
		return true
	end
	return false
end

local function EnumerateViewerIcons(viewer)
	local out = {}
	local seen = {}
	if not viewer then return out end

	local function add(icon)
		if not icon or seen[icon] then return end
		seen[icon] = true
		if icon.Icon or icon.icon or icon.IconTexture or icon.iconTexture then
			out[#out + 1] = icon
		end
	end

	-- 1) Try common pool fields (modern Blizzard often uses frame pools)
	local pools = {
		viewer.iconPool, viewer.IconPool,
		viewer.pool, viewer.Pool,
		viewer.buffPool, viewer.BuffPool,
		viewer.iconFramePool, viewer.IconFramePool,
	}
	for _, p in ipairs(pools) do
		if p and p.EnumerateActive then
			for icon in p:EnumerateActive() do
				add(icon)
			end
		end
	end

	-- 2) Recursive child traversal (icons are commonly nested under scroll frames)
	local function scan(frame, depth)
		if not frame or depth > 8 then return end
		if not frame.GetChildren then return end
		for _, child in ipairs({ frame:GetChildren() }) do
			add(child)
			scan(child, depth + 1)
		end
	end
	scan(viewer, 0)

	return out
end


-- ----------------------------
-- Backend entrypoints
-- ----------------------------
function Addon:CDM_EnsureLoaded()
	if self.state._cdmLoaded then return true end
	if C_AddOns and C_AddOns.LoadAddOn then
		pcall(C_AddOns.LoadAddOn, "Blizzard_CooldownViewer")
	end
	self.state._cdmLoaded = true
	return true
end

function Addon:CDM_LocateKMIcon()
	self:CDM_EnsureLoaded()

	local viewer = _G.PlayerBuffIconCooldownViewer or _G.BuffIconCooldownViewer
	if not viewer then return nil end

	local texCandidates = BuildCandidateTextures()
	local idCandidates = (self.KM_AURA_IDS and #self.KM_AURA_IDS > 0) and self.KM_AURA_IDS or { 51124, 51128 }

	local icons = EnumerateViewerIcons(viewer)
	if self.DevToolsEnabled and self:DevToolsEnabled() then
		DevLog("CDM: scan viewer=%s children=%d", tostring(viewer.GetName and viewer:GetName() or viewer), #icons)
	end

	for _, icon in ipairs(icons) do
		if IconLooksLikeKM(icon, texCandidates, idCandidates) then
			return icon
		end
	end

	return nil
end

-- Read current stack state from the located icon.
-- Returns (stacks)
function Addon:CDM_ReadKMState()
	local icon = self.state._cdmIcon
	if not icon then return 0 end

	-- If the icon is hidden, KM is not active.
	if icon.IsShown then
		local ok, shown = pcall(icon.IsShown, icon)
		if ok and not shown then
			return 0
		end
	end

	-- Try to read numeric stacks from the icon (often becomes SecretValue in 12.x).
	local stacks = nil
	local fs = FindCountFontString(icon)
	stacks = ParseCountText(fs)

	-- Fallback: many CDM builds moved the count FontString into nested containers.
	if stacks == nil then
		if not icon.__kmptFontStrings then
			icon.__kmptFontStrings = FindAllFontStrings(icon)
		end
		local best = 0
		for _, fs2 in ipairs(icon.__kmptFontStrings or {}) do
			local n = ParseCountText(fs2)
			if n and (not IsSecret(n)) and n > best then best = n end
		end
		if best > 0 then stacks = best end
	end

	-- If we still cannot read a numeric count, fall back to our internal pulse-based counter.
	if stacks == nil then
		do local okN, vN = pcall(tonumber, self.state._cdmStacks); if okN and (not IsSecret(vN)) then stacks = vN end end
	end

	-- If we still cannot read any count, treat "shown" as >= 1 stack.
	if IsSecret(stacks) or type(stacks) ~= "number" or stacks <= 0 then stacks = 1 end
	if stacks > 2 then stacks = 2 end
	return stacks
end


-- ----------------------------
-- Pulse model (12.x safe): use UI pulses instead of reading secret stack text
-- ----------------------------
function Addon:CDM_OnProcPulse(now, start, duration)
	now = now or GetTime()
	-- Always update stack state; counters are gated inside CDM_OnStacksChanged/OnOvercapPulse.

	local st = self.state
	-- Dedup: CDM can repaint / call SetCooldown multiple times per proc.
	local db = self.GetDB and self:GetDB() or nil
	local minInterval = (db and db.cdm and tonumber(db.cdm.procMinInterval)) or 0.14
	if minInterval < 0.05 then minInterval = 0.05 end
	local last = tonumber(st._cdmLastProcPulseAt or 0) or 0
	if (now - last) < minInterval then return end
	st._cdmLastProcPulseAt = now


	-- Signature dedup: CDM can repaint and call SetCooldown multiple times with identical (start,duration) for the same proc.
	local function SafeNum(v)
		if v == nil or IsSecret(v) then return nil end
		local ok, n = pcall(tonumber, v)
		if not ok or n == nil or IsSecret(n) or type(n) ~= "number" then return nil end
		return n
	end
	local sN = SafeNum(start)
	local dN = SafeNum(duration)
	if sN and dN then
		local ls = st._cdmLastPulseStart
		local ld = st._cdmLastPulseDur
		-- Blizzard calls SetCooldown every ~3 seconds to sync duration sweeps. 
		-- These syncs carry the exact same start time and duration.
		-- We MUST ignore them indefinitely, not just within a 1.25s window.
		if ls == sN and ld == dN then
			return
		end
		st._cdmLastPulseStart = sN
		st._cdmLastPulseDur = dN
		st._cdmLastPulseSigAt = now
	end
	
	if self:GetBackend() ~= "cdm" then return end

	local oldStacks = tonumber(st._cdmStacks or st.stacks or 0) or 0
	if oldStacks < 0 then oldStacks = 0 end
	if oldStacks > 2 then oldStacks = 2 end

	-- If we just seeded 0->1 from OnShow, the immediate SetCooldown is usually the same proc.
	local seedAt = tonumber(st._cdmSeedAt or 0) or 0
	if oldStacks == 1 and seedAt > 0 and (now - seedAt) < 0.35 then
		st._cdmSeedAt = 0
		-- Count this proc (pulse-confirmed), but do NOT increment stacks to 2.
		if self:IsCountingGains() then
			self.counters.procs = (self.counters.procs or 0) + 1
			if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
		end
		DevLog("CDM: proc pulse confirmed seed (0->1)")
		return
	end
	st._cdmSeedAt = 0

	if oldStacks >= 2 then
		-- Refresh-at-cap pulse => overcap.
		st._cdmStacks = 2
		st.stacks = 2
		self:CDM_OnOvercapPulse(now)
		return
	end

	local newStacks = oldStacks + 1
	st._cdmStacks = newStacks
	self:CDM_OnStacksChanged(newStacks, now, "pulse")
end


-- ----------------------------
-- Hook handling
-- ----------------------------
function Addon:CDM_OnOvercapPulse(now)
	now = now or GetTime()
	if self:GetBackend() ~= "cdm" then return end
	if self.state.manualPaused then return end
	if not self:IsCountingGains() then return end

	local oldStacks = tonumber(self.state.stacks or 0) or 0
	if oldStacks ~= 2 then return end

	-- Dedup pulses. Cooldown viewers can repaint; we only count a new proc if enough time passed.
	local db = self.GetDB and self:GetDB() or nil
	local minInterval = (db and db.cdm and tonumber(db.cdm.overcapMinInterval)) or 0.18
	local last = tonumber(self.state.lastOvercapAt or 0) or 0
	if (now - last) < minInterval then return end
	self.state.lastOvercapAt = now

	self.counters.procs = (self.counters.procs or 0) + 1
	self.counters.overcap = (self.counters.overcap or 0) + 1
	self.counters.wasted = (self.counters.wasted or 0) + 1

	if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end

	DevLog("CDM: overcap pulse counted")
end

function Addon:CDM_OnStacksChanged(newStacks, now, reason)
	now = now or GetTime()
	newStacks = tonumber(newStacks) or 0
	if newStacks < 0 then newStacks = 0 end
	if newStacks > 2 then newStacks = 2 end

	local oldStacks = tonumber(self.state.stacks or 0) or 0
	-- Optional debug heuristic: ignore a "0" sample if aura presence still says KM is active.
	-- Default OFF because aura presence can be misdetected under SecretValue rules and freeze stacks.
	local db = (self.GetDB and self:GetDB()) or nil
	local cdm = db and db.cdm or nil
	local ignoreZeroIfAuraPresent = cdm and cdm.ignoreZeroIfAuraPresent
	if ignoreZeroIfAuraPresent and newStacks == 0 and reason ~= "spender-predict" and self.FindKillingMachineAura then
		local aura = self:FindKillingMachineAura()
		local auraPresent = (aura ~= nil)
		if auraPresent and oldStacks > 0 then
			DevLog("CDM: ignore 0 sample (aura still present)")
			return
		end
	end
	if newStacks == oldStacks then return end

	-- Gains
	if newStacks > oldStacks then
		local gained = newStacks - oldStacks
		if self:IsCountingGains() then
			self.counters.procs = (self.counters.procs or 0) + gained
		end
		self.state.stacks = newStacks
		self.state.lastStackGainAt = now
		if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(newStacks) end
		if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
		DevLog("CDM: stacks %d->%d gained=%d reason=%s", oldStacks, newStacks, gained, tostring(reason))
		return
	end

	-- Losses
	local lost = oldStacks - newStacks
	if self:IsCountingLosses() then
		local recentSpender = (now - (self.state.lastSpenderAt or 0)) <= 0.45
		if recentSpender then
			self.counters.used = (self.counters.used or 0) + lost
			self.counters.consumed = self.counters.used
			DevLog("CDM: stacks %d->%d lost=%d classified=used", oldStacks, newStacks, lost)
		else
			self.counters.expired = (self.counters.expired or 0) + lost
			self.counters.wasted = (self.counters.wasted or 0) + lost
			DevLog("CDM: stacks %d->%d lost=%d classified=expired", oldStacks, newStacks, lost)
			if self.UI and self.UI.ShowWasted then self.UI:ShowWasted() end
		end
	end

	self.state.stacks = newStacks
	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(newStacks) end
	if self.UI and self.UI.UpdateCounters then self.UI:UpdateCounters() end
end

function Addon:CDM_AttachHooks(icon)
	if not icon or icon.__kmptHooked then return end
	icon.__kmptHooked = true

	self.state._cdmIcon = icon

	-- Icon show/hide: CDM UI can repaint/recycle icons; treat OnShow as a *presence seed*.
	-- The actual proc counting is driven by SetCooldown pulses (CDM_OnProcPulse).
	icon:HookScript("OnShow", function()
	if not Addon or not Addon.state then return end
	if Addon.state.manualPaused then return end
	if Addon:GetBackend() ~= "cdm" then return end

	local st = Addon.state
	st._cdmHideSeq = (st._cdmHideSeq or 0) + 1

	local now = GetTime()
	st._cdmLastShowAt = now

		-- Seed hint (do NOT count as a proc). We defer the actual 0->1 seed slightly to avoid UI recycle flicker.
		st._cdmSeedAt = now
		local seq = st._cdmHideSeq
		if C_Timer and C_Timer.After then
			C_Timer.After(0.15, function()
				if not Addon or not Addon.state then return end
				if Addon:GetBackend() ~= "cdm" then return end
				if Addon.state.manualPaused then return end
				if Addon.state._cdmHideSeq ~= seq then return end
				if not icon:IsShown() then return end

				local old = tonumber(Addon.state._cdmStacks or Addon.state.stacks or 0) or 0
				local lastPulse = tonumber(Addon.state._cdmLastProcPulseAt or 0) or 0
				if old <= 0 and (GetTime() - lastPulse) > 0.10 then
					Addon.state._cdmStacks = 1
					Addon.state.stacks = 1
					if Addon.UI and Addon.UI.UpdateStacks then Addon.UI:UpdateStacks(1) end
				end
			end)
		end
end)

icon:HookScript("OnHide", function()
	if not Addon or not Addon.state then return end
	if Addon.state.manualPaused then return end
	if Addon:GetBackend() ~= "cdm" then return end

	local st = Addon.state
	st._cdmHideSeq = (st._cdmHideSeq or 0) + 1
	local seq = st._cdmHideSeq

	local now = GetTime()

	-- Viewer icons can briefly flash-hide during UI repaints; ignore very fast hide after show.
	local gate = 0.35
	local lastShow = tonumber(st._cdmLastShowAt or 0) or 0
	if lastShow > 0 and (now - lastShow) < gate then
		DevLog("CDM: ignore hide flicker dt=%.3f", now - lastShow)
		return
	end

	-- Defer hide handling: some CDM viewers toggle visibility for a frame while reflowing.
	if C_Timer and C_Timer.After then
		C_Timer.After(0.30, function()
			if not Addon or not Addon.state then return end
			if Addon:GetBackend() ~= "cdm" then return end
			if Addon.state._cdmHideSeq ~= seq then return end
			if icon:IsShown() then return end

			-- If the icon hid very shortly after it was shown, and we did not just spend the proc,
			-- treat this as a viewer recycle/flicker (do NOT count as expiration).
			local now2 = GetTime()
			local lastShow2 = tonumber(Addon.state._cdmLastShowAt or 0) or 0
			local shownFor2 = (lastShow2 > 0) and (now2 - lastShow2) or 999
			local recentSpend2 = tonumber(Addon.state._cdmRecentSpenderAt or 0) or 0
			if shownFor2 < 2.0 and (now2 - recentSpend2) >= 0.45 then
				DevLog("CDM: ignore early hide dt=%.3f (likely flicker)", shownFor2)
				return
			end

			local stacks = Addon:CDM_ReadKMState()
			stacks = tonumber(stacks) or 0
			if stacks <= 0 then
				-- Optional debug heuristic: ignore hide-confirm if aura presence still says KM is active.
				-- Default OFF because aura presence can be misdetected and prevent proper resets.
				local db = (Addon.GetDB and Addon:GetDB()) or nil
				local cdm = db and db.cdm or nil
				local ignoreHideIfAuraPresent = cdm and cdm.ignoreHideConfirmIfAuraPresent
				if ignoreHideIfAuraPresent and Addon.FindKillingMachineAura then
					local aura = Addon:FindKillingMachineAura()
					if aura ~= nil then
						DevLog("CDM: ignore hide-confirm (aura still present)")
						return
					end
				end
				Addon:CDM_OnStacksChanged(0, GetTime(), "hide-confirm")
			end
		end)
	else
		Addon:CDM_OnStacksChanged(0, now, "hide")
	end
end)


	-- Stacks text changes (debug-only; OFF by default because it can double-count under icon recycling)
	local db = (self.GetDB and self:GetDB()) or nil
	local cdm = db and db.cdm or nil
	local useTextHooks = cdm and cdm.useTextHooks
	if useTextHooks and type(hooksecurefunc) == "function" then
			icon.__kmptFontStrings = icon.__kmptFontStrings or FindAllFontStrings(icon)
			local list = icon.__kmptFontStrings or {}
	
			-- Ensure the canonical count FontString is included as well.
			local primary = FindCountFontString(icon)
			if primary and primary.GetText then
				local present = false
				for _, r in ipairs(list) do
					if r == primary then present = true break end
				end
				if not present then
					list[#list + 1] = primary
					icon.__kmptFontStrings = list
				end
			end
	
			for _, fs in ipairs(list) do
				if fs and fs.SetText and not fs.__kmptHooked then
					fs.__kmptHooked = true
					hooksecurefunc(fs, "SetText", function()
						if not Addon or not Addon.state then return end
						if Addon:GetBackend() ~= "cdm" then return end
						local stacks = Addon:CDM_ReadKMState()
						Addon:CDM_OnStacksChanged(stacks, GetTime(), "text")
					end)
				end
			end
	end


	-- Cooldown pulse (12.x safe): treat as a proc pulse (gain or refresh-at-cap).
	local cd = FindCooldown(icon)
	if cd and cd.SetCooldown and type(hooksecurefunc) == "function" then
		hooksecurefunc(cd, "SetCooldown", function(_, start, duration)
			if not Addon or not Addon.state then return end
			if Addon:GetBackend() ~= "cdm" then return end
			Addon:CDM_OnProcPulse(GetTime(), start, duration)
		end)
	end

	-- Seed immediately (do NOT count as a proc)
	local stacks = self:CDM_ReadKMState()
	stacks = tonumber(stacks) or 0
	if stacks < 0 then stacks = 0 end
	if stacks > 2 then stacks = 2 end
	self.state._cdmStacks = stacks
	self.state.stacks = stacks
	self.state._cdmSeedAt = 0
	if self.UI and self.UI.UpdateStacks then self.UI:UpdateStacks(stacks) end

	DevLog("CDM: hooks attached to %s", tostring(icon.GetName and icon:GetName() or icon))
end

-- ----------------------------
-- Lifecycle
-- ----------------------------
function Addon:CDM_Start()
	if self.state._cdmTicker then return end

	self:CDM_EnsureLoaded()

	-- Slow ticker: only used to locate (or re-locate) the KM icon.
	-- Once hooks are attached, we keep the ticker very light to survive frame pool recycling.
	local f = CreateFrame("Frame")
	self.state._cdmTicker = f
	f.elapsed = 0
	f:SetScript("OnUpdate", function(_, dt)
		if not Addon or not Addon.state then return end
		if Addon:GetBackend() ~= "cdm" then return end
		f.elapsed = f.elapsed + (dt or 0)
		local db = Addon.GetDB and Addon:GetDB() or nil
		local scanEvery = (db and db.cdm and tonumber(db.cdm.scanInterval)) or 0.50
		if scanEvery < 0.10 then scanEvery = 0.10 end
		if f.elapsed < scanEvery then return end
		f.elapsed = 0

		local icon = Addon.state._cdmIcon
		if icon and icon.__kmptHooked then
			-- Ensure it is still a frame (icon can be recycled). If it errors, drop and rescan.
			local ok = pcall(function() return icon.GetObjectType and icon:GetObjectType() end)
			if ok then
				return
			end
			Addon.state._cdmIcon = nil
		end

		local found = Addon:CDM_LocateKMIcon()
		if found then
			Addon:CDM_AttachHooks(found)
		end
	end)
end

function Addon:CDM_Stop()
	local f = self.state._cdmTicker
	if f then
		f:SetScript("OnUpdate", nil)
		f:Hide()
	end
	self.state._cdmTicker = nil
	self.state._cdmIcon = nil
end

-- Dev helper: dump currently visible BuffIconCooldownViewer icons (textures, spellId if present).
function Addon:CDM_DebugDump()
	local viewer = _G.PlayerBuffIconCooldownViewer or _G.BuffIconCooldownViewer
	if not viewer then
		DevLog("CDM: viewer not found")
		return
	end
	local icons = EnumerateViewerIcons(viewer)
	DevLog("CDM: dump viewer=%s icons=%d", tostring(viewer.GetName and viewer:GetName() or viewer), #icons)
	for i = 1, math.min(#icons, 30) do
		local icon = icons[i]
		local texObj = icon.Icon or icon.icon
		local tex = SafeGetTexture(texObj)
		local sid = TryGetSpellIdFromIcon(icon)
		local shown = (icon.IsShown and select(2, pcall(icon.IsShown, icon))) or false
		DevLog("CDM: icon[%d] shown=%s spellId=%s tex=%s name=%s", i, tostring(shown), tostring(sid), tostring(tex), tostring(icon.GetName and icon:GetName() or ""))
	end
end
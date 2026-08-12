-- TestLab.lua
-- KMProcsTracker — in-game probes for Midnight secret-value behavior
--
-- IMPORTANT:
--   This module MUST NOT call RegisterEvent/UnregisterAllEvents.
--   Core.lua owns event registration. Note: Midnight (12.0+) restricts COMBAT_LOG_EVENT_UNFILTERED,
--   so CLEU is not registered by default.
--   We only gate handling via booleans.
--
-- Output:
--   Prefers DevTools log window (DevLogForce). Falls back to chat/print.

local ADDON_NAME, Addon = ...
Addon.TestLab = Addon.TestLab or {}

local Lab = Addon.TestLab

-- ----------------------------
-- Helpers
-- ----------------------------
local function IsSecret(v)
	return (type(issecretvalue) == "function") and issecretvalue(v)
end

local function S(v)
	if IsSecret(v) then return "<secret>" end
	return tostring(v)
end

local function CountTable(t)
	if type(t) ~= "table" then return 0 end
	local n = #t
	if n and n > 0 then return n end
	local c = 0
	for _ in pairs(t) do c = c + 1 end
	return c
end

local function Chat(fmt, ...)
	if Addon and Addon.Chatf and select("#", ...) > 0 then
		Addon:Chatf(fmt, ...)
	elseif Addon and Addon.Chat then
		Addon:Chat(string.format(fmt, ...))
	else
		print(string.format(fmt, ...))
	end
end

local function Dbg(fmt, ...)
	if Addon and Addon.DevLogForce then
		Addon:DevLogForce(fmt, ...)
	elseif Addon and Addon.DevLog then
		Addon:DevLog(fmt, ...)
	else
		Chat(fmt, ...)
	end
end

-- ----------------------------
-- State + API expected by DevToolsUI
-- ----------------------------
Lab._state = Lab._state or { enabled = false, aura = false, sao = false, cdm = false, cl = false }

Lab._cdmHooksInstalled = Lab._cdmHooksInstalled or false

Lab._lastAuraLogAt = Lab._lastAuraLogAt or 0
Lab._lastAuraDumpAt = Lab._lastAuraDumpAt or 0
Lab._lastAid = Lab._lastAid
Lab._lastStacks = Lab._lastStacks
Lab._lastSig = Lab._lastSig

function Lab:GetState()
	local st = self._state
	return {
		enabled = st.enabled and true or false,
		aura = st.aura and true or false,
		sao = st.sao and true or false,
		cdm = st.cdm and true or false,
		cl = st.cl and true or false,
	}
end

function Lab:SetEnabled(on)
	self._state.enabled = on and true or false
end

function Lab:SetAura(on)
	self._state.aura = on and true or false
end

function Lab:SetSAO(on)
	self._state.sao = on and true or false
end

function Lab:SetCDM(on)
	self._state.cdm = on and true or false
	if self._state.enabled and self._state.cdm then
		self:InstallCDMHooks()
	end
end

function Lab:SetCombatLog(on)
	self._state.cl = on and true or false
end

function Lab:ToggleCombatLog(force)
	if force == nil then
		self._state.cl = not self._state.cl
	else
		self._state.cl = force and true or false
	end
	Dbg("LAB: CL %s", self._state.cl and "ON" or "OFF")
	if self._state.cl then
		Dbg("LAB: note: Midnight restricts COMBAT_LOG_EVENT_UNFILTERED; CLEU probe will not receive events.")
	end
end

-- ----------------------------
-- Gates used by Core forwarders
-- ----------------------------
function Lab:IsAuraEnabled()
	return self._state.enabled and self._state.aura
end

function Lab:IsSAOEnabled()
	return self._state.enabled and self._state.sao
end

function Lab:IsCastEnabled()
	local st = self._state
	return st.enabled and (st.aura or st.sao or st.cdm or st.cl)
end

function Lab:IsCLEUEnabled()
	return self._state.enabled and self._state.cl
end

-- ----------------------------
-- Slash handler: /kmpt lab ...
-- ----------------------------
local function BoolFrom(s)
	if s == "on" or s == "1" or s == "true" then return true end
	if s == "off" or s == "0" or s == "false" then return false end
	if s == "toggle" or s == "" or s == nil then return nil end
	return nil
end

function Lab:Slash(msg)
	msg = (msg or ""):lower()
	local a, b = msg:match("^(%S+)%s*(.*)$")
	a = a or ""
	b = b or ""

	if a == "" or a == "help" then
		Chat("KMPT Lab: /kmpt lab on|off|status")
		Chat("KMPT Lab: /kmpt lab aura|sao|cdm|cl [on|off|toggle]")
		return
	end

	if a == "status" then
		local st = self:GetState()
		Chat("KMPT Lab: enabled=%s aura=%s sao=%s cdm=%s cl=%s",
			tostring(st.enabled), tostring(st.aura), tostring(st.sao), tostring(st.cdm), tostring(st.cl))
		return
	end

	if a == "on" then self:SetEnabled(true); Chat("KMPT Lab: ON"); return end
	if a == "off" then self:SetEnabled(false); Chat("KMPT Lab: OFF"); return end

	local sw = BoolFrom(b)
	if a == "aura" then
		if sw == nil then sw = not self._state.aura end
		self:SetAura(sw)
		Chat("KMPT Lab: aura=%s", tostring(self._state.aura))
		return
	elseif a == "sao" then
		if sw == nil then sw = not self._state.sao end
		self:SetSAO(sw)
		Chat("KMPT Lab: sao=%s", tostring(self._state.sao))
		return
	elseif a == "cdm" then
		if sw == nil then sw = not self._state.cdm end
		self:SetCDM(sw)
		Chat("KMPT Lab: cdm=%s", tostring(self._state.cdm))
		return
	elseif a == "cl" then
		if sw == nil then sw = not self._state.cl end
		self:SetCombatLog(sw)
		Chat("KMPT Lab: cl=%s", tostring(self._state.cl))
		return
	end

	Chat("KMPT Lab: unknown command. /kmpt lab help")
end

-- ----------------------------
-- CDM hooks (optional)
-- ----------------------------
local function HookOnce(obj, script, fn)
	if not (obj and obj.HookScript) then return end
	obj.__kmptLabHooked = obj.__kmptLabHooked or {}
	if obj.__kmptLabHooked[script] then return end
	obj.__kmptLabHooked[script] = true
	obj:HookScript(script, fn)
end

local function SafeGetTexture(region)
	if not (region and region.GetTexture) then return nil end
	local ok, tex = pcall(region.GetTexture, region)
	if not ok then return nil end
	return tex
end

function Lab:InstallCDMHooks()
	if self._cdmHooksInstalled then return end
	self._cdmHooksInstalled = true

	local viewer = _G and _G.BuffIconCooldownViewer
	if not viewer then
		Dbg("LAB: CDM viewer not found (BuffIconCooldownViewer). Proc once and reopen DevTools.")
		return
	end

	local icons = viewer.icons or viewer.iconFrames
	if not icons and viewer.pool and viewer.pool.activeObjects then
		icons = viewer.pool.activeObjects
	end

	local hooked = 0
	if type(icons) == "table" then
		for _, icon in pairs(icons) do
			if type(icon) == "table" and icon.HookScript then
				HookOnce(icon, "OnShow", function(selfFrame)
					local tex = SafeGetTexture(selfFrame.Icon or selfFrame.icon or selfFrame.Texture or selfFrame.texture)
					Dbg("LAB: CDM Icon SHOW tex=%s name=%s", S(tex), S(selfFrame.GetName and selfFrame:GetName()))
				end)
				HookOnce(icon, "OnHide", function(selfFrame)
					local tex = SafeGetTexture(selfFrame.Icon or selfFrame.icon or selfFrame.Texture or selfFrame.texture)
					Dbg("LAB: CDM Icon HIDE tex=%s name=%s", S(tex), S(selfFrame.GetName and selfFrame:GetName()))
				end)
				hooked = hooked + 1
			end
		end
	end

	-- Hook alert dispatchers if present (cheap, helps confirm CDM channel exists)
	if not viewer.__kmptLabHookedAlerts then
		viewer.__kmptLabHookedAlerts = true
		if type(viewer.TriggerAuraAppliedAlert) == "function" then
			hooksecurefunc(viewer, "TriggerAuraAppliedAlert", function(_, ...)
				Dbg("LAB: CDM AuraAppliedAlert args=%d", select("#", ...))
			end)
		end
		if type(viewer.TriggerAuraRemovedAlert) == "function" then
			hooksecurefunc(viewer, "TriggerAuraRemovedAlert", function(_, ...)
				Dbg("LAB: CDM AuraRemovedAlert args=%d", select("#", ...))
			end)
		end
	end

	if hooked > 0 then
		Dbg("LAB: CDM hooks installed on %d icon(s)", hooked)
	else
		Dbg("LAB: CDM viewer found but icons not enumerable (proc once, then toggle CDM again)")
	end
end

-- ----------------------------
-- Core forwarders (called from Core.lua)
-- ----------------------------
function Lab:OnUnitAura(now, updateInfo, kmAid, stacks)
	if not self:IsAuraEnabled() then return end

	local added, updated, removed = 0, 0, 0
	if type(updateInfo) == "table" then
		added = CountTable(updateInfo.addedAuras or updateInfo.addedAuraInstanceIDs)
		updated = CountTable(updateInfo.updatedAuras or updateInfo.updatedAuraInstanceIDs)
		removed = CountTable(updateInfo.removedAuraInstanceIDs or updateInfo.removedAuras)
	end

	local sig = string.format("A%d U%d R%d", added, updated, removed)
	local changed = (kmAid ~= self._lastAid) or (stacks ~= self._lastStacks) or (sig ~= self._lastSig) or (removed > 0) or (added > 0)

	-- throttle: log only on changes, or at most 2/sec
	if not changed and (now - (self._lastAuraLogAt or 0) < 0.50) then
		return
	end

	self._lastAuraLogAt = now
	self._lastAid = kmAid
	self._lastStacks = stacks
	self._lastSig = sig

	local sao = (Addon and Addon.CountKMOverlays) and Addon:CountKMOverlays() or -1
	Dbg("LAB: AURA kmAid=%s stacks=%s sao=%d sig=%s", S(kmAid), S(stacks), sao, sig)

	-- Dump KM aura fields (secret-safe) at most 1/sec, or when auraInstanceID changes.
	if kmAid and (changed or (now - (self._lastAuraDumpAt or 0) > 1.00)) then
		self._lastAuraDumpAt = now
		if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", kmAid)
			if ok and type(aura) == "table" then
				Dbg("LAB: aura[aID=%s] name=%s spellId=%s apps=%s dur=%s exp=%s",
					S(kmAid), S(aura.name), S(aura.spellId), S(aura.applications), S(aura.duration), S(aura.expirationTime))
			else
				Dbg("LAB: aura[aID=%s] lookup failed", S(kmAid))
			end
		end
	end
end

function Lab:OnSAOShow(now, spellId)
	if not self:IsSAOEnabled() then return end
	local sao = (Addon and Addon.CountKMOverlays) and Addon:CountKMOverlays() or -1
	Dbg("LAB: SAO SHOW spellId=%s total=%d (secret=%s)", S(spellId), sao, tostring(IsSecret(spellId)))
end

function Lab:OnSAOHide(now, spellId)
	if not self:IsSAOEnabled() then return end
	local sao = (Addon and Addon.CountKMOverlays) and Addon:CountKMOverlays() or -1
	Dbg("LAB: SAO HIDE spellId=%s total=%d (secret=%s)", S(spellId), sao, tostring(IsSecret(spellId)))
end

function Lab:OnCastSucceeded(now, spellId)
	if not self:IsCastEnabled() then return end
	spellId = tonumber(spellId) or spellId
	-- only log relevant spenders (avoid spam)
	if spellId == 49020 or spellId == 207230 then
		Dbg("LAB: CAST_SUCCEEDED spellId=%s", S(spellId))
	end
end

function Lab:OnCLEU(ts, subEvent, srcGUID, dstGUID, spellId, spellName, auraType, amount)
	if not self:IsCLEUEnabled() then return end
	Dbg("LAB: CLEU %s spellId=%s name=%s auraType=%s amount=%s",
		S(subEvent), S(spellId), S(spellName), S(auraType), S(amount))
end

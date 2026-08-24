local API = CoAAnalyticsAPI
local Nameplates = CoAAnalyticsNameplates or {}
CoAAnalyticsNameplates = Nameplates
CoAAnalyticsAddon.Modules.Nameplates = Nameplates

local config = API and API.Config or {}
local state = API.RuntimeState
local AllyJournal = API.AllyJournal
local addonDB

local ICON_SIZE = config.ICON_SIZE or 18
local ICON_OFFSET_Y = config.ICON_OFFSET_Y or 3
local ICON_GAP = config.ICON_GAP or 2
local MAX_NAMEPLATE_UNITS = config.MAX_NAMEPLATE_UNITS or 80
local NAMEPLATE_CVAR = config.NAMEPLATE_CVAR or "nameplateShowEnemies"
local NAMEPLATE_CVAR_RECHECK_DELAY = config.NAMEPLATE_CVAR_RECHECK_DELAY or 0.10
local ANCHOR_REFRESH_DELAY = config.ANCHOR_REFRESH_DELAY or 0.10
local INSPECT_GAP = config.INSPECT_GAP or 0.75
local RETRY_DELAY = config.RETRY_DELAY or 2
local MAX_FRIENDLY_INSPECT_ATTEMPTS = config.MAX_FRIENDLY_INSPECT_ATTEMPTS or 3
local FRIENDLY_SCAN_INTERVAL = config.FRIENDLY_SCAN_INTERVAL or 4
local FRIENDLY_RESULT_READ_DELAYS = config.FRIENDLY_RESULT_READ_DELAYS or { 0.15, 0.40, 0.80 }
local FRIENDLY_RETRY_COOLDOWN = config.FRIENDLY_RETRY_COOLDOWN or 20
local ROLE_ATLAS_FALLBACKS = config.ROLE_ATLAS_FALLBACKS or {}
local ROLE_ATLAS_KEYS = config.ROLE_ATLAS_KEYS or {}
local ROLE_ATLAS_CANDIDATES = config.ROLE_ATLAS_CANDIDATES or {}
local ROLE_FALLBACK_TEXTURES = config.ROLE_FALLBACK_TEXTURES or {}
local ABOVE_POSITION_OFFSETS = config.ABOVE_POSITION_OFFSETS or {}
local SPEC_ICON_ATLAS_TEXTURE = config.SPEC_ICON_ATLAS_TEXTURE
local UNKNOWN_SPEC_TEXTURE = config.UNKNOWN_SPEC_TEXTURE

local Debug = API.Debug
local IsCVarEnabled = API.IsCVarEnabled
local IsInspectRequestAccepted = API.IsInspectRequestAccepted
local IsGroupTrackingActive = API.IsGroupTrackingActive
local GetBattlefieldClassToken = API.GetBattlefieldClassToken
local GetBattlefieldTeam = API.GetBattlefieldTeam
local ClassTokensMatch = API.ClassTokensMatch
local RefreshBattlefieldRosterMetadata = API.RefreshBattlefieldRosterMetadata
local CacheUnitIdentity = API.CacheUnitIdentity
local CacheUnitRole = API.CacheUnitRole

local function EnsureEnemyNameplateTracking()
	if not state.isActive or not addonDB then
		return
	end

	if not addonDB.nameplateOverrideActive then
		addonDB.previousEnemyNameplates = GetCVar(NAMEPLATE_CVAR)
		addonDB.nameplateOverrideActive = true
	end

	if not IsCVarEnabled(GetCVar(NAMEPLATE_CVAR)) then
		SetCVar(NAMEPLATE_CVAR, "1")
		Debug("enabled enemy nameplate tracking")
	end
end

local function ScheduleEnemyNameplateCheck()
	if not state.isActive then
		return
	end

	state.nextNameplateCVarCheckAt = GetTime() + NAMEPLATE_CVAR_RECHECK_DELAY
	state.worker:Show()
end

local function GetUnitBattlefieldTeam(unit)
	if not unit or not UnitExists(unit) then
		return
	end
	local name, realm = UnitName(unit)
	if not name then
		return
	end
	if realm and realm ~= "" then
		local team = GetBattlefieldTeam(name .. "-" .. realm)
		if team ~= nil then
			return team
		end
	end
	return GetBattlefieldTeam(name)
end

local function IsFriendlyPlayer(unit, guid)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return false
	end
	guid = guid or UnitGUID(unit)
	if UnitIsUnit(unit, "player") or (guid and state.friendlyGUIDs[guid]) then
		return true
	end

	local team = GetUnitBattlefieldTeam(unit)
	if team ~= nil and state.playerBattlefieldTeam ~= nil then
		return tostring(team) == tostring(state.playerBattlefieldTeam)
	end

	-- Positive friendship is a safe fallback while the first scoreboard
	-- snapshot is loading. Merely being non-attackable is never considered
	-- proof of friendship because enemies become neutral after a BG ends.
	if type(UnitIsFriend) == "function" and UnitIsFriend("player", unit) then
		return true
	end
	return false
end

local function IsEnemyPlayer(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return false
	end
	local team = GetUnitBattlefieldTeam(unit)
	if team ~= nil and state.playerBattlefieldTeam ~= nil then
		return tostring(team) ~= tostring(state.playerBattlefieldTeam)
	end
	return (type(UnitIsEnemy) == "function" and UnitIsEnemy("player", unit))
		or UnitCanAttack("player", unit)
end

local function RoleFromSpecInfo(specInfo)
	if specInfo.Support then
		return "SUPPORT"
	elseif specInfo.Healer then
		return "HEALER"
	elseif specInfo.Tank then
		return "TANK"
	elseif specInfo.MeleeDPS then
		return "MELEE_DAMAGER"
	elseif specInfo.RangedDPS or specInfo.CasterDPS then
		return "RANGED_DAMAGER"
	end

	-- CoA treats a specialization without Tank, Healer, or Support flags as DPS.
	return "DAMAGER"
end

local function GetClassSpecCatalog(classToken)
	local catalog = state.specCatalogByClass[classToken]
	if catalog then
		return catalog
	end

	catalog = {}
	local specs = C_ClassInfo.GetAllSpecs(classToken)
	if type(specs) == "table" then
		for _, spec in ipairs(specs) do
			local specInfo = C_ClassInfo.GetSpecInfo(classToken, spec)
			if specInfo and specInfo.PassiveID then
				catalog[#catalog + 1] = specInfo
			end
		end
	end

	state.specCatalogByClass[classToken] = catalog
	return catalog
end

local function IsAtlasAvailable(atlas)
	if not atlas or atlas == "" then
		return false
	end

	if type(AtlasUtil) == "table"
		and type(AtlasUtil.AtlasExists) == "function"
	then
		local success, exists = pcall(
			AtlasUtil.AtlasExists,
			AtlasUtil,
			atlas
		)
		return success and exists and true or false
	end

	return true
end

local function ResolveRoleAtlas(role)
	if state.resolvedRoleAtlases[role] ~= nil then
		return state.resolvedRoleAtlases[role] or nil
	end

	local candidates = {}
	local seen = {}
	local function AddCandidate(atlas)
		if type(atlas) == "string" and atlas ~= "" and not seen[atlas] then
			seen[atlas] = true
			candidates[#candidates + 1] = atlas
		end
	end

	local officialAtlases = type(ROLE_ATLAS) == "table" and ROLE_ATLAS
	if officialAtlases then
		for _, key in ipairs(ROLE_ATLAS_KEYS[role] or {}) do
			AddCandidate(officialAtlases[key])
		end
	end
	for _, atlas in ipairs(ROLE_ATLAS_CANDIDATES[role] or {}) do
		AddCandidate(atlas)
	end
	AddCandidate(ROLE_ATLAS_FALLBACKS[role])

	for _, atlas in ipairs(candidates) do
		if IsAtlasAvailable(atlas) then
			state.resolvedRoleAtlases[role] = atlas
			return atlas
		end
	end

	state.resolvedRoleAtlases[role] = false
end

local function ApplyRoleTexture(texture, role)
	local atlas = ResolveRoleAtlas(role)
	local atlasApplied = false

	if atlas and texture.SetAtlas then
		atlasApplied = pcall(texture.SetAtlas, texture, atlas, false)
	end

	if not atlasApplied then
		texture:SetTexture(
			ROLE_FALLBACK_TEXTURES[role] or ROLE_FALLBACK_TEXTURES.DAMAGER
		)
		texture:SetTexCoord(0, 1, 0, 1)
	end
end

local function GetSpecializationTextureData(classToken, specInfo)
	if not specInfo then
		return
	end

	local icon = specInfo.Icon or specInfo.icon
	if not icon
		and specInfo.ID
		and type(GetSpecializationInfoByID) == "function"
	then
		local success, _, _, _, returnedIcon = pcall(
			GetSpecializationInfoByID,
			specInfo.ID
		)
		if success then
			icon = returnedIcon
		end
	end

	if type(icon) == "string" and icon ~= "" then
		return icon
	end

	if classToken
		and specInfo.Spec
		and type(AtlasUtil) == "table"
		and type(AtlasUtil.GetCoords) == "function"
	then
		local success, left, right, top, bottom = pcall(
			AtlasUtil.GetCoords,
			AtlasUtil,
			"specicon-" .. classToken .. "-" .. specInfo.Spec
		)
		if success and left and right and top and bottom then
			return SPEC_ICON_ATLAS_TEXTURE, { left, right, top, bottom }
		end
	end
end

local function ApplySpecializationTexture(texture, data, showUnknown)
	if not texture then
		return false
	end

	if data and data.specializationTexture then
		texture:SetTexture(data.specializationTexture)
		if data.specializationTexCoords then
			texture:SetTexCoord(unpack(data.specializationTexCoords))
		else
			texture:SetTexCoord(0, 1, 0, 1)
		end
		texture:Show()
		return true
	end

	if showUnknown then
		texture:SetTexture(UNKNOWN_SPEC_TEXTURE)
		texture:SetTexCoord(0, 1, 0, 1)
		texture:Show()
	else
		texture:Hide()
	end
	return false
end

local function GetInlineNameplateAnchor(holder)
	local anchor = holder and holder.anchor
	if not anchor then
		return holder
	end

	return anchor.Health
		or anchor.healthBar
		or anchor.HealthBar
		or anchor.healthbar
		or anchor
end

local function AnchorIconTexture(texture, holder, position)
	texture:ClearAllPoints()
	texture:SetWidth(ICON_SIZE)
	texture:SetHeight(ICON_SIZE)

	local aboveOffset = ABOVE_POSITION_OFFSETS[position]
	if aboveOffset then
		texture:SetPoint("CENTER", holder, "CENTER", aboveOffset, 0)
	elseif position == "INLINE_LEFT" then
		texture:SetPoint(
			"RIGHT",
			GetInlineNameplateAnchor(holder),
			"LEFT",
			-ICON_GAP,
			0
		)
	else
		texture:SetPoint(
			"LEFT",
			GetInlineNameplateAnchor(holder),
			"RIGHT",
			ICON_GAP,
			0
		)
	end
end

local function ApplyIconLayout(holder)
	if not holder then
		return
	end

	local rolePosition = addonDB and addonDB.roleIconPosition
		or "ABOVE_CENTER"
	local specPosition = addonDB and addonDB.specIconPosition
		or "ABOVE_RIGHT"
	local showSpec = addonDB
		and addonDB.showSpecIcon
		and holder.specializationTexture

	AnchorIconTexture(holder.texture, holder, rolePosition)
	if showSpec and specPosition == rolePosition then
		holder.specTexture:ClearAllPoints()
		holder.specTexture:SetWidth(ICON_SIZE)
		holder.specTexture:SetHeight(ICON_SIZE)
		if specPosition == "INLINE_LEFT" then
			holder.specTexture:SetPoint(
				"RIGHT",
				holder.texture,
				"LEFT",
				-ICON_GAP,
				0
			)
		else
			holder.specTexture:SetPoint(
				"LEFT",
				holder.texture,
				"RIGHT",
				ICON_GAP,
				0
			)
		end
	else
		AnchorIconTexture(holder.specTexture, holder, specPosition)
	end

	if showSpec then
		holder.specTexture:Show()
	else
		holder.specTexture:Hide()
	end
end

local function CreateRoleIcon(anchor)
	local holder = CreateFrame("Frame", nil, anchor)
	holder.anchor = anchor
	holder:SetWidth(ICON_SIZE)
	holder:SetHeight(ICON_SIZE)
	holder:SetPoint("BOTTOM", anchor, "TOP", 0, ICON_OFFSET_Y)
	holder:EnableMouse(false)

	if holder.SetFrameLevel and anchor.GetFrameLevel then
		holder:SetFrameLevel(anchor:GetFrameLevel() + 20)
	end

	local texture = holder:CreateTexture(nil, "OVERLAY")
	texture:SetWidth(ICON_SIZE)
	texture:SetHeight(ICON_SIZE)
	holder.texture = texture

	local specTexture = holder:CreateTexture(nil, "OVERLAY")
	specTexture:SetWidth(ICON_SIZE)
	specTexture:SetHeight(ICON_SIZE)
	specTexture:Hide()
	holder.specTexture = specTexture
	ApplyIconLayout(holder)
	holder:Hide()

	state.iconsByAnchor[anchor] = holder
	return holder
end

local function GetRoleIcon(anchor)
	local holder = state.iconsByAnchor[anchor]
	if not holder then
		holder = CreateRoleIcon(anchor)
	else
		holder:SetParent(anchor)
		holder.anchor = anchor
		holder:ClearAllPoints()
		holder:SetPoint("BOTTOM", anchor, "TOP", 0, ICON_OFFSET_Y)
		if holder.SetFrameLevel and anchor.GetFrameLevel then
			holder:SetFrameLevel(anchor:GetFrameLevel() + 20)
		end
		ApplyIconLayout(holder)
	end
	return holder
end

local function ShowRole(record, roleData)
	if not record or not record.icon or not roleData then
		return
	end

	record.role = roleData.role
	record.specialization = roleData.specialization
	record.icon.ownerUnit = record.unit
	record.icon.ownerGUID = record.guid
	record.icon.role = roleData.role
	record.icon.specialization = roleData.specialization
	record.icon.specializationTexture = roleData.specializationTexture
	record.icon.specializationTexCoords = roleData.specializationTexCoords
	ApplyRoleTexture(record.icon.texture, roleData.role)
	ApplySpecializationTexture(record.icon.specTexture, roleData, false)
	ApplyIconLayout(record.icon)
	record.icon:Show()
end

local function RefreshVisibleIconLayouts()
	for _, record in pairs(state.visibleUnits) do
		if record.icon then
			ApplyIconLayout(record.icon)
		end
	end
end

local function ReleaseUnit(unit)
	local record = state.visibleUnits[unit]
	if not record then
		return
	end

	if record.icon and record.icon.ownerUnit == unit then
		record.icon.ownerUnit = nil
		record.icon.ownerGUID = nil
		record.icon.role = nil
		record.icon.specialization = nil
		record.icon.specializationTexture = nil
		record.icon.specializationTexCoords = nil
		record.icon.specTexture:Hide()
		record.icon:Hide()
	end

	state.visibleUnits[unit] = nil
end

local function QueueInspection(unit, guid, delay, retryWhileVisible, preferUnit, mode)
	if not unit
		or not guid
		or not UnitExists(unit)
		or not UnitIsPlayer(unit)
		or UnitGUID(unit) ~= guid
		or state.roleCache[guid]
	then
		return
	end
	mode = mode or (state.friendlyGUIDs[guid] and "friendly_coa" or "enemy_coa")
	local isFriendlyMode = mode == "friendly_coa"
	if isFriendlyMode then
		local retryAt = state.friendlyRetryAtByGUID[guid]
		if preferUnit then
			state.friendlyRetryAtByGUID[guid] = nil
			if retryAt then
				state.inspectAttemptsByGUID[guid] = 0
				AllyJournal:Status(
					"DIRECT_RETRY_UNLOCK",
					unit,
					guid,
					"direct target/focus/mouseover bypassed cooldown"
				)
			end
		elseif retryAt and GetTime() < retryAt then
			AllyJournal:Status(
				"RETRY_COOLDOWN",
				unit,
				guid,
				"periodic roster retry paused; direct references remain allowed"
			)
			return
		elseif retryAt then
			state.friendlyRetryAtByGUID[guid] = nil
			state.inspectAttemptsByGUID[guid] = 0
			AllyJournal:Status("RETRY_COOLDOWN_END", unit, guid, "periodic retry allowed")
		end
	end

	if state.pendingInspect and state.pendingInspect.guid == guid then
		if preferUnit
			and state.pendingInspect.mode == mode
			and UnitExists(unit)
			and UnitGUID(unit) == guid
		then
			state.pendingInspect.unit = unit
			if state.pendingInspect.mode == "friendly_coa" then
				AllyJournal:Status(
					"DIRECT_REF_UPGRADE",
					unit,
					guid,
					"pending inspection now uses direct reference"
				)
			end
		end
		return
	end

	if state.queuedGUIDs[guid] then
		if preferUnit then
			for index, entry in ipairs(state.inspectQueue) do
				if entry.guid == guid and entry.mode == mode then
					entry.unit = unit
					entry.readyAt = math.min(
						entry.readyAt or GetTime(),
						GetTime() + (delay or 0)
					)
					table.remove(state.inspectQueue, index)
					table.insert(state.inspectQueue, 1, entry)
					Debug("preferred inspect reference", UnitName(unit) or guid, unit)
					break
				end
			end
		end
		return
	end

	local entry = {
		unit = unit,
		guid = guid,
		readyAt = GetTime() + (delay or 0),
		retryWhileVisible = retryWhileVisible,
		mode = mode,
	}
	if preferUnit then
		table.insert(state.inspectQueue, 1, entry)
	else
		state.inspectQueue[#state.inspectQueue + 1] = entry
	end
	state.queuedGUIDs[guid] = true
	state.worker:Show()
	Debug("queued", UnitName(unit) or guid, unit)
	if isFriendlyMode then
		AllyJournal:Status(
			"QUEUED",
			unit,
			guid,
			"delay=" .. tostring(delay or 0)
				.. " preferred=" .. tostring(preferUnit and true or false)
		)
	end
end

local function QueueUnit(unit, delay)
	local record = state.visibleUnits[unit]
	if not record then
		return
	end

	QueueInspection(unit, record.guid, delay, true, false, "enemy_coa")
end

local function ObserveFriendlyUnit(unit, delay, fromFriendlyRoster)
	if not IsGroupTrackingActive()
		or not unit
		or not UnitExists(unit)
		or not UnitIsPlayer(unit)
	then
		return
	end

	local guid = UnitGUID(unit)
	if not guid then
		return
	end
	if fromFriendlyRoster then
		state.friendlyGUIDs[guid] = true
	elseif not IsFriendlyPlayer(unit, guid) then
		return
	end

	local data = CacheUnitIdentity(unit)
	if not data then
		return
	end
	data.isFriendly = true
	data.relationSource = fromFriendlyRoster and "roster" or "scoreboard"
	if state.roleCache[guid] then
		return
	end
	local battlefieldClass = GetBattlefieldClassToken(data.fullName or data.name)
	if not UnitIsUnit(unit, "player")
		and state.isActive
		and not battlefieldClass
	then
		-- Wait for the authoritative BG scoreboard class list. UnitClass can
		-- temporarily report stale CoA classes for other raid members.
		AllyJournal:Status(
			"WAIT_SCORE_CLASS",
			unit,
			guid,
			"scoreboard class token unavailable; UnitClass="
				.. tostring(data.unitClassToken)
		)
		return
	end

	local isDirectReference = UnitIsUnit(unit, "target")
		or UnitIsUnit(unit, "focus")
		or UnitIsUnit(unit, "mouseover")
	local canInspect = UnitIsUnit(unit, "player")
		or type(CanInspect) ~= "function"
		or CanInspect(unit, false)
	local inRange
	if type(UnitInRange) == "function" then
		local success, value = pcall(UnitInRange, unit)
		if success then
			inRange = value
		end
	end
	AllyJournal:Observe(
		unit,
		guid,
		battlefieldClass or data.scoreboardClassToken or data.unitClassToken,
		canInspect,
		inRange,
		isDirectReference
	)
	if canInspect or inRange == true or isDirectReference then
		QueueInspection(
			unit,
			data.guid,
			delay or 0.10,
			false,
			isDirectReference,
			"friendly_coa"
		)
	else
		AllyJournal:Status(
			"WAIT_RANGE",
			unit,
			guid,
			"CanInspect=false and UnitInRange=" .. tostring(inRange)
		)
	end
end

local function ScanFriendlyRoster()
	if not IsGroupTrackingActive() then
		return
	end
	if state.isActive then
		RefreshBattlefieldRosterMetadata()
	end

	ObserveFriendlyUnit("player", nil, true)
	for index = 1, 40 do
		ObserveFriendlyUnit("raid" .. index, nil, true)
	end
	for index = 1, 4 do
		ObserveFriendlyUnit("party" .. index, nil, true)
	end
end

local function ScanFriendlyReferences()
	if not IsGroupTrackingActive() then
		return
	end

	ObserveFriendlyUnit("target", 0.05, false)
	ObserveFriendlyUnit("focus", 0.05, false)
	ObserveFriendlyUnit("mouseover", 0.05, false)
end

local function ScheduleFriendlyRosterPolling()
	if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
		return
	end

	local generation = state.friendlyScanGeneration
	local Poll
	Poll = function()
		if not IsGroupTrackingActive()
			or generation ~= state.friendlyScanGeneration
		then
			return
		end

		ScanFriendlyRoster()
		C_Timer.After(FRIENDLY_SCAN_INTERVAL, Poll)
	end
	C_Timer.After(FRIENDLY_SCAN_INTERVAL, Poll)
end

local function ObserveEnemyReference(unit)
	if not state.isActive or not IsEnemyPlayer(unit) then
		return
	end

	local guid = UnitGUID(unit)
	if not guid or state.roleCache[guid] then
		return
	end

	local data = CacheUnitIdentity(unit)
	if data then
		data.isFriendly = false
		data.relationSource = "enemy"
	end
	QueueInspection(unit, guid, 0.05, false, false, "enemy_coa")
end

local function ScanEnemyReferences()
	if not state.isActive then
		return
	end

	ObserveEnemyReference("target")
	ObserveEnemyReference("focus")
	ObserveEnemyReference("mouseover")
	ObserveEnemyReference("targettarget")
	ObserveEnemyReference("focustarget")

	for index = 1, 40 do
		ObserveEnemyReference("raid" .. index .. "target")
	end
	for index = 1, 4 do
		ObserveEnemyReference("party" .. index .. "target")
	end
end

local function ScheduleAnchorRefresh(unit)
	local guid = unit and UnitGUID(unit)
	if not guid then
		return
	end

	state.pendingAnchorRefreshes[unit] = {
		guid = guid,
		readyAt = GetTime() + ANCHOR_REFRESH_DELAY,
	}
	state.worker:Show()
end

local function AttachUnit(unit)
	if not state.isActive or not IsEnemyPlayer(unit) then
		ReleaseUnit(unit)
		return false
	end

	local guid = UnitGUID(unit)
	if not guid then
		return false
	end
	local identity = CacheUnitIdentity(unit)
	if identity then
		identity.isFriendly = false
		identity.relationSource = "enemy_nameplate"
	end

	local namePlate = C_NamePlate
		and C_NamePlate.GetNamePlateForUnit
		and C_NamePlate.GetNamePlateForUnit(unit)
	local anchor = namePlate and (namePlate.unitFrame or namePlate)
	if not anchor then
		return false
	end

	local current = state.visibleUnits[unit]
	if current and current.guid == guid and current.anchor == anchor then
		local cached = state.roleCache[guid]
		if cached then
			ShowRole(current, cached)
		else
			QueueUnit(unit)
		end
		return true
	end

	ReleaseUnit(unit)

	local icon = GetRoleIcon(anchor)
	icon.ownerUnit = unit
	icon.ownerGUID = guid
	icon:Hide()

	local record = {
		unit = unit,
		guid = guid,
		anchor = anchor,
		icon = icon,
	}
	state.visibleUnits[unit] = record

	local cached = state.roleCache[guid]
	if cached then
		ShowRole(record, cached)
	else
		QueueUnit(unit, 0.10)
	end
	return true
end

local function ScanNameplates()
	for index = 1, MAX_NAMEPLATE_UNITS do
		local unit = "nameplate" .. index
		if UnitExists(unit) then
			AttachUnit(unit)
		elseif state.visibleUnits[unit] then
			ReleaseUnit(unit)
		end
	end
end

local function ProcessAnchorRefreshes(now)
	for unit, refresh in pairs(state.pendingAnchorRefreshes) do
		if refresh.readyAt <= now then
			state.pendingAnchorRefreshes[unit] = nil
			if UnitGUID(unit) == refresh.guid then
				AttachUnit(unit)
			end
		end
	end
end

local function StoreResolvedRole(unit, guid, classToken, specInfo)
	local identity = CacheUnitIdentity(unit) or state.playerDataByGUID[guid]
	local scoreboardClassToken = identity and identity.scoreboardClassToken
	if scoreboardClassToken and not ClassTokensMatch(scoreboardClassToken, classToken) then
		Debug(
			"rejected specialization from wrong class catalog",
			UnitName(unit) or guid,
			classToken,
			scoreboardClassToken
		)
		if AllyJournal:IsTracked(guid) then
			AllyJournal:Status(
				"SPEC_CLASS_REJECTED",
				unit,
				guid,
				"catalogClass=" .. tostring(classToken)
					.. " scoreboardClass=" .. tostring(scoreboardClassToken)
			)
		end
		return
	end

	local specializationTexture, specializationTexCoords =
		GetSpecializationTextureData(classToken, specInfo)
	local roleData = {
		role = RoleFromSpecInfo(specInfo),
		specialization = specInfo.Name or "Unknown",
		specializationID = specInfo.ID,
		specializationTexture = specializationTexture,
		specializationTexCoords = specializationTexCoords,
		specializationClassToken = classToken,
	}
	state.roleCache[guid] = roleData
	CacheUnitRole(unit, guid, roleData)
	local cachedData = state.playerDataByGUID[guid]
	if cachedData and cachedData.isFriendly then
		AllyJournal:Resolved(unit, guid, roleData)
	end

	for _, record in pairs(state.visibleUnits) do
		if record.guid == guid then
			ShowRole(record, roleData)
		end
	end

	Debug(
		UnitName(unit) or guid,
		roleData.specialization,
		roleData.role
	)
	return roleData
end

local function ResolveDirectSpecialization(unit, guid)
	if not UnitExists(unit)
		or not UnitIsPlayer(unit)
		or UnitGUID(unit) ~= guid
		or not UnitIsUnit(unit, "player")
		or type(C_ClassInfo) ~= "table"
		or type(GetSpecialization) ~= "function"
	then
		return
	end

	local success, specializationID = pcall(GetSpecialization)
	if not success or not specializationID or specializationID == 0 then
		return
	end

	local identity = CacheUnitIdentity(unit)
	local classToken = identity and (
		identity.scoreboardClassToken
		or identity.specializationClassToken
		or identity.unitClassToken
	)
	if not classToken then
		return
	end

	for _, specInfo in ipairs(GetClassSpecCatalog(classToken)) do
		if tonumber(specInfo.ID) == tonumber(specializationID) then
			return StoreResolvedRole(unit, guid, classToken, specInfo)
		end
	end

	Debug(
		"rejected mismatched player spec",
		UnitName(unit) or guid,
		specializationID,
		classToken
	)
end

local function ResolveInspectedRole(unit, guid)
	if not UnitExists(unit)
		or not UnitIsPlayer(unit)
		or UnitGUID(unit) ~= guid
	then
		if AllyJournal:IsTracked(guid) then
			AllyJournal:Status(
				"READ_TOKEN_INVALID",
				unit,
				guid,
				"exists=" .. tostring(unit and UnitExists(unit))
					.. " currentGUID=" .. tostring(unit and UnitGUID(unit))
			)
		end
		return nil, "unit token invalid"
	end

	if type(C_CharacterAdvancement) ~= "table"
		or type(C_ClassInfo) ~= "table"
	then
		if AllyJournal:IsTracked(guid) then
			AllyJournal:Status("READ_API_MISSING", unit, guid, "CoA inspection API missing")
		end
		return nil, "CoA API missing"
	end

	local inspectInfoSuccess, activeSpec = pcall(
		C_CharacterAdvancement.GetInspectInfo,
		unit
	)
	if not inspectInfoSuccess or not activeSpec then
		Debug(
			"CoA inspect info unavailable",
			UnitName(unit) or guid,
			unit,
			inspectInfoSuccess and "empty" or activeSpec
		)
		if AllyJournal:IsTracked(guid) then
			AllyJournal:Status(
				"READ_INFO_EMPTY",
				unit,
				guid,
				"pcall=" .. tostring(inspectInfoSuccess)
					.. " value=" .. tostring(activeSpec)
			)
		end
		return nil, "GetInspectInfo empty: " .. tostring(activeSpec)
	end

	local identity = CacheUnitIdentity(unit)
	local classToken = identity and (
		identity.scoreboardClassToken
		or identity.specializationClassToken
		or identity.unitClassToken
	)
	if not classToken then
		Debug("CoA inspect missing class token", UnitName(unit) or guid, unit)
		if AllyJournal:IsTracked(guid) then
			AllyJournal:Status(
				"READ_CLASS_MISSING",
				unit,
				guid,
				"activeSpec=" .. tostring(activeSpec)
			)
		end
		return nil, "class token missing"
	end

	local specs = GetClassSpecCatalog(classToken)
	local knownChecks = 0
	local callErrors = 0
	local checkResults = {}

	for _, specInfo in ipairs(specs) do
		local success, isKnown = pcall(
			C_CharacterAdvancement.UnitKnownID,
			unit,
			specInfo.PassiveID,
			activeSpec
		)

		if success then
			knownChecks = knownChecks + 1
		else
			callErrors = callErrors + 1
		end
		checkResults[#checkResults + 1] = tostring(specInfo.ID)
			.. "/" .. tostring(specInfo.PassiveID)
			.. "=" .. (success and tostring(isKnown) or "error")
		if success and isKnown then
			return StoreResolvedRole(unit, guid, classToken, specInfo)
		end
	end

	Debug(
		"CoA inspect found no matching specialization passive",
		UnitName(unit) or guid,
		classToken,
		activeSpec,
		#specs
	)
	if AllyJournal:IsTracked(guid) then
		AllyJournal:Status(
			"READ_NO_PASSIVE",
			unit,
			guid,
			"class=" .. tostring(classToken)
				.. " activeSpec=" .. tostring(activeSpec)
				.. " catalog=" .. tostring(#specs)
				.. " checks=" .. tostring(knownChecks)
				.. " errors=" .. tostring(callErrors)
				.. " tested=" .. table.concat(checkResults, ",")
		)
	end
	return nil, "no matching passive; activeSpec=" .. tostring(activeSpec)
end

local function UnitMatchesGUID(unit, guid)
	return unit
		and guid
		and UnitExists(unit)
		and UnitIsPlayer(unit)
		and UnitGUID(unit) == guid
end

local function FindBestUnitForGUID(guid, fallbackUnit)
	for _, unit in ipairs({ "target", "mouseover", "focus" }) do
		if UnitMatchesGUID(unit, guid) then
			return unit
		end
	end

	if UnitMatchesGUID(fallbackUnit, guid) then
		return fallbackUnit
	end

	for unit, record in pairs(state.visibleUnits) do
		if record.guid == guid and UnitMatchesGUID(unit, guid) then
			return unit
		end
	end

	for index = 1, 40 do
		local raidUnit = "raid" .. index
		if UnitMatchesGUID(raidUnit, guid) then
			return raidUnit
		end
		local raidTarget = raidUnit .. "target"
		if UnitMatchesGUID(raidTarget, guid) then
			return raidTarget
		end
	end
	for index = 1, 4 do
		local partyUnit = "party" .. index
		if UnitMatchesGUID(partyUnit, guid) then
			return partyUnit
		end
		local partyTarget = partyUnit .. "target"
		if UnitMatchesGUID(partyTarget, guid) then
			return partyTarget
		end
	end
end

local function PopReadyInspect(now)
	local index = 1
	while index <= #state.inspectQueue do
		local entry = state.inspectQueue[index]
		if entry.readyAt <= now then
			table.remove(state.inspectQueue, index)
			state.queuedGUIDs[entry.guid] = nil

			local bestUnit = FindBestUnitForGUID(entry.guid, entry.unit)
			if bestUnit and not state.roleCache[entry.guid] then
				entry.unit = bestUnit
				return entry
			end
		else
			index = index + 1
		end
	end
end

local function CanUseCharacterAdvancementInspection(unit, guid)
	return UnitMatchesGUID(unit, guid)
		and type(C_CharacterAdvancement) == "table"
		and type(C_CharacterAdvancement.InspectUnit) == "function"
		and type(C_CharacterAdvancement.GetInspectInfo) == "function"
		and type(C_CharacterAdvancement.UnitKnownID) == "function"
		and type(C_ClassInfo) == "table"
end

local function RetryFailedInspect(request)
	if not request or state.roleCache[request.guid] then
		return
	end

	local retryUnit = FindBestUnitForGUID(request.guid, request.unit)
	if request.mode == "enemy_coa" then
		if request.retryWhileVisible then
			for unit, record in pairs(state.visibleUnits) do
				if record.guid == request.guid and UnitMatchesGUID(unit, request.guid) then
					QueueInspection(
						unit,
						request.guid,
						RETRY_DELAY,
						true,
						false,
						"enemy_coa"
					)
					break
				end
			end
		end
	elseif request.mode == "friendly_coa"
		and (request.attempt or 1) < MAX_FRIENDLY_INSPECT_ATTEMPTS
		and retryUnit
	then
		AllyJournal:Status(
			"INSPECT_REQUEUE",
			retryUnit,
			request.guid,
			"nextAttempt=" .. tostring((request.attempt or 1) + 1)
		)
		QueueInspection(
			retryUnit,
			request.guid,
			RETRY_DELAY,
			false,
			true,
			"friendly_coa"
		)
	elseif request.mode == "friendly_coa" then
		state.friendlyRetryAtByGUID[request.guid] = GetTime() + FRIENDLY_RETRY_COOLDOWN
		AllyJournal:Status(
			"INSPECT_RETRY_STOP",
			retryUnit or request.unit,
			request.guid,
			"attempt=" .. tostring(request.attempt)
				.. " hasToken=" .. tostring(retryUnit ~= nil)
				.. " cooldown=" .. tostring(FRIENDLY_RETRY_COOLDOWN)
		)
	end
end

local function StartNextInspect(now)
	if state.pendingInspect or now < state.nextInspectAt then
		return
	end

	local entry = PopReadyInspect(now)
	if not entry then
		return
	end
	local isFriendly = entry.mode == "friendly_coa"
	local attempt = (state.inspectAttemptsByGUID[entry.guid] or 0) + 1
	state.inspectAttemptsByGUID[entry.guid] = attempt

	if isFriendly then
		if UnitIsUnit(entry.unit, "player") then
			ResolveDirectSpecialization(entry.unit, entry.guid)
			state.nextInspectAt = now + INSPECT_GAP
			return
		end
	end

	local bestUnit = FindBestUnitForGUID(entry.guid, entry.unit)
	if bestUnit then
		entry.unit = bestUnit
	end
	state.pendingInspect = {
		unit = entry.unit,
		guid = entry.guid,
		startedAt = now,
		retryWhileVisible = entry.retryWhileVisible,
		mode = entry.mode or (isFriendly and "friendly_coa" or "enemy_coa"),
		attempt = attempt,
	}
	if isFriendly then
		local canInspect = type(CanInspect) ~= "function" or CanInspect(entry.unit, false)
		local inRange
		if type(UnitInRange) == "function" then
			local rangeSuccess, rangeValue = pcall(UnitInRange, entry.unit)
			if rangeSuccess then
				inRange = rangeValue
			end
		end
		AllyJournal:Attempt(
			entry.unit,
			entry.guid,
			attempt,
			"canInspect=" .. tostring(canInspect)
				.. " inRange=" .. tostring(inRange)
				.. " combat=" .. tostring(type(InCombatLockdown) == "function" and InCombatLockdown())
		)
	end

	if not CanUseCharacterAdvancementInspection(entry.unit, entry.guid) then
		local request = state.pendingInspect
		if isFriendly then
			AllyJournal:Status(
				"INSPECT_API_BLOCKED",
				entry.unit,
				entry.guid,
				"token invalid or CoA API unavailable"
			)
		end
		state.pendingInspect = nil
		state.nextInspectAt = now + INSPECT_GAP
		RetryFailedInspect(request)
		return
	end

	Debug(
		isFriendly and "friendly CoA inspect start" or "enemy CoA inspect start",
		UnitName(entry.unit) or entry.guid,
		entry.unit
	)
	local success, inspectResult = pcall(
		C_CharacterAdvancement.InspectUnit,
		entry.unit
	)
	if isFriendly then
		AllyJournal:Status(
			success and IsInspectRequestAccepted(inspectResult)
				and "INSPECT_CALL_ACCEPTED"
				or "INSPECT_CALL_REJECTED",
			entry.unit,
			entry.guid,
			"pcall=" .. tostring(success)
				.. " resultType=" .. tostring(type(inspectResult))
				.. " result=" .. tostring(inspectResult)
		)
	end

	if not success or not IsInspectRequestAccepted(inspectResult) then
		local request = state.pendingInspect
		if not success then
			Debug(request.mode .. " inspect call failed", inspectResult)
		else
			Debug(request.mode .. " inspect rejected", type(inspectResult), inspectResult)
		end
		state.pendingInspect = nil
		state.nextInspectAt = now + INSPECT_GAP
		RetryFailedInspect(request)
	end
end

local function FinishInspect(result)
	local request = state.pendingInspect
	if not request
		or (request.mode ~= "friendly_coa" and request.mode ~= "enemy_coa")
	then
		return
	end
	if request.resolveAt then
		if request.mode == "friendly_coa" then
			AllyJournal:Add(
				"EXTRA_RESULT_EVENT",
				request.unit,
				request.guid,
				"result=" .. tostring(result)
			)
		end
		return
	end

	state.pendingInspect = nil
	local now = GetTime()
	state.nextInspectAt = now + INSPECT_GAP
	Debug(request.mode .. " inspect result", result)
	if request.mode == "friendly_coa" then
		AllyJournal:Add(
			"RESULT_EVENT",
			request.unit,
			request.guid,
			"accepted=" .. tostring(IsInspectRequestAccepted(result))
				.. " value=" .. tostring(result)
		)
	end

	local resolved
	local failureReason
	if IsInspectRequestAccepted(result) then
		if UnitMatchesGUID(request.unit, request.guid) then
			resolved, failureReason = ResolveInspectedRole(request.unit, request.guid)
		end
		if not resolved then
			local currentUnit = FindBestUnitForGUID(request.guid, request.unit)
			if currentUnit and currentUnit ~= request.unit then
				request.unit = currentUnit
				resolved, failureReason = ResolveInspectedRole(currentUnit, request.guid)
			end
		end
	else
		failureReason = "result rejected: " .. tostring(result)
	end

	if not resolved and request.mode == "friendly_coa"
		and IsInspectRequestAccepted(result)
	then
		request.resolveRetryIndex = 1
		request.resolveAt = now + FRIENDLY_RESULT_READ_DELAYS[1]
		request.startedAt = now
		request.lastResolveReason = failureReason
		state.pendingInspect = request
		AllyJournal:Status(
			"READ_RETRY_SCHEDULED",
			request.unit,
			request.guid,
			"delay=" .. tostring(FRIENDLY_RESULT_READ_DELAYS[1])
				.. " reason=" .. tostring(failureReason)
		)
		state.worker:Show()
	elseif not resolved then
		RetryFailedInspect(request)
	end
end

local function ProcessPendingFriendlyResolution(now)
	local request = state.pendingInspect
	if not request or not request.resolveAt or now < request.resolveAt then
		return
	end

	local currentUnit = FindBestUnitForGUID(request.guid, request.unit)
	local resolved
	local failureReason = "no valid unit token"
	if currentUnit then
		request.unit = currentUnit
		resolved, failureReason = ResolveInspectedRole(currentUnit, request.guid)
	end
	if resolved then
		state.pendingInspect = nil
		state.nextInspectAt = now + INSPECT_GAP
		return
	end

	local nextRetryIndex = (request.resolveRetryIndex or 1) + 1
	local nextDelay = FRIENDLY_RESULT_READ_DELAYS[nextRetryIndex]
	if nextDelay then
		request.resolveRetryIndex = nextRetryIndex
		request.resolveAt = now + nextDelay
		request.lastResolveReason = failureReason
		AllyJournal:Status(
			"READ_RETRY_SCHEDULED",
			request.unit,
			request.guid,
			"read=" .. tostring(nextRetryIndex + 1)
				.. " delay=" .. tostring(nextDelay)
				.. " reason=" .. tostring(failureReason)
		)
		return
	end

	state.pendingInspect = nil
	state.nextInspectAt = now + INSPECT_GAP
	AllyJournal:Status(
		"READ_RETRIES_EXHAUSTED",
		request.unit,
		request.guid,
		"reason=" .. tostring(failureReason)
	)
	RetryFailedInspect(request)
end

function Nameplates.Initialize()
	addonDB = API and API.GetDatabase and API.GetDatabase()
	return addonDB ~= nil
end

Nameplates.EnsureEnemyNameplateTracking = EnsureEnemyNameplateTracking
Nameplates.ScheduleEnemyNameplateCheck = ScheduleEnemyNameplateCheck
Nameplates.ApplyRoleTexture = ApplyRoleTexture
Nameplates.ApplySpecializationTexture = ApplySpecializationTexture
Nameplates.RefreshVisibleIconLayouts = RefreshVisibleIconLayouts
Nameplates.ReleaseUnit = ReleaseUnit
Nameplates.ObserveFriendlyUnit = ObserveFriendlyUnit
Nameplates.ScanFriendlyRoster = ScanFriendlyRoster
Nameplates.ScanFriendlyReferences = ScanFriendlyReferences
Nameplates.ScheduleFriendlyRosterPolling = ScheduleFriendlyRosterPolling
Nameplates.ObserveEnemyReference = ObserveEnemyReference
Nameplates.ScanEnemyReferences = ScanEnemyReferences
Nameplates.ScheduleAnchorRefresh = ScheduleAnchorRefresh
Nameplates.AttachUnit = AttachUnit
Nameplates.ScanNameplates = ScanNameplates
Nameplates.ProcessAnchorRefreshes = ProcessAnchorRefreshes
Nameplates.RetryFailedInspect = RetryFailedInspect
Nameplates.StartNextInspect = StartNextInspect
Nameplates.FinishInspect = FinishInspect
Nameplates.ProcessPendingFriendlyResolution = ProcessPendingFriendlyResolution

API.ApplyRoleTexture = ApplyRoleTexture
API.ApplySpecializationTexture = ApplySpecializationTexture
API.RefreshVisibleIconLayouts = RefreshVisibleIconLayouts
API.ScanFriendlyRoster = ScanFriendlyRoster
API.ScanEnemyReferences = ScanEnemyReferences

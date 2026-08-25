local ADDON_NAME = ...
local ADDON_VERSION = CoAAnalyticsAddon and CoAAnalyticsAddon.VERSION or "2.17.0"

local ICON_SIZE = 18
local ICON_OFFSET_Y = 3
local ICON_GAP = 2
local ICON_POSITION_DISTANCE = ICON_SIZE + ICON_GAP
local MINIMAP_BUTTON_RADIUS = 80
local MAX_NAMEPLATE_UNITS = 80
local NAMEPLATE_CVAR = "nameplateShowEnemies"
local NAMEPLATE_CVAR_RECHECK_DELAY = 0.10
local ANCHOR_REFRESH_DELAY = 0.10
local INSPECT_UPDATE_INTERVAL = 0.05
local INSPECT_GAP = 0.75
local INSPECT_TIMEOUT = 5
local RETRY_DELAY = 2
local MAX_FRIENDLY_INSPECT_ATTEMPTS = 3
local FRIENDLY_SCAN_INTERVAL = 4
local FRIENDLY_RESULT_READ_DELAYS = { 0.15, 0.40, 0.80 }
local FRIENDLY_RETRY_COOLDOWN = 20
local ALLY_JOURNAL_MAX_LINES = 600
local ALLY_JOURNAL_MAX_AGE = 10800
local RANKING_VISIBLE_ROWS = 7
local RANKING_ROW_HEIGHT = 33
local RANKING_TABLE_LEFT_INSET = 12
local RANKING_TABLE_RIGHT_INSET = 24
local RANKING_SCORE_RIGHT_INSET = 83
local RANKING_PERCENT_RIGHT_INSET = 10
local RANKING_DATABASE_VERSION = 5
local RANKING_PROXIMITY_FLOOR = 0.50
local RANKING_NEAR_TOP_RATIO = 0.90
local RANKING_POINT_EPSILON = 0.000000001
local SPECIALIZATION_RANKING_PRIOR_BG = 5
local STOMP_DEATH_WEIGHT = 0.70
local STOMP_DAMAGE_WEIGHT = 0.30
local STOMP_MATCH_WEIGHT_SCALE = 0.75
local STOMP_MINIMUM_MATCH_WEIGHT = 0.25
local PLAYER_RANKING_PRIOR_MATCHES = 10
local PLAYER_RANKING_NEAR_TOP_RATIO = 0.90
local PLAYER_RANKING_UNCERTAINTY_MARGIN = 6
local PLAYER_RANKING_PLACEMENT_MATCHES = 3
local PLAYER_RANKING_DATABASE_VERSION = 3
local PLAYER_RANKING_LEVEL_POWER_EXPONENT = 1.50
local PLAYER_RANKING_LEVEL_FACTOR_MIN = 0.65
local PLAYER_RANKING_LEVEL_FACTOR_MAX = 1.55
local PLAYER_RANKING_MIN_PARTICIPATION = 0.25
local PLAYER_SEARCH_MAX_SUGGESTIONS = 8

local PLAYER_RANKING_ROLE_KEYS = {
	"MELEE_DAMAGER",
	"RANGED_DAMAGER",
	"DAMAGER",
	"HEALER",
	"TANK",
	"SUPPORT",
}

local ROLE_ATLAS_FALLBACKS = {
	DAMAGER = "ui-lfg-roleicon-dps",
	MELEE_DAMAGER = "ui-lfg-roleicon-meleedps",
	RANGED_DAMAGER = "ui-lfg-roleicon-rangeddps",
	HEALER = "ui-lfg-roleicon-healer",
	TANK = "ui-lfg-roleicon-tank",
	SUPPORT = "ui-lfg-roleicon-generic",
}

local ROLE_ATLAS_KEYS = {
	DAMAGER = { "DAMAGER" },
	MELEE_DAMAGER = { "MELEE_DAMAGER", "MELEE_DPS", "MELEEDPS", "MELEE" },
	RANGED_DAMAGER = { "RANGED_DAMAGER", "RANGED_DPS", "RANGEDDPS", "RANGED" },
	HEALER = { "HEALER" },
	TANK = { "TANK" },
	SUPPORT = { "SUPPORT" },
}

local ROLE_ATLAS_CANDIDATES = {
	MELEE_DAMAGER = {
		"ui-lfg-roleicon-meleedps",
		"ui-lfg-roleicon-melee-dps",
		"ui-lfg-roleicon-melee",
		"ui-lfg-roleicon-dps-melee",
	},
	RANGED_DAMAGER = {
		"ui-lfg-roleicon-rangeddps",
		"ui-lfg-roleicon-ranged-dps",
		"ui-lfg-roleicon-ranged",
		"ui-lfg-roleicon-dps-ranged",
	},
}

local ROLE_FALLBACK_TEXTURES = {
	DAMAGER = "Interface\\Icons\\Ability_DualWield",
	MELEE_DAMAGER = "Interface\\Icons\\INV_Sword_04",
	RANGED_DAMAGER = "Interface\\Icons\\INV_Weapon_Bow_07",
	HEALER = "Interface\\Icons\\Spell_Holy_HolyBolt",
	TANK = "Interface\\Icons\\INV_Shield_06",
	SUPPORT = "Interface\\Icons\\Spell_Holy_BlessingOfStrength",
}

local ABOVE_POSITION_OFFSETS = {
	ABOVE_LEFT = -ICON_POSITION_DISTANCE,
	ABOVE_CENTER = 0,
	ABOVE_RIGHT = ICON_POSITION_DISTANCE,
}

local VALID_ICON_POSITIONS = {
	ABOVE_LEFT = true,
	ABOVE_CENTER = true,
	ABOVE_RIGHT = true,
	INLINE_LEFT = true,
	INLINE_RIGHT = true,
}

local LEGACY_ICON_POSITIONS = {
	LEFT = "ABOVE_LEFT",
	CENTER = "ABOVE_CENTER",
	RIGHT = "ABOVE_RIGHT",
}

local ICON_POSITION_OPTIONS = {
	{ value = "ABOVE_LEFT", text = "Above - left" },
	{ value = "ABOVE_CENTER", text = "Above - center" },
	{ value = "ABOVE_RIGHT", text = "Above - right" },
	{ value = "INLINE_LEFT", text = "Same line - left" },
	{ value = "INLINE_RIGHT", text = "Same line - right" },
}

local SPEC_ICON_ATLAS_TEXTURE =
	"Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES-SPECS"
local UNKNOWN_SPEC_TEXTURE = "Interface\\Icons\\INV_Misc_QuestionMark"

local driver = CreateFrame("Frame")
local debugEnabled = false
local addonDB

-- Lua 5.1 limits each chunk to 200 active local variables. The bulky state
-- tables are grouped so the main file stays loadable.
local state = {
	worker = CreateFrame("Frame"),
	isActive = false,
	updateElapsed = 0,
	nextInspectAt = 0,
	nextNameplateCVarCheckAt = nil,
	friendlyScanGeneration = 0,
	visibleUnits = {},
	iconsByAnchor = setmetatable({}, { __mode = "k" }),
	roleCache = {},
	playerDataByGUID = {},
	playerDataByName = {},
	ambiguousPlayerBaseNames = {},
	battlefieldClassByName = {},
	battlefieldTeamByName = {},
	friendlyGUIDs = {},
	specCatalogByClass = {},
	resolvedRoleAtlases = {},
	inspectQueue = {},
	queuedGUIDs = {},
	inspectAttemptsByGUID = {},
	friendlyRetryAtByGUID = {},
	pendingAnchorRefreshes = {},
}

local AllyJournal = {}

local function Chat(message)
	local chatFrame = DEFAULT_CHAT_FRAME or ChatFrame1
	if chatFrame then
		chatFrame:AddMessage("|cff00ba79CoA Analytics:|r " .. tostring(message))
	end
end

local function Debug(...)
	if not debugEnabled then
		return
	end

	local values = {}
	for index = 1, select("#", ...) do
		values[index] = tostring(select(index, ...))
	end
	Chat(table.concat(values, " "))
end

local function IsCVarEnabled(value)
	value = string.lower(tostring(value or ""))
	return value == "1" or value == "true"
end

local function IsInspectRequestAccepted(result)
	if result == nil or result == true or result == 1 then
		return true
	end

	if type(result) == "string" then
		result = string.lower(result)
		return result == "true"
			or result == "1"
			or result == "ca_inspect_ok"
	end

	return false
end

local function IsBattleground()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "pvp"
end

local function IsPvEInstance()
	local inInstance, instanceType = IsInInstance()
	return inInstance and (instanceType == "party" or instanceType == "raid")
end

local function IsGroupTrackingActive()
	return state.isActive or IsPvEInstance()
end

local function NormalizePlayerName(name)
	if not name or name == "" then
		return
	end

	return string.lower(name)
end

local function GetBasePlayerName(name)
	return name and (string.match(name, "^([^-]+)") or name)
end

local function GetCachedPlayerData(name)
	local normalized = NormalizePlayerName(name)
	if not normalized then
		return
	end
	local exact = state.playerDataByName[normalized]
	if exact then
		return exact
	end
	local baseNormalized = NormalizePlayerName(GetBasePlayerName(name))
	if state.ambiguousPlayerBaseNames[baseNormalized] then
		return
	end
	return state.playerDataByName[baseNormalized]
end

local function GetBattlefieldClassToken(name)
	local normalized = NormalizePlayerName(name)
	if not normalized then
		return
	end

	return state.battlefieldClassByName[normalized]
		or state.battlefieldClassByName[NormalizePlayerName(GetBasePlayerName(name))]
end

local function GetBattlefieldTeam(name)
	local normalized = NormalizePlayerName(name)
	if not normalized then
		return
	end

	local team = state.battlefieldTeamByName[normalized]
	if team ~= nil then
		return team
	end
	return state.battlefieldTeamByName[NormalizePlayerName(GetBasePlayerName(name))]
end

local function ClassTokensMatch(left, right)
	if not left or not right then
		return true
	end
	return string.upper(tostring(left)) == string.upper(tostring(right))
end

local function RefreshBattlefieldRosterMetadata()
	if type(GetNumBattlefieldScores) ~= "function"
		or type(GetBattlefieldScore) ~= "function"
	then
		return
	end

	local scoreCount = GetNumBattlefieldScores()
	if not scoreCount or scoreCount <= 0 then
		-- Keep the last complete snapshot. The client can briefly expose zero
		-- rows while rebuilding the scoreboard, especially at match end.
		return
	end

	local playerName = UnitName("player")
	local playerNormalized = NormalizePlayerName(playerName)
	local playerBaseNormalized = NormalizePlayerName(GetBasePlayerName(playerName))
	for index = 1, scoreCount do
		local name, _, _, _, _, team, _, _, _, classToken =
			GetBattlefieldScore(index)
		if name and type(classToken) == "string" and classToken ~= "" then
			local normalized = NormalizePlayerName(name)
			local baseNormalized = NormalizePlayerName(GetBasePlayerName(name))
			state.battlefieldClassByName[normalized] = classToken
			state.battlefieldClassByName[baseNormalized] = classToken
			if team ~= nil then
				state.battlefieldTeamByName[normalized] = team
				state.battlefieldTeamByName[baseNormalized] = team
				if playerNormalized and (
					normalized == playerNormalized
					or baseNormalized == playerBaseNormalized
				)
				then
					state.playerBattlefieldTeam = team
				end
			end

			local data = GetCachedPlayerData(name)
			if data then
				data.scoreboardClassToken = classToken
				if team ~= nil then
					data.battlefieldTeam = team
					if state.playerBattlefieldTeam ~= nil then
						data.isFriendly = tostring(team) == tostring(state.playerBattlefieldTeam)
					end
				end
			end
		end
	end
end

local function CacheUnitIdentity(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
		return
	end

	local guid = UnitGUID(unit)
	local name, realm = UnitName(unit)
	if not guid or not name then
		return
	end

	local fullName = name
	if realm and realm ~= "" then
		fullName = name .. "-" .. realm
	end

	-- A GUID owns exactly one specialization record. Never reuse a record only
	-- because a base name matches: cross-realm players can share that name.
	local data = state.playerDataByGUID[guid] or {}
	local _, unitClassToken = UnitClass(unit)
	local scoreboardClassToken = GetBattlefieldClassToken(fullName)
		or GetBattlefieldClassToken(name)
	local battlefieldTeam = GetBattlefieldTeam(fullName)
	if battlefieldTeam == nil then
		battlefieldTeam = GetBattlefieldTeam(name)
	end
	if scoreboardClassToken then
		data.scoreboardClassToken = scoreboardClassToken
	end
	local level = UnitLevel(unit)

	data.guid = guid
	data.name = name
	data.fullName = fullName
	data.unitClassToken = unitClassToken or data.unitClassToken
	if battlefieldTeam ~= nil then
		data.battlefieldTeam = battlefieldTeam
		if state.playerBattlefieldTeam ~= nil then
			data.isFriendly = tostring(battlefieldTeam)
				== tostring(state.playerBattlefieldTeam)
		end
	elseif state.friendlyGUIDs[guid] then
		data.isFriendly = true
	end
	if level and level > 0 then
		data.level = level
	end

	state.playerDataByGUID[guid] = data
	local normalizedName = NormalizePlayerName(name)
	local normalizedFullName = NormalizePlayerName(fullName)
	state.playerDataByName[normalizedFullName] = data
	local existingBaseData = state.playerDataByName[normalizedName]
	if existingBaseData and existingBaseData.guid ~= guid then
		state.ambiguousPlayerBaseNames[normalizedName] = true
		state.playerDataByName[normalizedName] = nil
	elseif not state.ambiguousPlayerBaseNames[normalizedName] then
		state.playerDataByName[normalizedName] = data
	end
	return data
end

local function CacheUnitRole(unit, guid, roleData)
	local data = CacheUnitIdentity(unit) or state.playerDataByGUID[guid]
	if not data then
		return
	end

	data.role = roleData.role
	data.specialization = roleData.specialization
	data.specializationID = roleData.specializationID
	data.specializationTexture = roleData.specializationTexture
	data.specializationTexCoords = roleData.specializationTexCoords
	data.specializationClassToken = roleData.specializationClassToken
	data.roleSource = "specialization"
	if CoAAnalyticsAddon and CoAAnalyticsAddon.Events then
		CoAAnalyticsAddon.Events:Fire("PLAYER_DATA_UPDATED", data)
	end
	return data
end

local function RestoreEnemyNameplateSetting()
	if not addonDB or not addonDB.nameplateOverrideActive then
		return
	end

	local previousValue = addonDB.previousEnemyNameplates
	addonDB.nameplateOverrideActive = nil
	addonDB.previousEnemyNameplates = nil

	if previousValue ~= nil
		and tostring(GetCVar(NAMEPLATE_CVAR)) ~= tostring(previousValue)
	then
		SetCVar(NAMEPLATE_CVAR, previousValue)
	end
end

local function InitializeRankingDatabase()
	if not addonDB then
		return
	end

	if type(addonDB.rankings) ~= "table" then
		addonDB.rankings = {
			version = RANKING_DATABASE_VERSION,
		}
	end
	local rankings = addonDB.rankings
	local previousVersion = tonumber(rankings.version) or 1
	rankings.totalBattlegrounds = tonumber(rankings.totalBattlegrounds) or 0

	-- Version 1 only knew the two raw Top 1 players. Those results cannot be
	-- reconstructed into proximity/stomp points, so preserve them as history
	-- while the statistically comparable score starts at zero in version 2.
	if previousVersion < 2 then
		rankings.legacyBattlegrounds = tonumber(rankings.legacyBattlegrounds)
			or rankings.totalBattlegrounds
	end
	rankings.legacyBattlegrounds = tonumber(rankings.legacyBattlegrounds) or 0
	rankings.smoothedBattlegrounds = tonumber(rankings.smoothedBattlegrounds) or 0
	rankings.stompEvaluatedBGs = tonumber(rankings.stompEvaluatedBGs) or 0
	rankings.stompScoreTotal = tonumber(rankings.stompScoreTotal) or 0
	rankings.matchWeightTotal = tonumber(rankings.matchWeightTotal) or 0
	rankings.contextIncompleteBGs = tonumber(rankings.contextIncompleteBGs) or 0

	for _, categoryKey in ipairs({ "dps", "healing" }) do
		if type(rankings[categoryKey]) ~= "table" then
			rankings[categoryKey] = {}
		end
		local category = rankings[categoryKey]
		category.identifiedBGs = tonumber(category.identifiedBGs) or 0
		category.unknownBGs = tonumber(category.unknownBGs) or 0
		if previousVersion < 2 then
			category.legacyIdentifiedBGs =
				tonumber(category.legacyIdentifiedBGs) or category.identifiedBGs
			category.legacyUnknownBGs =
				tonumber(category.legacyUnknownBGs) or category.unknownBGs
		end
		category.legacyIdentifiedBGs =
			tonumber(category.legacyIdentifiedBGs) or 0
		category.legacyUnknownBGs = tonumber(category.legacyUnknownBGs) or 0
		category.analyzedBGs = tonumber(category.analyzedBGs) or 0
		category.incompleteBGs = tonumber(category.incompleteBGs) or 0
		category.emptyBGs = tonumber(category.emptyBGs) or 0
		category.totalWeight = tonumber(category.totalWeight) or 0
		local historicalAverageWeight = category.analyzedBGs > 0
			and category.totalWeight / category.analyzedBGs
			or 1
		if type(category.entries) ~= "table" then
			category.entries = {}
		end
		for _, entry in pairs(category.entries) do
			if type(entry) == "table" then
				local existingTop1 = tonumber(entry.top1Finishes)
					or tonumber(entry.wins)
					or 0
				if previousVersion < 2 then
					entry.legacyTop1 = tonumber(entry.legacyTop1)
						or existingTop1
				end
				entry.legacyTop1 = tonumber(entry.legacyTop1) or 0
				entry.top1Finishes = existingTop1
				entry.wins = existingTop1
				entry.top1V2 = tonumber(entry.top1V2) or 0
				entry.performancePoints =
					tonumber(entry.performancePoints) or 0
				entry.appearances = tonumber(entry.appearances) or 0
				-- Version 4 normalizes points by weighted participation. Older BGs
				-- only stored their count: rebuilding their weight from the average
				-- influence preserves the whole history without handing an advantage
				-- to specializations that simply showed up often.
				local storedAppearanceWeight =
					tonumber(entry.appearanceWeight)
				if not storedAppearanceWeight
					or (storedAppearanceWeight <= 0 and entry.appearances > 0)
				then
					entry.appearanceWeight =
						entry.appearances * historicalAverageWeight
				else
					entry.appearanceWeight = storedAppearanceWeight
				end
				entry.qualifiedBGs = tonumber(entry.qualifiedBGs) or 0
				entry.nearTopBGs = tonumber(entry.nearTopBGs) or 0
			end
		end
	end

	if type(rankings.players) ~= "table" then
		rankings.players = {}
	end
	local playerRankings = rankings.players
	local previousPlayerVersion = tonumber(playerRankings.version) or 1
	playerRankings.repairs = type(playerRankings.repairs) == "table"
		and playerRankings.repairs or {}
	local function RemoveInvalidPlayerSample(
		entry,
		score,
		weight,
		participation,
		clearLast
	)
		score = math.max(0, tonumber(score) or 0)
		weight = math.min(
			math.max(0, tonumber(weight) or 0),
			math.max(0, tonumber(entry.scoreWeight) or 0)
		)
		if weight <= 0 or (tonumber(entry.appearances) or 0) <= 0 then
			return false
		end
		entry.scoreSum = math.max(
			0,
			(tonumber(entry.scoreSum) or 0) - score * weight
		)
		entry.scoreWeight = math.max(
			0,
			(tonumber(entry.scoreWeight) or 0) - weight
		)
		entry.appearances = math.max(0, entry.appearances - 1)
		entry.comparableBGs = math.max(
			0,
			(tonumber(entry.comparableBGs) or 0) - 1
		)
		entry.participationTotal = math.max(
			0,
			(tonumber(entry.participationTotal) or 0)
				- math.max(0, tonumber(participation) or 1)
		)
		local identityKey = entry.classToken and entry.specializationID
			and (string.upper(tostring(entry.classToken))
				.. ":" .. tostring(entry.specializationID))
		local specialization = identityKey and entry.specializations
			and entry.specializations[identityKey]
		if type(specialization) == "table" then
			specialization.appearances = math.max(
				0,
				(tonumber(specialization.appearances) or 0) - 1
			)
		end
		entry.mainSpecializationAppearances = math.max(
			0,
			(tonumber(entry.mainSpecializationAppearances) or 0) - 1
		)
		entry.invalidSamplesRemoved =
			(tonumber(entry.invalidSamplesRemoved) or 0) + 1
		if clearLast then
			entry.lastScore = nil
			entry.lastMatchWeight = nil
			entry.lastDamage = nil
			entry.lastHealing = nil
			entry.lastParticipationRatio = nil
		end
		return true
	end
	playerRankings.totalBattlegrounds =
		tonumber(playerRankings.totalBattlegrounds) or 0
	playerRankings.incompleteBattlegrounds =
		tonumber(playerRankings.incompleteBattlegrounds) or 0
	if type(playerRankings.categories) ~= "table" then
		playerRankings.categories = {}
	end
	for _, roleKey in ipairs(PLAYER_RANKING_ROLE_KEYS) do
		local category = playerRankings.categories[roleKey]
		if type(category) ~= "table" then
			category = {}
			playerRankings.categories[roleKey] = category
		end
		category.analyzedBGs = tonumber(category.analyzedBGs) or 0
		category.incompleteBGs = tonumber(category.incompleteBGs) or 0
		category.totalWeight = tonumber(category.totalWeight) or 0
		if type(category.entries) ~= "table" then
			category.entries = {}
		end
		for _, entry in pairs(category.entries) do
			if type(entry) == "table" then
				entry.scoreSum = tonumber(entry.scoreSum) or 0
				entry.scoreWeight = tonumber(entry.scoreWeight) or 0
				entry.appearances = tonumber(entry.appearances) or 0
				entry.participationTotal =
					tonumber(entry.participationTotal) or entry.appearances
				entry.comparableBGs = tonumber(entry.comparableBGs) or 0
				entry.nearTopBGs = tonumber(entry.nearTopBGs) or 0
				entry.top1Finishes = tonumber(entry.top1Finishes) or 0
				if previousPlayerVersion < 2 and type(entry.legacyV1) ~= "table" then
					entry.legacyV1 = {
						scoreSum = entry.scoreSum,
						scoreWeight = entry.scoreWeight,
						appearances = entry.appearances,
						comparableBGs = entry.comparableBGs,
						nearTopBGs = entry.nearTopBGs,
						top1Finishes = entry.top1Finishes,
					}
				end
				if previousPlayerVersion < 2 and entry.scoreWeight > 0 then
					-- The old score was a hard-clamped ratio. The new 2r/(1+r) curve can
					-- be applied to its aggregated mean: 100 stays 100, extreme values
					-- are compressed without reversing their order. The exact original
					-- remains available in legacyV1.
					local previousRawScore = entry.scoreSum / entry.scoreWeight
					local convertedScore = previousRawScore > 0
						and 200 * previousRawScore / (100 + previousRawScore)
						or 0
					entry.scoreSum = convertedScore * entry.scoreWeight
					entry.normalizationVersion = 2
				end

				local normalizedEntryName = string.lower(tostring(
					entry.key or entry.name or ""
				))
				local knownRepairKey =
					"chrominou_zero_healing_1785937799"
				local currentPlayerGUID = type(UnitGUID) == "function"
					and UnitGUID("player")
				local isKnownChrominouSample = roleKey == "HEALER"
					and normalizedEntryName == "chrominou"
					and currentPlayerGUID
					and entry.guid == currentPlayerGUID
				if isKnownChrominouSample
					and not playerRankings.repairs[knownRepairKey]
				then
					local repairWeight = 0.5586903975959343
					local repairScore = 30
					local backup = {
						scoreSum = entry.scoreSum,
						scoreWeight = entry.scoreWeight,
						appearances = entry.appearances,
						comparableBGs = entry.comparableBGs,
						participationTotal = entry.participationTotal,
					}
					local clearLast = (tonumber(entry.lastHealing) or 0) <= 0
						and tonumber(entry.lastScore) == repairScore
					local applied = RemoveInvalidPlayerSample(
						entry,
						repairScore,
						repairWeight,
						1,
						clearLast
					)
					playerRankings.repairs[knownRepairKey] = {
						applied = applied and true or false,
						appliedAt = time(),
						backup = backup,
						removedScore = repairScore,
						removedWeight = repairWeight,
					}
				end

				if previousPlayerVersion < 3 and not isKnownChrominouSample then
					local damage = tonumber(entry.lastDamage) or 0
					local healing = tonumber(entry.lastHealing) or 0
					local objectives = tonumber(entry.lastObjectives) or 0
					local utility = tonumber(entry.lastUtility) or 0
					local inactive = (roleKey == "HEALER" and healing <= 0)
						or ((roleKey == "MELEE_DAMAGER"
							or roleKey == "RANGED_DAMAGER"
							or roleKey == "DAMAGER") and damage <= 0)
						or ((roleKey == "TANK" or roleKey == "SUPPORT")
							and damage <= 0 and healing <= 0
							and objectives <= 0 and utility <= 0)
					if inactive and tonumber(entry.lastScore)
						and tonumber(entry.lastMatchWeight)
					then
						RemoveInvalidPlayerSample(
							entry,
							entry.lastScore,
							entry.lastMatchWeight,
							entry.lastParticipationRatio or 1,
							true
						)
					end
				end

				-- A character can only be credited once per battleground. An older
				-- version could keep one appearance more than the global counter.
				-- Fixing those counters without changing their mean removes the
				-- duplicate while preserving the history.
				if playerRankings.totalBattlegrounds > 0 then
					entry.appearances = math.min(
						entry.appearances,
						playerRankings.totalBattlegrounds
					)
				end
				if entry.scoreWeight > entry.appearances and entry.scoreWeight > 0 then
					entry.scoreSum = entry.scoreSum
						* entry.appearances / entry.scoreWeight
					entry.scoreWeight = entry.appearances
				end
				entry.comparableBGs = math.min(entry.comparableBGs, entry.appearances)
				entry.nearTopBGs = math.min(entry.nearTopBGs, entry.comparableBGs)
				entry.top1Finishes = math.min(entry.top1Finishes, entry.comparableBGs)
				entry.specializations = type(entry.specializations) == "table"
					and entry.specializations or {}
				for _, specialization in pairs(entry.specializations) do
					if type(specialization) == "table" then
						specialization.appearances = math.min(
							tonumber(specialization.appearances) or 0,
							entry.appearances
						)
					end
				end
				entry.mainSpecializationAppearances = math.min(
					tonumber(entry.mainSpecializationAppearances) or 0,
					entry.appearances
				)
			end
		end
	end
	playerRankings.version = PLAYER_RANKING_DATABASE_VERSION

	-- Set the version last so a partially interrupted migration is retried.
	rankings.version = RANKING_DATABASE_VERSION
end

local function CopySavedValue(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, child in pairs(value) do
		copy[CopySavedValue(key, seen)] = CopySavedValue(child, seen)
	end
	return copy
end

local function ImportLegacyDatabase()
	if type(CoAAnalyticsDB) == "table" then
		return
	end

	-- The previous addon folder owns the historical SavedVariables file.
	-- Load its tiny migration bridge once, then clone every setting and BG
	-- ranking into the new CoA Analytics database.
	if type(CoABGIntelligenceDB) ~= "table"
		and type(LoadAddOn) == "function"
	then
		pcall(LoadAddOn, "CoABGIntelligence")
	end
	if type(CoABGIntelligenceDB) == "table" then
		CoAAnalyticsDB = CopySavedValue(CoABGIntelligenceDB)
		CoAAnalyticsDB.migratedFromCoABGIntelligence = true
		CoAAnalyticsDB.migratedAtVersion = ADDON_VERSION
	end
end

local function InitializeDatabase()
	ImportLegacyDatabase()
	if type(CoAAnalyticsDB) ~= "table" then
		CoAAnalyticsDB = {}
	end
	addonDB = CoAAnalyticsDB
	InitializeRankingDatabase()

	addonDB.roleIconPosition =
		LEGACY_ICON_POSITIONS[addonDB.roleIconPosition]
		or addonDB.roleIconPosition

	-- Migrate settings saved by versions that displayed a class icon.
	if addonDB.specIconPosition == nil then
		addonDB.specIconPosition = addonDB.classIconPosition
	end
	addonDB.specIconPosition =
		LEGACY_ICON_POSITIONS[addonDB.specIconPosition]
		or addonDB.specIconPosition
	if addonDB.showSpecIcon == nil then
		if addonDB.showClassIcon == nil then
			addonDB.showSpecIcon = true
		else
			addonDB.showSpecIcon = addonDB.showClassIcon
		end
	end
	if not VALID_ICON_POSITIONS[addonDB.roleIconPosition] then
		addonDB.roleIconPosition = "ABOVE_CENTER"
	end
	if not VALID_ICON_POSITIONS[addonDB.specIconPosition] then
		addonDB.specIconPosition = "ABOVE_RIGHT"
	end
	if type(addonDB.minimapButtonAngle) ~= "number" then
		addonDB.minimapButtonAngle = 225
	end
	if addonDB.showDungeonPerformanceOverlay == nil then
		addonDB.showDungeonPerformanceOverlay = true
	end
	if type(addonDB.dungeonOverlayPosition) ~= "table" then
		addonDB.dungeonOverlayPosition = nil
	end

	-- Recover the user's setting after a reload or logout that happened in a BG.
	if addonDB.nameplateOverrideActive and not IsBattleground() then
		RestoreEnemyNameplateSetting()
	end
end

function AllyJournal:GetData()
	return self.data or (addonDB and addonDB.allyDebugLog)
end

function AllyJournal:Add(eventName, unit, guid, detail)
	local journal = self:GetData()
	if not journal then
		return
	end

	local elapsed = GetTime() - (tonumber(journal.startedAt) or GetTime())
	local name = unit and UnitExists(unit) and UnitName(unit)
	local state = guid and journal.allies and journal.allies[guid]
	name = name or (state and state.name) or "-"
	local line = string.format(
		"[%06.1f] %-18s name=%s unit=%s guid=%s%s",
		math.max(0, elapsed),
		tostring(eventName or "EVENT"),
		tostring(name),
		tostring(unit or "-"),
		tostring(guid or "-"),
		detail and (" " .. tostring(detail)) or ""
	)

	journal.lines[#journal.lines + 1] = line
	while #journal.lines > ALLY_JOURNAL_MAX_LINES do
		table.remove(journal.lines, 1)
		journal.droppedLines = (tonumber(journal.droppedLines) or 0) + 1
	end
end

function AllyJournal:Start(forceNew)
	if not addonDB then
		return
	end

	local zone = (type(GetRealZoneText) == "function" and GetRealZoneText())
		or (type(GetZoneText) == "function" and GetZoneText())
		or "Battleground"
	local serverNow = type(time) == "function" and time() or 0
	local existing = addonDB.allyDebugLog
	local canContinue = not forceNew
		and type(existing) == "table"
		and existing.addonVersion == ADDON_VERSION
		and existing.active
		and existing.zone == zone
		and type(existing.lines) == "table"
		and type(existing.allies) == "table"
		and (
			serverNow == 0
			or tonumber(existing.serverStartedAt) == nil
			or serverNow - tonumber(existing.serverStartedAt) < ALLY_JOURNAL_MAX_AGE
		)

	if not canContinue then
		existing = {
			version = 1,
			addonVersion = ADDON_VERSION,
			active = true,
			completed = false,
			zone = zone,
			startedAt = GetTime(),
			serverStartedAt = serverNow,
			lines = {},
			allies = {},
		}
		addonDB.allyDebugLog = existing
	end

	self.data = existing
	existing.active = true
	local build, _, buildDate, interfaceVersion = GetBuildInfo()
	self:Add(
		canContinue and "SESSION_CONTINUE" or "SESSION_START",
		nil,
		nil,
		"addon=" .. ADDON_VERSION
			.. " client=" .. tostring(build)
			.. " buildDate=" .. tostring(buildDate)
			.. " interface=" .. tostring(interfaceVersion)
			.. " zone=" .. tostring(zone)
	)
end

function AllyJournal:GetAlly(unit, guid)
	local journal = self:GetData()
	if not journal or not guid then
		return
	end
	journal.allies = journal.allies or {}
	local state = journal.allies[guid]
	if not state then
		state = {
			guid = guid,
			tokens = {},
			attempts = 0,
		}
		journal.allies[guid] = state
	end
	if unit and UnitExists(unit) then
		state.name = UnitName(unit) or state.name
		state.tokens[unit] = true
	end
	return state
end

function AllyJournal:IsTracked(guid)
	local journal = self:GetData()
	return journal and journal.allies and journal.allies[guid] ~= nil
end

function AllyJournal:Observe(unit, guid, classToken, canInspect, inRange, direct)
	local state = self:GetAlly(unit, guid)
	if not state then
		return
	end
	state.classToken = classToken or state.classToken
	state.lastCanInspect = canInspect and true or false
	state.lastInRange = inRange == true and true or false
	state.lastDirect = direct and true or false

	local signature = tostring(unit)
		.. ":" .. tostring(classToken)
		.. ":" .. tostring(canInspect)
		.. ":" .. tostring(inRange)
		.. ":" .. tostring(direct)
	if state.lastObservation ~= signature then
		state.lastObservation = signature
		self:Add(
			"ALLY_OBSERVED",
			unit,
			guid,
			"class=" .. tostring(classToken)
				.. " canInspect=" .. tostring(canInspect)
				.. " inRange=" .. tostring(inRange)
				.. " direct=" .. tostring(direct)
		)
	end
end

function AllyJournal:Status(eventName, unit, guid, detail)
	local state = self:GetAlly(unit, guid)
	if not state then
		return
	end
	local signature = tostring(eventName) .. ":" .. tostring(detail)
	if state.lastStatusSignature == signature then
		return
	end
	state.lastStatusSignature = signature
	state.lastStatus = eventName
	state.lastDetail = detail
	self:Add(eventName, unit, guid, detail)
end

function AllyJournal:Attempt(unit, guid, attempt, detail)
	local state = self:GetAlly(unit, guid)
	if not state then
		return
	end
	state.attempts = math.max(tonumber(state.attempts) or 0, tonumber(attempt) or 0)
	state.lastAttemptUnit = unit
	self:Add("INSPECT_START", unit, guid, "attempt=" .. tostring(attempt) .. " " .. tostring(detail or ""))
end

function AllyJournal:Resolved(unit, guid, roleData)
	local state = self:GetAlly(unit, guid)
	if not state then
		return
	end
	state.resolved = true
	state.specialization = roleData and roleData.specialization
	state.specializationClassToken = roleData and roleData.specializationClassToken
	state.role = roleData and roleData.role
	state.lastStatus = "RESOLVED"
	self:Add(
		"RESOLVED",
		unit,
		guid,
		"spec=" .. tostring(state.specialization)
			.. " specClass=" .. tostring(state.specializationClassToken)
			.. " role=" .. tostring(state.role)
	)
end

function AllyJournal:Complete(reason)
	local journal = self:GetData()
	if not journal or journal.completed then
		return
	end
	journal.completed = true
	local total = 0
	local resolved = 0
	for _, state in pairs(journal.allies or {}) do
		total = total + 1
		if state.resolved then
			resolved = resolved + 1
		end
	end
	self:Add(
		"END_SUMMARY",
		nil,
		nil,
		"reason=" .. tostring(reason or "unknown")
			.. " allies=" .. tostring(total)
			.. " resolved=" .. tostring(resolved)
			.. " unknown=" .. tostring(total - resolved)
	)
	for guid, state in pairs(journal.allies or {}) do
		if not state.resolved then
			self:Add(
				"END_UNKNOWN",
				nil,
				guid,
				"name=" .. tostring(state.name)
					.. " class=" .. tostring(state.classToken)
					.. " attempts=" .. tostring(state.attempts)
					.. " lastStatus=" .. tostring(state.lastStatus)
					.. " lastDetail=" .. tostring(state.lastDetail)
					.. " lastToken=" .. tostring(state.lastAttemptUnit)
			)
		end
	end
end

function AllyJournal:Stop(reason)
	local journal = self:GetData()
	if not journal then
		return
	end
	self:Add("SESSION_STOP", nil, nil, tostring(reason or "left battleground"))
	journal.active = false
end

function AllyJournal:BuildExport()
	local journal = self:GetData()
	if not journal then
		return "No ally detection log available."
	end
	local header = {
		"CoA Analytics - ally detection log",
		"Addon version: " .. tostring(journal.addonVersion or "?"),
		"Zone: " .. tostring(journal.zone or "?"),
		"Log finished: " .. tostring(journal.completed and true or false),
		"Dropped lines (cap): " .. tostring(journal.droppedLines or 0),
		"------------------------------------------------------------",
	}
	for _, line in ipairs(journal.lines or {}) do
		header[#header + 1] = line
	end
	local currentTotal = 0
	local currentResolved = 0
	local currentUnknown = {}
	for guid, state in pairs(journal.allies or {}) do
		currentTotal = currentTotal + 1
		if state.resolved then
			currentResolved = currentResolved + 1
		else
			currentUnknown[#currentUnknown + 1] =
				tostring(state.name or "?")
					.. " | class=" .. tostring(state.classToken)
					.. " | attempts=" .. tostring(state.attempts)
					.. " | last=" .. tostring(state.lastStatus)
					.. " | detail=" .. tostring(state.lastDetail)
					.. " | guid=" .. tostring(guid)
		end
	end
	table.sort(currentUnknown)
	header[#header + 1] = "------------------------------------------------------------"
	header[#header + 1] = "STATE AT COPY TIME: allies=" .. tostring(currentTotal)
		.. " resolved=" .. tostring(currentResolved)
		.. " unknown=" .. tostring(currentTotal - currentResolved)
	for _, unknownLine in ipairs(currentUnknown) do
		header[#header + 1] = "UNKNOWN | " .. unknownLine
	end
	return table.concat(header, "\n")
end

function AllyJournal:Show()
	if not self.frame then
		local frame = CreateFrame("Frame", "CoAAnalyticsAllyLogFrame", UIParent)
		frame:SetWidth(780)
		frame:SetHeight(540)
		frame:SetPoint("CENTER")
		frame:SetFrameStrata("DIALOG")
		frame:SetClampedToScreen(true)
		frame:SetMovable(true)
		frame:EnableMouse(true)
		frame:RegisterForDrag("LeftButton")
		frame:SetScript("OnDragStart", frame.StartMoving)
		frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 32,
			edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})

		local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("TOP", 0, -18)
		title:SetText("Ally Detection Log")

		local help = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		help:SetPoint("TOPLEFT", 24, -43)
		help:SetText("Click Select All, press Ctrl+C, then send the text after the battleground.")

		local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -5, -5)

		local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 25, -68)
		scroll:SetPoint("BOTTOMRIGHT", -49, 57)

		local editBox = CreateFrame("EditBox", nil, scroll)
		editBox:SetMultiLine(true)
		editBox:SetAutoFocus(false)
		editBox:SetFontObject(ChatFontNormal)
		editBox:SetWidth(690)
		editBox:SetScript("OnEscapePressed", function(selfEdit)
			selfEdit:ClearFocus()
		end)
		scroll:SetScrollChild(editBox)

		local selectButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		selectButton:SetWidth(150)
		selectButton:SetHeight(24)
		selectButton:SetPoint("BOTTOMLEFT", 24, 22)
		selectButton:SetText("Select All")
		selectButton:SetScript("OnClick", function()
			editBox:SetFocus()
			editBox:HighlightText()
		end)

		local closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		closeButton:SetWidth(100)
		closeButton:SetHeight(24)
		closeButton:SetPoint("BOTTOMRIGHT", -24, 22)
		closeButton:SetText("Close")
		closeButton:SetScript("OnClick", function()
			frame:Hide()
		end)

		self.frame = frame
		self.editBox = editBox
	end

	local export = self:BuildExport()
	local _, lineCount = string.gsub(export, "\n", "\n")
	self.editBox:SetHeight(math.max(410, (lineCount + 2) * 14))
	self.editBox:SetText(export)
	self.editBox:SetCursorPosition(0)
	self.frame:Show()
end

function AllyJournal:Clear()
	if addonDB then
		addonDB.allyDebugLog = nil
	end
	self.data = nil
	if state.isActive then
		self:Start(true)
	end
	Chat("journal de detection allie efface")
end

-- BG ranking calculation is loaded from BGRanking.lua.

-- Nameplate detection and rendering are loaded from Nameplates.lua.

-- The interface is loaded from UI.lua so its growth stays isolated from the core.

local function ResetState(clearCache)
	state.friendlyScanGeneration = state.friendlyScanGeneration + 1
	for _, record in pairs(state.visibleUnits) do
		if record.icon then
			record.icon.ownerUnit = nil
			record.icon.ownerGUID = nil
			record.icon.role = nil
			record.icon.specialization = nil
			record.icon.specializationTexture = nil
			record.icon.specializationTexCoords = nil
			record.icon.specTexture:Hide()
			record.icon:Hide()
		end
	end
	wipe(state.visibleUnits)

	wipe(state.inspectQueue)
	wipe(state.queuedGUIDs)
	wipe(state.inspectAttemptsByGUID)
	wipe(state.friendlyRetryAtByGUID)
	wipe(state.pendingAnchorRefreshes)
	state.pendingInspect = nil
	state.nextInspectAt = 0
	state.nextNameplateCVarCheckAt = nil
	state.updateElapsed = 0
	state.worker:Hide()

	if clearCache then
		wipe(state.roleCache)
		wipe(state.playerDataByGUID)
		wipe(state.playerDataByName)
		wipe(state.ambiguousPlayerBaseNames)
		wipe(state.battlefieldClassByName)
		wipe(state.battlefieldTeamByName)
		wipe(state.friendlyGUIDs)
		state.playerBattlefieldTeam = nil
	end
end

local function RefreshZone(forceReset)
	local activeNow = IsBattleground()
	local pveNow = IsPvEInstance()
	if activeNow ~= state.isActive or forceReset then
		local wasActive = state.isActive
		state.isActive = activeNow
		ResetState(true)

		if wasActive and not state.isActive then
			AllyJournal:Complete("left battleground")
			AllyJournal:Stop("left battleground")
			RestoreEnemyNameplateSetting()
		elseif state.isActive then
			if not wasActive then
				AllyJournal:Start(false)
			else
				AllyJournal:Add("WORLD_REFRESH", nil, nil, "state reset while still in battleground")
			end
			CoAAnalyticsAddon.Modules.Nameplates.EnsureEnemyNameplateTracking()
		end

		Debug(state.isActive and "enabled in battleground" or "disabled outside battleground")
		if state.isActive then
			if type(RequestBattlefieldScoreData) == "function" then
				pcall(RequestBattlefieldScoreData)
			end
			CoAAnalyticsAddon.Modules.Nameplates.ScanNameplates()
			CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyRoster()
			CoAAnalyticsAddon.Modules.Nameplates.ScanEnemyReferences()
			CoAAnalyticsAddon.Modules.Nameplates.ScheduleFriendlyRosterPolling()
		elseif pveNow then
			CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyRoster()
			CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyReferences()
			CoAAnalyticsAddon.Modules.Nameplates.ScheduleFriendlyRosterPolling()
		end
	end
end

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_LOGOUT")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("CVAR_UPDATE")
driver:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("UNIT_TARGET")
driver:RegisterEvent("PLAYER_TARGET_CHANGED")
driver:RegisterEvent("PLAYER_FOCUS_CHANGED")
driver:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
driver:RegisterEvent("NAME_PLATE_UNIT_ADDED")
driver:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
driver:RegisterEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT")

driver:SetScript("OnEvent", function(_, event, value)
	if event == "PLAYER_LOGOUT" then
		if state.isActive then
			AllyJournal:Add("PLAYER_LOGOUT", nil, nil, "journal kept active for reload/reconnect")
		end
		state.isActive = false
		ResetState(false)
		driver:UnregisterEvent("INSPECT_CHARACTER_ADVANCEMENT_RESULT")
	elseif event == "PLAYER_LOGIN" then
		InitializeDatabase()
		if CoAAnalyticsAddon.Modules.Nameplates and CoAAnalyticsAddon.Modules.Nameplates.Initialize then
			CoAAnalyticsAddon.Modules.Nameplates.Initialize()
		end
		if CoAAnalyticsAddon.Modules.UI and CoAAnalyticsAddon.Modules.UI.Initialize then
			CoAAnalyticsAddon.Modules.UI.Initialize()
		end
		if CoAAnalyticsAddon.Modules.DungeonOverlay
			and CoAAnalyticsAddon.Modules.DungeonOverlay.Initialize
		then
			CoAAnalyticsAddon.Modules.DungeonOverlay.Initialize()
		end
		if CoAAnalyticsAddon.Modules.Minimap
			and CoAAnalyticsAddon.Modules.Minimap.Initialize
		then
			CoAAnalyticsAddon.Modules.Minimap.Initialize()
		end
		if CoAAnalyticsAddon.Modules.BGTimer
			and CoAAnalyticsAddon.Modules.BGTimer.Initialize
		then
			CoAAnalyticsAddon.Modules.BGTimer.Initialize()
		end
		RefreshZone(false)
	elseif event == "INSPECT_CHARACTER_ADVANCEMENT_RESULT" then
		CoAAnalyticsAddon.Modules.Nameplates.FinishInspect(value)
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		if state.isActive then
			CoAAnalyticsAddon.Modules.Nameplates.AttachUnit(value)
			CoAAnalyticsAddon.Modules.Nameplates.ScheduleAnchorRefresh(value)
		end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		state.pendingAnchorRefreshes[value] = nil
		CoAAnalyticsAddon.Modules.Nameplates.ReleaseUnit(value)
	elseif event == "PLAYER_ENTERING_WORLD" then
		RefreshZone(true)
	elseif event == "PLAYER_REGEN_DISABLED"
		or event == "PLAYER_REGEN_ENABLED"
	then
		if state.isActive then
			CoAAnalyticsAddon.Modules.Nameplates.ScheduleEnemyNameplateCheck()
		end
		if event == "PLAYER_REGEN_ENABLED" then
			CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyRoster()
			CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyReferences()
		end
	elseif event == "UPDATE_BATTLEFIELD_SCORE"
		or event == "RAID_ROSTER_UPDATE"
		or event == "PARTY_MEMBERS_CHANGED"
	then
		CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyRoster()
		CoAAnalyticsAddon.Modules.Nameplates.ScanEnemyReferences()
	elseif event == "UNIT_TARGET" then
		if IsGroupTrackingActive() and value then
			if state.isActive then
				CoAAnalyticsAddon.Modules.Nameplates.ObserveEnemyReference(value .. "target")
			end
			CoAAnalyticsAddon.Modules.Nameplates.ObserveFriendlyUnit(value .. "target", 0.05, false)
		end
	elseif event == "PLAYER_TARGET_CHANGED"
		or event == "PLAYER_FOCUS_CHANGED"
		or event == "UPDATE_MOUSEOVER_UNIT"
	then
		if state.isActive then
			CoAAnalyticsAddon.Modules.Nameplates.ScanEnemyReferences()
		end
		CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyReferences()
	elseif event == "CVAR_UPDATE" then
		if string.lower(tostring(value or "")) == string.lower(NAMEPLATE_CVAR) then
			CoAAnalyticsAddon.Modules.Nameplates.ScheduleEnemyNameplateCheck()
		end
	else
		RefreshZone(false)
	end
end)

state.worker:SetScript("OnUpdate", function(self, elapsed)
	if not IsGroupTrackingActive() then
		self:Hide()
		return
	end

	state.updateElapsed = state.updateElapsed + elapsed
	if state.updateElapsed < INSPECT_UPDATE_INTERVAL then
		return
	end
	state.updateElapsed = 0

	local now = GetTime()
	if state.nextNameplateCVarCheckAt and now >= state.nextNameplateCVarCheckAt then
		state.nextNameplateCVarCheckAt = nil
		CoAAnalyticsAddon.Modules.Nameplates.EnsureEnemyNameplateTracking()
	end

	CoAAnalyticsAddon.Modules.Nameplates.ProcessAnchorRefreshes(now)
	CoAAnalyticsAddon.Modules.Nameplates.ProcessPendingFriendlyResolution(now)

	if state.pendingInspect
		and now - state.pendingInspect.startedAt >= INSPECT_TIMEOUT
	then
		local timedOut = state.pendingInspect
		state.pendingInspect = nil
		state.nextInspectAt = now + INSPECT_GAP
		Debug(timedOut.mode .. " inspect timed out", timedOut.unit)
		if timedOut.mode == "friendly_coa" then
			AllyJournal:Status(
				"INSPECT_TIMEOUT",
				timedOut.unit,
				timedOut.guid,
				"attempt=" .. tostring(timedOut.attempt)
			)
		end
		CoAAnalyticsAddon.Modules.Nameplates.RetryFailedInspect(timedOut)
	end

	CoAAnalyticsAddon.Modules.Nameplates.StartNextInspect(now)

	if not state.pendingInspect
		and #state.inspectQueue == 0
		and not state.nextNameplateCVarCheckAt
		and not next(state.pendingAnchorRefreshes)
	then
		self:Hide()
	end
end)
state.worker:Hide()

CoAAnalyticsAPI = CoAAnalyticsAPI or {}
CoAAnalyticsAPI.VERSION = ADDON_VERSION
CoAAnalyticsAPI.Config = {
	ICON_SIZE = ICON_SIZE,
	ICON_OFFSET_Y = ICON_OFFSET_Y,
	ICON_GAP = ICON_GAP,
	MAX_NAMEPLATE_UNITS = MAX_NAMEPLATE_UNITS,
	NAMEPLATE_CVAR = NAMEPLATE_CVAR,
	NAMEPLATE_CVAR_RECHECK_DELAY = NAMEPLATE_CVAR_RECHECK_DELAY,
	ANCHOR_REFRESH_DELAY = ANCHOR_REFRESH_DELAY,
	INSPECT_GAP = INSPECT_GAP,
	RETRY_DELAY = RETRY_DELAY,
	MAX_FRIENDLY_INSPECT_ATTEMPTS = MAX_FRIENDLY_INSPECT_ATTEMPTS,
	FRIENDLY_SCAN_INTERVAL = FRIENDLY_SCAN_INTERVAL,
	FRIENDLY_RESULT_READ_DELAYS = FRIENDLY_RESULT_READ_DELAYS,
	FRIENDLY_RETRY_COOLDOWN = FRIENDLY_RETRY_COOLDOWN,
	ROLE_ATLAS_FALLBACKS = ROLE_ATLAS_FALLBACKS,
	ROLE_ATLAS_KEYS = ROLE_ATLAS_KEYS,
	ROLE_ATLAS_CANDIDATES = ROLE_ATLAS_CANDIDATES,
	ROLE_FALLBACK_TEXTURES = ROLE_FALLBACK_TEXTURES,
	ABOVE_POSITION_OFFSETS = ABOVE_POSITION_OFFSETS,
	SPEC_ICON_ATLAS_TEXTURE = SPEC_ICON_ATLAS_TEXTURE,
	UNKNOWN_SPEC_TEXTURE = UNKNOWN_SPEC_TEXTURE,
	MINIMAP_BUTTON_RADIUS = MINIMAP_BUTTON_RADIUS,
	RANKING_VISIBLE_ROWS = RANKING_VISIBLE_ROWS,
	RANKING_ROW_HEIGHT = RANKING_ROW_HEIGHT,
	RANKING_TABLE_LEFT_INSET = RANKING_TABLE_LEFT_INSET,
	RANKING_TABLE_RIGHT_INSET = RANKING_TABLE_RIGHT_INSET,
	RANKING_SCORE_RIGHT_INSET = RANKING_SCORE_RIGHT_INSET,
	RANKING_PERCENT_RIGHT_INSET = RANKING_PERCENT_RIGHT_INSET,
	RANKING_POINT_EPSILON = RANKING_POINT_EPSILON,
	SPECIALIZATION_RANKING_PRIOR_BG = SPECIALIZATION_RANKING_PRIOR_BG,
	RANKING_PROXIMITY_FLOOR = RANKING_PROXIMITY_FLOOR,
	RANKING_NEAR_TOP_RATIO = RANKING_NEAR_TOP_RATIO,
	STOMP_DEATH_WEIGHT = STOMP_DEATH_WEIGHT,
	STOMP_DAMAGE_WEIGHT = STOMP_DAMAGE_WEIGHT,
	STOMP_MATCH_WEIGHT_SCALE = STOMP_MATCH_WEIGHT_SCALE,
	STOMP_MINIMUM_MATCH_WEIGHT = STOMP_MINIMUM_MATCH_WEIGHT,
	PLAYER_RANKING_PRIOR_MATCHES = PLAYER_RANKING_PRIOR_MATCHES,
	PLAYER_RANKING_NEAR_TOP_RATIO = PLAYER_RANKING_NEAR_TOP_RATIO,
	PLAYER_RANKING_UNCERTAINTY_MARGIN = PLAYER_RANKING_UNCERTAINTY_MARGIN,
	PLAYER_RANKING_PLACEMENT_MATCHES = PLAYER_RANKING_PLACEMENT_MATCHES,
	PLAYER_RANKING_LEVEL_POWER_EXPONENT = PLAYER_RANKING_LEVEL_POWER_EXPONENT,
	PLAYER_RANKING_LEVEL_FACTOR_MIN = PLAYER_RANKING_LEVEL_FACTOR_MIN,
	PLAYER_RANKING_LEVEL_FACTOR_MAX = PLAYER_RANKING_LEVEL_FACTOR_MAX,
	PLAYER_RANKING_MIN_PARTICIPATION = PLAYER_RANKING_MIN_PARTICIPATION,
	PLAYER_RANKING_ROLE_KEYS = PLAYER_RANKING_ROLE_KEYS,
	PLAYER_SEARCH_MAX_SUGGESTIONS = PLAYER_SEARCH_MAX_SUGGESTIONS,
	ICON_POSITION_OPTIONS = ICON_POSITION_OPTIONS,
	ROLE_FALLBACK_TEXTURES = ROLE_FALLBACK_TEXTURES,
}
CoAAnalyticsAPI.GetPlayerData = GetCachedPlayerData
CoAAnalyticsAPI.RuntimeState = state
CoAAnalyticsAPI.AllyJournal = AllyJournal
CoAAnalyticsAPI.GetPlayerDataByGUID = function(guid)
	return guid and state.playerDataByGUID[guid]
end
CoAAnalyticsAPI.GetDatabase = function()
	return addonDB
end
CoAAnalyticsAPI.Debug = Debug
CoAAnalyticsAPI.IsCVarEnabled = IsCVarEnabled
CoAAnalyticsAPI.IsInspectRequestAccepted = IsInspectRequestAccepted
CoAAnalyticsAPI.IsGroupTrackingActive = IsGroupTrackingActive
CoAAnalyticsAPI.GetBattlefieldClassToken = GetBattlefieldClassToken
CoAAnalyticsAPI.GetBattlefieldTeam = GetBattlefieldTeam
CoAAnalyticsAPI.ClassTokensMatch = ClassTokensMatch
CoAAnalyticsAPI.RefreshBattlefieldRosterMetadata = RefreshBattlefieldRosterMetadata
CoAAnalyticsAPI.CacheUnitIdentity = CacheUnitIdentity
CoAAnalyticsAPI.CacheUnitRole = CacheUnitRole
CoAAnalyticsAPI.CompleteAllyJournal = function(reason)
	AllyJournal:Complete(reason)
end
CoAAnalyticsAPI.IsBattleground = IsBattleground
CoAAnalyticsAPI.IsPvEInstance = IsPvEInstance
CoAAnalyticsAPI.NormalizePlayerName = NormalizePlayerName
CoAAnalyticsAPI.InitializeRankingDatabase = InitializeRankingDatabase
CoAAnalyticsAddon.Modules.Core = CoAAnalyticsAPI

SLASH_COAANALYTICS1 = "/coaa"
SLASH_COAANALYTICS2 = "/coabgi"
SlashCmdList.COAANALYTICS = function(message)
	message = string.lower(message or "")
	message = message:gsub("^%s+", ""):gsub("%s+$", "")

	if message == "debug" then
		debugEnabled = not debugEnabled
		Chat("debug " .. (debugEnabled and "enabled" or "disabled"))
	elseif message == "settings" or message == "config" then
		if CoAAnalyticsAddon.Modules.UI then CoAAnalyticsAddon.Modules.UI.Open("settings") end
	elseif message == "ranking" or message == "rankings" or message == "classement" then
		if CoAAnalyticsAddon.Modules.UI then CoAAnalyticsAddon.Modules.UI.Open("ranking", "specializations") end
	elseif message == "joueurs" or message == "players"
		or message == "classement joueurs"
	then
		if CoAAnalyticsAddon.Modules.UI then CoAAnalyticsAddon.Modules.UI.Open("ranking", "players") end
	elseif message == "pve" or message == "classement pve" then
		if CoAAnalyticsAddon.Modules.UI then CoAAnalyticsAddon.Modules.UI.Open("pve") end
	elseif message == "performance" or message == "performance pve"
		or message == "pve performance"
	then
		if CoAAnalyticsAddon.Modules.UI then CoAAnalyticsAddon.Modules.UI.Open("pvesession") end
	elseif (message == "pve log" or message == "pve log status") and CoAAnalyticsPvE then
		CoAAnalyticsPvE.PrintDungeonDiagnosticStatus()
	elseif (message == "pve log on" or message == "pve log start") and CoAAnalyticsPvE then
		CoAAnalyticsPvE.SetDungeonDiagnosticEnabled(true)
	elseif (message == "pve log off" or message == "pve log stop") and CoAAnalyticsPvE then
		CoAAnalyticsPvE.SetDungeonDiagnosticEnabled(false)
	elseif message == "pve log clear" and CoAAnalyticsPvE then
		CoAAnalyticsPvE.ClearDungeonDiagnostic()
	elseif message == "pve pets" and CoAAnalyticsPvE then
		CoAAnalyticsPvE.PrintUnattributed()
	elseif message == "pve status" and CoAAnalyticsPvE then
		CoAAnalyticsPvE.PrintStatus()
	elseif message == "pve complete" and CoAAnalyticsPvE then
		CoAAnalyticsPvE.CompleteDungeon(true)
	elseif message == "log" or message == "journal" then
		AllyJournal:Show()
	elseif message == "log clear" or message == "journal clear" then
		AllyJournal:Clear()
	elseif message == "retry" then
		ResetState(true)
		RefreshZone(false)
		if state.isActive then
			CoAAnalyticsAddon.Modules.Nameplates.EnsureEnemyNameplateTracking()
			CoAAnalyticsAddon.Modules.Nameplates.ScanNameplates()
			CoAAnalyticsAddon.Modules.Nameplates.ScanFriendlyRoster()
		end
		Chat("detection data cleared and requeued")
	elseif message == "status" then
		local visibleCount = 0
		local cachedCount = 0
		for _ in pairs(state.visibleUnits) do
			visibleCount = visibleCount + 1
		end
		for _ in pairs(state.roleCache) do
			cachedCount = cachedCount + 1
		end
		Chat(
			(state.isActive and "active" or "inactive")
				.. ", enemy nameplates "
				.. (IsCVarEnabled(GetCVar(NAMEPLATE_CVAR)) and "on" or "off")
				.. ", visible " .. visibleCount
				.. ", identified " .. cachedCount
				.. ", queued " .. #state.inspectQueue
				.. (state.pendingInspect and ", inspecting 1" or "")
		)
	else
		Chat("/coaa settings | ranking | players | pve | performance | pve log on|off|status|clear | pve status | pve pets | log | status | debug | retry")
	end
end

Debug(ADDON_NAME, "loaded")

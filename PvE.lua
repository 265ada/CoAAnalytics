local ADDON_NAME = ...
local API = CoAAnalyticsAPI

CoAAnalyticsPvE = CoAAnalyticsPvE or {}
local PvE = CoAAnalyticsPvE
CoAAnalyticsAddon.Modules.PvE = PvE

local DATABASE_VERSION = 5
local PRIOR_SAMPLES = 10
local SAMPLE_INTERVAL = 0.33
local HEALTH_SAMPLE_INTERVAL = 0.50
local COMBAT_END_GRACE = 2
local DUNGEON_COMPLETION_DELAY = 1.5
local DUNGEON_COMPLETION_TIMEOUT = 6
local ROSTER_INTERVAL = 3
local MOB_FORGET_DELAY = 5
local LOSS_GRACE = 1
local MAX_NAMEPLATE_UNITS = 40
local SESSION_SNAPSHOT_INTERVAL = 1
local EPSILON = 0.000001
local HEALER_SCORE_VERSION = 5
local DIAGNOSTIC_MIN_COMBAT = 30
local DIAGNOSTIC_HISTORY_LIMIT = 10
local MIN_SCORING_OBSERVED = 5
local MIN_SCORING_PARTICIPATION = 0.05
local URGENT_RECOVERY_THRESHOLD = 0.65
-- A heal that lands on someone at or below this fraction of maximum health is
-- treated as a clutch heal: without it the target was on a credible path to
-- dying. The deeper the target had fallen and the larger the heal relative to
-- their health pool, the more credit the healer receives.
local CLUTCH_HEALTH_THRESHOLD = 0.35
local LIFESAVE_HEALTH_THRESHOLD = 0.20
local CLUTCH_MIN_HEAL_FRACTION = 0.04
local LIFESAVE_MIN_HEAL_FRACTION = 0.10
local CLUTCH_FULL_CREDIT_FRACTION = 0.25
local CLUTCH_DAMAGE_ROLE_MAX_BONUS = 4
local CLUTCH_SUPPORT_MAX_BONUS = 6
local CLUTCH_CREDIT_PER_MINUTE_SCALE = 2.50
-- A healer who also contributes damage is rewarded, but only once their actual
-- healing duties are demonstrably met. The gate is zero if anyone died a
-- preventable death, so damage can never be traded against healing.
local HEALER_DAMAGE_MAX_BONUS = 6
local HEALER_DAMAGE_GATE_FLOOR = 0.90
local HEALER_DAMAGE_GATE_SPAN = 0.20
-- Mitigation is measured from what the combat log actually proves: the
-- resisted, blocked and absorbed portions of every hit the tank took, plus the
-- swings they avoided outright. No spell list is required, so this works on a
-- custom client whose defensive abilities are unknown to the addon.
local TANK_PRESSURE_WINDOW = 2
local TANK_PRESSURE_HEALTH_FRACTION = 0.15
local TANK_PAR_MITIGATION_RATE = 0.25
local TANK_PAR_AVOIDANCE_RATE = 0.30
local TANK_PAR_SELF_SUSTAIN_RATE = 0.15
local TANK_SPIKE_RESPONSE_SCALE = 2.50
-- Pace. A dungeon is cleared in wall-clock time, not in combat time, so the
-- gaps between pulls matter as much as the pulls. Anything longer than this is
-- treated as real downtime rather than the normal seconds between packs.
local PACE_DOWNTIME_FLOOR = 5
-- A spell that lands on the same non-tank three or more times in one fight is
-- the clearest signal the client can give that the damage was avoidable and
-- the player did not move. Everything past the second hit is counted.
local REPEAT_HIT_FREE_HITS = 2
local REPEAT_HIT_MAX_TRACKED_SPELLS = 48
local DIAGNOSTIC_FILE_PATH = "WTF\\Account\\<account>\\SavedVariables\\CoAAnalytics.lua"
-- Level is only one indicator of power: gear and build still matter. This
-- deliberately cautious curve corrects the most obvious gap without erasing
-- the player's real performance.
local LEVEL_POWER_EXPONENT = 1.50
local LEVEL_FACTOR_MIN = 0.65
local LEVEL_FACTOR_MAX = 1.55

local driver = CreateFrame("Frame")
local session
local updateElapsed = 0
local healthElapsed = 0
local rosterElapsed = 0
local snapshotElapsed = 0
local combatIdleElapsed = 0
local BuildCurrentDungeonSnapshot
local IsValidRosterUnit
local RecordRepeatedHit

local CATEGORY_KEYS = { "dps", "healing", "tank", "support" }
local SCOPE_KEYS = { "all", "dungeon", "raid" }

local function Chat(message)
	local chatFrame = DEFAULT_CHAT_FRAME or ChatFrame1
	if chatFrame then
		chatFrame:AddMessage("|cff4f9df5CoA Analytics PvE:|r " .. tostring(message))
	end
end

local function NotifyDiagnosticStatus()
	if CoAAnalyticsAddon and CoAAnalyticsAddon.Events then
		CoAAnalyticsAddon.Events:Fire("PVE_DIAGNOSTIC_STATUS_UPDATED")
	end
end

local function Clamp(value, minimum, maximum)
	value = tonumber(value) or 0
	if value < minimum then
		return minimum
	elseif value > maximum then
		return maximum
	end
	return value
end

local function SafeNumber(value)
	value = tonumber(value)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return value
end

local function CopyCoordinates(coordinates)
	if type(coordinates) ~= "table" then
		return
	end
	return { coordinates[1], coordinates[2], coordinates[3], coordinates[4] }
end

local function GetValidPlayerName(name)
	if type(name) ~= "string" then
		return
	end
	name = string.gsub(name, "^%s*(.-)%s*$", "%1")
	if name == "" then
		return
	end
	local lowered = string.lower(name)
	if lowered == "unknown"
		or lowered == "joueur inconnu"
		or lowered == "unite inconnue"
		or lowered == "unit inconnue"
		or lowered == "unknown player"
		or lowered == "unknown unit"
	then
		return
	end
	if _G and (name == _G.UNKNOWNOBJECT or name == _G.UNKNOWN) then
		return
	end
	return name
end

local function GetUnitPlayerName(unit)
	local name, realm = UnitName(unit)
	name = GetValidPlayerName(name)
	if not name then
		return
	end
	realm = GetValidPlayerName(realm)
	return realm and (name .. "-" .. realm) or name
end

local function SetRosterMemberName(member, candidate)
	if not member then
		return false
	end
	candidate = GetValidPlayerName(candidate)
	if not candidate or candidate == member.name then
		return false
	end
	member.name = candidate
	local guid = member.guid
	if session and session.run and session.run.players[guid] then
		session.run.players[guid].name = candidate
	end
	if session and session.encounter and session.encounter.players[guid] then
		session.encounter.players[guid].name = candidate
	end
	return true
end

local function IsPvEInstance()
	local inInstance, instanceType = IsInInstance()
	return inInstance and (instanceType == "party" or instanceType == "raid")
end

local function GetInstanceContext()
	local inInstance, instanceType = IsInInstance()
	if not inInstance or (instanceType ~= "party" and instanceType ~= "raid") then
		return
	end
	local name, returnedType, difficultyID, difficultyName, maxPlayers = GetInstanceInfo()
	instanceType = returnedType or instanceType
	return {
		instanceName = name or GetRealZoneText() or "Unknown instance",
		instanceType = instanceType,
		scope = instanceType == "raid" and "raid" or "dungeon",
		difficultyID = difficultyID or 0,
		difficultyName = difficultyName or tostring(difficultyID or 0),
		maxPlayers = maxPlayers or (instanceType == "raid" and 40 or 5),
	}
end

local function EnsureCategory(root, scope, category)
	root.scopes = type(root.scopes) == "table" and root.scopes or {}
	root.scopes[scope] = type(root.scopes[scope]) == "table" and root.scopes[scope] or {}
	local value = root.scopes[scope][category]
	if type(value) ~= "table" then
		value = {}
		root.scopes[scope][category] = value
	end
	value.samples = SafeNumber(value.samples)
	value.incomplete = SafeNumber(value.incomplete)
	value.entries = type(value.entries) == "table" and value.entries or {}
	value.contexts = type(value.contexts) == "table" and value.contexts or {}
	return value
end

local function InitializeDatabase()
	local addonDB = API and API.GetDatabase and API.GetDatabase()
	if not addonDB then
		return
	end
	if type(addonDB.pveRankings) ~= "table" then
		addonDB.pveRankings = {}
	end
	local root = addonDB.pveRankings
	root.version = DATABASE_VERSION
	root.totalDungeonRuns = SafeNumber(root.totalDungeonRuns)
	root.totalRaidEncounters = SafeNumber(root.totalRaidEncounters)
	root.inferredDungeonRuns = SafeNumber(root.inferredDungeonRuns)
	root.incompleteSamples = SafeNumber(root.incompleteSamples)
	root.dungeonDiagnostics = type(root.dungeonDiagnostics) == "table"
		and root.dungeonDiagnostics or {}
	if type(root.lastDungeonDiagnostic) == "table"
		and #root.dungeonDiagnostics == 0
	then
		root.dungeonDiagnostics[1] = root.lastDungeonDiagnostic
	end
	for _, scope in ipairs(SCOPE_KEYS) do
		for _, category in ipairs(CATEGORY_KEYS) do
			EnsureCategory(root, scope, category)
		end
	end
	return root
end

local function IsIdentityValid(data)
	return type(data) == "table"
		and data.specializationClassToken
		and data.specializationID
		and data.specialization
		and data.specialization ~= "?"
		and data.specialization ~= "Unknown"
end

local function GetIdentityKey(data)
	if not IsIdentityValid(data) then
		return
	end
	return string.upper(tostring(data.specializationClassToken))
		.. ":" .. tostring(data.specializationID)
end

local function EnsureEntry(category, data)
	local key = GetIdentityKey(data)
	if not key then
		return
	end
	local entry = category.entries[key]
	if type(entry) ~= "table" then
		entry = {}
		category.entries[key] = entry
	end
	entry.classToken = data.specializationClassToken
	entry.specializationID = data.specializationID
	entry.specialization = data.specialization
	entry.specializationTexture = data.specializationTexture
	entry.specializationTexCoords = CopyCoordinates(data.specializationTexCoords)
	entry.samples = SafeNumber(entry.samples)
	entry.scoreSum = SafeNumber(entry.scoreSum)
	entry.scoreWeight = SafeNumber(entry.scoreWeight)
	entry.top1 = SafeNumber(entry.top1)
	entry.levelAdjustedSamples = SafeNumber(entry.levelAdjustedSamples)
	entry.levelSum = SafeNumber(entry.levelSum)
	entry.contexts = type(entry.contexts) == "table" and entry.contexts or {}
	return entry, key
end

local function AddMetricSums(target, metrics, count)
	count = count or 1
	target.samples = SafeNumber(target.samples) + count
	for key, value in pairs(metrics) do
		if type(value) == "number" then
			target[key .. "Sum"] = SafeNumber(target[key .. "Sum"]) + value * count
		end
	end
end

local function AddContextMetrics(category, entry, contextKey, metrics, count)
	local global = category.contexts[contextKey]
	if type(global) ~= "table" then
		global = {}
		category.contexts[contextKey] = global
	end
	local own = entry.contexts[contextKey]
	if type(own) ~= "table" then
		own = {}
		entry.contexts[contextKey] = own
	end
	AddMetricSums(global, metrics, count)
	AddMetricSums(own, metrics, count)
	entry.samples = SafeNumber(entry.samples) + (count or 1)
end

local function GetMemberData(member)
	if not member then
		return
	end
	local current = API and API.GetPlayerDataByGUID
		and API.GetPlayerDataByGUID(member.guid)
	if current then
		member.data = current
	end
	return member.data
end

local function GetRole(member)
	local data = GetMemberData(member)
	if data and data.role then
		return data.role
	end
	if member and member.unit and type(UnitGroupRolesAssigned) == "function" then
		local success, role = pcall(UnitGroupRolesAssigned, member.unit)
		if success and role and role ~= "NONE" then
			return role
		end
	end
end

local function IsDamageRole(role)
	return role == "DAMAGER"
		or role == "MELEE_DAMAGER"
		or role == "RANGED_DAMAGER"
end

local function GetParticipantLevel(participant)
	if not participant then
		return
	end
	local member = participant.member
	if member and member.unit and UnitExists(member.unit)
		and UnitGUID(member.unit) == participant.guid
	then
		local liveLevel = UnitLevel(member.unit)
		if liveLevel and liveLevel > 0 then
			member.level = liveLevel
			return liveLevel
		end
	end
	local level = member and member.level
		or participant.data and participant.data.level
	level = tonumber(level)
	if level and level > 0 then
		return level
	end
end

local function GetMedianLevel(participants)
	local levels = {}
	for _, participant in ipairs(participants or {}) do
		local level = GetParticipantLevel(participant)
		if level then
			levels[#levels + 1] = level
		end
	end
	if #levels == 0 then
		return
	end
	table.sort(levels)
	local middle = math.floor((#levels + 1) / 2)
	if #levels % 2 == 0 then
		return (levels[middle] + levels[middle + 1]) / 2
	end
	return levels[middle]
end

local function GetLevelPowerFactor(participant, referenceLevel)
	local level = GetParticipantLevel(participant)
	if not level or not referenceLevel or referenceLevel <= 0 then
		return 1, level
	end
	local factor = (level / referenceLevel) ^ LEVEL_POWER_EXPONENT
	return Clamp(factor, LEVEL_FACTOR_MIN, LEVEL_FACTOR_MAX), level
end

local function GetLevelAdjustedValue(value, participant, referenceLevel)
	local factor, level = GetLevelPowerFactor(participant, referenceLevel)
	return SafeNumber(value) / factor, factor, level
end

local function NewStats(member)
	return {
		guid = member.guid,
		name = member.name,
		damage = 0,
		bossDamage = 0,
		trashDamage = 0,
		rawHealing = 0,
		effectiveHealing = 0,
		absorbs = 0,
		tankTargetHealing = 0,
		damageTaken = 0,
		tankDamage = 0,
		externalSupport = 0,
		deaths = 0,
		responsibilitySeconds = 0,
		controlledSeconds = 0,
		lossSeconds = 0,
		threatLossEvents = 0,
		pickupTotal = 0,
		pickupCount = 0,
		tankingWallSeconds = 0,
		damageTakenRaw = 0,
		damageMitigated = 0,
		pressureDamageTaken = 0,
		pressureDamageMitigated = 0,
		pressureSeconds = 0,
		incomingAttacks = 0,
		avoidedAttacks = 0,
		selfHealing = 0,
		selfAbsorbs = 0,
		tankingSelfSustain = 0,
		defensiveCastsUnderPressure = 0,
		healthSeconds = 0,
		maxTwoSecondDamage = 0,
		healthObservedSeconds = 0,
		healthPctSeconds = 0,
		below75Seconds = 0,
		below50Seconds = 0,
		below25Seconds = 0,
		criticalEpisodes = 0,
		criticalFailures = 0,
		recoveryTimeTotal = 0,
		recoveryCount = 0,
		urgentRecoveryTimeTotal = 0,
		urgentRecoveryCount = 0,
		urgentRecoveryFailures = 0,
		minHealthPct = 1,
		utilityActions = 0,
		interrupts = 0,
		dispels = 0,
		repeatedHitDamage = 0,
		repeatedHitCount = 0,
		clutchHeals = 0,
		clutchHealing = 0,
		clutchCredit = 0,
		lifeSaves = 0,
		clutchHealsOnTank = 0,
		clutchHealsOnHealer = 0,
		clutchSelfHeals = 0,
		clutchRescuedBy = 0,
		combatObservedSeconds = 0,
		aliveCombatSeconds = 0,
		healerScorableCombatSeconds = 0,
		healerScorableAliveSeconds = 0,
		bossObservedSeconds = 0,
		trashObservedSeconds = 0,
		healerCoverageAssessableSeconds = 0,
		healerCoveredHealthObservedSeconds = 0,
		healerCoveredBelow75Seconds = 0,
		healerCoveredBelow50Seconds = 0,
		healerCoveredBelow25Seconds = 0,
		healerCoveredMinHealthPct = 1,
		healerOutOfRangeSeconds = 0,
		healerCoveredDamageTaken = 0,
		healerUncoveredDamageTaken = 0,
		coveredCriticalEpisodes = 0,
		coveredCriticalFailures = 0,
		coveredRecoveryTimeTotal = 0,
		coveredRecoveryCount = 0,
		coveredUrgentRecoveryTimeTotal = 0,
		coveredUrgentRecoveryCount = 0,
		coveredUrgentRecoveryFailures = 0,
		manaObservedSeconds = 0,
		manaPctSeconds = 0,
		below20ManaSeconds = 0,
		below10ManaSeconds = 0,
		minManaPct = 1,
		lastManaPct = 1,
		preventableDeaths = 0,
		oneShotDeaths = 0,
		outOfReachDeaths = 0,
		recoveryDeaths = 0,
		nonCombatDeaths = 0,
	}
end

local function NewSample(context, kind, encounterID, encounterName)
	return {
		kind = kind or context.scope,
		instanceName = context.instanceName,
		difficultyID = context.difficultyID,
		difficultyName = context.difficultyName,
		maxPlayers = context.maxPlayers,
		encounterID = encounterID,
		encounterName = encounterName,
		players = {},
		bossTime = 0,
		trashTime = 0,
		groupDamageTaken = 0,
		deaths = 0,
		preventableDeaths = 0,
		oneShotDeaths = 0,
		outOfReachDeaths = 0,
		recoveryDeaths = 0,
		nonCombatDeaths = 0,
		wipeLikeEvents = 0,
		wipes = 0,
		bossCount = 0,
		bossSegmentCount = 0,
		trashSegmentCount = 0,
		maxBossSegment = 0,
		maxTrashSegment = 0,
		officialEncounterStarts = 0,
		fallbackEncounterStarts = 0,
		officialEncounterEnds = 0,
		unattributedAbsorb = 0,
		pullCount = 0,
		downtimeSeconds = 0,
		longestDowntime = 0,
		mobCastsCompleted = 0,
		mobCastsInterrupted = 0,
		startedAt = GetTime(),
	}
end

local function GetSampleStats(sample, guid)
	if not sample or not session or not guid then
		return
	end
	local stats = sample.players[guid]
	if stats then
		return stats
	end
	local member = session.roster[guid]
	if not member then
		return
	end
	stats = NewStats(member)
	sample.players[guid] = stats
	return stats
end

local function RefreshRoster()
	if not session then
		return
	end
	if API and API.ScanFriendlyRoster then
		API.ScanFriendlyRoster()
	end

	local now = GetTime()
	local found = {}
	local units = { "player" }
	for index = 1, 40 do
		units[#units + 1] = "raid" .. index
	end
	for index = 1, 4 do
		units[#units + 1] = "party" .. index
	end
	for _, unit in ipairs(units) do
		if UnitExists(unit) and UnitIsPlayer(unit) then
			local guid = UnitGUID(unit)
			if guid and not found[guid] then
				found[guid] = true
				local member = session.roster[guid]
				if not member then
					member = {
						guid = guid,
						joinedAt = now,
						joinCount = 1,
					}
					session.roster[guid] = member
					if now - session.startedAt > 20 then
						session.rosterChanged = true
					end
				elseif not member.present then
					member.joinCount = SafeNumber(member.joinCount) + 1
					member.lastJoinedAt = now
					if now - session.startedAt > 20 then
						session.rosterChanged = true
					end
				end
				if not member.present then
					member.presentSince = now
				end
				member.present = true
				member.lastSeenAt = now
				member.unit = unit
				member.data = API and API.GetPlayerDataByGUID
					and API.GetPlayerDataByGUID(guid) or member.data
				local resolvedName = GetUnitPlayerName(unit)
				if not resolvedName and member.data then
					resolvedName = GetValidPlayerName(member.data.fullName)
						or GetValidPlayerName(member.data.name)
				end
				SetRosterMemberName(member, resolvedName)
				local level = UnitLevel(unit)
				if level and level > 0 then
					member.level = level
				end
				local maxHealth = UnitHealthMax(unit)
				if maxHealth and maxHealth > 0 then
					member.maxHealth = maxHealth
				end
			end
		end
	end

	local currentCount = 0
	for guid, member in pairs(session.roster) do
		if found[guid] then
			currentCount = currentCount + 1
		elseif member.present then
			member.presenceSeconds = SafeNumber(member.presenceSeconds)
				+ math.max(0, now - SafeNumber(member.presentSince))
			member.present = false
			member.presentSince = nil
			member.leftAt = now
			member.leaveCount = SafeNumber(member.leaveCount) + 1
			member.unit = nil
			session.rosterChanged = true
		end
	end
	session.currentGroupSize = currentCount
	session.peakGroupSize = math.max(SafeNumber(session.peakGroupSize), currentCount)

	-- The unit scan only sees the single controlled pet of each member. Guardians
	-- (totems, ghouls, mirror images, elementals, treants) never occupy a *pet
	-- unit token and are only learnable from SPELL_SUMMON. Wiping the table here
	-- discarded those mappings every roster refresh, so all guardian damage was
	-- credited to nobody. Only the unit-scan entries are refreshed now.
	session.summonedPets = session.summonedPets or {}
	for petGUID, ownerGUID in pairs(session.petOwners) do
		if not session.summonedPets[petGUID] then
			session.petOwners[petGUID] = nil
		elseif not session.roster[ownerGUID] then
			session.petOwners[petGUID] = nil
			session.summonedPets[petGUID] = nil
		end
	end
	local petUnits = { "pet" }
	for index = 1, 40 do
		petUnits[#petUnits + 1] = "raidpet" .. index
	end
	for index = 1, 4 do
		petUnits[#petUnits + 1] = "partypet" .. index
	end
	for _, petUnit in ipairs(petUnits) do
		if UnitExists(petUnit) then
			local petGUID = UnitGUID(petUnit)
			local ownerUnit
			if petUnit == "pet" then
				ownerUnit = "player"
			else
				ownerUnit = string.gsub(petUnit, "pet", "")
			end
			local ownerGUID = ownerUnit and UnitGUID(ownerUnit)
			if petGUID and ownerGUID and session.roster[ownerGUID] then
				session.petOwners[petGUID] = ownerGUID
			end
		end
	end
end

local function GetOwnerGUID(guid)
	if not session or not guid then
		return
	end
	local member = session.roster[guid]
	if member and (member.present or IsValidRosterUnit(guid, member)) then
		return guid
	end
	return session.petOwners[guid]
end

local function ForSamples(callback)
	if not session then
		return
	end
	if session.run and not session.run.recorded then
		callback(session.run)
	end
	if session.encounter and session.encounter ~= session.run then
		callback(session.encounter)
	end
end

local function RecordUrgentRecovery(stats, now)
	if not stats or not stats.criticalStartedAt or stats.urgentRecovered then
		return
	end
	stats.urgentRecoveryTimeTotal = SafeNumber(stats.urgentRecoveryTimeTotal)
		+ math.min(12, math.max(0, now - stats.criticalStartedAt))
	stats.urgentRecoveryCount = SafeNumber(stats.urgentRecoveryCount) + 1
	stats.urgentRecovered = true
end

local function FinalizeCriticalEpisode(stats, now, failed)
	if not stats or not stats.criticalStartedAt then
		return
	end
	if not stats.urgentRecovered then
		RecordUrgentRecovery(stats, now)
		if failed then
			stats.urgentRecoveryFailures = SafeNumber(stats.urgentRecoveryFailures) + 1
		end
	end
	stats.recoveryTimeTotal = SafeNumber(stats.recoveryTimeTotal)
		+ math.min(20, math.max(0, now - stats.criticalStartedAt))
	stats.recoveryCount = SafeNumber(stats.recoveryCount) + 1
	if failed then
		stats.criticalFailures = SafeNumber(stats.criticalFailures) + 1
	end
	stats.criticalStartedAt = nil
	stats.urgentRecovered = nil
end

local function RecordCoveredUrgentRecovery(stats, now)
	if not stats or not stats.coveredCriticalStartedAt or stats.coveredUrgentRecovered then
		return
	end
	stats.coveredUrgentRecoveryTimeTotal =
		SafeNumber(stats.coveredUrgentRecoveryTimeTotal)
			+ math.min(12, math.max(0, now - stats.coveredCriticalStartedAt))
	stats.coveredUrgentRecoveryCount = SafeNumber(stats.coveredUrgentRecoveryCount) + 1
	stats.coveredUrgentRecovered = true
end

local function FinalizeCoveredCriticalEpisode(stats, now, failed)
	if not stats or not stats.coveredCriticalStartedAt then
		return
	end
	if not stats.coveredUrgentRecovered then
		RecordCoveredUrgentRecovery(stats, now)
		if failed then
			stats.coveredUrgentRecoveryFailures =
				SafeNumber(stats.coveredUrgentRecoveryFailures) + 1
		end
	end
	stats.coveredRecoveryTimeTotal = SafeNumber(stats.coveredRecoveryTimeTotal)
		+ math.min(20, math.max(0, now - stats.coveredCriticalStartedAt))
	stats.coveredRecoveryCount = SafeNumber(stats.coveredRecoveryCount) + 1
	if failed then
		stats.coveredCriticalFailures = SafeNumber(stats.coveredCriticalFailures) + 1
	end
	stats.coveredCriticalStartedAt = nil
	stats.coveredUrgentRecovered = nil
end

local function CancelCoveredCriticalEpisode(stats)
	if not stats then
		return
	end
	if stats.coveredCriticalStartedAt then
		stats.coveredCriticalEpisodes = math.max(
			0,
			SafeNumber(stats.coveredCriticalEpisodes) - 1
		)
	end
	stats.coveredCriticalStartedAt = nil
	stats.coveredUrgentRecovered = nil
end

local function CloseCombatSegment(sample, now)
	if not sample or not sample.combatStartedAt then
		return
	end
	local duration = math.max(0, now - sample.combatStartedAt)
	if sample.combatIsBoss then
		sample.bossTime = sample.bossTime + duration
		if duration >= 0.05 then
			sample.bossSegmentCount = SafeNumber(sample.bossSegmentCount) + 1
			sample.maxBossSegment = math.max(SafeNumber(sample.maxBossSegment), duration)
		end
	else
		sample.trashTime = sample.trashTime + duration
		if duration >= 0.05 then
			sample.trashSegmentCount = SafeNumber(sample.trashSegmentCount) + 1
			sample.maxTrashSegment = math.max(SafeNumber(sample.maxTrashSegment), duration)
		end
	end
	sample.combatStartedAt = nil
end

local function StartCombatSegment(sample, isBoss, now)
	if not sample then
		return
	end
	now = now or GetTime()
	if sample.combatStartedAt and sample.combatIsBoss ~= isBoss then
		CloseCombatSegment(sample, now)
	end
	if not sample.combatStartedAt then
		sample.combatStartedAt = now
		sample.combatIsBoss = isBoss and true or false
	end
end

local function StartCombat()
	if not session then
		return
	end
	combatIdleElapsed = 0
	if session.inCombat then
		return
	end
	session.inCombat = true
	local resumedAt = GetTime()
	if session.combatEndedAt then
		local gap = math.max(0, resumedAt - session.combatEndedAt)
		if gap >= PACE_DOWNTIME_FLOOR then
			ForSamples(function(sample)
				sample.downtimeSeconds = SafeNumber(sample.downtimeSeconds) + gap
				sample.longestDowntime = math.max(
					SafeNumber(sample.longestDowntime), gap
				)
			end)
		end
		session.combatEndedAt = nil
	end
	ForSamples(function(sample)
		sample.pullCount = SafeNumber(sample.pullCount) + 1
	end)
	if session.diagnosticEnabled and session.diagnosticPendingStart then
		session.diagnosticPendingStart = false
		Chat("diagnostic started with the first combat")
		NotifyDiagnosticStatus()
	end
	local now = GetTime()
	if session.run then
		StartCombatSegment(session.run, session.encounter ~= nil, now)
	end
	if session.context.scope == "raid" and not session.encounter then
		session.encounter = NewSample(session.context, "raid", nil, "Boss detecte")
		session.encounter.fallback = true
	end
	if session.encounter then
		StartCombatSegment(session.encounter, true, now)
	end
end

local function EndCombat()
	if not session then
		return
	end
	local now = GetTime()
	ForSamples(function(sample)
		CloseCombatSegment(sample, now)
		for _, stats in pairs(sample.players or {}) do
			FinalizeCriticalEpisode(stats, now, false)
			FinalizeCoveredCriticalEpisode(stats, now, false)
		end
	end)
	session.inCombat = false
	session.combatEndedAt = now
	-- A pull is over, so nothing is "repeatedly" hitting anyone any more.
	ForSamples(function(sample)
		for _, stats in pairs(sample.players or {}) do
			stats.spellHits = nil
		end
	end)
	session.mobCasts = nil
	combatIdleElapsed = 0
	if session.encounter and session.encounter.fallback then
		local finished = session.encounter
		session.encounter = nil
		if finished.bossKilled then
			if session.context.scope == "raid" then
				PvE.RecordSample(finished, "raid", "boss fallback")
			elseif session.run then
				session.run.bossCount = SafeNumber(session.run.bossCount) + 1
				session.lastBossSuccessAt = GetTime()
			end
		end
	end
end

local function IsGroupCombatActive()
	if not session then
		return false
	end
	if session.encounter then
		return true
	end
	if type(UnitAffectingCombat) ~= "function" then
		return false
	end
	for guid, member in pairs(session.roster or {}) do
		local unit = member and member.unit
		if unit and UnitExists(unit) and UnitGUID(unit) == guid
			and UnitAffectingCombat(unit)
		then
			return true
		end
	end
	return false
end

local function BuildContextKey(sample, suffix)
	local encounter = sample.encounterName or sample.instanceName or "Instance"
	return table.concat({
		tostring(sample.kind or "pve"),
		tostring(sample.instanceName or "Instance"),
		tostring(encounter),
		tostring(sample.difficultyID or 0),
		tostring(sample.groupSize or 0),
		tostring(suffix or "base"),
	}, "|")
end

local function SnapshotParticipants(sample)
	local participants = {}
	local rosterSize = 0
	for guid, member in pairs(session and session.roster or {}) do
		rosterSize = rosterSize + 1
		local stats = sample.players[guid] or NewStats(member)
		local data = GetMemberData(member)
		local presenceSeconds = SafeNumber(member.presenceSeconds)
		if member.present and member.presentSince then
			presenceSeconds = presenceSeconds
				+ math.max(0, GetTime() - SafeNumber(member.presentSince))
		end
		participants[#participants + 1] = {
			guid = guid,
			member = member,
			data = data,
			role = GetRole(member),
			stats = stats,
			level = member.level or data and data.level,
			presenceSeconds = presenceSeconds,
			currentlyPresent = member.present and true or false,
		}
	end
	local nominalMaximum = SafeNumber(sample.maxPlayers)
	local simultaneous = math.max(
		SafeNumber(session and session.peakGroupSize),
		SafeNumber(session and session.currentGroupSize),
		1
	)
	if nominalMaximum > 0 then
		simultaneous = math.min(simultaneous, nominalMaximum)
	end
	sample.groupSize = simultaneous
	sample.rosterSize = rosterSize
	return participants
end

local function GroupBySpecialization(values)
	local grouped = {}
	for _, value in ipairs(values) do
		local key = GetIdentityKey(value.data)
		if key then
			local group = grouped[key]
			if not group then
				group = { data = value.data, values = {}, count = 0 }
				grouped[key] = group
			end
			group.count = group.count + 1
			group.values[#group.values + 1] = value
		end
	end
	return grouped
end

local function GetRobustMean(values, key, participationKey)
	local ordered = {}
	for _, value in ipairs(values or {}) do
		if not participationKey
			or SafeNumber(value[participationKey]) >= MIN_SCORING_PARTICIPATION
		then
			ordered[#ordered + 1] = SafeNumber(value[key])
		end
	end
	if #ordered == 0 then
		return 0
	end
	table.sort(ordered)
	local middle = math.floor((#ordered + 1) / 2)
	local median = #ordered % 2 == 0
		and (ordered[middle] + ordered[middle + 1]) / 2
		or ordered[middle]
	if median <= 0 then
		local total = 0
		for _, number in ipairs(ordered) do total = total + number end
		return total / #ordered
	end
	local minimum = median * 0.50
	local maximum = median * 1.50
	local total = 0
	for _, number in ipairs(ordered) do
		total = total + Clamp(number, minimum, maximum)
	end
	return total / #ordered
end

local function GetCombatParticipation(participant, activeTime)
	local stats = participant and participant.stats or {}
	activeTime = math.max(1, SafeNumber(activeTime))
	local observed = SafeNumber(stats.combatObservedSeconds)
	local participation = observed > 0 and Clamp(observed / activeTime, 0.10, 1) or 1
	local aliveRate = observed > 0 and Clamp(
		SafeNumber(stats.aliveCombatSeconds) / observed,
		0,
		1
	) or 1
	return participation, aliveRate
end

local function GetRawCombatParticipation(participant, activeTime)
	local observed = SafeNumber(participant and participant.stats
		and participant.stats.combatObservedSeconds)
	return activeTime > 0 and Clamp(observed / activeTime, 0, 1) or 0
end

local function GetEffectiveRoleCount(players, activeTime)
	if not players or #players == 0 then
		return 0
	end
	local exposure = 0
	for _, participant in ipairs(players) do
		exposure = exposure + GetRawCombatParticipation(participant, activeTime)
	end
	return Clamp(math.floor(exposure + 0.5), 1, #players)
end

local function GetParticipantEligibility(participant, activeTime)
	local stats = participant and participant.stats or {}
	local observed = SafeNumber(stats.combatObservedSeconds)
	local minimumObserved = math.max(
		MIN_SCORING_OBSERVED,
		math.min(20, SafeNumber(activeTime) * MIN_SCORING_PARTICIPATION)
	)
	local measurableActivity = SafeNumber(stats.damage)
		+ SafeNumber(stats.rawHealing)
		+ SafeNumber(stats.effectiveHealing)
		+ SafeNumber(stats.absorbs)
		+ SafeNumber(stats.damageTaken)
	if SafeNumber(stats.utilityActions) > 0
		or SafeNumber(stats.responsibilitySeconds) > 0
	then
		measurableActivity = measurableActivity + 1
	end
	if observed + EPSILON < minimumObserved then
		return false, "insufficient combat presence", observed, minimumObserved
	end
	if measurableActivity <= EPSILON then
		return false, "no measurable activity", observed, minimumObserved
	end
	return true, nil, observed, minimumObserved
end

local function GetPhaseParticipation(participant, phaseTime, observedKey, fallback)
	phaseTime = SafeNumber(phaseTime)
	if phaseTime <= EPSILON then
		return 1, 1
	end
	local observed = SafeNumber(participant and participant.stats
		and participant.stats[observedKey])
	if observed <= EPSILON then
		return fallback or 1, fallback or 0
	end
	local raw = Clamp(observed / phaseTime, 0, 1)
	return Clamp(raw, 0.10, 1), raw
end

local function GetPhaseEvidence(players, key)
	local total = 0
	local contributors = 0
	local strongest = 0
	for _, participant in ipairs(players or {}) do
		local value = SafeNumber(participant[key])
		total = total + value
		if value > EPSILON then
			contributors = contributors + 1
			strongest = math.max(strongest, value)
		end
	end
	return total, contributors, total > 0 and strongest / total or 0
end

local function GetDpsWeights(sample, bossMean, trashMean, players)
	local bossWeight = 0
	local trashWeight = 0
	local bossTime = SafeNumber(sample.bossTime)
	local trashTime = SafeNumber(sample.trashTime)
	local activeTime = math.max(1, bossTime + trashTime)
	local bossTotal, bossContributors, bossDominance = GetPhaseEvidence(
		players,
		"adjustedBossDamage"
	)
	local trashTotal, trashContributors, trashDominance = GetPhaseEvidence(
		players,
		"adjustedTrashDamage"
	)
	local damageTotal = math.max(EPSILON, bossTotal + trashTotal)
	local bossDamageShare = Clamp(bossTotal / damageTotal, 0, 1)
	local trashDamageShare = Clamp(trashTotal / damageTotal, 0, 1)
	local minimumPhaseTime = math.max(5, activeTime * 0.03)
	local bossReliable = bossMean > 0
		and (bossTime >= minimumPhaseTime or bossDamageShare >= 0.03)
		and (bossContributors >= 2 or bossDamageShare >= 0.10)
	local trashReliable = trashMean > 0
		and (trashTime >= minimumPhaseTime or trashDamageShare >= 0.03)
		and (trashContributors >= 2 or trashDamageShare >= 0.10)
	if bossReliable then
		local bossShare = Clamp(bossTime / activeTime, 0, 1)
		bossWeight = Clamp(0.45 + 0.25 * bossShare, 0.45, 0.60)
	end
	if trashReliable then
		trashWeight = bossWeight > 0 and 1 - bossWeight or 1
	end
	if not trashReliable then
		bossWeight = bossReliable and 1 or 0
	end
	return bossWeight, trashWeight, {
		bossReliable = bossReliable and true or false,
		trashReliable = trashReliable and true or false,
		bossDamageShare = bossDamageShare,
		trashDamageShare = trashDamageShare,
		bossContributors = bossContributors,
		trashContributors = trashContributors,
		bossDominance = bossDominance,
		trashDominance = trashDominance,
		minimumPhaseTime = minimumPhaseTime,
	}
end

local function GetClutchBonus(participant, activeTime, maximumBonus)
	local creditPerMinute = SafeNumber(participant.stats.clutchCredit)
		/ math.max(activeTime / 60, 1)
	return math.min(
		maximumBonus,
		creditPerMinute * CLUTCH_CREDIT_PER_MINUTE_SCALE
	), creditPerMinute
end

local function FinalizeDpsScore(outputScore, participant, activeTime)
	local participation, aliveRate = GetCombatParticipation(participant, activeTime)
	local participationFactor = 0.92 + 0.08 * Clamp(participation / 0.75, 0, 1)
	local survivalFactor = 0.90 + 0.10 * aliveRate
	local utilityPerMinute = SafeNumber(participant.stats.utilityActions)
		/ math.max(activeTime / 60, 1)
	local utilityBonus = math.min(3, utilityPerMinute * 1.5)
	-- A damage dealer who lands a real save is doing something the damage
	-- number cannot express. The bonus is capped so it can never outweigh
	-- actually doing the job the role exists for.
	local clutchBonus = GetClutchBonus(
		participant,
		activeTime,
		CLUTCH_DAMAGE_ROLE_MAX_BONUS
	)
	return Clamp(
		outputScore * participationFactor * survivalFactor
			+ utilityBonus + clutchBonus,
		30,
		200
	), participation, aliveRate, utilityBonus, clutchBonus
end

local function AddDpsRanking(root, scope, sample, participants)
	local category = EnsureCategory(root, scope, "dps")
	local damagePlayers = {}
	local unknownHighDamage = false
	local highestDamage = 0
	local activeTime = math.max(1, SafeNumber(sample.bossTime) + SafeNumber(sample.trashTime))
	for _, participant in ipairs(participants) do
		local damage = SafeNumber(participant.stats.damage)
		if damage > highestDamage then
			highestDamage = damage
		end
	end
	for _, participant in ipairs(participants) do
		local damage = SafeNumber(participant.stats.damage)
		local eligible = GetParticipantEligibility(participant, activeTime)
		if eligible and damage > 0
			and IsDamageRole(participant.role) and IsIdentityValid(participant.data)
		then
			damagePlayers[#damagePlayers + 1] = participant
		elseif eligible and damage > 0 and damage >= highestDamage * 0.50
			and not IsIdentityValid(participant.data)
		then
			unknownHighDamage = true
		end
	end
	if #damagePlayers < 2 or highestDamage <= 0 or unknownHighDamage then
		category.incomplete = category.incomplete + 1
		return false
	end

	local levelReference = GetMedianLevel(damagePlayers)
	for _, participant in ipairs(damagePlayers) do
		local participation = GetCombatParticipation(participant, activeTime)
		participant.bossParticipation, participant.bossParticipationRaw = GetPhaseParticipation(
			participant,
			sample.bossTime,
			"bossObservedSeconds",
			participation
		)
		participant.trashParticipation, participant.trashParticipationRaw = GetPhaseParticipation(
			participant,
			sample.trashTime,
			"trashObservedSeconds",
			participation
		)
		participant.adjustedBossDamage, participant.levelFactor, participant.level =
			GetLevelAdjustedValue(
				SafeNumber(participant.stats.bossDamage) / participant.bossParticipation,
				participant,
				levelReference
			)
		participant.adjustedTrashDamage =
			GetLevelAdjustedValue(
				SafeNumber(participant.stats.trashDamage) / participant.trashParticipation,
				participant,
				levelReference
			)
	end
	local bossMean = GetRobustMean(
		damagePlayers, "adjustedBossDamage", "bossParticipationRaw"
	)
	local trashMean = GetRobustMean(
		damagePlayers, "adjustedTrashDamage", "trashParticipationRaw"
	)
	local bossWeight, trashWeight
	if sample.kind == "raid" then
		bossWeight, trashWeight = bossMean > 0 and 1 or 0, 0
	else
		bossWeight, trashWeight = GetDpsWeights(
			sample,
			bossMean,
			trashMean,
			damagePlayers
		)
	end
	local weightTotal = bossWeight + trashWeight
	if weightTotal <= 0 then
		category.incomplete = category.incomplete + 1
		return false
	end
	bossWeight = bossWeight / weightTotal
	trashWeight = trashWeight / weightTotal

	local scored = {}
	local leading = 0
	for _, participant in ipairs(damagePlayers) do
		local bossRatio = bossMean > 0
			and participant.adjustedBossDamage / bossMean or 0
		local trashRatio = trashMean > 0
			and participant.adjustedTrashDamage / trashMean or 0
		local personalBossWeight = participant.bossParticipationRaw
			and participant.bossParticipationRaw >= MIN_SCORING_PARTICIPATION
			and bossWeight or 0
		local personalTrashWeight = participant.trashParticipationRaw
			and participant.trashParticipationRaw >= MIN_SCORING_PARTICIPATION
			and trashWeight or 0
		local personalWeightTotal = personalBossWeight + personalTrashWeight
		local outputScore = personalWeightTotal > 0 and 100 * (
			personalBossWeight * bossRatio + personalTrashWeight * trashRatio
		) / personalWeightTotal or 0
		local score, participation, aliveRate, utilityBonus, clutchBonus =
			FinalizeDpsScore(outputScore, participant, activeTime)
		scored[#scored + 1] = {
			data = participant.data,
			score = score,
			name = participant.member.name,
			level = participant.level,
			levelFactor = participant.levelFactor,
			levelReference = levelReference,
			participation = participation,
			bossParticipation = participant.bossParticipation,
			trashParticipation = participant.trashParticipation,
			bossParticipationRaw = participant.bossParticipationRaw,
			trashParticipationRaw = participant.trashParticipationRaw,
			aliveRate = aliveRate,
			utilityBonus = utilityBonus,
			clutchBonus = clutchBonus,
		}
		if score > leading then
			leading = score
		end
	end

	for _, group in pairs(GroupBySpecialization(scored)) do
		local score = 0
		local scoreWeight = 0
		local top1 = false
		local levelTotal = 0
		local levelCount = 0
		for _, value in ipairs(group.values) do
			local weight = Clamp(SafeNumber(value.participation), 0.10, 1)
			score = score + value.score * weight
			scoreWeight = scoreWeight + weight
			if value.level then
				levelTotal = levelTotal + value.level
				levelCount = levelCount + 1
			end
			if value.score + EPSILON >= leading then
				top1 = true
			end
		end
		score = score / math.max(scoreWeight, EPSILON)
		local entry = EnsureEntry(category, group.data)
		local effectiveWeight = math.min(1, scoreWeight)
		entry.scoreSum = entry.scoreSum + score * effectiveWeight
		entry.scoreWeight = entry.scoreWeight + effectiveWeight
		entry.samples = entry.samples + 1
		entry.top1 = entry.top1 + (top1 and 1 or 0)
		entry.lastScore = score
		if levelReference and levelCount > 0 then
			entry.levelAdjustedSamples = entry.levelAdjustedSamples + 1
			entry.levelSum = entry.levelSum + levelTotal / levelCount
			entry.lastLevelReference = levelReference
		end
	end
	category.samples = category.samples + 1
	return true
end

local function GetHealingProfile(participant, healerCount)
	if healerCount <= 1 then
		return "solo"
	end
	local impact = SafeNumber(participant.stats.effectiveHealing)
		+ SafeNumber(participant.stats.absorbs)
	if impact <= 0 then
		return "mixed"
	end
	local ratio = SafeNumber(participant.stats.tankTargetHealing) / impact
	if ratio >= 0.60 then
		return "tank"
	elseif ratio <= 0.25 then
		return "raid"
	end
	return "mixed"
end

local function BuildHealingContext(sample, participants, totalHealerImpact, nonHealerHealing, activeTime)
	local observed = 0
	local below75 = 0
	local below50 = 0
	local below25 = 0
	local recoveryTime = 0
	local recoveries = 0
	local urgentRecoveryTime = 0
	local urgentRecoveries = 0
	local urgentRecoveryFailures = 0
	local criticalEpisodes = 0
	local criticalFailures = 0
	local preventableDeaths = 0
	local oneShotDeaths = 0
	local outOfReachDeaths = 0
	local recoveryDeaths = 0
	local coverageAssessable = 0
	local coveredDamageTaken = 0
	local uncoveredDamageTaken = 0
	local totalMaxHealth = 0
	local minimumHealth = 1
	-- The yardstick for "a healer who also does damage" is what the actual
	-- damage dealers in this same fight produced, using the same robust mean
	-- the DPS ranking uses so one padded parse cannot move the bar.
	local damageRates = {}
	for _, participant in ipairs(participants or {}) do
		if IsDamageRole(participant.role) then
			local rate = SafeNumber(participant.stats and participant.stats.damage)
				/ math.max(1, SafeNumber(activeTime))
			if rate > 0 then
				damageRates[#damageRates + 1] = { damageRate = rate }
			end
		end
	end
	local damageReference = GetRobustMean(damageRates, "damageRate")
	for _, participant in ipairs(participants or {}) do
		local stats = participant.stats or {}
		local assessed = SafeNumber(stats.healerCoverageAssessableSeconds)
		coverageAssessable = coverageAssessable + assessed
		coveredDamageTaken = coveredDamageTaken
			+ SafeNumber(stats.healerCoveredDamageTaken)
		uncoveredDamageTaken = uncoveredDamageTaken
			+ SafeNumber(stats.healerUncoveredDamageTaken)
		local participantObserved = assessed > 0
			and SafeNumber(stats.healerCoveredHealthObservedSeconds)
			or SafeNumber(stats.healthObservedSeconds)
		observed = observed + participantObserved
		below75 = below75 + SafeNumber(assessed > 0
			and stats.healerCoveredBelow75Seconds or stats.below75Seconds)
		below50 = below50 + SafeNumber(assessed > 0
			and stats.healerCoveredBelow50Seconds or stats.below50Seconds)
		below25 = below25 + SafeNumber(assessed > 0
			and stats.healerCoveredBelow25Seconds or stats.below25Seconds)
		recoveryTime = recoveryTime + SafeNumber(assessed > 0
			and stats.coveredRecoveryTimeTotal or stats.recoveryTimeTotal)
		recoveries = recoveries + SafeNumber(assessed > 0
			and stats.coveredRecoveryCount or stats.recoveryCount)
		urgentRecoveryTime = urgentRecoveryTime
			+ SafeNumber(assessed > 0 and stats.coveredUrgentRecoveryTimeTotal
				or stats.urgentRecoveryTimeTotal)
		urgentRecoveries = urgentRecoveries + SafeNumber(assessed > 0
			and stats.coveredUrgentRecoveryCount or stats.urgentRecoveryCount)
		urgentRecoveryFailures = urgentRecoveryFailures
			+ SafeNumber(assessed > 0 and stats.coveredUrgentRecoveryFailures
				or stats.urgentRecoveryFailures)
		criticalEpisodes = criticalEpisodes + SafeNumber(assessed > 0
			and stats.coveredCriticalEpisodes or stats.criticalEpisodes)
		criticalFailures = criticalFailures + SafeNumber(assessed > 0
			and stats.coveredCriticalFailures or stats.criticalFailures)
		preventableDeaths = preventableDeaths + SafeNumber(stats.preventableDeaths)
		oneShotDeaths = oneShotDeaths + SafeNumber(stats.oneShotDeaths)
		outOfReachDeaths = outOfReachDeaths + SafeNumber(stats.outOfReachDeaths)
		recoveryDeaths = recoveryDeaths + SafeNumber(stats.recoveryDeaths)
		local maximum = participant.member and participant.member.maxHealth
		if maximum and maximum > 0 then
			local presenceWeight = activeTime and activeTime > 0
				and Clamp(
					SafeNumber(stats.combatObservedSeconds) / activeTime,
					0.10,
					1
				) or 1
			totalMaxHealth = totalMaxHealth + maximum * presenceWeight
		end
		if participantObserved > 0 then
			minimumHealth = math.min(minimumHealth, SafeNumber(assessed > 0
				and stats.healerCoveredMinHealthPct or stats.minHealthPct))
		end
	end

	local scorableDamageTaken = coverageAssessable > 0
		and coveredDamageTaken or SafeNumber(sample.groupDamageTaken)
	local danger = observed > 0 and (
		0.15 * below75 + 0.35 * below50 + 0.50 * below25
	) / observed or 0
	local healthStability = Clamp(1.30 - 2 * danger, 0.45, 1.30)
	local groupSize = math.max(1, sample.groupSize or #participants)
	local survival = Clamp(
		1.20 / (
			1 + preventableDeaths / groupSize * 1.50
		),
		0.45,
		1.20
	)
	local stability = 0.75 * healthStability + 0.25 * survival
	local responsiveness = 1.15
	local averageRecovery
	local averageUrgentRecovery
	if urgentRecoveries > 0 then
		averageUrgentRecovery = urgentRecoveryTime / urgentRecoveries
		responsiveness = Clamp(3.5 / (averageUrgentRecovery + 1), 0.50, 1.40)
	elseif criticalEpisodes > 0 then
		responsiveness = 0.60
	end
	-- A slow recovery with no failure must not be punished twice: stability
	-- already measures the time spent at low health. This floor makes the
	-- measurement fairer to HoTs as long as nobody dies for lack of healing.
	if urgentRecoveryFailures <= 0 and preventableDeaths <= 0 then
		responsiveness = math.max(responsiveness, 0.85)
	end
	if recoveries > 0 then
		averageRecovery = recoveryTime / recoveries
	end

	activeTime = math.max(1, SafeNumber(activeTime))
	local pressure = totalMaxHealth > 0
		and scorableDamageTaken / totalMaxHealth / math.max(activeTime / 60, 1)
		or 0
	local opportunity = Clamp(
		0.25
			+ 0.45 * Clamp(pressure / 1.50, 0, 1)
			+ 0.30 * Clamp(criticalEpisodes / 5, 0, 1),
		0.25,
		1
	)
	local confidence = opportunity >= 0.80 and "high"
		or opportunity >= 0.55 and "normal"
		or "low"

	return {
		activeTime = activeTime,
		healableLoad = math.max(
			1,
			scorableDamageTaken - SafeNumber(nonHealerHealing)
		),
		observedSeconds = observed,
		below75Seconds = below75,
		below50Seconds = below50,
		below25Seconds = below25,
		criticalEpisodes = criticalEpisodes,
		criticalFailures = criticalFailures,
		urgentRecoveryFailures = urgentRecoveryFailures,
		preventableDeaths = preventableDeaths,
		oneShotDeaths = oneShotDeaths,
		outOfReachDeaths = outOfReachDeaths,
		recoveryDeaths = recoveryDeaths,
		coverageAssessableSeconds = coverageAssessable,
		scorableDamageTaken = scorableDamageTaken,
		coveredDamageTaken = coveredDamageTaken,
		uncoveredDamageTaken = uncoveredDamageTaken,
		averageRecovery = averageRecovery,
		averageUrgentRecovery = averageUrgentRecovery,
		urgentRecoveryThreshold = URGENT_RECOVERY_THRESHOLD,
		minimumHealthPct = minimumHealth,
		stability = stability,
		responsiveness = responsiveness,
		pressure = pressure,
		opportunity = opportunity,
		confidence = confidence,
		damageReference = damageReference,
	}
end

local function CalculateHealerOutcome(
	sample,
	participant,
	healerCount,
	totalHealerImpact,
	context,
	attributeUnassignedAbsorb
)
	local stats = participant.stats or {}
	local impact = SafeNumber(participant.impact)
	local participation = GetRawCombatParticipation(participant, context.activeTime)
	local coverageImpact = impact / math.max(0.10, participation)
	local attributedAbsorb = SafeNumber(stats.absorbs)
	if attributeUnassignedAbsorb then
		attributedAbsorb = attributedAbsorb + SafeNumber(sample.unattributedAbsorb)
	end
	local raw = SafeNumber(stats.rawHealing) + attributedAbsorb
	local peer = healerCount * impact / math.max(totalHealerImpact, 1)
	local coverage = Clamp((coverageImpact / context.healableLoad) / 0.85, 0.50, 1.35)
	local effectiveRatio = raw > 0 and Clamp(impact / raw, 0, 1) or 0
	-- Overheal is almost neutral: HoTs and preventive healing must not be
	-- penalized as long as the resource stays under control.
	local efficiency = Clamp(0.90 + 0.15 * effectiveRatio, 0.90, 1.05)
	local observedMana = SafeNumber(stats.manaObservedSeconds)
	local low20Rate = observedMana > 0
		and Clamp(SafeNumber(stats.below20ManaSeconds) / observedMana, 0, 1) or 0
	local low10Rate = observedMana > 0
		and Clamp(SafeNumber(stats.below10ManaSeconds) / observedMana, 0, 1) or 0
	local manaManagement = observedMana > 0 and Clamp(
		1.10 - 0.30 * low20Rate - 0.55 * low10Rate,
		0.55,
		1.10
	) or 1
	local observedCombat = SafeNumber(stats.combatObservedSeconds)
	if SafeNumber(stats.healerScorableCombatSeconds) > 0 then
		observedCombat = SafeNumber(stats.healerScorableCombatSeconds)
	end
	local aliveRate = observedCombat > 0 and Clamp(
		(SafeNumber(stats.healerScorableCombatSeconds) > 0
			and SafeNumber(stats.healerScorableAliveSeconds)
			or SafeNumber(stats.aliveCombatSeconds)) / observedCombat,
		0,
		1
	) or 1
	local deathFactor = 1 / (
		1 + SafeNumber(stats.preventableDeaths) * 0.35
	)
	local availability = Clamp(
		(0.55 + 0.70 * aliveRate) * deathFactor,
		0.45,
		1.25
	)
	local utilityPerMinute = SafeNumber(stats.utilityActions)
		/ math.max(context.activeTime / 60, 1)
	local prevention = Clamp(
		1
			+ math.min(0.20, attributedAbsorb / math.max(impact, 1) * 0.50)
			+ math.min(0.15, utilityPerMinute * 0.05),
		1,
		1.35
	)
	-- Healing duty comes first. The damage bonus only opens up once stability,
	-- coverage and responsiveness are collectively above par, and it closes
	-- completely the moment somebody dies a death this healer could have
	-- prevented.
	local dutyScore = 0.40 * context.stability
		+ 0.35 * coverage
		+ 0.25 * context.responsiveness
	local damageGate = SafeNumber(stats.preventableDeaths) > 0 and 0
		or Clamp(
			(dutyScore - HEALER_DAMAGE_GATE_FLOOR) / HEALER_DAMAGE_GATE_SPAN,
			0,
			1
		)
	local damageRate = SafeNumber(stats.damage)
		/ math.max(1, SafeNumber(context.activeTime))
	local damageReference = SafeNumber(context.damageReference)
	local damageRatio = damageReference > 0
		and Clamp(damageRate / damageReference, 0, 1) or 0
	local healerDamageBonus = HEALER_DAMAGE_MAX_BONUS * damageGate * damageRatio
	local healerClutchBonus = math.min(
		CLUTCH_SUPPORT_MAX_BONUS,
		SafeNumber(stats.clutchCredit)
			/ math.max(SafeNumber(context.activeTime) / 60, 1)
			* CLUTCH_CREDIT_PER_MINUTE_SCALE
	)
	local rawScore
	if healerCount <= 1 then
		rawScore = 100 * (
			0.25 * context.stability
				+ 0.20 * coverage
				+ 0.20 * context.responsiveness
				+ 0.20 * availability
				+ 0.08 * manaManagement
				+ 0.05 * prevention
				+ 0.02 * efficiency
		)
	else
		rawScore = 100 * (
			0.25 * Clamp(peer, 0.40, 1.60)
				+ 0.15 * coverage
				+ 0.15 * context.stability
				+ 0.15 * context.responsiveness
				+ 0.15 * availability
				+ 0.08 * manaManagement
				+ 0.05 * prevention
				+ 0.02 * efficiency
		)
	end
	rawScore = rawScore + healerDamageBonus + healerClutchBonus
	-- Opportunity becomes a confidence value, not an artificial cap on the
	-- rating. It weights the history without dragging execution back to 7/10.
	local score = rawScore
	return {
		version = HEALER_SCORE_VERSION,
		score = Clamp(score, 30, 200),
		rawScore = rawScore,
		peer = peer,
		coverage = coverage,
		stability = context.stability,
		responsiveness = context.responsiveness,
		efficiency = efficiency,
		effectiveRatio = effectiveRatio,
		manaManagement = manaManagement,
		averageManaPct = observedMana > 0
			and SafeNumber(stats.manaPctSeconds) / observedMana or nil,
		minimumManaPct = observedMana > 0 and SafeNumber(stats.minManaPct) or nil,
		endingManaPct = observedMana > 0 and SafeNumber(stats.lastManaPct) or nil,
		lowManaRate = low20Rate,
		prevention = prevention,
		dutyScore = dutyScore,
		damageGate = damageGate,
		damageRate = damageRate,
		damageReference = damageReference,
		damageRatio = damageRatio,
		damageDone = SafeNumber(stats.damage),
		healerDamageBonus = healerDamageBonus,
		healerClutchBonus = healerClutchBonus,
		clutchHeals = SafeNumber(stats.clutchHeals),
		clutchHealing = SafeNumber(stats.clutchHealing),
		lifeSaves = SafeNumber(stats.lifeSaves),
		clutchHealsOnTank = SafeNumber(stats.clutchHealsOnTank),
		clutchHealsOnHealer = SafeNumber(stats.clutchHealsOnHealer),
		personalSurvival = availability,
		availability = availability,
		aliveRate = aliveRate,
		preventableDeaths = SafeNumber(stats.preventableDeaths),
		oneShotDeaths = SafeNumber(stats.oneShotDeaths),
		outOfReachDeaths = context.outOfReachDeaths,
		recoveryDeaths = context.recoveryDeaths,
		coverageAssessableSeconds = context.coverageAssessableSeconds,
		scorableDamageTaken = context.scorableDamageTaken,
		coveredDamageTaken = context.coveredDamageTaken,
		uncoveredDamageTaken = context.uncoveredDamageTaken,
		opportunity = context.opportunity,
		confidence = context.confidence,
		pressure = context.pressure,
		criticalEpisodes = context.criticalEpisodes,
		criticalFailures = context.criticalFailures,
		averageRecovery = context.averageRecovery,
		averageUrgentRecovery = context.averageUrgentRecovery,
		urgentRecoveryFailures = context.urgentRecoveryFailures,
		urgentRecoveryThreshold = context.urgentRecoveryThreshold,
		minimumHealthPct = context.minimumHealthPct,
		healableLoad = context.healableLoad,
		impact = impact,
		coverageImpact = coverageImpact,
		participation = participation,
		rawHealing = raw,
		utilityActions = SafeNumber(stats.utilityActions),
		damageReference = damageReference,
	}
end

local function AddHealingRanking(root, scope, sample, participants)
	local category = EnsureCategory(root, scope, "healing")
	local healers = {}
	local eligibleParticipants = {}
	local nonHealerHealing = 0
	local totalHealerImpact = 0
	local activeTime = SafeNumber(sample.bossTime) + SafeNumber(sample.trashTime)
	for _, participant in ipairs(participants) do
		local eligible = GetParticipantEligibility(participant, activeTime)
		local impact = SafeNumber(participant.stats.effectiveHealing)
			+ SafeNumber(participant.stats.absorbs)
		if eligible then
			eligibleParticipants[#eligibleParticipants + 1] = participant
		end
		if eligible and impact > 0 and participant.role == "HEALER"
			and IsIdentityValid(participant.data)
		then
			participant.impact = impact
			healers[#healers + 1] = participant
			totalHealerImpact = totalHealerImpact + impact
		elseif eligible then
			nonHealerHealing = nonHealerHealing
				+ SafeNumber(participant.stats.effectiveHealing)
				+ SafeNumber(participant.stats.absorbs)
		end
	end
	-- Legacy 3.3.5 damage events expose the absorbed amount but not always
	-- the shield caster. With a single identified healer, attribute that
	-- otherwise-lost prevention to the only healing role. In raids, only
	-- explicitly attributed SPELL_ABSORBED events are credited.
	if #healers == 1 and SafeNumber(sample.unattributedAbsorb) > 0 then
		healers[1].impact = healers[1].impact + sample.unattributedAbsorb
		totalHealerImpact = totalHealerImpact + sample.unattributedAbsorb
	end
	if #healers == 0 or totalHealerImpact <= 0 then
		category.incomplete = category.incomplete + 1
		return false
	end
	local healerCount = GetEffectiveRoleCount(healers, activeTime)

	local healableLoad = math.max(
		1,
		SafeNumber(sample.groupDamageTaken) - nonHealerHealing
	)
	local survival = 1 / (
		1
		+ SafeNumber(sample.preventableDeaths) / math.max(1, sample.groupSize)
	)
	local healingContext = BuildHealingContext(
		sample,
		eligibleParticipants,
		totalHealerImpact,
		nonHealerHealing,
		activeTime
	)
	local metrics = {}
	local leading = 0
	for _, participant in ipairs(healers) do
		local participation = GetRawCombatParticipation(participant, activeTime)
		local raw = SafeNumber(participant.stats.rawHealing)
			+ SafeNumber(participant.stats.absorbs)
		local impact = participant.impact
		local profile = GetHealingProfile(participant, healerCount)
		local outcome = CalculateHealerOutcome(
			sample,
			participant,
			healerCount,
			totalHealerImpact,
			healingContext,
			#healers == 1
		)
		local contextKey = BuildContextKey(
			sample,
			"healers=" .. healerCount .. ";profile=" .. profile
		)
		local value = {
			data = participant.data,
			contextKey = contextKey,
			coverage = Clamp(impact / healableLoad, 0, 2),
			survival = survival,
			efficiency = raw > 0 and Clamp(impact / raw, 0, 1) or 0,
			peer = healerCount * impact / math.max(totalHealerImpact, 1),
			impact = impact,
			outcomeScore = outcome.score,
			participation = participation,
			outcomeWeight = outcome.opportunity * participation,
		}
		metrics[#metrics + 1] = value
		if impact > leading then
			leading = impact
		end
	end

	for _, group in pairs(GroupBySpecialization(metrics)) do
		local byContext = {}
		local top1 = false
		for _, value in ipairs(group.values) do
			local bucket = byContext[value.contextKey]
			if not bucket then
				bucket = {
					count = 0, coverage = 0, survival = 0,
					efficiency = 0, peer = 0, outcomeScore = 0,
					outcomeWeightedScore = 0, outcomeWeight = 0,
				}
				byContext[value.contextKey] = bucket
			end
			bucket.count = bucket.count + 1
			bucket.coverage = bucket.coverage + value.coverage
			bucket.survival = bucket.survival + value.survival
			bucket.efficiency = bucket.efficiency + value.efficiency
			bucket.peer = bucket.peer + value.peer
			bucket.outcomeScore = bucket.outcomeScore + value.outcomeScore
			bucket.outcomeWeightedScore = bucket.outcomeWeightedScore
				+ value.outcomeScore * value.outcomeWeight
			bucket.outcomeWeight = bucket.outcomeWeight + value.outcomeWeight
			if value.impact + EPSILON >= leading then
				top1 = true
			end
		end
		local entry = EnsureEntry(category, group.data)
		for contextKey, bucket in pairs(byContext) do
			local participationWeight = 0
			for _, value in ipairs(group.values) do
				if value.contextKey == contextKey then
					participationWeight = participationWeight
						+ Clamp(SafeNumber(value.participation), 0.10, 1)
				end
			end
			participationWeight = math.min(1, participationWeight)
			AddContextMetrics(category, entry, contextKey, {
				coverage = bucket.coverage / bucket.count,
				survival = bucket.survival / bucket.count,
				efficiency = bucket.efficiency / bucket.count,
				peer = bucket.peer / bucket.count,
			}, participationWeight)
			local ownContext = entry.contexts[contextKey]
			local globalContext = category.contexts[contextKey]
			local outcomeScore = bucket.outcomeWeight > 0
				and bucket.outcomeWeightedScore / bucket.outcomeWeight
				or bucket.outcomeScore / bucket.count
			local outcomeWeight = bucket.outcomeWeight / bucket.count
			ownContext.outcomeV4ScoreSum = SafeNumber(ownContext.outcomeV4ScoreSum)
				+ outcomeScore * outcomeWeight
			ownContext.outcomeV4Weight = SafeNumber(ownContext.outcomeV4Weight)
				+ outcomeWeight
			ownContext.outcomeV4Runs = SafeNumber(ownContext.outcomeV4Runs) + 1
			globalContext.outcomeV4ScoreSum = SafeNumber(globalContext.outcomeV4ScoreSum)
				+ outcomeScore * outcomeWeight
			globalContext.outcomeV4Weight = SafeNumber(globalContext.outcomeV4Weight)
				+ outcomeWeight
			globalContext.outcomeV4Runs = SafeNumber(globalContext.outcomeV4Runs) + 1
		end
		entry.top1 = entry.top1 + (top1 and 1 or 0)
	end
	category.samples = category.samples + 1
	return true
end

-- Four independent, log-verifiable signals, each normalized so that par for
-- the metric equals 1.0 and the weights sum to 1.0.
local function GetTankMitigationProfile(stats, memberHealth)
	stats = stats or {}
	local rawTaken = math.max(1, SafeNumber(stats.damageTakenRaw))
	local mitigationRate = Clamp(
		SafeNumber(stats.damageMitigated) / rawTaken, 0, 1
	)
	local pressureRaw = SafeNumber(stats.pressureDamageTaken)
	local pressureMitigationRate = pressureRaw > 0
		and Clamp(SafeNumber(stats.pressureDamageMitigated) / pressureRaw, 0, 1)
		or mitigationRate
	local incoming = math.max(1, SafeNumber(stats.incomingAttacks))
	local avoidanceRate = Clamp(
		SafeNumber(stats.avoidedAttacks) / incoming, 0, 1
	)
	local selfSustainRate = Clamp(
		SafeNumber(stats.tankingSelfSustain) / rawTaken, 0, 1
	)
	-- Positive when mitigation is concentrated in the dangerous windows, which
	-- is exactly the behaviour worth rewarding.
	local spikeResponse = Clamp(
		0.50 + (pressureMitigationRate - mitigationRate) * TANK_SPIKE_RESPONSE_SCALE,
		0,
		1.25
	)
	local quality = Clamp(
		0.40 * Clamp(mitigationRate / TANK_PAR_MITIGATION_RATE, 0, 1.25)
			+ 0.25 * Clamp(avoidanceRate / TANK_PAR_AVOIDANCE_RATE, 0, 1.25)
			+ 0.20 * Clamp(selfSustainRate / TANK_PAR_SELF_SUSTAIN_RATE, 0, 1.25)
			+ 0.15 * spikeResponse,
		0.40,
		1.30
	)
	return {
		quality = quality,
		mitigationRate = mitigationRate,
		pressureMitigationRate = pressureMitigationRate,
		avoidanceRate = avoidanceRate,
		selfSustainRate = selfSustainRate,
		spikeResponse = spikeResponse,
		damageTakenRaw = SafeNumber(stats.damageTakenRaw),
		damageMitigated = SafeNumber(stats.damageMitigated),
		selfHealing = SafeNumber(stats.selfHealing),
		selfAbsorbs = SafeNumber(stats.selfAbsorbs),
		tankingSelfSustain = SafeNumber(stats.tankingSelfSustain),
		incomingAttacks = SafeNumber(stats.incomingAttacks),
		avoidedAttacks = SafeNumber(stats.avoidedAttacks),
		pressureDamageTaken = pressureRaw,
		defensiveCastsUnderPressure =
			SafeNumber(stats.defensiveCastsUnderPressure),
		maximumHealth = memberHealth,
	}
end

local function AddTankRanking(root, scope, sample, participants)
	local category = EnsureCategory(root, scope, "tank")
	local tanks = {}
	local activeTime = math.max(
		1,
		SafeNumber(sample.bossTime) + SafeNumber(sample.trashTime)
	)
	for _, participant in ipairs(participants) do
		local stats = participant.stats
		if GetParticipantEligibility(participant, activeTime)
			and participant.role == "TANK"
			and IsIdentityValid(participant.data)
			and SafeNumber(stats.responsibilitySeconds) >= 5
		then
			tanks[#tanks + 1] = participant
		end
	end
	if #tanks == 0 then
		category.incomplete = category.incomplete + 1
		return false
	end

	local values = {}
	local leading = 0
	local contextKey = BuildContextKey(
		sample,
		"tanks=" .. GetEffectiveRoleCount(tanks, activeTime)
	)
	for _, participant in ipairs(tanks) do
		local stats = participant.stats
		local responsibility = math.max(1, SafeNumber(stats.responsibilitySeconds))
		local uptime = Clamp(SafeNumber(stats.controlledSeconds) / responsibility, 0, 1)
		local lossRate = Clamp(SafeNumber(stats.lossSeconds) / responsibility, 0, 1)
		local pickup = SafeNumber(stats.pickupCount) > 0
			and SafeNumber(stats.pickupTotal) / stats.pickupCount or 0
		local pickupScore = 1 / (1 + pickup / 3)
		local aggro = 0.55 * uptime + 0.25 * pickupScore + 0.20 * (1 - lossRate)
		local healthSeconds = math.max(1, SafeNumber(stats.healthSeconds))
		local memberHealth = participant.member.maxHealth or 1
		local value = {
			data = participant.data,
			participation = GetRawCombatParticipation(participant, activeTime),
			contextKey = contextKey,
			uptime = uptime,
			pickup = pickup,
			lossRate = lossRate,
			damageRate = SafeNumber(stats.tankDamage) / healthSeconds,
			supportRate = SafeNumber(stats.externalSupport) / healthSeconds,
			spike = SafeNumber(stats.maxTwoSecondDamage) / math.max(1, memberHealth),
			survival = Clamp(
				(0.70 + 0.30 * select(2, GetCombatParticipation(participant,
					SafeNumber(sample.bossTime) + SafeNumber(sample.trashTime))))
				/ (
					1 + SafeNumber(stats.deaths) * 0.20
				),
				0.40,
				1
			),
			aggro = aggro,
			mitigation = GetTankMitigationProfile(stats, memberHealth).quality,
		}
		values[#values + 1] = value
		local provisional = 100 * (0.90 * aggro + 0.10 * value.survival)
		if provisional > leading then
			leading = provisional
		end
		value.provisional = provisional
	end

	for _, group in pairs(GroupBySpecialization(values)) do
		local sums = {
			uptime = 0, pickup = 0, lossRate = 0, damageRate = 0,
			supportRate = 0, spike = 0, survival = 0, aggro = 0,
			mitigation = 0,
		}
		local top1 = false
		for _, value in ipairs(group.values) do
			for key in pairs(sums) do
				sums[key] = sums[key] + value[key]
			end
			if value.provisional + EPSILON >= leading then
				top1 = true
			end
		end
		for key in pairs(sums) do
			sums[key] = sums[key] / group.count
		end
		local entry = EnsureEntry(category, group.data)
		local participationWeight = 0
		for _, value in ipairs(group.values) do
			participationWeight = participationWeight
				+ SafeNumber(value.participation)
		end
		AddContextMetrics(
			category,
			entry,
			contextKey,
			sums,
			math.min(1, math.max(0.10, participationWeight))
		)
		entry.top1 = entry.top1 + (top1 and 1 or 0)
	end
	category.samples = category.samples + 1
	return true
end

local function AddSupportRanking(root, scope, sample, participants)
	local category = EnsureCategory(root, scope, "support")
	local supports = {}
	local activeTime = math.max(
		1,
		SafeNumber(sample.bossTime) + SafeNumber(sample.trashTime)
	)
	for _, participant in ipairs(participants) do
		if GetParticipantEligibility(participant, activeTime)
			and participant.role == "SUPPORT" and IsIdentityValid(participant.data)
		then
			supports[#supports + 1] = participant
		end
	end
	if #supports == 0 then
		return false
	end
	local contextKey = BuildContextKey(
		sample,
		"supports=" .. GetEffectiveRoleCount(supports, activeTime)
	)
	for _, participant in ipairs(supports) do
		local stats = participant.stats
		local participation, aliveRate = GetCombatParticipation(participant, activeTime)
		local contribution = SafeNumber(stats.damage)
			+ SafeNumber(stats.effectiveHealing) + SafeNumber(stats.absorbs)
		local entry = EnsureEntry(category, participant.data)
		AddContextMetrics(category, entry, contextKey, {
			contributionRate = contribution / activeTime / participation,
			utilityRate = SafeNumber(stats.utilityActions) / math.max(activeTime / 60, 1),
			clutchRate = SafeNumber(stats.clutchCredit)
				/ math.max(activeTime / 60, 1),
			availability = aliveRate,
		}, math.max(0.10, GetRawCombatParticipation(participant, activeTime)))
	end
	category.samples = category.samples + 1
	return true
end

function PvE.RecordSample(sample, scope, reason)
	local root = InitializeDatabase()
	if not root or not sample or sample.recorded then
		return false
	end
	local now = GetTime()
	CloseCombatSegment(sample, now)
	for _, stats in pairs(sample.players or {}) do
		FinalizeCriticalEpisode(stats, now, false)
		FinalizeCoveredCriticalEpisode(stats, now, false)
	end
	local activeTime = SafeNumber(sample.bossTime) + SafeNumber(sample.trashTime)
	local minimumTime = scope == "raid" and 10 or 30
	if activeTime < minimumTime then
		root.incompleteSamples = root.incompleteSamples + 1
		return false, "combat too short"
	end
	sample.kind = scope
	sample.recorded = true
	local participants = SnapshotParticipants(sample)
	local recorded = false
	for _, targetScope in ipairs({ "all", scope }) do
		local dps = AddDpsRanking(root, targetScope, sample, participants)
		local healing = AddHealingRanking(root, targetScope, sample, participants)
		local tank = AddTankRanking(root, targetScope, sample, participants)
		local support = AddSupportRanking(root, targetScope, sample, participants)
		recorded = dps or healing or tank or support or recorded
	end
	if not recorded then
		root.incompleteSamples = root.incompleteSamples + 1
		return false, "incomplete roles or specializations"
	end
	if scope == "raid" then
		root.totalRaidEncounters = root.totalRaidEncounters + 1
	else
		root.totalDungeonRuns = root.totalDungeonRuns + 1
	end
	root.lastSample = {
		instanceName = sample.instanceName,
		encounterName = sample.encounterName,
		scope = scope,
		reason = reason,
		activeTime = activeTime,
		time = time(),
	}
	if PvE.IsRankingPanelShown and PvE.IsRankingPanelShown() then
		PvE.RefreshPanel()
	end
	return recorded
end

local function BeginEncounter(encounterID, encounterName, source)
	if not session then
		return
	end
	source = source or "official"
	local now = GetTime()
	if session.run then
		if source == "fallback" then
			session.run.fallbackEncounterStarts =
				SafeNumber(session.run.fallbackEncounterStarts) + 1
		else
			session.run.officialEncounterStarts =
				SafeNumber(session.run.officialEncounterStarts) + 1
		end
		CloseCombatSegment(session.run, now)
		StartCombatSegment(session.run, true, now)
	end
	if session.encounter then
		CloseCombatSegment(session.encounter, now)
	end
	session.encounter = NewSample(
		session.context,
		session.context.scope,
		encounterID,
		encounterName
	)
	session.encounter.encounterSource = source
	StartCombatSegment(session.encounter, true, now)
end

local function EndEncounter(encounterID, encounterName, success)
	if not session or not session.encounter then
		return
	end
	local finished = session.encounter
	session.encounter = nil
	finished.encounterID = encounterID or finished.encounterID
	finished.encounterName = encounterName or finished.encounterName
	CloseCombatSegment(finished, GetTime())
	if session.run and finished.encounterSource == "official" then
		session.run.officialEncounterEnds =
			SafeNumber(session.run.officialEncounterEnds) + 1
	end
	if tonumber(success) == 1 or success == true then
		if session.context.scope == "raid" then
			PvE.RecordSample(finished, "raid", "encounter end")
		else
			session.run.bossCount = SafeNumber(session.run.bossCount) + 1
			session.lastBossSuccessAt = GetTime()
		end
	else
		if session.run then
			session.run.wipes = SafeNumber(session.run.wipes) + 1
		end
	end
	if session.run and session.inCombat and IsGroupCombatActive() then
		StartCombatSegment(session.run, false, GetTime())
	end
	if session.completionPendingAt then
		session.completionPendingAt = math.min(
			session.completionPendingAt,
			GetTime() + 0.10
		)
	end
end

function PvE.CompleteDungeon(manual)
	if not session or session.context.scope ~= "dungeon" or not session.run then
		if manual then
			Chat("no active dungeon to finalize")
		end
		return false
	end
	if session.run.recorded then
		if manual then
			Chat("this dungeon was already recorded")
		end
		return false
	end
	local now = GetTime()
	CloseCombatSegment(session.run, now)
	for _, stats in pairs(session.run.players or {}) do
		FinalizeCriticalEpisode(stats, now, false)
		FinalizeCoveredCriticalEpisode(stats, now, false)
	end
	session.run.completionPath = manual and "manual validation"
		or session.completionReason or "completion event"
	local finalSnapshot = BuildCurrentDungeonSnapshot
		and BuildCurrentDungeonSnapshot(true)
	local recorded, reason = PvE.RecordSample(
		session.run,
		"dungeon",
		manual and "manual validation" or "completion event"
	)
	if finalSnapshot then
		finalSnapshot.active = false
		finalSnapshot.finished = recorded and true or false
	end
	if PvE.SaveCurrentDungeon then
		PvE.SaveCurrentDungeon(recorded and true or false, true, finalSnapshot)
	end
	if PvE.SaveDungeonDiagnostic then
		PvE.SaveDungeonDiagnostic(
			manual and "manual validation" or "completion event",
			finalSnapshot
		)
	end
	if manual then
		Chat(recorded and "dungeon recorded" or ("dungeon skipped: " .. tostring(reason)))
	end
	return recorded
end

local function ScheduleDungeonCompletion(reason)
	if not session or session.context.scope ~= "dungeon" or not session.run
		or session.run.recorded
	then
		return
	end
	local now = GetTime()
	session.completionReason = reason or "completion event"
	session.completionPendingAt = now + DUNGEON_COMPLETION_DELAY
	session.completionDeadline = now + DUNGEON_COMPLETION_TIMEOUT
end

local function EnterInstance(context)
	local addonDB = API and API.GetDatabase and API.GetDatabase()
	local diagnosticArmed = context.scope == "dungeon"
		and addonDB and addonDB.pveDiagnosticArmed and true or false
	session = {
		context = context,
		startedAt = GetTime(),
		roster = {},
		petOwners = {},
		summonedPets = {},
		mobs = {},
		diagnosticEnabled = context.scope == "dungeon" and diagnosticArmed,
		diagnosticPendingStart = context.scope == "dungeon" and diagnosticArmed,
	}
	combatIdleElapsed = 0
	healthElapsed = 0
	if diagnosticArmed and addonDB then
		Chat("diagnostic ready: it will start on the first combat")
	end
	if context.scope == "dungeon" then
		session.run = NewSample(context, "dungeon")
	end
	RefreshRoster()
	if context.scope == "dungeon" and PvE.StartCurrentDungeon then
		PvE.StartCurrentDungeon()
	end
	driver:Show()
	NotifyDiagnosticStatus()
end

local function LeaveInstance(loggingOut)
	if not session then
		return
	end
	local old = session
	local completedDuringLeave = false
	-- The completion event is sufficient proof that the last boss is finished.
	-- If the exit teleport arrives before ENCOUNTER_END, consolidate the
	-- encounter first instead of losing the boss and the tail of its log.
	if not loggingOut
		and old.context.scope == "dungeon"
		and old.completionPendingAt
		and old.run
		and not old.run.recorded
	then
		if old.encounter then
			EndEncounter(
				old.encounter.encounterID,
				old.encounter.encounterName,
				true
			)
		end
		completedDuringLeave = PvE.CompleteDungeon(false) and true or false
	end
	local inferredSnapshot
	if not loggingOut
		and old.context.scope == "dungeon"
		and old.run
		and not old.run.recorded
		and SafeNumber(old.run.bossCount) > 0
		and old.lastBossSuccessAt
		and GetTime() - old.lastBossSuccessAt <= 180
	then
		local root = InitializeDatabase()
		local now = GetTime()
		CloseCombatSegment(old.run, now)
		for _, stats in pairs(old.run.players or {}) do
			FinalizeCriticalEpisode(stats, now, false)
			FinalizeCoveredCriticalEpisode(stats, now, false)
		end
		old.run.completionPath = "exit after boss"
		inferredSnapshot = BuildCurrentDungeonSnapshot
			and BuildCurrentDungeonSnapshot(true)
		if root and PvE.RecordSample(old.run, "dungeon", "exit after boss") then
			root.inferredDungeonRuns = root.inferredDungeonRuns + 1
		end
	end
	if old.context.scope == "dungeon"
		and not completedDuringLeave
		and PvE.SaveCurrentDungeon
	then
		PvE.SaveCurrentDungeon(
			loggingOut and false or true,
			true,
			inferredSnapshot
		)
	end
	if old.context.scope == "dungeon"
		and not completedDuringLeave
		and PvE.SaveDungeonDiagnostic
	then
		PvE.SaveDungeonDiagnostic(
			loggingOut and "logout" or "dungeon exit",
			inferredSnapshot
		)
	end
	if old.context.scope == "dungeon"
		and old.diagnosticEnabled
		and not old.diagnosticSaved
	then
		local addonDB = API and API.GetDatabase and API.GetDatabase()
		if addonDB then
			addonDB.pveDiagnosticArmed = true
		end
		if not loggingOut then
			Chat("diagnostic kept for the next real dungeon")
		end
	end
	session = nil
	driver:Hide()
	if PvE.IsSessionPanelShown and PvE.IsSessionPanelShown()
		and PvE.RefreshSessionPanel
	then
		PvE.RefreshSessionPanel()
	end
	NotifyDiagnosticStatus()
end

local function RefreshInstance(loggingOut)
	local context = GetInstanceContext()
	if not context then
		LeaveInstance(loggingOut)
		if not loggingOut and PvE.MarkCurrentDungeonInactive then
			PvE.MarkCurrentDungeonInactive()
		end
		return
	end
	if not session
		or session.context.instanceName ~= context.instanceName
		or session.context.scope ~= context.scope
		or tostring(session.context.difficultyID) ~= tostring(context.difficultyID)
	then
		LeaveInstance(false)
		EnterInstance(context)
	else
		RefreshRoster()
	end
end

local function UpdateDamageWindow(stats, amount)
	local second = math.floor(GetTime())
	if stats.damageSecond ~= second then
		if stats.damageSecond == second - 1 then
			stats.previousSecondDamage = SafeNumber(stats.currentSecondDamage)
		else
			stats.previousSecondDamage = 0
		end
		stats.currentSecondDamage = 0
		stats.damageSecond = second
	end
	stats.currentSecondDamage = SafeNumber(stats.currentSecondDamage) + amount
	stats.maxTwoSecondDamage = math.max(
		SafeNumber(stats.maxTwoSecondDamage),
		SafeNumber(stats.previousSecondDamage) + stats.currentSecondDamage
	)
end

local function MarkMobEngaged(guid)
	if not session or not guid or GetOwnerGUID(guid) then
		return
	end
	local mob = session.mobs[guid]
	if not mob then
		mob = { guid = guid }
		session.mobs[guid] = mob
	end
	if not mob.engagedAt then
		mob.engagedAt = GetTime()
	end
	mob.lastSeen = GetTime()
end

-- Rolling two second window of damage taken. Once a tank has eaten more than
-- TANK_PRESSURE_HEALTH_FRACTION of their health pool inside that window they
-- are flagged as under pressure, and mitigation is accounted separately for
-- the duration. That is what separates a tank who holds cooldowns for the
-- dangerous moments from one who bleeds them on trash.
local function UpdateTakenWindow(stats, incoming, maximumHealth, now)
	local second = math.floor(now)
	if stats.takenSecond ~= second then
		if stats.takenSecond == second - 1 then
			stats.previousSecondTaken = SafeNumber(stats.currentSecondTaken)
		else
			stats.previousSecondTaken = 0
		end
		stats.currentSecondTaken = 0
		stats.takenSecond = second
	end
	stats.currentSecondTaken = SafeNumber(stats.currentSecondTaken) + incoming
	local windowTotal = SafeNumber(stats.previousSecondTaken)
		+ stats.currentSecondTaken
	if maximumHealth > 0
		and windowTotal >= maximumHealth * TANK_PRESSURE_HEALTH_FRACTION
	then
		stats.underPressureUntil = now + TANK_PRESSURE_WINDOW
		session.anyPressureUntil = stats.underPressureUntil
	end
	return stats.underPressureUntil ~= nil and now <= stats.underPressureUntil
end

local function RecordDamage(sourceGUID, destGUID, amount, absorbed, resisted, blocked, spellId)
	if not session or amount <= 0 then
		return
	end
	local sourceOwner = GetOwnerGUID(sourceGUID)
	local destOwner = GetOwnerGUID(destGUID)
	if sourceOwner and not destOwner then
		MarkMobEngaged(destGUID)
	elseif destOwner and not sourceOwner then
		MarkMobEngaged(sourceGUID)
	end
	-- The combat log reports `amount` post-mitigation and the shielded portion
	-- separately in `absorbed`. Details counts both toward damage done, so a
	-- target running absorbs no longer deflates the attacker's output. Damage
	-- taken deliberately stays post-absorb, which is also Details' convention.
	local dealt = amount + math.max(0, SafeNumber(absorbed))
	-- Everything the target's mitigation removed from this hit. `amount` is
	-- already post-mitigation, so raw incoming pressure is the sum of the two.
	local mitigated = math.max(0, SafeNumber(absorbed))
		+ math.max(0, SafeNumber(resisted))
		+ math.max(0, SafeNumber(blocked))
	local now = GetTime()
	local destMember = destOwner and session.roster[destOwner]
	ForSamples(function(sample)
		local member = destMember
		if sourceOwner and not destOwner then
			local stats = GetSampleStats(sample, sourceOwner)
			if stats then
				stats.damage = stats.damage + dealt
				if session.encounter then
					stats.bossDamage = stats.bossDamage + dealt
				else
					stats.trashDamage = stats.trashDamage + dealt
				end
			end
		end
		if destOwner then
			sample.groupDamageTaken = sample.groupDamageTaken + amount
			local stats = GetSampleStats(sample, destOwner)
			if stats then
				stats.damageTaken = stats.damageTaken + amount
				if stats.healerCoverageCurrentlyAssessable then
					if stats.healerCurrentlyCovered then
						stats.healerCoveredDamageTaken =
							SafeNumber(stats.healerCoveredDamageTaken) + amount
					else
						stats.healerUncoveredDamageTaken =
							SafeNumber(stats.healerUncoveredDamageTaken) + amount
					end
				end
				if member then
					member.damagedSinceSample = true
				end
				stats.damageTakenRaw = SafeNumber(stats.damageTakenRaw)
					+ amount + mitigated
				stats.damageMitigated = SafeNumber(stats.damageMitigated) + mitigated
				stats.incomingAttacks = SafeNumber(stats.incomingAttacks) + 1
				local underPressure = UpdateTakenWindow(
					stats,
					amount + mitigated,
					SafeNumber(member and member.maxHealth),
					now
				)
				if underPressure then
					stats.pressureDamageTaken = SafeNumber(stats.pressureDamageTaken)
						+ amount + mitigated
					stats.pressureDamageMitigated =
						SafeNumber(stats.pressureDamageMitigated) + mitigated
				end
				if stats.tankingNow then
					stats.tankDamage = stats.tankDamage + amount
					UpdateDamageWindow(stats, amount)
				elseif not sourceOwner then
					RecordRepeatedHit(stats, spellId, amount + mitigated)
				end
			end
			if absorbed and absorbed > 0 then
				sample.unattributedAbsorb = sample.unattributedAbsorb + absorbed
			end
		end
	end)
end

-- SPELL_HEAL fires after the health has already been applied, so the health
-- the target was actually sitting at when the cast landed is reconstructed by
-- removing the restored amount again. Absorbs prevent damage instead of
-- restoring health, so for those the current value is already the right one.
local function GetClutchHealthFraction(targetGUID, restored)
	-- A cached-health pre-filter was tried here to skip the health API on heals
	-- that top off a healthy target. It was removed: health can fall without an
	-- attributable damage event, so the filter produced false negatives on real
	-- saves, and the measured cost it avoided was not detectable. Correctness
	-- wins over a micro-optimization on a path that is already sub-microsecond.
	local member = session and session.roster[targetGUID]
	if not member then
		return
	end
	local unit = member.unit
	if not unit or not IsValidRosterUnit(targetGUID, member) then
		return
	end
	-- Maximum health is refreshed twice a second by the sampler; reading it
	-- again per heal would double the API cost for a value that barely moves.
	local maximum = SafeNumber(member.maxHealth)
	if maximum <= 0 then
		maximum = tonumber(UnitHealthMax(unit)) or 0
	end
	if maximum <= 0 then
		return
	end
	local current = tonumber(UnitHealth(unit)) or 0
	if current <= 0 then
		return
	end
	local before = math.max(0, current - math.max(0, SafeNumber(restored)))
	return Clamp(before / maximum, 0, 1), maximum
end

-- Credit scales on two axes: how close to death the target was, and how much
-- of their health pool the heal actually returned. A trivial tick on someone at
-- 34% is worth almost nothing; a large heal on someone at 8% is worth a full
-- point. Self-heals are tracked but never rewarded, because surviving your own
-- mistake is not the same as saving someone else.
local function RecordClutchHeal(sourceOwner, destOwner, effective, restored)
	if not session or effective <= 0 then
		return
	end
	local beforePct, maximum = GetClutchHealthFraction(destOwner, restored)
	if not beforePct or beforePct > CLUTCH_HEALTH_THRESHOLD then
		return
	end
	local healFraction = effective / maximum
	if healFraction < CLUTCH_MIN_HEAL_FRACTION then
		return
	end

	local severity = Clamp(
		(CLUTCH_HEALTH_THRESHOLD - beforePct) / CLUTCH_HEALTH_THRESHOLD,
		0,
		1
	)
	local magnitude = Clamp(healFraction / CLUTCH_FULL_CREDIT_FRACTION, 0, 1)
	local credit = Clamp(severity * magnitude, 0, 1)
	local isSelf = sourceOwner == destOwner
	local isLifeSave = beforePct <= LIFESAVE_HEALTH_THRESHOLD
		and healFraction >= LIFESAVE_MIN_HEAL_FRACTION
	local targetRole = GetRole(session.roster[destOwner])

	ForSamples(function(sample)
		local sourceStats = GetSampleStats(sample, sourceOwner)
		if sourceStats then
			if isSelf then
				sourceStats.clutchSelfHeals =
					SafeNumber(sourceStats.clutchSelfHeals) + 1
			else
				sourceStats.clutchHeals = SafeNumber(sourceStats.clutchHeals) + 1
				sourceStats.clutchHealing =
					SafeNumber(sourceStats.clutchHealing) + effective
				sourceStats.clutchCredit =
					SafeNumber(sourceStats.clutchCredit) + credit
				if isLifeSave then
					sourceStats.lifeSaves = SafeNumber(sourceStats.lifeSaves) + 1
				end
				if targetRole == "TANK" then
					sourceStats.clutchHealsOnTank =
						SafeNumber(sourceStats.clutchHealsOnTank) + 1
				elseif targetRole == "HEALER" then
					sourceStats.clutchHealsOnHealer =
						SafeNumber(sourceStats.clutchHealsOnHealer) + 1
				end
			end
		end
		if not isSelf then
			local destStats = GetSampleStats(sample, destOwner)
			if destStats then
				destStats.clutchRescuedBy =
					SafeNumber(destStats.clutchRescuedBy) + 1
			end
		end
	end)
end

local function RecordHealing(sourceGUID, destGUID, amount, overhealing)
	if not session or amount <= 0 then
		return
	end
	if not session.inCombat and IsGroupCombatActive() then
		StartCombat()
	end
	if not session.inCombat then
		return
	end
	local sourceOwner = GetOwnerGUID(sourceGUID)
	local destOwner = GetOwnerGUID(destGUID)
	if not sourceOwner or not destOwner then
		return
	end
	local effective = math.max(0, amount - math.max(0, overhealing or 0))
	ForSamples(function(sample)
		local sourceStats = GetSampleStats(sample, sourceOwner)
		local destStats = GetSampleStats(sample, destOwner)
		if sourceStats then
			sourceStats.rawHealing = sourceStats.rawHealing + amount
			sourceStats.effectiveHealing = sourceStats.effectiveHealing + effective
			local targetMember = session.roster[destOwner]
			if GetRole(targetMember) == "TANK" then
				sourceStats.tankTargetHealing = sourceStats.tankTargetHealing + effective
			end
		end
		if destStats and destStats.tankingNow and sourceOwner ~= destOwner then
			destStats.externalSupport = destStats.externalSupport + effective
		end
		if destStats and sourceOwner == destOwner then
			destStats.selfHealing = SafeNumber(destStats.selfHealing) + effective
			if destStats.tankingNow then
				destStats.tankingSelfSustain =
					SafeNumber(destStats.tankingSelfSustain) + effective
			end
		end
	end)
	RecordClutchHeal(sourceOwner, destOwner, effective, effective)
end

local function RecordAbsorb(destGUID, absorberGUID, amount)
	if not session then
		return
	end
	if not session.inCombat and IsGroupCombatActive() then
		StartCombat()
	end
	if not session.inCombat then
		return
	end
	local absorberOwner = GetOwnerGUID(absorberGUID)
	local destOwner = GetOwnerGUID(destGUID)
	if not absorberOwner or not destOwner or amount <= 0 then
		return
	end
	ForSamples(function(sample)
		local sourceStats = GetSampleStats(sample, absorberOwner)
		local destStats = GetSampleStats(sample, destOwner)
		if sourceStats then
			sourceStats.absorbs = sourceStats.absorbs + amount
			if GetRole(session.roster[destOwner]) == "TANK" then
				sourceStats.tankTargetHealing = sourceStats.tankTargetHealing + amount
			end
		end
		if destStats and destStats.tankingNow and absorberOwner ~= destOwner then
			destStats.externalSupport = destStats.externalSupport + amount
		end
		if destStats and absorberOwner == destOwner then
			destStats.selfAbsorbs = SafeNumber(destStats.selfAbsorbs) + amount
			if destStats.tankingNow then
				destStats.tankingSelfSustain =
					SafeNumber(destStats.tankingSelfSustain) + amount
			end
		end
	end)
	RecordClutchHeal(absorberOwner, destOwner, amount, 0)
end

-- A dodged, parried, blocked or missed swing is mitigation the tank earned
-- through stats and positioning. Details tracks the same events in its
-- avoidance table.
local AVOIDED_MISS_TYPES = {
	DODGE = true,
	PARRY = true,
	BLOCK = true,
	MISS = true,
	ABSORB = true,
	IMMUNE = true,
	DEFLECT = true,
}

local function RecordAvoidance(destGUID, missType)
	if not session or not session.inCombat then
		return
	end
	local destOwner = GetOwnerGUID(destGUID)
	if not destOwner then
		return
	end
	local avoided = AVOIDED_MISS_TYPES[tostring(missType or ""):upper()] and true or false
	ForSamples(function(sample)
		local stats = GetSampleStats(sample, destOwner)
		if stats then
			stats.incomingAttacks = SafeNumber(stats.incomingAttacks) + 1
			if avoided then
				stats.avoidedAttacks = SafeNumber(stats.avoidedAttacks) + 1
			end
		end
	end)
end

-- The client exposes no reliable way to tell a defensive cooldown from any
-- other self-cast, so this stays a raw diagnostic count and is never scored.
-- The scored signal is the measured mitigation outcome above.
local function RecordDefensiveCast(sourceGUID, destGUID)
	-- SPELL_CAST_SUCCESS is one of the highest volume subevents in the log and
	-- this counter only means anything inside a pressure window. Bail on a
	-- single number compare rather than paying for a closure per cast.
	if not session or not session.inCombat
		or not session.anyPressureUntil
		or GetTime() > session.anyPressureUntil
	then
		return
	end
	local owner = GetOwnerGUID(sourceGUID)
	if not owner or (destGUID and destGUID ~= sourceGUID) then
		return
	end
	ForSamples(function(sample)
		local stats = GetSampleStats(sample, owner)
		if stats and stats.underPressureUntil
			and GetTime() <= stats.underPressureUntil
		then
			stats.defensiveCastsUnderPressure =
				SafeNumber(stats.defensiveCastsUnderPressure) + 1
		end
	end)
end

-- Mob casts are tracked start-to-resolution so interrupts can be expressed as
-- coverage rather than a raw count. Only one cast per mob is ever in flight, so
-- the table is naturally bounded by the number of engaged mobs.
local function RecordMobCastStart(sourceGUID)
	if not session or not sourceGUID or GetOwnerGUID(sourceGUID) then
		return
	end
	session.mobCasts = session.mobCasts or {}
	session.mobCasts[sourceGUID] = GetTime()
end

local function RecordMobCastEnd(sourceGUID, interrupted)
	if not session or not sourceGUID then
		return
	end
	local casts = session.mobCasts
	if not casts or not casts[sourceGUID] then
		return
	end
	casts[sourceGUID] = nil
	ForSamples(function(sample)
		if interrupted then
			sample.mobCastsInterrupted = SafeNumber(sample.mobCastsInterrupted) + 1
		else
			sample.mobCastsCompleted = SafeNumber(sample.mobCastsCompleted) + 1
		end
	end)
end

-- Damage the player was hit by repeatedly from one spell inside a single pull.
-- The first two hits are free; a mechanic can legitimately catch someone once.
-- Past that it is the strongest avoidable-damage signal available without a
-- per-spell database, which a custom client cannot provide.
RecordRepeatedHit = function(stats, spellId, amount)
	if not spellId or amount <= 0 or stats.tankingNow then
		return
	end
	local hits = stats.spellHits
	if not hits then
		hits = { count = 0 }
		stats.spellHits = hits
	end
	local seen = hits[spellId]
	if not seen then
		if hits.count >= REPEAT_HIT_MAX_TRACKED_SPELLS then
			return
		end
		hits.count = hits.count + 1
		seen = 0
	end
	seen = seen + 1
	hits[spellId] = seen
	if seen > REPEAT_HIT_FREE_HITS then
		stats.repeatedHitDamage = SafeNumber(stats.repeatedHitDamage) + amount
		stats.repeatedHitCount = SafeNumber(stats.repeatedHitCount) + 1
	end
end

local function RecordUtility(sourceGUID, kind)
	if not session then
		return
	end
	if not session.inCombat and IsGroupCombatActive() then
		StartCombat()
	end
	if not session.inCombat then
		return
	end
	local owner = GetOwnerGUID(sourceGUID)
	if not owner then
		return
	end
	ForSamples(function(sample)
		local stats = GetSampleStats(sample, owner)
		if stats then
			stats.utilityActions = SafeNumber(stats.utilityActions) + 1
			if kind == "interrupt" then
				stats.interrupts = SafeNumber(stats.interrupts) + 1
			elseif kind == "dispel" then
				stats.dispels = SafeNumber(stats.dispels) + 1
			end
		end
	end)
end

local function GetDeathContext(now)
	local current = 0
	local dead = 0
	for guid, member in pairs(session and session.roster or {}) do
		if IsValidRosterUnit(guid, member) then
			current = current + 1
			if type(UnitIsDeadOrGhost) == "function"
				and UnitIsDeadOrGhost(member.unit)
			then
				dead = dead + 1
			end
		end
	end
	session.recentGroupDeaths = type(session.recentGroupDeaths) == "table"
		and session.recentGroupDeaths or {}
	local recent = {}
	for _, deathAt in ipairs(session.recentGroupDeaths) do
		if now - SafeNumber(deathAt) <= 10 then
			recent[#recent + 1] = deathAt
		end
	end
	recent[#recent + 1] = now
	session.recentGroupDeaths = recent
	local clustered = session.context.scope == "dungeon" and #recent >= 2
	local majorityDead = session.context.scope == "dungeon"
		and current >= 3 and dead >= math.ceil(current / 2)
	local wasRecovering = session.recoveryActive and true or false
	local recovery = wasRecovering or clustered or majorityDead
	if recovery and not wasRecovering then
		session.recoveryActive = true
		session.recoveryStartedAt = now
	end
	return {
		inCombat = session.inCombat and true or false,
		recovery = recovery,
		startedRecovery = recovery and not wasRecovering,
		clustered = clustered,
		majorityDead = majorityDead,
		current = current,
		dead = dead,
	}
end

local function RecordDeath(destGUID)
	if not session then
		return
	end
	-- A pet's death must never be counted as its owner's. Only GUIDs present
	-- directly in the roster are player characters.
	local rosterMember = session.roster[destGUID]
	local owner = rosterMember
		and (rosterMember.present or IsValidRosterUnit(destGUID, rosterMember))
		and destGUID
	if owner then
		local now = GetTime()
		local deathContext = GetDeathContext(now)
		ForSamples(function(sample)
			sample.deaths = sample.deaths + 1
			if deathContext.startedRecovery then
				sample.wipeLikeEvents = SafeNumber(sample.wipeLikeEvents) + 1
			end
			local stats = GetSampleStats(sample, owner)
			if stats then
				local criticalDuration = stats.criticalStartedAt
					and math.max(0, now - stats.criticalStartedAt) or 0
				local coverageAssessable =
					SafeNumber(stats.healerCoverageAssessableSeconds) > 0
				local healerCouldAct = not coverageAssessable
					or stats.coveredCriticalStartedAt ~= nil
				local preventable = deathContext.inCombat
					and not deathContext.recovery
					and criticalDuration >= 1.5
					and healerCouldAct
				if preventable then
					stats.preventableDeaths = SafeNumber(stats.preventableDeaths) + 1
					sample.preventableDeaths = SafeNumber(sample.preventableDeaths) + 1
				elseif criticalDuration < 1.5 and deathContext.inCombat
					and not deathContext.recovery
				then
					stats.oneShotDeaths = SafeNumber(stats.oneShotDeaths) + 1
					sample.oneShotDeaths = SafeNumber(sample.oneShotDeaths) + 1
				elseif not deathContext.inCombat then
					stats.nonCombatDeaths = SafeNumber(stats.nonCombatDeaths) + 1
					sample.nonCombatDeaths = SafeNumber(sample.nonCombatDeaths) + 1
				elseif deathContext.recovery then
					stats.recoveryDeaths = SafeNumber(stats.recoveryDeaths) + 1
					sample.recoveryDeaths = SafeNumber(sample.recoveryDeaths) + 1
				elseif coverageAssessable and not healerCouldAct then
					stats.outOfReachDeaths = SafeNumber(stats.outOfReachDeaths) + 1
					sample.outOfReachDeaths = SafeNumber(sample.outOfReachDeaths) + 1
				end
				if preventable and stats.coveredCriticalStartedAt then
					FinalizeCoveredCriticalEpisode(stats, now, true)
				else
					CancelCoveredCriticalEpisode(stats)
				end
				FinalizeCriticalEpisode(stats, now, preventable)
				stats.deaths = stats.deaths + 1
			end
		end)
	else
		local mob = session.mobs[destGUID]
		if mob and (mob.classification == "worldboss" or mob.classification == "rareelite") then
			if session.encounter and session.encounter.fallback then
				session.encounter.bossKilled = true
				session.encounter.encounterName = mob.name or session.encounter.encounterName
			end
		end
	end
end

local function ParseCombatLog(...)
	if not session then
		return
	end
	local timestamp, subevent, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11 = ...
	local sourceGUID, sourceName, destGUID, destName, extraIndex
	if type(arg3) == "boolean" then
		sourceGUID = arg4
		sourceName = arg5
		destGUID = arg8
		destName = arg9
		extraIndex = 12
	else
		sourceGUID = arg3
		sourceName = arg4
		destGUID = arg6
		destName = arg7
		extraIndex = 9
	end
	if not subevent then
		return
	end
	SetRosterMemberName(session.roster[sourceGUID], sourceName)
	SetRosterMemberName(session.roster[destGUID], destName)
	if not session.inCombat and (
		subevent == "SWING_DAMAGE"
		or subevent == "SPELL_DAMAGE"
		or subevent == "SPELL_PERIODIC_DAMAGE"
		or subevent == "RANGE_DAMAGE"
		or subevent == "DAMAGE_SHIELD"
		or subevent == "DAMAGE_SPLIT"
		or subevent == "ENVIRONMENTAL_DAMAGE"
	) and (GetOwnerGUID(sourceGUID) or GetOwnerGUID(destGUID)) then
		StartCombat()
	end

	if subevent == "SWING_DAMAGE" then
		local amount = SafeNumber(select(extraIndex, ...))
		local resisted = SafeNumber(select(extraIndex + 3, ...))
		local blocked = SafeNumber(select(extraIndex + 4, ...))
		local absorbed = SafeNumber(select(extraIndex + 5, ...))
		RecordDamage(sourceGUID, destGUID, amount, absorbed, resisted, blocked)
	elseif subevent == "SPELL_DAMAGE"
		or subevent == "SPELL_PERIODIC_DAMAGE"
		or subevent == "RANGE_DAMAGE"
		or subevent == "DAMAGE_SHIELD"
		or subevent == "DAMAGE_SPLIT"
	then
		local amount = SafeNumber(select(extraIndex + 3, ...))
		local resisted = SafeNumber(select(extraIndex + 6, ...))
		local blocked = SafeNumber(select(extraIndex + 7, ...))
		local absorbed = SafeNumber(select(extraIndex + 8, ...))
		RecordDamage(
			sourceGUID, destGUID, amount, absorbed, resisted, blocked,
			select(extraIndex, ...)
		)
	elseif subevent == "ENVIRONMENTAL_DAMAGE" then
		RecordDamage(sourceGUID, destGUID, SafeNumber(select(extraIndex + 1, ...)), 0)
	elseif subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL" then
		local amount = SafeNumber(select(extraIndex + 3, ...))
		local overhealing = SafeNumber(select(extraIndex + 4, ...))
		RecordHealing(sourceGUID, destGUID, amount, overhealing)
	elseif subevent == "SPELL_ABSORBED" then
		local absorberGUID
		local amount = 0
		local count = select("#", ...)
		for index = extraIndex, count do
			local value = select(index, ...)
			if type(value) == "string" and GetOwnerGUID(value) then
				absorberGUID = value
			elseif type(value) == "number" and index == count then
				amount = SafeNumber(value)
			end
		end
		RecordAbsorb(destGUID, absorberGUID, amount)
	elseif subevent == "SWING_MISSED" then
		RecordAvoidance(destGUID, select(extraIndex, ...))
	elseif subevent == "SPELL_MISSED"
		or subevent == "RANGE_MISSED"
		or subevent == "SPELL_PERIODIC_MISSED"
	then
		RecordAvoidance(destGUID, select(extraIndex + 3, ...))
	elseif subevent == "SPELL_CAST_START" then
		RecordMobCastStart(sourceGUID)
	elseif subevent == "SPELL_CAST_SUCCESS" then
		RecordMobCastEnd(sourceGUID, false)
		RecordDefensiveCast(sourceGUID, destGUID)
	elseif subevent == "SPELL_CAST_FAILED" then
		RecordMobCastEnd(sourceGUID, false)
	elseif subevent == "SPELL_INTERRUPT" then
		RecordMobCastEnd(destGUID, true)
		RecordUtility(sourceGUID, "interrupt")
	elseif subevent == "SPELL_DISPEL" or subevent == "SPELL_STOLEN" then
		RecordUtility(sourceGUID, "dispel")
	elseif subevent == "UNIT_DIED" or subevent == "UNIT_DESTROYED" then
		RecordDeath(destGUID)
	elseif subevent == "SPELL_SUMMON" or subevent == "SPELL_CREATE" then
		local owner = GetOwnerGUID(sourceGUID)
		if owner and destGUID then
			session.petOwners[destGUID] = owner
			session.summonedPets = session.summonedPets or {}
			session.summonedPets[destGUID] = true
		end
	end
end

local function AddMobToken(tokens, seen, unit)
	if #tokens >= MAX_NAMEPLATE_UNITS
		or not UnitExists(unit)
		or UnitIsPlayer(unit)
		or not UnitCanAttack("player", unit)
	then
		return
	end
	local guid = UnitGUID(unit)
	if guid and not seen[guid] then
		seen[guid] = true
		tokens[#tokens + 1] = { guid = guid, unit = unit }
	end
end

local function CollectMobTokens()
	local tokens, seen = {}, {}
	for _, unit in ipairs({ "target", "focus", "mouseover" }) do
		AddMobToken(tokens, seen, unit)
	end
	for index = 1, 5 do
		AddMobToken(tokens, seen, "boss" .. index)
	end
	for index = 1, 40 do
		AddMobToken(tokens, seen, "raid" .. index .. "target")
	end
	for index = 1, 4 do
		AddMobToken(tokens, seen, "party" .. index .. "target")
	end
	for index = 1, MAX_NAMEPLATE_UNITS do
		AddMobToken(tokens, seen, "nameplate" .. index)
	end
	return tokens
end

IsValidRosterUnit = function(guid, member)
	local unit = member and member.unit
	return unit and UnitExists(unit) and UnitGUID(unit) == guid
end

local function GetSoloLocalHealerCoverage(targetGUID, targetUnit)
	local healerGUID
	local healerUnit
	local healerCount = 0
	for guid, member in pairs(session and session.roster or {}) do
		if IsValidRosterUnit(guid, member) and GetRole(member) == "HEALER" then
			healerCount = healerCount + 1
			healerGUID = guid
			healerUnit = member.unit
		end
	end
	if healerCount ~= 1 or not healerUnit
		or not UnitIsUnit(healerUnit, "player")
	then
		return true, false
	end
	if type(UnitIsDeadOrGhost) == "function" and UnitIsDeadOrGhost(healerUnit) then
		return false, true
	end
	if targetGUID == healerGUID then
		return true, true
	end
	if type(UnitInRange) == "function" then
		local success, inRange = pcall(UnitInRange, targetUnit)
		if success then
			return (inRange == true or inRange == 1), true
		end
	end
	return true, false
end

local function UpdateRecoveryState(now)
	if not session or not session.recoveryActive then
		return
	end
	local current = 0
	local alive = 0
	for guid, member in pairs(session.roster or {}) do
		if IsValidRosterUnit(guid, member) then
			current = current + 1
			local dead = type(UnitIsDeadOrGhost) == "function"
				and UnitIsDeadOrGhost(member.unit)
			if not dead then
				alive = alive + 1
			end
		end
	end
	if (current > 0 and alive == current
		and now - SafeNumber(session.recoveryStartedAt) >= 5)
		or now - SafeNumber(session.recoveryStartedAt) >= 120
	then
		session.recoveryActive = false
		session.recoveryStartedAt = nil
		session.recentGroupDeaths = {}
	end
end

local function SampleGroupHealth(elapsed)
	if not session or not session.inCombat then
		return
	end
	local now = GetTime()
	UpdateRecoveryState(now)
	for guid, member in pairs(session.roster) do
		local unit = member.unit
		local validUnit = unit and UnitExists(unit) and UnitGUID(unit) == guid
		local dead = validUnit and type(UnitIsDeadOrGhost) == "function"
			and UnitIsDeadOrGhost(unit)
		if validUnit then
			ForSamples(function(sample)
				local stats = GetSampleStats(sample, guid)
				if stats then
					stats.combatObservedSeconds =
						SafeNumber(stats.combatObservedSeconds) + elapsed
					if not dead then
						stats.aliveCombatSeconds =
							SafeNumber(stats.aliveCombatSeconds) + elapsed
					end
					if GetRole(member) == "HEALER" and not session.recoveryActive then
						stats.healerScorableCombatSeconds =
							SafeNumber(stats.healerScorableCombatSeconds) + elapsed
						if not dead then
							stats.healerScorableAliveSeconds =
								SafeNumber(stats.healerScorableAliveSeconds) + elapsed
						end
					end
					if sample.combatIsBoss then
						stats.bossObservedSeconds =
							SafeNumber(stats.bossObservedSeconds) + elapsed
					else
						stats.trashObservedSeconds =
							SafeNumber(stats.trashObservedSeconds) + elapsed
					end
				end
			end)
		end
		if validUnit and not dead then
			local healerCovered, healerCoverageAssessable =
				GetSoloLocalHealerCoverage(guid, unit)
			local maximum = UnitHealthMax(unit)
			local current = UnitHealth(unit)
			if maximum and maximum > 0 and current and current >= 0 then
				local percent = Clamp(current / maximum, 0, 1)
				member.maxHealth = maximum
				member.lastHealthPct = percent
				member.damagedSinceSample = nil
				ForSamples(function(sample)
					local stats = GetSampleStats(sample, guid)
					if stats then
						stats.healthObservedSeconds = SafeNumber(stats.healthObservedSeconds) + elapsed
						stats.healthPctSeconds = SafeNumber(stats.healthPctSeconds) + percent * elapsed
						stats.minHealthPct = math.min(
							SafeNumber(stats.minHealthPct) > 0 and stats.minHealthPct or 1,
							percent
						)
						if percent < 0.75 then
							stats.below75Seconds = SafeNumber(stats.below75Seconds) + elapsed
						end
						if percent < 0.50 then
							stats.below50Seconds = SafeNumber(stats.below50Seconds) + elapsed
							if not stats.criticalStartedAt then
								stats.criticalStartedAt = now
								stats.urgentRecovered = false
								stats.criticalEpisodes = SafeNumber(stats.criticalEpisodes) + 1
							end
						end
						if percent < 0.25 then
							stats.below25Seconds = SafeNumber(stats.below25Seconds) + elapsed
						end
						if stats.criticalStartedAt
							and percent >= URGENT_RECOVERY_THRESHOLD
						then
							RecordUrgentRecovery(stats, now)
						end
						if stats.criticalStartedAt and percent >= 0.80 then
							FinalizeCriticalEpisode(stats, now, false)
						end
						if healerCoverageAssessable then
							stats.healerCoverageCurrentlyAssessable = true
							stats.healerCurrentlyCovered = healerCovered and true or false
							stats.healerCoverageAssessableSeconds =
								SafeNumber(stats.healerCoverageAssessableSeconds) + elapsed
							if healerCovered then
								stats.healerCoveredHealthObservedSeconds =
									SafeNumber(stats.healerCoveredHealthObservedSeconds) + elapsed
								stats.healerCoveredMinHealthPct = math.min(
									SafeNumber(stats.healerCoveredMinHealthPct) > 0
										and stats.healerCoveredMinHealthPct or 1,
									percent
								)
								if percent < 0.75 then
									stats.healerCoveredBelow75Seconds =
										SafeNumber(stats.healerCoveredBelow75Seconds) + elapsed
								end
								if percent < 0.50 then
									stats.healerCoveredBelow50Seconds =
										SafeNumber(stats.healerCoveredBelow50Seconds) + elapsed
									if not stats.coveredCriticalStartedAt then
										stats.coveredCriticalStartedAt = now
										stats.coveredUrgentRecovered = false
										stats.coveredCriticalEpisodes =
											SafeNumber(stats.coveredCriticalEpisodes) + 1
									end
								end
								if percent < 0.25 then
									stats.healerCoveredBelow25Seconds =
										SafeNumber(stats.healerCoveredBelow25Seconds) + elapsed
								end
								if stats.coveredCriticalStartedAt
									and percent >= URGENT_RECOVERY_THRESHOLD
								then
									RecordCoveredUrgentRecovery(stats, now)
								end
								if stats.coveredCriticalStartedAt and percent >= 0.80 then
									FinalizeCoveredCriticalEpisode(stats, now, false)
								end
							else
								stats.healerOutOfRangeSeconds =
									SafeNumber(stats.healerOutOfRangeSeconds) + elapsed
								CancelCoveredCriticalEpisode(stats)
							end
						end
						if not healerCoverageAssessable then
							stats.healerCoverageCurrentlyAssessable = nil
							stats.healerCurrentlyCovered = nil
						end
					end
				end)
			end

			if GetRole(member) == "HEALER"
				and type(UnitManaMax) == "function"
				and type(UnitMana) == "function"
			then
				local manaMaximum = UnitManaMax(unit)
				local manaCurrent = UnitMana(unit)
				if manaMaximum and manaMaximum > 0 and manaCurrent
					and manaCurrent >= 0
				then
					local manaPercent = Clamp(manaCurrent / manaMaximum, 0, 1)
					ForSamples(function(sample)
						local stats = GetSampleStats(sample, guid)
						if stats then
							stats.manaObservedSeconds =
								SafeNumber(stats.manaObservedSeconds) + elapsed
							stats.manaPctSeconds = SafeNumber(stats.manaPctSeconds)
								+ manaPercent * elapsed
							stats.minManaPct = math.min(
								stats.minManaPct == nil and 1 or SafeNumber(stats.minManaPct),
								manaPercent
							)
							stats.lastManaPct = manaPercent
							if manaPercent < 0.20 then
								stats.below20ManaSeconds =
									SafeNumber(stats.below20ManaSeconds) + elapsed
							end
							if manaPercent < 0.10 then
								stats.below10ManaSeconds =
									SafeNumber(stats.below10ManaSeconds) + elapsed
							end
						end
					end)
				end
			end
		end
	end
end

local function SampleThreat(elapsed)
	if not session or not session.inCombat or type(UnitDetailedThreatSituation) ~= "function" then
		return
	end
	local tanks = {}
	for guid, member in pairs(session.roster) do
		if GetRole(member) == "TANK" and member.unit and UnitExists(member.unit) then
			tanks[#tanks + 1] = { guid = guid, unit = member.unit, member = member }
		end
	end
	if #tanks == 0 then
		return
	end

	local now = GetTime()
	local tankingNow = {}
	local seen = {}
	for _, mobToken in ipairs(CollectMobTokens()) do
		seen[mobToken.guid] = true
		local mob = session.mobs[mobToken.guid]
		if not mob then
			mob = {
				guid = mobToken.guid,
				firstSeen = now,
				name = UnitName(mobToken.unit),
				classification = UnitClassification(mobToken.unit),
			}
			session.mobs[mobToken.guid] = mob
		else
			mob.firstSeen = mob.firstSeen or now
			mob.name = mob.name or UnitName(mobToken.unit)
			mob.classification = mob.classification
				or UnitClassification(mobToken.unit)
		end
		mob.lastSeen = now
		if mob.classification == "worldboss"
			and session.context.scope == "dungeon"
			and not session.encounter
		then
			BeginEncounter(nil, mob.name or "Boss detecte", "fallback")
			if session.encounter then
				session.encounter.fallback = true
			end
		end
		local holder
		for _, tank in ipairs(tanks) do
			local success, isTanking, status = pcall(
				UnitDetailedThreatSituation,
				tank.unit,
				mobToken.unit
			)
			if success and (isTanking or status == 2 or status == 3) then
				holder = tank
				break
			end
		end

		if holder then
			if mob.ownerGUID ~= holder.guid then
				local pickupStartedAt = mob.ownerGUID
					and mob.lossStartedAt or mob.engagedAt
				mob.ownerGUID = holder.guid
				local pickup = pickupStartedAt
					and math.max(0, now - pickupStartedAt) or 0
				ForSamples(function(sample)
					local stats = GetSampleStats(sample, holder.guid)
					if stats then
						stats.pickupTotal = stats.pickupTotal + math.min(pickup, 10)
						stats.pickupCount = stats.pickupCount + 1
					end
				end)
			end
			mob.lossStartedAt = nil
			mob.lossCounted = nil
			tankingNow[holder.guid] = true
			ForSamples(function(sample)
				local stats = GetSampleStats(sample, holder.guid)
				if stats then
					stats.responsibilitySeconds = stats.responsibilitySeconds + elapsed
					stats.controlledSeconds = stats.controlledSeconds + elapsed
				end
			end)
		elseif mob.ownerGUID and session.roster[mob.ownerGUID] then
			mob.lossStartedAt = mob.lossStartedAt or now
			ForSamples(function(sample)
				local stats = GetSampleStats(sample, mob.ownerGUID)
				if stats then
					stats.responsibilitySeconds = stats.responsibilitySeconds + elapsed
					if now - mob.lossStartedAt >= LOSS_GRACE then
						stats.lossSeconds = stats.lossSeconds + elapsed
						if not mob.lossCounted then
							stats.threatLossEvents =
								SafeNumber(stats.threatLossEvents) + 1
						end
					end
				end
			end)
			if now - mob.lossStartedAt >= LOSS_GRACE then
				mob.lossCounted = true
			end
		end
	end

	for _, tank in ipairs(tanks) do
		ForSamples(function(sample)
			local stats = GetSampleStats(sample, tank.guid)
			if stats then
				stats.tankingNow = tankingNow[tank.guid] and true or false
				if tankingNow[tank.guid] then
					local maxHealth = UnitHealthMax(tank.unit)
					if maxHealth and maxHealth > 0 then
						tank.member.maxHealth = maxHealth
						stats.healthSeconds = stats.healthSeconds + maxHealth * elapsed
					end
					stats.tankingWallSeconds = stats.tankingWallSeconds + elapsed
				end
			end
		end)
	end

	for guid, mob in pairs(session.mobs) do
		if not seen[guid] and now - SafeNumber(mob.lastSeen) > MOB_FORGET_DELAY then
			session.mobs[guid] = nil
		end
	end
end

local function RegisterOptionalEvent(event)
	pcall(driver.RegisterEvent, driver, event)
end

driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_LOGOUT")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
driver:RegisterEvent("RAID_ROSTER_UPDATE")
driver:RegisterEvent("PARTY_MEMBERS_CHANGED")
driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
RegisterOptionalEvent("ENCOUNTER_START")
RegisterOptionalEvent("ENCOUNTER_END")
RegisterOptionalEvent("LFG_COMPLETION_REWARD")
RegisterOptionalEvent("CHALLENGE_MODE_COMPLETED")
RegisterOptionalEvent("UNIT_NAME_UPDATE")

driver:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		InitializeDatabase()
		RefreshInstance(false)
	elseif event == "PLAYER_LOGOUT" then
		LeaveInstance(true)
	elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
		RefreshInstance(false)
	elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
		RefreshRoster()
	elseif event == "UNIT_NAME_UPDATE" then
		RefreshRoster()
	elseif event == "PLAYER_REGEN_DISABLED" then
		StartCombat()
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- When the local player dies, their group may still be fighting. The
		-- group loop decides the real end of the segment.
		combatIdleElapsed = 0
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		ParseCombatLog(...)
	elseif event == "ENCOUNTER_START" then
		local encounterID, encounterName = ...
		BeginEncounter(encounterID, encounterName, "official")
	elseif event == "ENCOUNTER_END" then
		local encounterID, encounterName, difficultyID, groupSize, success = ...
		EndEncounter(encounterID, encounterName, success)
	elseif event == "LFG_COMPLETION_REWARD" or event == "CHALLENGE_MODE_COMPLETED" then
		ScheduleDungeonCompletion("completion event")
	end
end)

driver:SetScript("OnUpdate", function(_, elapsed)
	if not session or not IsPvEInstance() then
		return
	end
	UpdateRecoveryState(GetTime())
	if IsGroupCombatActive() then
		combatIdleElapsed = 0
		if not session.inCombat then
			StartCombat()
		end
	elseif session.inCombat then
		combatIdleElapsed = combatIdleElapsed + elapsed
		if combatIdleElapsed >= COMBAT_END_GRACE then
			EndCombat()
		end
	end
	if session.completionPendingAt and GetTime() >= session.completionPendingAt then
		if session.encounter and GetTime() < SafeNumber(session.completionDeadline) then
			session.completionPendingAt = GetTime() + 0.25
		else
			-- Some Ascension clients send the LFG completion before, or even
			-- without, the final ENCOUNTER_END. The completion then confirms the
			-- kill and lets the boss be consolidated after the grace delay.
			if session.encounter then
				EndEncounter(
					session.encounter.encounterID,
					session.encounter.encounterName,
					true
				)
			end
			session.completionPendingAt = nil
			session.completionDeadline = nil
			PvE.CompleteDungeon(false)
		end
	end
	updateElapsed = updateElapsed + elapsed
	healthElapsed = healthElapsed + elapsed
	rosterElapsed = rosterElapsed + elapsed
	snapshotElapsed = snapshotElapsed + elapsed
	if rosterElapsed >= ROSTER_INTERVAL then
		rosterElapsed = 0
		RefreshRoster()
	end
	if updateElapsed >= SAMPLE_INTERVAL then
		local sampled = updateElapsed
		updateElapsed = 0
		SampleThreat(sampled)
	end
	if healthElapsed >= HEALTH_SAMPLE_INTERVAL then
		local sampled = healthElapsed
		healthElapsed = 0
		SampleGroupHealth(sampled)
	end
	if session.context.scope == "dungeon"
		and snapshotElapsed >= SESSION_SNAPSHOT_INTERVAL
	then
		snapshotElapsed = 0
		if PvE.SaveCurrentDungeon then
			PvE.SaveCurrentDungeon(false, true)
		end
		if PvE.IsSessionPanelShown and PvE.IsSessionPanelShown()
			and PvE.RefreshSessionPanel
		then
			PvE.RefreshSessionPanel()
		end
	end
end)
driver:Hide()

local function Mean(metric, key)
	local samples = SafeNumber(metric and metric.samples)
	if samples <= 0 then
		return 0
	end
	return SafeNumber(metric[key .. "Sum"]) / samples
end

local function ShrinkScore(rawScore, samples)
	samples = SafeNumber(samples)
	local reliability = samples / (samples + PRIOR_SAMPLES)
	return 100 + (rawScore - 100) * reliability
end

local function CalculateHealingScore(entry, category)
	local totalScore, totalSamples, totalEffectiveSamples = 0, 0, 0
	for contextKey, own in pairs(entry.contexts or {}) do
		local global = category.contexts[contextKey]
		local samples = SafeNumber(own.samples)
		if global and samples > 0 then
			local coverage = Clamp(
				(Mean(own, "coverage") + 0.02) / (Mean(global, "coverage") + 0.02),
				0.50,
				1.50
			)
			local survival = Clamp(
				(Mean(own, "survival") + 0.05) / (Mean(global, "survival") + 0.05),
				0.70,
				1.30
			)
			local efficiency = Clamp(
				(Mean(own, "efficiency") + 0.05) / (Mean(global, "efficiency") + 0.05),
				0.70,
				1.30
			)
			local isRaid = string.sub(contextKey, 1, 5) == "raid|"
			local score
			if isRaid then
				local peer = Clamp(Mean(own, "peer"), 0.50, 1.50)
				score = 100 * (
					0.50 * coverage
					+ 0.20 * peer
					+ 0.20 * survival
					+ 0.10 * efficiency
				)
			else
				score = 100 * (
					0.70 * coverage
					+ 0.20 * survival
					+ 0.10 * efficiency
				)
			end
			local outcomeSamples = math.min(
				samples,
				SafeNumber(own.outcomeScoreSamples)
			)
			local v3Runs = math.min(
				math.max(0, samples - outcomeSamples),
				SafeNumber(own.outcomeV3Runs)
			)
			local v3Weight = math.min(v3Runs, SafeNumber(own.outcomeV3Weight))
			local v4Runs = math.min(
				math.max(0, samples - outcomeSamples - v3Runs),
				SafeNumber(own.outcomeV4Runs)
			)
			local v4Weight = math.min(v4Runs, SafeNumber(own.outcomeV4Weight))
			local legacySamples = math.max(
				0,
				samples - outcomeSamples - v3Runs - v4Runs
			)
			local weightedScore = score * legacySamples
			local effectiveSamples = legacySamples
			if outcomeSamples > 0 then
				weightedScore = weightedScore + SafeNumber(own.outcomeScoreSum)
				effectiveSamples = effectiveSamples + outcomeSamples
			end
			if v3Weight > 0 then
				weightedScore = weightedScore + SafeNumber(own.outcomeV3ScoreSum)
				effectiveSamples = effectiveSamples + v3Weight
			end
			if v4Weight > 0 then
				weightedScore = weightedScore + SafeNumber(own.outcomeV4ScoreSum)
				effectiveSamples = effectiveSamples + v4Weight
			end
			if effectiveSamples > 0 then
				score = weightedScore / effectiveSamples
			end
			totalScore = totalScore + score * effectiveSamples
			totalSamples = totalSamples + samples
			totalEffectiveSamples = totalEffectiveSamples + effectiveSamples
		end
	end
	return totalEffectiveSamples > 0 and totalScore / totalEffectiveSamples or 100,
		totalSamples,
		totalEffectiveSamples
end

local function InverseContextRatio(own, global, key)
	local ownValue = Mean(own, key)
	local globalValue = Mean(global, key)
	if ownValue <= EPSILON and globalValue <= EPSILON then
		return 1
	end
	return Clamp((globalValue + 0.0001) / (ownValue + 0.0001), 0.50, 1.50)
end

local function CalculateTankScore(entry, category)
	local totalScore, totalSamples = 0, 0
	for contextKey, own in pairs(entry.contexts or {}) do
		local global = category.contexts[contextKey]
		local samples = SafeNumber(own.samples)
		if global and samples > 0 then
			local uptime = Clamp(Mean(own, "uptime"), 0, 1)
			local pickupScore = 1 / (1 + Mean(own, "pickup") / 3)
			local stability = 1 - Clamp(Mean(own, "lossRate"), 0, 1)
			local ownAggro = 0.55 * uptime + 0.25 * pickupScore + 0.20 * stability
			local globalUptime = Clamp(Mean(global, "uptime"), 0, 1)
			local globalPickup = 1 / (1 + Mean(global, "pickup") / 3)
			local globalStability = 1 - Clamp(Mean(global, "lossRate"), 0, 1)
			local globalAggro = 0.55 * globalUptime
				+ 0.25 * globalPickup
				+ 0.20 * globalStability
			local aggro = Clamp(
				(ownAggro + 0.05) / (globalAggro + 0.05),
				0.50,
				1.50
			)
			local resilience = (
				0.55 * InverseContextRatio(own, global, "damageRate")
					+ 0.20 * InverseContextRatio(own, global, "supportRate")
					+ 0.25 * InverseContextRatio(own, global, "spike")
			)
			local survival = Clamp(
				(Mean(own, "survival") + 0.05) / (Mean(global, "survival") + 0.05),
				0.70,
				1.30
			)
			-- Mitigation quality is compared against the same context so a
			-- naturally tankier spec does not simply win the metric outright.
			local ownMitigation = Mean(own, "mitigation")
			local globalMitigation = Mean(global, "mitigation")
			local mitigation = globalMitigation > 0
				and Clamp((ownMitigation + 0.05) / (globalMitigation + 0.05), 0.60, 1.40)
				or 1
			local score = 100 * (
				0.38 * aggro
					+ 0.30 * resilience
					+ 0.20 * mitigation
					+ 0.12 * survival
			)
			totalScore = totalScore + score * samples
			totalSamples = totalSamples + samples
		end
	end
	return totalSamples > 0 and totalScore / totalSamples or 100, totalSamples
end

local function CalculateSupportScore(entry, category)
	local totalScore, totalSamples = 0, 0
	for contextKey, own in pairs(entry.contexts or {}) do
		local global = category.contexts[contextKey]
		local samples = SafeNumber(own.samples)
		if global and samples > 0 then
			local contribution = Clamp(
				(Mean(own, "contributionRate") + 0.01)
					/ (Mean(global, "contributionRate") + 0.01),
				0.50,
				1.50
			)
			local availability = Clamp(Mean(own, "availability"), 0.40, 1)
			local utility = Clamp(1 + Mean(own, "utilityRate") * 0.05, 1, 1.25)
			local score = 100 * (
				0.75 * contribution + 0.20 * availability + 0.05 * utility
			)
			totalScore = totalScore + score * samples
			totalSamples = totalSamples + samples
		end
	end
	return totalSamples > 0 and totalScore / totalSamples or 100, totalSamples
end

local CURRENT_STAT_KEYS = {
	"damage", "bossDamage", "trashDamage", "rawHealing", "effectiveHealing",
	"absorbs", "tankTargetHealing", "damageTaken", "tankDamage",
	"externalSupport", "deaths", "responsibilitySeconds", "controlledSeconds",
	"lossSeconds", "pickupTotal", "pickupCount", "tankingWallSeconds",
	"healthSeconds", "maxTwoSecondDamage", "healthObservedSeconds",
	"healthPctSeconds", "below75Seconds", "below50Seconds", "below25Seconds",
	"criticalEpisodes", "criticalFailures", "recoveryTimeTotal", "recoveryCount",
	"urgentRecoveryTimeTotal", "urgentRecoveryCount", "urgentRecoveryFailures",
	"minHealthPct", "utilityActions", "combatObservedSeconds",
	"clutchHeals", "clutchHealing", "clutchCredit", "lifeSaves",
	"clutchHealsOnTank", "clutchHealsOnHealer", "clutchSelfHeals",
	"clutchRescuedBy", "threatLossEvents",
	"damageTakenRaw", "damageMitigated", "pressureDamageTaken",
	"pressureDamageMitigated", "pressureSeconds", "incomingAttacks",
	"avoidedAttacks", "selfHealing", "selfAbsorbs", "tankingSelfSustain",
	"defensiveCastsUnderPressure", "interrupts", "dispels",
	"repeatedHitDamage", "repeatedHitCount",
	"aliveCombatSeconds", "healerScorableCombatSeconds",
	"healerScorableAliveSeconds", "bossObservedSeconds", "trashObservedSeconds",
	"healerCoverageAssessableSeconds", "healerCoveredHealthObservedSeconds",
	"healerCoveredBelow75Seconds", "healerCoveredBelow50Seconds",
	"healerCoveredBelow25Seconds", "healerCoveredMinHealthPct",
	"healerOutOfRangeSeconds", "healerCoveredDamageTaken",
	"healerUncoveredDamageTaken", "coveredCriticalEpisodes",
	"coveredCriticalFailures", "coveredRecoveryTimeTotal",
	"coveredRecoveryCount", "coveredUrgentRecoveryTimeTotal",
	"coveredUrgentRecoveryCount", "coveredUrgentRecoveryFailures",
	"manaObservedSeconds", "manaPctSeconds",
	"below20ManaSeconds", "below10ManaSeconds", "minManaPct", "lastManaPct",
	"preventableDeaths", "oneShotDeaths", "outOfReachDeaths",
	"recoveryDeaths", "nonCombatDeaths",
}

local function GetLiveCombatTimes(sample)
	local bossTime = SafeNumber(sample and sample.bossTime)
	local trashTime = SafeNumber(sample and sample.trashTime)
	if sample and sample.combatStartedAt then
		local duration = math.max(0, GetTime() - sample.combatStartedAt)
		if sample.combatIsBoss then
			bossTime = bossTime + duration
		else
			trashTime = trashTime + duration
		end
	end
	return bossTime, trashTime, bossTime + trashTime
end

local function CurrentRating(score)
	if not score then
		return
	end
	-- 100 is the expected performance and maps to 7/10. Every 10 points of
	-- score adds or removes one point of rating.
	return Clamp(7 + (score - 100) / 10, 0, 10)
end

function PvE.GetRatingColor(rating)
	rating = SafeNumber(rating)
	if rating >= 8.5 then
		return 0.18, 0.90, 0.45
	elseif rating >= 7 then
		return 0.95, 0.78, 0.18
	elseif rating >= 5 then
		return 0.95, 0.52, 0.16
	end
	return 0.95, 0.28, 0.28
end

function PvE.FormatRating(rating)
	local value = SafeNumber(rating)
	local rounded = math.floor(value * 10 + 0.5) / 10
	local integer = math.floor(rounded + 0.5)
	if math.abs(rounded - integer) < 0.0001 then
		return tostring(integer)
	end
	return string.format("%.1f", rounded)
end

local function NotifyCurrentDungeonChanged(snapshot)
	if CoAAnalyticsAddon and CoAAnalyticsAddon.Events then
		CoAAnalyticsAddon.Events:Fire(
			"PVE_DUNGEON_SNAPSHOT_UPDATED",
			snapshot
		)
	end
end

local function InverseLiveRatio(value, reference, key)
	if type(reference) ~= "table" or SafeNumber(reference.samples) <= 0 then
		return 1
	end
	local referenceValue = Mean(reference, key)
	if value <= EPSILON and referenceValue <= EPSILON then
		return 1
	end
	return Clamp((referenceValue + 0.0001) / (value + 0.0001), 0.50, 1.50)
end

local function CopyCurrentStats(stats)
	local copy = {}
	for _, key in ipairs(CURRENT_STAT_KEYS) do
		copy[key] = SafeNumber(stats and stats[key])
	end
	return copy
end

BuildCurrentDungeonSnapshot = function(finished)
	if not session or session.context.scope ~= "dungeon" or not session.run then
		return
	end
	local sample = session.run
	local participants = SnapshotParticipants(sample)
	local bossTime, trashTime, activeTime = GetLiveCombatTimes(sample)
	local damagePlayers = {}
	local healers = {}
	local tanks = {}
	local supports = {}
	local eligibleParticipants = {}
	local rowByGUID = {}
	local snapshotRows = {}
	local nonHealerHealing = 0
	local totalHealerImpact = 0

	for _, participant in ipairs(participants) do
		local role = participant.role
		if role == "NONE" then
			role = nil
		end
		participant.role = role
		local stats = participant.stats
		local data = participant.data or {}
		local impact = SafeNumber(stats.effectiveHealing) + SafeNumber(stats.absorbs)
		participant.impact = impact
		local eligible, exclusionReason, observed, minimumObserved =
			GetParticipantEligibility(participant, activeTime)
		participant.eligible = eligible
		participant.exclusionReason = exclusionReason
		participant.observedCombat = observed
		participant.minimumObserved = minimumObserved
		if eligible then
			eligibleParticipants[#eligibleParticipants + 1] = participant
		end
		if eligible and IsDamageRole(role) and SafeNumber(stats.damage) > 0 then
			damagePlayers[#damagePlayers + 1] = participant
		elseif eligible and role == "HEALER" and impact > 0 then
			healers[#healers + 1] = participant
			totalHealerImpact = totalHealerImpact + impact
		elseif eligible and role == "TANK"
			and SafeNumber(stats.responsibilitySeconds) >= 5
		then
			tanks[#tanks + 1] = participant
		elseif eligible and role == "SUPPORT"
			and (SafeNumber(stats.damage) + impact) > 0
		then
			supports[#supports + 1] = participant
		end
		if eligible and role ~= "HEALER" then
			nonHealerHealing = nonHealerHealing + impact
		end
		if eligible and IsDamageRole(role) and SafeNumber(stats.damage) <= 0 then
			participant.eligible = false
			participant.exclusionReason = "no damage for this role"
		elseif eligible and role == "HEALER" and impact <= 0 then
			participant.eligible = false
			participant.exclusionReason = "no effective healing for this role"
		elseif eligible and role == "TANK"
			and SafeNumber(stats.responsibilitySeconds) < 5
		then
			participant.eligible = false
			participant.exclusionReason = "insufficient tanking time"
		end

		local classToken = data.specializationClassToken or data.classToken
		local row = {
			guid = participant.guid,
			name = GetValidPlayerName(participant.member.name)
				or GetValidPlayerName(stats.name)
				or GetValidPlayerName(data.fullName)
				or GetValidPlayerName(data.name)
				or "Unknown player",
			classToken = classToken,
			specializationClassToken = classToken,
			specializationID = data.specializationID,
			specialization = data.specialization,
			specializationTexture = data.specializationTexture,
			specializationTexCoords = CopyCoordinates(data.specializationTexCoords),
			role = role,
			damage = SafeNumber(stats.damage),
			dps = activeTime > 0 and SafeNumber(stats.damage) / activeTime or 0,
			healing = impact,
			hps = activeTime > 0 and impact / activeTime or 0,
			damageTaken = SafeNumber(stats.damageTaken),
			deaths = SafeNumber(stats.deaths),
			rawStats = CopyCurrentStats(stats),
			level = GetParticipantLevel(participant),
			eligible = participant.eligible and true or false,
			exclusionReason = participant.exclusionReason,
			participation = GetRawCombatParticipation(participant, activeTime),
			combatObservedSeconds = observed,
			minimumObservedSeconds = minimumObserved,
			presenceSeconds = participant.presenceSeconds,
			currentlyPresent = participant.currentlyPresent,
			joinedAfterSeconds = participant.member.joinedAt and math.max(
				0, SafeNumber(participant.member.joinedAt) - SafeNumber(session.startedAt)
			) or nil,
			leftAfterSeconds = participant.member.leftAt and math.max(
				0, SafeNumber(participant.member.leftAt) - SafeNumber(session.startedAt)
			) or nil,
			joinCount = SafeNumber(participant.member.joinCount),
			leaveCount = SafeNumber(participant.member.leaveCount),
			execution = {
				interrupts = SafeNumber(stats.interrupts),
				dispels = SafeNumber(stats.dispels),
				repeatedHitDamage = SafeNumber(stats.repeatedHitDamage),
				repeatedHitCount = SafeNumber(stats.repeatedHitCount),
				damageTaken = SafeNumber(stats.damageTaken),
				avoidableShare = SafeNumber(stats.damageTaken) > 0
					and Clamp(
						SafeNumber(stats.repeatedHitDamage)
							/ SafeNumber(stats.damageTaken),
						0, 1
					) or 0,
			},
			clutch = {
				clutchHeals = SafeNumber(stats.clutchHeals),
				clutchHealing = SafeNumber(stats.clutchHealing),
				clutchCredit = SafeNumber(stats.clutchCredit),
				lifeSaves = SafeNumber(stats.lifeSaves),
				clutchHealsOnTank = SafeNumber(stats.clutchHealsOnTank),
				clutchHealsOnHealer = SafeNumber(stats.clutchHealsOnHealer),
				clutchSelfHeals = SafeNumber(stats.clutchSelfHeals),
				clutchRescuedBy = SafeNumber(stats.clutchRescuedBy),
			},
		}
		rowByGUID[participant.guid] = row
		snapshotRows[#snapshotRows + 1] = row
	end

	if #healers == 1 and SafeNumber(sample.unattributedAbsorb) > 0 then
		healers[1].impact = healers[1].impact + SafeNumber(sample.unattributedAbsorb)
		totalHealerImpact = totalHealerImpact + SafeNumber(sample.unattributedAbsorb)
		local healerRow = rowByGUID[healers[1].guid]
		if healerRow then
			healerRow.healing = healers[1].impact
			healerRow.hps = activeTime > 0 and healers[1].impact / activeTime or 0
		end
	end

	if activeTime >= 3 and #damagePlayers > 0 then
		local levelReference = GetMedianLevel(damagePlayers)
		for _, participant in ipairs(damagePlayers) do
			local participation = GetCombatParticipation(participant, activeTime)
			participant.bossParticipation, participant.bossParticipationRaw =
				GetPhaseParticipation(
				participant, bossTime, "bossObservedSeconds", participation
			)
			participant.trashParticipation, participant.trashParticipationRaw =
				GetPhaseParticipation(
				participant, trashTime, "trashObservedSeconds", participation
			)
			participant.adjustedBossDamage, participant.levelFactor, participant.level =
				GetLevelAdjustedValue(
					SafeNumber(participant.stats.bossDamage)
						/ participant.bossParticipation,
					participant,
					levelReference
				)
			participant.adjustedTrashDamage =
				GetLevelAdjustedValue(
					SafeNumber(participant.stats.trashDamage)
						/ participant.trashParticipation,
					participant,
					levelReference
				)
		end
		local bossMean = GetRobustMean(
			damagePlayers, "adjustedBossDamage", "bossParticipationRaw"
		)
		local trashMean = GetRobustMean(
			damagePlayers, "adjustedTrashDamage", "trashParticipationRaw"
		)
		local bossWeight, trashWeight, phaseEvidence = GetDpsWeights({
			bossTime = bossTime,
			trashTime = trashTime,
		}, bossMean, trashMean, damagePlayers)
		local weightTotal = bossWeight + trashWeight
		if weightTotal > 0 then
			bossWeight = bossWeight / weightTotal
			trashWeight = trashWeight / weightTotal
			for _, participant in ipairs(damagePlayers) do
				local bossRatio = bossMean > 0
					and participant.adjustedBossDamage / bossMean or 0
				local trashRatio = trashMean > 0
					and participant.adjustedTrashDamage / trashMean or 0
				local row = rowByGUID[participant.guid]
				row.level = participant.level or row.level
				row.levelReference = levelReference
				row.levelFactor = participant.levelFactor
				local personalBossWeight = participant.bossParticipationRaw
					and participant.bossParticipationRaw >= MIN_SCORING_PARTICIPATION
					and bossWeight or 0
				local personalTrashWeight = participant.trashParticipationRaw
					and participant.trashParticipationRaw >= MIN_SCORING_PARTICIPATION
					and trashWeight or 0
				local personalWeightTotal = personalBossWeight + personalTrashWeight
				local outputScore = personalWeightTotal > 0 and 100 * (
					personalBossWeight * bossRatio
						+ personalTrashWeight * trashRatio
				) / personalWeightTotal or 0
				local participation, aliveRate, utilityBonus, clutchBonus
				row.score, participation, aliveRate, utilityBonus, clutchBonus =
					FinalizeDpsScore(outputScore, participant, activeTime)
				row.dpsBreakdown = {
					outputScore = outputScore,
					bossRatio = bossRatio,
					trashRatio = trashRatio,
					bossWeight = bossWeight,
					trashWeight = trashWeight,
					bossPhaseReliable = phaseEvidence.bossReliable,
					trashPhaseReliable = phaseEvidence.trashReliable,
					bossDamageShare = phaseEvidence.bossDamageShare,
					trashDamageShare = phaseEvidence.trashDamageShare,
					bossContributors = phaseEvidence.bossContributors,
					trashContributors = phaseEvidence.trashContributors,
					minimumPhaseTime = phaseEvidence.minimumPhaseTime,
					participation = participation,
					bossParticipation = participant.bossParticipation,
					trashParticipation = participant.trashParticipation,
					bossParticipationRaw = participant.bossParticipationRaw,
					trashParticipationRaw = participant.trashParticipationRaw,
					aliveRate = aliveRate,
					utilityBonus = utilityBonus,
					clutchBonus = clutchBonus,
					clutchHeals = SafeNumber(participant.stats.clutchHeals),
					clutchHealing = SafeNumber(participant.stats.clutchHealing),
					lifeSaves = SafeNumber(participant.stats.lifeSaves),
					clutchHealsOnTank =
						SafeNumber(participant.stats.clutchHealsOnTank),
					clutchHealsOnHealer =
						SafeNumber(participant.stats.clutchHealsOnHealer),
				}
			end
		end
	end

	local healingContext = BuildHealingContext(
		sample,
		eligibleParticipants,
		totalHealerImpact,
		nonHealerHealing,
		activeTime
	)
	local effectiveHealerCount = GetEffectiveRoleCount(healers, activeTime)
	if activeTime >= 3 and #healers > 0 and totalHealerImpact > 0 then
		for _, participant in ipairs(healers) do
			local outcome = CalculateHealerOutcome(
				sample,
				participant,
				effectiveHealerCount,
				totalHealerImpact,
				healingContext,
				#healers == 1
			)
			local row = rowByGUID[participant.guid]
			row.score = outcome.score
			row.healerBreakdown = outcome
		end
	end

	if activeTime >= 3 and #tanks > 0 then
		local root = InitializeDatabase()
		local tankCategory = root and EnsureCategory(root, "dungeon", "tank")
		local contextKey = BuildContextKey(
			sample,
			"tanks=" .. GetEffectiveRoleCount(tanks, activeTime)
		)
		local reference = tankCategory and tankCategory.contexts[contextKey]
		for _, participant in ipairs(tanks) do
			local stats = participant.stats
			local responsibility = SafeNumber(stats.responsibilitySeconds)
			if responsibility >= 5 then
				local uptime = Clamp(SafeNumber(stats.controlledSeconds) / responsibility, 0, 1)
				local lossRate = Clamp(SafeNumber(stats.lossSeconds) / responsibility, 0, 1)
				local pickup = SafeNumber(stats.pickupCount) > 0
					and SafeNumber(stats.pickupTotal) / stats.pickupCount or 0
				local pickupScore = 1 / (1 + pickup / 3)
				local aggro = 0.55 * uptime + 0.25 * pickupScore + 0.20 * (1 - lossRate)
				local healthSeconds = math.max(1, SafeNumber(stats.healthSeconds))
				local memberHealth = participant.member.maxHealth or 1
				local damageRate = SafeNumber(stats.tankDamage) / healthSeconds
				local supportRate = SafeNumber(stats.externalSupport) / healthSeconds
				local spike = SafeNumber(stats.maxTwoSecondDamage) / math.max(1, memberHealth)
				local resilience = (
					0.55 * InverseLiveRatio(damageRate, reference, "damageRate")
						+ 0.20 * InverseLiveRatio(supportRate, reference, "supportRate")
						+ 0.25 * InverseLiveRatio(spike, reference, "spike")
				)
				local _, aliveRate = GetCombatParticipation(participant, activeTime)
				local tankSurvival = Clamp(
					(0.70 + 0.30 * aliveRate) / (
						1 + SafeNumber(stats.deaths) * 0.20
					),
					0.40,
					1
				)
				local aggroPerformance = Clamp((aggro + 0.05) / 0.95, 0.50, 1.45)
				local mitigationProfile =
					GetTankMitigationProfile(stats, memberHealth)
				local row = rowByGUID[participant.guid]
				row.score = Clamp(100 * (
					0.38 * aggroPerformance
						+ 0.30 * resilience
						+ 0.20 * mitigationProfile.quality
						+ 0.12 * tankSurvival
				), 30, 200)
				row.tankBreakdown = {
					uptime = uptime,
					pickup = pickup,
					lossRate = lossRate,
					responsibilitySeconds = responsibility,
					controlledSeconds = SafeNumber(stats.controlledSeconds),
					lossSeconds = SafeNumber(stats.lossSeconds),
					threatLossEvents = SafeNumber(stats.threatLossEvents),
					pickupCount = SafeNumber(stats.pickupCount),
					deaths = SafeNumber(stats.deaths),
					aggro = aggroPerformance,
					resilience = resilience,
					survival = tankSurvival,
					aliveRate = aliveRate,
					damageRate = damageRate,
					supportRate = supportRate,
					spike = spike,
					mitigation = mitigationProfile.quality,
					mitigationRate = mitigationProfile.mitigationRate,
					pressureMitigationRate = mitigationProfile.pressureMitigationRate,
					avoidanceRate = mitigationProfile.avoidanceRate,
					selfSustainRate = mitigationProfile.selfSustainRate,
					spikeResponse = mitigationProfile.spikeResponse,
					damageTakenRaw = mitigationProfile.damageTakenRaw,
					damageMitigated = mitigationProfile.damageMitigated,
					selfHealing = mitigationProfile.selfHealing,
					selfAbsorbs = mitigationProfile.selfAbsorbs,
					tankingSelfSustain = mitigationProfile.tankingSelfSustain,
					incomingAttacks = mitigationProfile.incomingAttacks,
					avoidedAttacks = mitigationProfile.avoidedAttacks,
					pressureDamageTaken = mitigationProfile.pressureDamageTaken,
					defensiveCastsUnderPressure =
						mitigationProfile.defensiveCastsUnderPressure,
				}
			end
		end
	end

	if activeTime >= 3 and #supports > 0 then
		local root = InitializeDatabase()
		local supportCategory = root and EnsureCategory(root, "dungeon", "support")
		local contextKey = BuildContextKey(
			sample,
			"supports=" .. GetEffectiveRoleCount(supports, activeTime)
		)
		local reference = supportCategory and supportCategory.contexts[contextKey]
		for _, participant in ipairs(supports) do
			participant.measuredContribution = SafeNumber(participant.stats.damage)
				+ participant.impact
			local participation, aliveRate = GetCombatParticipation(participant, activeTime)
			local contributionRate = participant.measuredContribution
				/ activeTime / participation
			local referenceRate = reference and Mean(reference, "contributionRate") or 0
			local contribution = referenceRate > 0 and Clamp(
				(contributionRate + 0.01) / (referenceRate + 0.01),
				0.50,
				1.50
			) or 1
			local utilityRate = SafeNumber(participant.stats.utilityActions)
				/ math.max(activeTime / 60, 1)
			local utility = Clamp(1 + utilityRate * 0.05, 1, 1.25)
			local row = rowByGUID[participant.guid]
			row.score = Clamp(100 * (
				0.75 * contribution + 0.20 * aliveRate + 0.05 * utility
			), 30, 200)
			row.supportBreakdown = {
				contribution = contribution,
				contributionRate = contributionRate,
				participation = participation,
				aliveRate = aliveRate,
				utility = utility,
				utilityRate = utilityRate,
			}
		end
	end

	local ratingTotal, ratingCount, ratingWeightTotal = 0, 0, 0
	for _, row in ipairs(snapshotRows) do
		if row.score then
			row.rating = CurrentRating(row.score)
			local ratingWeight = Clamp(SafeNumber(row.participation), 0.10, 1)
			row.ratingWeight = ratingWeight
			ratingTotal = ratingTotal + row.rating * ratingWeight
			ratingWeightTotal = ratingWeightTotal + ratingWeight
			ratingCount = ratingCount + 1
		end
	end
	table.sort(snapshotRows, function(left, right)
		if left.rating and not right.rating then
			return true
		elseif right.rating and not left.rating then
			return false
		elseif left.rating and right.rating and math.abs(left.rating - right.rating) > EPSILON then
			return left.rating > right.rating
		end
		return tostring(left.name or "") < tostring(right.name or "")
	end)

	return {
		active = not finished and not sample.recorded,
		finished = finished or sample.recorded or false,
		healerFormulaVersion = HEALER_SCORE_VERSION,
		instanceName = session.context.instanceName,
		difficultyName = session.context.difficultyName,
		difficultyID = session.context.difficultyID,
		startedAt = time() - math.floor(math.max(0, GetTime() - session.startedAt)),
		updatedAt = time(),
		endedAt = (finished or sample.recorded) and time() or nil,
		activeTime = activeTime,
		bossTime = bossTime,
		trashTime = trashTime,
		averageRating = ratingWeightTotal > 0 and ratingTotal / ratingWeightTotal or nil,
		ratedPlayers = ratingCount,
		groupSize = SafeNumber(sample.groupSize),
		rosterSize = #snapshotRows,
		replacements = math.max(0, #snapshotRows - SafeNumber(sample.groupSize)),
		bossCount = SafeNumber(sample.bossCount),
		wipes = SafeNumber(sample.wipes),
		completionPath = sample.completionPath,
		pace = {
			elapsedSeconds = math.max(0, GetTime() - SafeNumber(session.startedAt)),
			combatSeconds = activeTime,
			downtimeSeconds = SafeNumber(sample.downtimeSeconds),
			longestDowntime = SafeNumber(sample.longestDowntime),
			pullCount = SafeNumber(sample.pullCount),
			-- The share of time in the instance actually spent fighting. This
			-- is what separates a fast clear from a slow one far more often
			-- than raw throughput does.
			efficiency = (function()
				local elapsed = math.max(1, GetTime() - SafeNumber(session.startedAt))
				return Clamp(activeTime / elapsed, 0, 1)
			end)(),
			averagePullSeconds = SafeNumber(sample.pullCount) > 0
				and activeTime / SafeNumber(sample.pullCount) or 0,
		},
		interrupts = {
			interrupted = SafeNumber(sample.mobCastsInterrupted),
			completed = SafeNumber(sample.mobCastsCompleted),
			coverage = (SafeNumber(sample.mobCastsInterrupted)
				+ SafeNumber(sample.mobCastsCompleted)) > 0
				and SafeNumber(sample.mobCastsInterrupted)
					/ (SafeNumber(sample.mobCastsInterrupted)
						+ SafeNumber(sample.mobCastsCompleted))
				or 0,
		},
		segmentSummary = {
			bossSegments = SafeNumber(sample.bossSegmentCount),
			trashSegments = SafeNumber(sample.trashSegmentCount),
			maxBossSegment = SafeNumber(sample.maxBossSegment),
			maxTrashSegment = SafeNumber(sample.maxTrashSegment),
			officialEncounterStarts = SafeNumber(sample.officialEncounterStarts),
			officialEncounterEnds = SafeNumber(sample.officialEncounterEnds),
			fallbackEncounterStarts = SafeNumber(sample.fallbackEncounterStarts),
		},
		rows = snapshotRows,
			healthSummary = {
			observedSeconds = healingContext.observedSeconds,
			below75Seconds = healingContext.below75Seconds,
			below50Seconds = healingContext.below50Seconds,
			below25Seconds = healingContext.below25Seconds,
			criticalEpisodes = healingContext.criticalEpisodes,
			criticalFailures = healingContext.criticalFailures,
			urgentRecoveryFailures = healingContext.urgentRecoveryFailures,
			preventableDeaths = healingContext.preventableDeaths,
			oneShotDeaths = healingContext.oneShotDeaths,
			outOfReachDeaths = healingContext.outOfReachDeaths,
			recoveryDeaths = healingContext.recoveryDeaths,
			coverageAssessableSeconds = healingContext.coverageAssessableSeconds,
			scorableDamageTaken = healingContext.scorableDamageTaken,
			coveredDamageTaken = healingContext.coveredDamageTaken,
			uncoveredDamageTaken = healingContext.uncoveredDamageTaken,
			averageRecovery = healingContext.averageRecovery,
			averageUrgentRecovery = healingContext.averageUrgentRecovery,
			urgentRecoveryThreshold = healingContext.urgentRecoveryThreshold,
			minimumHealthPct = healingContext.minimumHealthPct,
			pressure = healingContext.pressure,
			opportunity = healingContext.opportunity,
			confidence = healingContext.confidence,
		},
			sampleTotals = {
			groupDamageTaken = SafeNumber(sample.groupDamageTaken),
			deaths = SafeNumber(sample.deaths),
			preventableDeaths = SafeNumber(sample.preventableDeaths),
			oneShotDeaths = SafeNumber(sample.oneShotDeaths),
			outOfReachDeaths = SafeNumber(sample.outOfReachDeaths),
			recoveryDeaths = SafeNumber(sample.recoveryDeaths),
			nonCombatDeaths = SafeNumber(sample.nonCombatDeaths),
			wipeLikeEvents = SafeNumber(sample.wipeLikeEvents),
			unattributedAbsorb = SafeNumber(sample.unattributedAbsorb),
		},
	}
end

function PvE.StartCurrentDungeon()
	local root = InitializeDatabase()
	if not root then
		return
	end
	root.currentDungeon = BuildCurrentDungeonSnapshot(false)
	NotifyCurrentDungeonChanged(root.currentDungeon)
	if PvE.IsSessionPanelShown and PvE.IsSessionPanelShown()
		and PvE.RefreshSessionPanel
	then
		PvE.RefreshSessionPanel()
	end
	return root.currentDungeon
end

function PvE.SaveCurrentDungeon(finished, suppressRefresh, providedSnapshot)
	local root = InitializeDatabase()
	if not root then
		return
	end
	local snapshot = providedSnapshot or BuildCurrentDungeonSnapshot(finished)
	if snapshot then
		root.currentDungeon = snapshot
		NotifyCurrentDungeonChanged(snapshot)
	end
	if not suppressRefresh
		and PvE.IsSessionPanelShown and PvE.IsSessionPanelShown()
		and PvE.RefreshSessionPanel
	then
		PvE.RefreshSessionPanel()
	end
	return root.currentDungeon
end

local function GetSnapshotHealerFormulaVersion(snapshot)
	if snapshot and snapshot.healerFormulaVersion then
		return snapshot.healerFormulaVersion
	end
	for _, row in ipairs(snapshot and snapshot.rows or {}) do
		if row.healerBreakdown and row.healerBreakdown.version then
			return row.healerBreakdown.version
		end
	end
	return HEALER_SCORE_VERSION
end

local function BuildDiagnosticRecord(snapshot, reason)
	if not snapshot or SafeNumber(snapshot.activeTime) < DIAGNOSTIC_MIN_COMBAT then
		return nil, "combat too short"
	end
	local ratedPlayers = SafeNumber(snapshot.ratedPlayers)
	if ratedPlayers <= 0 then
		for _, row in ipairs(snapshot.rows or {}) do
			if row.score or row.rating then
				ratedPlayers = ratedPlayers + 1
			end
		end
	end
	if ratedPlayers <= 0 then
		return nil, "no scored performance"
	end
	local build, _, buildDate, interfaceVersion = GetBuildInfo()
	return {
		schemaVersion = 4,
		healerFormulaVersion = GetSnapshotHealerFormulaVersion(snapshot),
		addonVersion = API and API.VERSION or "?",
		clientBuild = build,
		clientBuildDate = buildDate,
		interfaceVersion = interfaceVersion,
		capturedAt = time(),
		reason = reason or "dungeon end",
		completionPath = snapshot.completionPath,
		instanceName = snapshot.instanceName,
		difficultyName = snapshot.difficultyName,
		difficultyID = snapshot.difficultyID,
		startedAt = snapshot.startedAt,
		endedAt = snapshot.endedAt or time(),
		activeTime = snapshot.activeTime,
		bossTime = snapshot.bossTime,
		trashTime = snapshot.trashTime,
		segmentSummary = snapshot.segmentSummary,
		groupSize = snapshot.groupSize,
		rosterSize = snapshot.rosterSize,
		replacements = snapshot.replacements,
		bossCount = snapshot.bossCount,
		wipes = snapshot.wipes,
		averageRating = snapshot.averageRating,
		healthSummary = snapshot.healthSummary,
		sampleTotals = snapshot.sampleTotals,
		rows = snapshot.rows,
		formula = {
			solo = {
				stability = 0.25,
				coverage = 0.20,
				responsiveness = 0.20,
				availability = 0.20,
				manaManagement = 0.08,
				prevention = 0.05,
				overhealInfluence = 0.02,
				urgentRecoveryThreshold = URGENT_RECOVERY_THRESHOLD,
				noFailureResponsivenessFloor = 0.85,
			},
				dps = {
				adaptiveBossWeight = true,
				robustPeerReference = true,
				participationAdjusted = true,
				unreliablePhasesIgnored = true,
					minimumPhaseShare = 0.03,
					inactivePlayersExcluded = true,
					phaseParticipationAdjusted = true,
				},
			tank = {
				aggro = 0.45,
				resilience = 0.40,
				survival = 0.15,
			},
				opportunityWeightsHistory = true,
				healerResponsibility = {
					outOfRangeExcluded = true,
					recoveryDeathsExcluded = true,
					nonCombatDeathsExcluded = true,
					wipePenaltyRequiresPreventableDeath = true,
				},
			ratingReferenceScore = 100,
			ratingReferenceValue = 7,
		},
	}
end

local function GetDiagnosticKey(report)
	if type(report) ~= "table" then
		return
	end
	return table.concat({
		tostring(report.instanceName or "?"),
		tostring(SafeNumber(report.startedAt)),
		tostring(SafeNumber(report.endedAt)),
		tostring(math.floor(SafeNumber(report.activeTime) * 10 + 0.5)),
	}, "|")
end

local function StoreDungeonDiagnostic(root, report)
	if not root or type(report) ~= "table" then
		return
	end
	root.dungeonDiagnostics = type(root.dungeonDiagnostics) == "table"
		and root.dungeonDiagnostics or {}
	local key = GetDiagnosticKey(report)
	for index = #root.dungeonDiagnostics, 1, -1 do
		if GetDiagnosticKey(root.dungeonDiagnostics[index]) == key then
			table.remove(root.dungeonDiagnostics, index)
		end
	end
	table.insert(root.dungeonDiagnostics, 1, report)
	while #root.dungeonDiagnostics > DIAGNOSTIC_HISTORY_LIMIT do
		table.remove(root.dungeonDiagnostics)
	end
	root.lastDungeonDiagnostic = root.dungeonDiagnostics[1]
	return root.lastDungeonDiagnostic
end

function PvE.SaveDungeonDiagnostic(reason, providedSnapshot)
	if not session
		or session.context.scope ~= "dungeon"
		or not session.run
		or not session.diagnosticEnabled
		or session.diagnosticSaved
	then
		return
	end
	local root = InitializeDatabase()
	local snapshot = providedSnapshot or BuildCurrentDungeonSnapshot(true)
	if not root or not snapshot then
		return
	end
	local report, reportError = BuildDiagnosticRecord(snapshot, reason)
	if not report then
		return false, reportError
	end
	StoreDungeonDiagnostic(root, report)
	session.diagnosticSaved = true
	session.diagnosticPendingStart = false
	NotifyDiagnosticStatus()
	Chat(
		"diagnostic saved (" .. tostring(#(root.dungeonDiagnostics or {}))
			.. "/" .. tostring(DIAGNOSTIC_HISTORY_LIMIT)
			.. "). Tracking stays active for the next dungeon."
	)
	return root.lastDungeonDiagnostic
end

function PvE.SetDungeonDiagnosticEnabled(enabled)
	enabled = enabled and true or false
	local addonDB = API and API.GetDatabase and API.GetDatabase()
	if not addonDB then
		return false
	end
	if session and session.context.scope == "dungeon" and session.run then
		session.diagnosticEnabled = enabled
		if enabled then
			session.diagnosticSaved = false
		end
		local hasCombat = session.inCombat
			or session.run.combatStartedAt
			or SafeNumber(session.run.bossTime) + SafeNumber(session.run.trashTime) > 0
		session.diagnosticPendingStart = enabled and not hasCombat
		addonDB.pveDiagnosticArmed = enabled
		if enabled and session.diagnosticPendingStart then
			Chat("diagnostic ready: it will start on the first combat")
		else
			Chat(enabled and "diagnostic active for the current dungeon" or "diagnostic disabled")
		end
	else
		addonDB.pveDiagnosticArmed = enabled
		Chat(enabled and "diagnostic armed for the next dungeon" or "diagnostic disabled")
	end
	NotifyDiagnosticStatus()
	return true
end

function PvE.GetDungeonDiagnosticStatus()
	local addonDB = API and API.GetDatabase and API.GetDatabase()
	local root = InitializeDatabase()
	local pending = session and session.context.scope == "dungeon"
		and session.diagnosticEnabled and session.diagnosticPendingStart
	local active = session and session.context.scope == "dungeon"
		and session.diagnosticEnabled and not session.diagnosticSaved and not pending
	return {
		active = active and true or false,
		armed = (pending or (not active and addonDB and addonDB.pveDiagnosticArmed))
			and true or false,
		last = root and root.lastDungeonDiagnostic,
		count = root and #(root.dungeonDiagnostics or {}) or 0,
		limit = DIAGNOSTIC_HISTORY_LIMIT,
		path = DIAGNOSTIC_FILE_PATH,
	}
end

function PvE.ClearDungeonDiagnostic()
	local root = InitializeDatabase()
	if root then
		root.lastDungeonDiagnostic = nil
		root.dungeonDiagnostics = {}
	end
	NotifyDiagnosticStatus()
	Chat("diagnostic history cleared")
end

function PvE.ExportDungeonDiagnostic()
	local root = InitializeDatabase()
	local report = root and root.lastDungeonDiagnostic
	local current = root and root.currentDungeon
	if current and current.finished and SafeNumber(current.activeTime) >= DIAGNOSTIC_MIN_COMBAT
		and (
			not report
			or SafeNumber(report.activeTime) < DIAGNOSTIC_MIN_COMBAT
			or SafeNumber(current.endedAt) > SafeNumber(report.endedAt)
		)
	then
		local currentReport = BuildDiagnosticRecord(
			current,
			current.completionPath or "last dungeon kept"
		)
		if currentReport then
			report = StoreDungeonDiagnostic(root, currentReport)
		end
	end
	if not report then
		Chat("no diagnostic to export")
		return false
	end

	-- SavedVariables are written by the client only during logout or UI reload.
	-- Mark the report, then let the client perform the required write itself.
	report.exportedAt = time()
	report.exportPath = DIAGNOSTIC_FILE_PATH
	root.dungeonDiagnosticsExportedAt = time()
	root.dungeonDiagnosticsExportCount = #(root.dungeonDiagnostics or {})
	Chat("exporting " .. tostring(root.dungeonDiagnosticsExportCount)
		.. " diagnostic(s)...")
	ReloadUI()
	return true
end

function PvE.PrintDungeonDiagnosticStatus()
	local status = PvE.GetDungeonDiagnosticStatus()
	local mode = status.active and "active"
		or status.armed and "armed for the next dungeon"
		or "inactive"
	Chat("diagnostic " .. mode)
	if status.last then
		Chat(
			"last report: " .. tostring(status.last.instanceName or "Dungeon")
				.. " - " .. date("%d/%m/%Y %H:%M", status.last.capturedAt or time())
		)
		Chat(tostring(status.count or 1) .. " report(s) kept out of "
			.. tostring(status.limit or DIAGNOSTIC_HISTORY_LIMIT))
	end
	Chat("file after /reload: " .. DIAGNOSTIC_FILE_PATH)
end

function PvE.MarkCurrentDungeonInactive()
	local root = InitializeDatabase()
	local snapshot = root and root.currentDungeon
	if snapshot and snapshot.active then
		snapshot.active = false
		snapshot.finished = true
		snapshot.endedAt = time()
		snapshot.updatedAt = time()
	end
	NotifyCurrentDungeonChanged(snapshot)
	if PvE.IsSessionPanelShown and PvE.IsSessionPanelShown()
		and PvE.RefreshSessionPanel
	then
		PvE.RefreshSessionPanel()
	end
end

function PvE.GetCurrentDungeonSnapshot()
	local root = InitializeDatabase()
	return root and root.currentDungeon
end

function PvE.RefreshCurrentDungeonSnapshot()
	if session and session.context.scope == "dungeon" and session.run then
		PvE.SaveCurrentDungeon(false, true)
	end
end

local function GetConfidence(samples)
	if samples < 5 then
		return "Provisional", 0.95, 0.62, 0.18
	elseif samples < 20 then
		return "Moyenne", 0.38, 0.72, 0.95
	end
	return "Reliable", 0.18, 0.82, 0.46
end

function PvE.GetLeaderboard(categoryKey, scopeKey)
	local root = InitializeDatabase()
	if not root then
		return {}, { samples = 0, specializations = 0 }
	end
	local category = EnsureCategory(root, scopeKey, categoryKey)
	local entries = {}
	for _, entry in pairs(category.entries) do
		local rawScore, samples, reliabilitySamples
		if categoryKey == "dps" then
			samples = SafeNumber(entry.scoreWeight)
			rawScore = samples > 0 and SafeNumber(entry.scoreSum) / samples or 100
		elseif categoryKey == "healing" then
			rawScore, samples, reliabilitySamples = CalculateHealingScore(entry, category)
		elseif categoryKey == "tank" then
			rawScore, samples = CalculateTankScore(entry, category)
		else
			rawScore, samples = CalculateSupportScore(entry, category)
		end
		if samples > 0 then
			reliabilitySamples = reliabilitySamples or samples
			local confidence, r, g, b = GetConfidence(reliabilitySamples)
			entries[#entries + 1] = {
				classToken = entry.classToken,
				specializationID = entry.specializationID,
				specialization = entry.specialization,
				specializationTexture = entry.specializationTexture,
				specializationTexCoords = entry.specializationTexCoords,
				score = ShrinkScore(rawScore, reliabilitySamples),
				rawScore = rawScore,
				samples = samples,
				reliabilitySamples = reliabilitySamples,
				top1 = SafeNumber(entry.top1),
				confidence = confidence,
				confidenceColor = { r, g, b },
				levelAdjustedSamples = SafeNumber(entry.levelAdjustedSamples),
				averageLevel = SafeNumber(entry.levelAdjustedSamples) > 0
					and SafeNumber(entry.levelSum) / SafeNumber(entry.levelAdjustedSamples) or nil,
				lastLevelReference = tonumber(entry.lastLevelReference),
			}
		end
	end
	table.sort(entries, function(left, right)
		if math.abs(left.score - right.score) > EPSILON then
			return left.score > right.score
		end
		if left.samples ~= right.samples then
			return left.samples > right.samples
		end
		return tostring(left.specialization or "") < tostring(right.specialization or "")
	end)
	return entries, {
		samples = category.samples,
		incomplete = category.incomplete,
		specializations = #entries,
	}
end

PvE.InitializeDatabase = InitializeDatabase
PvE.IsDamageRole = IsDamageRole

-- The PvE panels are loaded from PvEUI.lua.

function PvE.PrintStatus()
	if not session then
		Chat("no active PvE instance")
		return
	end
	local identified, total = 0, 0
	for _, member in pairs(session.roster) do
		total = total + 1
		if IsIdentityValid(GetMemberData(member)) then
			identified = identified + 1
		end
	end
	Chat(
		tostring(session.context.instanceName)
			.. " (" .. tostring(session.context.scope) .. ")"
			.. ", specializations " .. identified .. "/" .. total
			.. ", combat=" .. tostring(session.inCombat and "yes" or "no")
			.. (session.run and ", boss=" .. tostring(session.run.bossCount or 0) or "")
	)
end

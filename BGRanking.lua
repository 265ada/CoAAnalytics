local API = CoAAnalyticsAPI
local Ranking = CoAAnalyticsBGRanking or {}
CoAAnalyticsBGRanking = Ranking
CoAAnalyticsAddon.Modules.BGRanking = Ranking

local config = API and API.Config or {}
local RANKING_PROXIMITY_FLOOR = config.RANKING_PROXIMITY_FLOOR or 0.50
local RANKING_NEAR_TOP_RATIO = config.RANKING_NEAR_TOP_RATIO or 0.90
local RANKING_POINT_EPSILON = config.RANKING_POINT_EPSILON or 0.000000001
local SPECIALIZATION_RANKING_PRIOR_BG =
	config.SPECIALIZATION_RANKING_PRIOR_BG or 5
local STOMP_DEATH_WEIGHT = config.STOMP_DEATH_WEIGHT or 0.70
local STOMP_DAMAGE_WEIGHT = config.STOMP_DAMAGE_WEIGHT or 0.30
local STOMP_MATCH_WEIGHT_SCALE = config.STOMP_MATCH_WEIGHT_SCALE or 0.75
local STOMP_MINIMUM_MATCH_WEIGHT = config.STOMP_MINIMUM_MATCH_WEIGHT or 0.25
local PLAYER_RANKING_NEAR_TOP_RATIO = config.PLAYER_RANKING_NEAR_TOP_RATIO or 0.90
local PLAYER_RANKING_LEVEL_POWER_EXPONENT =
	config.PLAYER_RANKING_LEVEL_POWER_EXPONENT or 1.50
local PLAYER_RANKING_LEVEL_FACTOR_MIN =
	config.PLAYER_RANKING_LEVEL_FACTOR_MIN or 0.65
local PLAYER_RANKING_LEVEL_FACTOR_MAX =
	config.PLAYER_RANKING_LEVEL_FACTOR_MAX or 1.55
local PLAYER_RANKING_MIN_PARTICIPATION =
	config.PLAYER_RANKING_MIN_PARTICIPATION or 0.25
local PLAYER_RANKING_ROLE_KEYS = config.PLAYER_RANKING_ROLE_KEYS or {}

local NormalizePlayerName = API.NormalizePlayerName
local InitializeRankingDatabase = API.InitializeRankingDatabase
local Debug = API.Debug
local CompleteAllyJournal = API.CompleteAllyJournal
local addonDB

local function CopyTextureCoordinates(coordinates)
	if type(coordinates) ~= "table" then
		return
	end

	return {
		coordinates[1],
		coordinates[2],
		coordinates[3],
		coordinates[4],
	}
end

local function GetRankingNumber(value)
	local number = tonumber(value)
	if not number
		or number ~= number
		or number == math.huge
		or number == -math.huge
		or number < 0
	then
		return
	end
	return number
end

local function ClampRankingValue(value, minimum, maximum)
	if value < minimum then
		return minimum
	end
	if value > maximum then
		return maximum
	end
	return value
end

local function GetParticipationRatio(participant)
	return ClampRankingValue(
		tonumber(participant and participant.participationRatio) or 1,
		0,
		1
	)
end

local function GetParticipationAdjustedValue(participant, valueField)
	local participation = GetParticipationRatio(participant)
	local rawValue = GetRankingNumber(participant and participant[valueField])
	if participation < PLAYER_RANKING_MIN_PARTICIPATION
		or not rawValue or rawValue <= 0
	then
		return
	end
	return rawValue / participation, rawValue, participation
end

local function GetExactRankingIdentity(participant)
	if type(participant) ~= "table" then
		return
	end
	local classToken = participant.specializationClassToken
	local specializationID = participant.specializationID
	local specialization = participant.specialization
	if not classToken
		or not specializationID
		or not specialization
		or specialization == "?"
		or specialization == "Unknown"
	then
		return
	end
	if participant.scoreboardClassToken
		and string.upper(tostring(participant.scoreboardClassToken))
			~= string.upper(tostring(classToken))
	then
		return
	end

	local key = string.upper(tostring(classToken))
		.. ":" .. tostring(specializationID)
	return key, classToken
end

local function EnsureRankingEntry(category, participant)
	local key, classToken = GetExactRankingIdentity(participant)
	if not key then
		return
	end
	local entry = category.entries[key]
	if type(entry) ~= "table" then
		entry = {}
		category.entries[key] = entry
	end

	entry.classToken = classToken
	entry.specializationID = participant.specializationID
	entry.specialization = participant.specialization
	entry.specializationTexture = participant.specializationTexture
	entry.specializationTexCoords = CopyTextureCoordinates(
		participant.specializationTexCoords
	)
	entry.performancePoints = tonumber(entry.performancePoints) or 0
	entry.top1Finishes = tonumber(entry.top1Finishes)
		or tonumber(entry.wins)
		or 0
	entry.wins = entry.top1Finishes
	entry.top1V2 = tonumber(entry.top1V2) or 0
	entry.legacyTop1 = tonumber(entry.legacyTop1) or 0
	entry.appearances = tonumber(entry.appearances) or 0
	entry.appearanceWeight = tonumber(entry.appearanceWeight) or 0
	entry.qualifiedBGs = tonumber(entry.qualifiedBGs) or 0
	entry.nearTopBGs = tonumber(entry.nearTopBGs) or 0
	return entry, key
end

local function CalculateBattlegroundStomp(participants)
	local totalsByTeam = {}
	local teamKeys = {}

	for _, participant in ipairs(participants or {}) do
		local team = participant and participant.team
		local deaths = participant and GetRankingNumber(participant.deaths)
		local damage = participant and GetRankingNumber(participant.damage)
		if team == nil or deaths == nil or damage == nil then
			return nil, nil, "missing team context"
		end

		local teamKey = tostring(team)
		if teamKey == "" then
			return nil, nil, "missing team token"
		end
		local totals = totalsByTeam[teamKey]
		if not totals then
			totals = { deaths = 0, damage = 0 }
			totalsByTeam[teamKey] = totals
			teamKeys[#teamKeys + 1] = teamKey
		end
		totals.deaths = totals.deaths + deaths
		totals.damage = totals.damage + damage
	end

	if #teamKeys ~= 2 then
		return nil, nil, "expected two teams"
	end
	table.sort(teamKeys)
	local first = totalsByTeam[teamKeys[1]]
	local second = totalsByTeam[teamKeys[2]]
	local totalDeaths = first.deaths + second.deaths
	local totalDamage = first.damage + second.damage
	local deathImbalance = math.abs(first.deaths - second.deaths)
		/ (totalDeaths + 10)
	local damageImbalance = 0
	local damageAndDeathsAligned = (
		first.damage > second.damage and first.deaths < second.deaths
	) or (
		second.damage > first.damage and second.deaths < first.deaths
	)
	if damageAndDeathsAligned and totalDamage > 0 then
		damageImbalance = math.abs(first.damage - second.damage) / totalDamage
	end

	local stompScore = ClampRankingValue(
		(STOMP_DEATH_WEIGHT * deathImbalance)
			+ (STOMP_DAMAGE_WEIGHT * damageImbalance),
		0,
		1
	)
	local matchWeight = math.max(
		STOMP_MINIMUM_MATCH_WEIGHT,
		1 - (STOMP_MATCH_WEIGHT_SCALE * stompScore)
	)
	return stompScore, matchWeight, {
		deathImbalance = deathImbalance,
		damageImbalance = damageImbalance,
		damageAndDeathsAligned = damageAndDeathsAligned,
	}
end

local function RecordSmoothedRankingCategory(
	category,
	participants,
	valueField,
	matchWeight,
	contextValid
)
	if not category then
		return false
	end
	if not contextValid then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false, "team context"
	end

	local globalTop = 0
	local bestBySpecialization = {}
	local seenSpecializations = {}
	local unresolvedContenders = false

	for _, participant in ipairs(participants or {}) do
		local value, rawValue, participation =
			GetParticipationAdjustedValue(participant, valueField)
		if value and value > globalTop then
			globalTop = value
		end
		local entry, key
		if value then
			entry, key = EnsureRankingEntry(category, participant)
		end
		if entry and key then
			local seen = seenSpecializations[key]
			if not seen or participation > seen.participation then
				seenSpecializations[key] = {
					entry = entry,
					participation = participation,
				}
			end
			local current = bestBySpecialization[key]
			if value and (not current or value > current.value) then
				bestBySpecialization[key] = {
					entry = entry,
					participant = participant,
					value = value,
					rawValue = rawValue,
					participation = participation,
				}
			end
		end
	end

	if globalTop <= 0 then
		category.emptyBGs = (tonumber(category.emptyBGs) or 0) + 1
		return false, "empty"
	end

	-- An unknown specialization above the effective 50% floor would own part
	-- of the normalized point. Exclude the category instead of redistributing
	-- that missing credit to the specializations which happened to be known.
	for _, participant in ipairs(participants or {}) do
		local value = GetParticipationAdjustedValue(participant, valueField) or 0
		local key = GetExactRankingIdentity(participant)
		if not key and (value / globalTop) > RANKING_PROXIMITY_FLOOR then
			unresolvedContenders = true
			break
		end
	end
	if unresolvedContenders then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false, "unresolved contender"
	end

	local qualified = {}
	local rawTotal = 0
	for key, best in pairs(bestBySpecialization) do
		local ratio = ClampRankingValue(best.value / globalTop, 0, 1)
		local proximity = math.max(
			0,
			(ratio - RANKING_PROXIMITY_FLOOR)
				/ (1 - RANKING_PROXIMITY_FLOOR)
		)
		local rawPoint = proximity * proximity
		if rawPoint > 0 then
			qualified[#qualified + 1] = {
				key = key,
				entry = best.entry,
				participant = best.participant,
				value = best.value,
				rawValue = best.rawValue,
				participation = best.participation,
				ratio = ratio,
				rawPoint = rawPoint,
			}
			rawTotal = rawTotal + rawPoint
		end
	end
	table.sort(qualified, function(left, right)
		return left.key < right.key
	end)

	if rawTotal <= 0 then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false, "no resolved top"
	end

	category.analyzedBGs = (tonumber(category.analyzedBGs) or 0) + 1
	category.totalWeight = (tonumber(category.totalWeight) or 0) + matchWeight
	for _, seen in pairs(seenSpecializations) do
		local entry = seen.entry
		entry.appearances = (tonumber(entry.appearances) or 0) + 1
		entry.appearanceWeight =
			(tonumber(entry.appearanceWeight) or 0)
				+ matchWeight * seen.participation
	end

	for _, result in ipairs(qualified) do
		local entry = result.entry
		local credit = (result.rawPoint / rawTotal)
			* matchWeight * result.participation
		entry.performancePoints =
			(tonumber(entry.performancePoints) or 0) + credit
		entry.qualifiedBGs = (tonumber(entry.qualifiedBGs) or 0) + 1
		if result.ratio + RANKING_POINT_EPSILON >= RANKING_NEAR_TOP_RATIO then
			entry.nearTopBGs = (tonumber(entry.nearTopBGs) or 0) + 1
		end
		if result.value + RANKING_POINT_EPSILON >= globalTop then
			entry.top1Finishes = (tonumber(entry.top1Finishes) or 0) + 1
			entry.top1V2 = (tonumber(entry.top1V2) or 0) + 1
			entry.wins = entry.top1Finishes
		end
		entry.lastPlayer = result.participant.name
		entry.lastValue = result.rawValue
		entry.lastAdjustedValue = result.value
		entry.lastRatio = result.ratio
		entry.lastCredit = credit
		entry.lastMatchWeight = matchWeight
		entry.lastParticipationRatio = result.participation
	end
	return true
end

local function GetSpecializationAppearanceWeight(category, entry)
	local weight = tonumber(entry and entry.appearanceWeight)
	if weight and weight > 0 then
		return weight
	end

	-- Defensive fallback for a database copied without running migration.
	local appearances = tonumber(entry and entry.appearances) or 0
	local analyzedBGs = tonumber(category and category.analyzedBGs) or 0
	local totalWeight = tonumber(category and category.totalWeight) or 0
	local averageWeight = analyzedBGs > 0 and totalWeight / analyzedBGs or 1
	return appearances * averageWeight
end

local function CalculateSpecializationRanking(category)
	local results = {}
	if type(category) ~= "table" or type(category.entries) ~= "table" then
		return results, {
			globalMean = 0,
			priorWeight = SPECIALIZATION_RANKING_PRIOR_BG,
			totalScore = 0,
		}
	end

	local totalPoints = 0
	local totalAppearanceWeight = 0
	for _, entry in pairs(category.entries) do
		if type(entry) == "table" then
			totalPoints = totalPoints
				+ math.max(0, tonumber(entry.performancePoints) or 0)
			totalAppearanceWeight = totalAppearanceWeight
				+ math.max(0, GetSpecializationAppearanceWeight(category, entry))
		end
	end
	local globalMean = totalAppearanceWeight > 0
		and totalPoints / totalAppearanceWeight
		or 0
	local totalScore = 0

	for _, entry in pairs(category.entries) do
		if type(entry) == "table" then
			local points = math.max(0, tonumber(entry.performancePoints) or 0)
			local top1 = tonumber(entry.top1Finishes)
				or tonumber(entry.wins)
				or 0
			if points > RANKING_POINT_EPSILON or top1 > 0 then
				local appearanceWeight =
					GetSpecializationAppearanceWeight(category, entry)
				local rawScore = appearanceWeight > 0
					and points / appearanceWeight
					or 0
				local smoothedScore =
					(points + globalMean * SPECIALIZATION_RANKING_PRIOR_BG)
					/ (appearanceWeight + SPECIALIZATION_RANKING_PRIOR_BG)
				local result = {
					entry = entry,
					points = points,
					appearanceWeight = appearanceWeight,
					rawScore = rawScore,
					score = smoothedScore,
					share = 0,
				}
				results[#results + 1] = result
				totalScore = totalScore + smoothedScore
			end
		end
	end

	for _, result in ipairs(results) do
		result.share = totalScore > 0 and result.score / totalScore or 0
	end
	table.sort(results, function(left, right)
		if math.abs(left.score - right.score) > RANKING_POINT_EPSILON then
			return left.score > right.score
		end
		local leftTop1 = tonumber(left.entry.top1Finishes)
			or tonumber(left.entry.wins)
			or 0
		local rightTop1 = tonumber(right.entry.top1Finishes)
			or tonumber(right.entry.wins)
			or 0
		if leftTop1 ~= rightTop1 then
			return leftTop1 > rightTop1
		end
		local leftNearTop = tonumber(left.entry.nearTopBGs) or 0
		local rightNearTop = tonumber(right.entry.nearTopBGs) or 0
		if leftNearTop ~= rightNearTop then
			return leftNearTop > rightNearTop
		end
		local leftClass = tostring(left.entry.classToken or "")
		local rightClass = tostring(right.entry.classToken or "")
		if leftClass ~= rightClass then
			return leftClass < rightClass
		end
		return tostring(left.entry.specialization or "")
			< tostring(right.entry.specialization or "")
	end)

	return results, {
		globalMean = globalMean,
		priorWeight = SPECIALIZATION_RANKING_PRIOR_BG,
		totalScore = totalScore,
		totalAppearanceWeight = totalAppearanceWeight,
	}
end

local PLAYER_ROLE_METRICS = {
	MELEE_DAMAGER = { damage = 0.90, survival = 0.10 },
	RANGED_DAMAGER = { damage = 0.90, survival = 0.10 },
	DAMAGER = { damage = 0.90, survival = 0.10 },
	HEALER = { healing = 0.95, survival = 0.05 },
	TANK = { objectives = 0.30, survival = 0.30, damage = 0.15, healing = 0.15, utility = 0.10 },
	SUPPORT = { utility = 0.25, damage = 0.30, healing = 0.25, objectives = 0.05, survival = 0.15 },
}

local function GetPlayerRankingRole(participant)
	local role = participant and participant.role
	if role == "MELEE_DAMAGER"
		or role == "RANGED_DAMAGER"
		or role == "DAMAGER"
		or role == "HEALER"
		or role == "TANK"
		or role == "SUPPORT"
	then
		return role
	end
end

local function GetPlayerRankingKey(participant)
	local name = participant and NormalizePlayerName(participant.name)
	if not name or name == "" then
		return
	end
	return name
end

local function EnsurePlayerRankingEntry(category, participant, roleKey)
	local key = GetPlayerRankingKey(participant)
	local _, classToken = GetExactRankingIdentity(participant)
	if not key or not classToken then
		return
	end
	local entry = category.entries[key]
	if type(entry) ~= "table" then
		entry = {}
		category.entries[key] = entry
	end
	entry.key = key
	entry.name = participant.name
	entry.guid = participant.guid or entry.guid
	entry.level = participant.level or entry.level
	entry.classToken = classToken
	entry.role = roleKey
	entry.scoreSum = tonumber(entry.scoreSum) or 0
	entry.scoreWeight = tonumber(entry.scoreWeight) or 0
	entry.appearances = tonumber(entry.appearances) or 0
	entry.comparableBGs = tonumber(entry.comparableBGs) or 0
	entry.nearTopBGs = tonumber(entry.nearTopBGs) or 0
	entry.top1Finishes = tonumber(entry.top1Finishes) or 0
	entry.specializations = type(entry.specializations) == "table"
		and entry.specializations or {}
	return entry
end

local function UpdatePlayerRankingSpecialization(entry, participant)
	local identityKey, classToken = GetExactRankingIdentity(participant)
	if not entry or not identityKey then
		return
	end
	local specialization = entry.specializations[identityKey]
	if type(specialization) ~= "table" then
		specialization = {}
		entry.specializations[identityKey] = specialization
	end
	specialization.classToken = classToken
	specialization.specializationID = participant.specializationID
	specialization.specialization = participant.specialization
	specialization.specializationTexture = participant.specializationTexture
	specialization.specializationTexCoords = CopyTextureCoordinates(
		participant.specializationTexCoords
	)
	specialization.appearances = (tonumber(specialization.appearances) or 0) + 1
	local mainAppearances = tonumber(entry.mainSpecializationAppearances) or 0
	if not entry.specializationID or specialization.appearances >= mainAppearances then
		entry.specializationID = specialization.specializationID
		entry.specialization = specialization.specialization
		entry.specializationTexture = specialization.specializationTexture
		entry.specializationTexCoords = CopyTextureCoordinates(
			specialization.specializationTexCoords
		)
		entry.mainSpecializationAppearances = specialization.appearances
	end
end

local function Median(values)
	if #values == 0 then
		return
	end
	table.sort(values)
	local middle = math.floor((#values + 1) / 2)
	if #values % 2 == 0 then
		return (values[middle] + values[middle + 1]) / 2
	end
	return values[middle]
end

local function Mean(values)
	if #values == 0 then
		return
	end
	local total = 0
	for _, value in ipairs(values) do
		total = total + value
	end
	return total / #values
end

local function GetRoleLevelReference(participants)
	local levels = {}
	for _, participant in ipairs(participants or {}) do
		local level = tonumber(participant.level)
		if level and level > 0 then
			levels[#levels + 1] = level
		end
	end
	return Median(levels)
end

local function GetPlayerLevelFactor(participant, referenceLevel)
	local level = tonumber(participant and participant.level)
	if not level or level <= 0 or not referenceLevel or referenceLevel <= 0 then
		return 1, level
	end
	return ClampRankingValue(
		(level / referenceLevel) ^ PLAYER_RANKING_LEVEL_POWER_EXPONENT,
		PLAYER_RANKING_LEVEL_FACTOR_MIN,
		PLAYER_RANKING_LEVEL_FACTOR_MAX
	), level
end

local function GetPlayerMetricValue(participant, metric, levelReference)
	local participation = GetParticipationRatio(participant)
	if participation < PLAYER_RANKING_MIN_PARTICIPATION then
		return
	end
	if metric == "survival" then
		local deaths = GetRankingNumber(participant.deaths) or 0
		return 1 / (1 + (deaths / participation) * 0.20)
	end
	local value = GetRankingNumber(participant[metric])
	if value == nil then
		return
	end
	value = value / participation
	if metric == "damage" or metric == "healing" then
		local factor = GetPlayerLevelFactor(participant, levelReference)
		value = value / factor
	end
	return value
end

local function HasPlayerRoleActivity(participant, roleKey)
	if GetParticipationRatio(participant)
		< PLAYER_RANKING_MIN_PARTICIPATION
	then
		return false
	end
	local damage = GetRankingNumber(participant and participant.damage) or 0
	local healing = GetRankingNumber(participant and participant.healing) or 0
	if roleKey == "HEALER" then
		return healing > 0
	end
	if roleKey == "MELEE_DAMAGER"
		or roleKey == "RANGED_DAMAGER"
		or roleKey == "DAMAGER"
	then
		return damage > 0
	end
	return damage > 0 or healing > 0
		or (GetRankingNumber(participant and participant.objectives) or 0) > 0
		or (GetRankingNumber(participant and participant.utility) or 0) > 0
end

local function GetRoleMetricReferences(participants, levelReference)
	local values = {
		damage = {},
		healing = {},
		objectives = {},
		utility = {},
		survival = {},
	}
	for _, participant in ipairs(participants) do
		for metric in pairs(values) do
			local value = GetPlayerMetricValue(participant, metric, levelReference)
			if value ~= nil then
				values[metric][#values[metric] + 1] = value
			end
		end
	end
	return {
		damage = Mean(values.damage),
		healing = Mean(values.healing),
		objectives = Mean(values.objectives),
		utility = Mean(values.utility),
		survival = Mean(values.survival),
	}
end

local function GetNormalizedPlayerMetric(
	participant,
	metric,
	reference,
	levelReference
)
	if not reference or reference <= 0 then
		return
	end
	local value = GetPlayerMetricValue(participant, metric, levelReference)
	if value == nil then
		return
	end
	local ratio = math.max(0, value / reference)
	-- Transformation continue bornee entre 0 et 2. Contrairement a l'ancien
	-- clamp, deux gros scores ne deviennent jamais artificiellement egaux.
	return ClampRankingValue(2 * ratio / (1 + ratio), 0, 2)
end

local function RecordPlayerRoleCategory(
	category,
	roleKey,
	participants,
	matchWeight,
	contextValid
)
	if not category then
		return false
	end
	if not contextValid then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false
	end
	local roleParticipants = {}
	for _, participant in ipairs(participants or {}) do
		if GetPlayerRankingRole(participant) == roleKey
			and GetExactRankingIdentity(participant)
			and HasPlayerRoleActivity(participant, roleKey)
		then
			roleParticipants[#roleParticipants + 1] = participant
		end
	end
	if #roleParticipants == 0 then
		return false
	end

	local levelReference = GetRoleLevelReference(roleParticipants)
	local references = GetRoleMetricReferences(roleParticipants, levelReference)
	if (roleKey == "MELEE_DAMAGER"
		or roleKey == "RANGED_DAMAGER"
		or roleKey == "DAMAGER")
		and (not references.damage or references.damage <= 0)
	then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false
	elseif roleKey == "HEALER"
		and (not references.healing or references.healing <= 0)
	then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false
	elseif (roleKey == "TANK" or roleKey == "SUPPORT")
		and (not references.damage or references.damage <= 0)
		and (not references.healing or references.healing <= 0)
		and (not references.objectives or references.objectives <= 0)
		and (not references.utility or references.utility <= 0)
	then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false
	end

	local metrics = PLAYER_ROLE_METRICS[roleKey]
	local results = {}
	local bestScore = 0
	for _, participant in ipairs(roleParticipants) do
		local weightedScore, availableWeight = 0, 0
		local levelFactor, playerLevel =
			GetPlayerLevelFactor(participant, levelReference)
		for metric, metricWeight in pairs(metrics) do
			local normalized = GetNormalizedPlayerMetric(
				participant,
				metric,
				references[metric],
				levelReference
			)
			if normalized then
				weightedScore = weightedScore + normalized * metricWeight
				availableWeight = availableWeight + metricWeight
			end
		end
		if availableWeight > 0 then
			local participation = GetParticipationRatio(participant)
			local score = ClampRankingValue(
				100 * weightedScore / availableWeight,
				30,
				200
			)
			results[#results + 1] = {
				participant = participant,
				score = score,
				level = playerLevel,
				levelFactor = levelFactor,
				levelReference = levelReference,
				participation = participation,
			}
			bestScore = math.max(bestScore, score)
		end
	end
	if #results == 0 or bestScore <= 0 then
		category.incompleteBGs = (tonumber(category.incompleteBGs) or 0) + 1
		return false
	end

	category.analyzedBGs = (tonumber(category.analyzedBGs) or 0) + 1
	category.totalWeight = (tonumber(category.totalWeight) or 0) + matchWeight
	for _, result in ipairs(results) do
		local participant = result.participant
		local entry = EnsurePlayerRankingEntry(category, participant, roleKey)
		if entry then
			local playerWeight = matchWeight * result.participation
			entry.scoreSum = entry.scoreSum + result.score * playerWeight
			entry.scoreWeight = entry.scoreWeight + playerWeight
			entry.appearances = entry.appearances + 1
			entry.participationTotal =
				(tonumber(entry.participationTotal) or 0)
					+ result.participation
			if #results >= 2 then
				entry.comparableBGs = entry.comparableBGs + 1
				if result.score + RANKING_POINT_EPSILON
					>= bestScore * PLAYER_RANKING_NEAR_TOP_RATIO
				then
					entry.nearTopBGs = entry.nearTopBGs + 1
				end
				if result.score + RANKING_POINT_EPSILON >= bestScore then
					entry.top1Finishes = entry.top1Finishes + 1
				end
			end
			entry.lastScore = result.score
			entry.lastMatchWeight = matchWeight
			entry.lastDamage = GetRankingNumber(participant.damage) or 0
			entry.lastHealing = GetRankingNumber(participant.healing) or 0
			entry.lastDeaths = GetRankingNumber(participant.deaths) or 0
			entry.lastObjectives = GetRankingNumber(participant.objectives) or 0
			entry.lastUtility = GetRankingNumber(participant.utility) or 0
			entry.lastLevel = result.level
			entry.lastLevelFactor = result.levelFactor
			entry.lastLevelReference = result.levelReference
			entry.lastParticipationRatio = result.participation
			entry.normalizationVersion = 2
			entry.lastSeen = time()
			UpdatePlayerRankingSpecialization(entry, participant)
		end
	end
	return true
end

local function RecordPlayerRankings(
	playerRankings,
	participants,
	matchWeight,
	contextValid
)
	if not playerRankings then
		return false
	end
	if not contextValid then
		playerRankings.incompleteBattlegrounds =
			(tonumber(playerRankings.incompleteBattlegrounds) or 0) + 1
		return false
	end
	local recorded = false
	for _, roleKey in ipairs(PLAYER_RANKING_ROLE_KEYS) do
		local category = playerRankings.categories[roleKey]
		if RecordPlayerRoleCategory(
			category,
			roleKey,
			participants,
			matchWeight,
			contextValid
		) then
			recorded = true
		end
	end
	if recorded then
		playerRankings.totalBattlegrounds =
			(tonumber(playerRankings.totalBattlegrounds) or 0) + 1
	end
	return recorded
end

local function RecordBattlegroundResult(signature, matchSnapshot)
	addonDB = API and API.GetDatabase and API.GetDatabase()
	if not addonDB
		or not signature
		or signature == ""
		or type(matchSnapshot) ~= "table"
		or type(matchSnapshot.participants) ~= "table"
	then
		return false
	end
	if CompleteAllyJournal then
		CompleteAllyJournal("battleground finished")
	end
	InitializeRankingDatabase()

	local rankings = addonDB.rankings
	if rankings.lastMatchSignature == signature then
		return false, "duplicate"
	end

	local stompScore, matchWeight, stompDetails =
		CalculateBattlegroundStomp(matchSnapshot.participants)
	local contextValid = stompScore ~= nil and matchWeight ~= nil

	rankings.lastMatchSignature = signature
	rankings.totalBattlegrounds = (tonumber(rankings.totalBattlegrounds) or 0) + 1
	rankings.smoothedBattlegrounds =
		(tonumber(rankings.smoothedBattlegrounds) or 0) + 1
	if contextValid then
		rankings.stompEvaluatedBGs =
			(tonumber(rankings.stompEvaluatedBGs) or 0) + 1
		rankings.stompScoreTotal =
			(tonumber(rankings.stompScoreTotal) or 0) + stompScore
		rankings.matchWeightTotal =
			(tonumber(rankings.matchWeightTotal) or 0) + matchWeight
	else
		rankings.contextIncompleteBGs =
			(tonumber(rankings.contextIncompleteBGs) or 0) + 1
	end

	-- matchWeight is deliberately calculated once and shared unchanged by
	-- both categories and every specialization. Deaths never penalize a player.
	local damageRecorded, damageReason = RecordSmoothedRankingCategory(
		rankings.dps,
		matchSnapshot.participants,
		"damage",
		matchWeight,
		contextValid
	)
	local healingRecorded, healingReason = RecordSmoothedRankingCategory(
		rankings.healing,
		matchSnapshot.participants,
		"healing",
		matchWeight,
		contextValid
	)
	local playersRecorded = RecordPlayerRankings(
		rankings.players,
		matchSnapshot.participants,
		matchWeight,
		contextValid
	)

	rankings.lastStompScore = stompScore
	rankings.lastMatchWeight = matchWeight
	rankings.lastStompDeathImbalance = stompDetails
		and stompDetails.deathImbalance
	rankings.lastStompDamageImbalance = stompDetails
		and stompDetails.damageImbalance
	rankings.lastContextValid = contextValid and true or false

	Debug(
		"battleground ranking recorded",
		"stomp=" .. tostring(stompScore),
		"weight=" .. tostring(matchWeight),
		"dps=" .. tostring(damageRecorded and "ok" or damageReason),
		"healing=" .. tostring(healingRecorded and "ok" or healingReason),
		"players=" .. tostring(playersRecorded and "ok" or "incomplete")
	)
	if CoAAnalyticsAddon and CoAAnalyticsAddon.Events then
		CoAAnalyticsAddon.Events:Fire("BG_RANKING_UPDATED")
	end
	return true
end

Ranking.RecordBattlegroundResult = RecordBattlegroundResult
Ranking.CopyTextureCoordinates = CopyTextureCoordinates
Ranking.ClampRankingValue = ClampRankingValue
Ranking.CalculateSpecializationRanking = CalculateSpecializationRanking

API.RecordBattlegroundResult = RecordBattlegroundResult
API.CopyTextureCoordinates = CopyTextureCoordinates
API.ClampRankingValue = ClampRankingValue
API.CalculateSpecializationRanking = CalculateSpecializationRanking

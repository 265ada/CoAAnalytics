local ADDON_NAME = ...

local API = CoAAnalyticsAPI
local MAX_ROWS = MAX_WORLDSTATE_SCORE_BUTTONS or 23
local NAME_COLUMN_WIDTH = 275
local ROLE_ICON_SIZE = 14
local AWARD_ICON_SIZE = 14
local HEADER_TEXT_OFFSET = 18
local ROLE_NAME_GAP = 3
local NAME_TEXT_MAX_WIDTH = 230
local AWARD_GAP = 2
local AWARD_TEXT_GAP = 3
local RECORDING_GRACE_SECONDS = 10
local RECORDING_RETRY_INTERVAL = 1
local RECORDING_SCORE_SETTLE_SECONDS = 2
local RANKING_SCORE_POLL_INTERVAL = 15
local RANKING_PROXIMITY_FLOOR = 0.50
local MIN_RANKING_PARTICIPATION = 0.25
local INITIAL_ROSTER_GRACE_SECONDS = 10
local RANKING_COUNTER_FIELDS = {
	"killingBlows",
	"honorableKills",
	"deaths",
	"damage",
	"healing",
	"objectives",
	"utility",
}
local TOP_DAMAGE_TEXTURE =
	"Interface\\AddOns\\CoAAnalytics\\Textures\\top_damage"
local TOP_HEALING_TEXTURE =
	"Interface\\AddOns\\CoAAnalytics\\Textures\\top_healing"

local ROLE_ATLAS_FALLBACKS = {
	DAMAGER = "ui-lfg-roleicon-dps",
	MELEE_DAMAGER = "ui-lfg-roleicon-meleedps",
	RANGED_DAMAGER = "ui-lfg-roleicon-rangeddps",
	HEALER = "ui-lfg-roleicon-healer",
	TANK = "ui-lfg-roleicon-tank",
	SUPPORT = "ui-lfg-roleicon-generic",
}

local ROLE_TEXTURE_FALLBACKS = {
	DAMAGER = "Interface\\Icons\\Ability_DualWield",
	MELEE_DAMAGER = "Interface\\Icons\\INV_Sword_04",
	RANGED_DAMAGER = "Interface\\Icons\\INV_Weapon_Bow_07",
	HEALER = "Interface\\Icons\\Spell_Holy_HolyBolt",
	TANK = "Interface\\Icons\\INV_Shield_06",
	SUPPORT = "Interface\\Icons\\Spell_Holy_BlessingOfStrength",
}

local UNKNOWN_ROLE_TEXTURE = "Interface\\Icons\\INV_Misc_QuestionMark"

local rows = {}
local initialized = false
local renderPending = false
local renderWorker = CreateFrame("Frame")
local wasInBattleground = false
local matchRecorded = false
local finishDetectedAt
local recordAttemptScheduled = false
local recordGeneration = 0
local rankingParticipants = {}
local lastScoreSnapshotSignature
local scoreSnapshotStableSince
local pendingMatchSignature
local pendingMatchSnapshot
local scorePollGeneration = 0
local rankingUtilityByGUID = {}
local rankingUtilityByName = {}
local observedActiveMatch = false
local matchEnteredRuntime = 0

local function IsBattleground()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "pvp"
end

local function GetBattlegroundRuntimeSeconds()
	if type(GetBattlefieldInstanceRunTime) ~= "function" then
		return 0
	end
	local success, milliseconds = pcall(GetBattlefieldInstanceRunTime)
	milliseconds = success and tonumber(milliseconds) or 0
	return milliseconds > 0 and milliseconds / 1000 or 0
end

local function SetAtlasOrTexture(texture, atlas, fallback)
	local applied = false
	if texture.SetAtlas and atlas then
		applied = pcall(texture.SetAtlas, texture, atlas, false)
	end
	if not applied then
		texture:SetTexture(fallback)
		texture:SetTexCoord(0, 1, 0, 1)
	end
end

local function SetRoleTexture(texture, role)
	if not role or role == "NONE" then
		texture:SetTexture(UNKNOWN_ROLE_TEXTURE)
		texture:SetTexCoord(0, 1, 0, 1)
		texture:Show()
		return
	end
	if API and API.ApplyRoleTexture then
		API.ApplyRoleTexture(texture, role)
		texture:Show()
		return
	end

	local officialAtlases = type(ROLE_ATLAS) == "table" and ROLE_ATLAS
	local atlas = officialAtlases and officialAtlases[role]
		or ROLE_ATLAS_FALLBACKS[role]
	SetAtlasOrTexture(
		texture,
		atlas,
		ROLE_TEXTURE_FALLBACKS[role] or ROLE_TEXTURE_FALLBACKS.DAMAGER
	)
	texture:Show()
end

local function GetClassColorCode(classToken)
	local color = classToken and RAID_CLASS_COLORS[classToken]
	if not color then
		return "ffffffff"
	end

	return string.format(
		"ff%02x%02x%02x",
		math.floor((color.r or 1) * 255 + 0.5),
		math.floor((color.g or 1) * 255 + 0.5),
		math.floor((color.b or 1) * 255 + 0.5)
	)
end

local function GetDisplayName(fullName)
	return fullName and (string.match(fullName, "^([^-]+)") or fullName) or "?"
end

local function CreateRowOverlay(index)
	local scoreRow = _G["WorldStateScoreButton" .. index]
	local classButton = _G["WorldStateScoreButton" .. index .. "ClassButton"]
	local nameFrame = _G["WorldStateScoreButton" .. index .. "Name"]
	local originalName = _G["WorldStateScoreButton" .. index .. "NameText"]
	if not scoreRow or not classButton or not nameFrame or not originalName then
		return
	end

	nameFrame:SetWidth(NAME_COLUMN_WIDTH)
	originalName:SetAlpha(0)

	local specIcon = classButton:CreateTexture(nil, "OVERLAY")
	specIcon:SetAllPoints(classButton)

	local roleIcon = nameFrame:CreateTexture(nil, "OVERLAY")
	roleIcon:SetWidth(ROLE_ICON_SIZE)
	roleIcon:SetHeight(ROLE_ICON_SIZE)
	roleIcon:SetPoint("LEFT", classButton, "RIGHT", 2, 0)
	roleIcon:Hide()

	local nameText = nameFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nameText:SetPoint("LEFT", roleIcon, "RIGHT", ROLE_NAME_GAP, 0)
	nameText:SetWidth(NAME_TEXT_MAX_WIDTH)
	nameText:SetHeight(16)
	nameText:SetJustifyH("LEFT")
	nameText:SetWordWrap(false)

	local topDamage = nameFrame:CreateTexture(nil, "OVERLAY")
	topDamage:SetWidth(AWARD_ICON_SIZE)
	topDamage:SetHeight(AWARD_ICON_SIZE)
	topDamage:SetTexture(TOP_DAMAGE_TEXTURE)
	topDamage:SetTexCoord(0, 1, 0, 1)
	topDamage:Hide()

	local topHealing = nameFrame:CreateTexture(nil, "OVERLAY")
	topHealing:SetWidth(AWARD_ICON_SIZE)
	topHealing:SetHeight(AWARD_ICON_SIZE)
	topHealing:SetTexture(TOP_HEALING_TEXTURE)
	topHealing:SetTexCoord(0, 1, 0, 1)
	topHealing:Hide()

	rows[index] = {
		scoreRow = scoreRow,
		classButton = classButton,
		specIcon = specIcon,
		nameFrame = nameFrame,
		originalName = originalName,
		nameText = nameText,
		roleIcon = roleIcon,
		topDamage = topDamage,
		topHealing = topHealing,
	}
end

local function PositionAwards(row, showDamage, showHealing)
	local awardCount = (showDamage and 1 or 0) + (showHealing and 1 or 0)
	local reservedWidth = 0
	if awardCount > 0 then
		reservedWidth = AWARD_TEXT_GAP
			+ (awardCount * AWARD_ICON_SIZE)
			+ ((awardCount - 1) * AWARD_GAP)
	end

	local maximumTextWidth = NAME_TEXT_MAX_WIDTH - reservedWidth
	row.nameText:SetWidth(1000)
	local textWidth = math.max(
		1,
		math.min(row.nameText:GetStringWidth() or 1, maximumTextWidth)
	)
	row.nameText:SetWidth(textWidth)

	row.topDamage:ClearAllPoints()
	if showDamage then
		row.topDamage:SetPoint(
			"LEFT",
			row.nameText,
			"RIGHT",
			AWARD_TEXT_GAP,
			0
		)
		row.topDamage:Show()
	else
		row.topDamage:Hide()
	end

	row.topHealing:ClearAllPoints()
	if showHealing then
		if showDamage then
			row.topHealing:SetPoint(
				"LEFT",
				row.topDamage,
				"RIGHT",
				AWARD_GAP,
				0
			)
		else
			row.topHealing:SetPoint(
				"LEFT",
				row.nameText,
				"RIGHT",
				AWARD_TEXT_GAP,
				0
			)
		end
		row.topHealing:Show()
	else
		row.topHealing:Hide()
	end
end

local function ScheduleRender()
	if not IsBattleground()
		or not WorldStateScoreFrame
		or not WorldStateScoreFrame:IsShown()
	then
		return
	end

	renderPending = true
	renderWorker:Show()
end

local function InitializeScoreboard()
	if initialized then
		return
	end
	if not WorldStateScoreFrame or not WorldStateScoreFrameName then
		return
	end

	initialized = true
	WorldStateScoreFrameName:SetWidth(NAME_COLUMN_WIDTH)
	WorldStateScoreFrameNameText:ClearAllPoints()
	WorldStateScoreFrameNameText:SetPoint(
		"LEFT",
		WorldStateScoreFrameName,
		"LEFT",
		HEADER_TEXT_OFFSET,
		0
	)
	WorldStateScoreFrameNameText:SetWidth(NAME_COLUMN_WIDTH - HEADER_TEXT_OFFSET)
	WorldStateScoreFrameNameText:SetJustifyH("LEFT")

	for index = 1, MAX_ROWS do
		CreateRowOverlay(index)
	end

	if WorldStateScoreScrollFrame and WorldStateScoreScrollFrame.HookScript then
		WorldStateScoreScrollFrame:HookScript("OnVerticalScroll", ScheduleRender)
	end
	if type(WorldStateScoreFrameTab_OnClick) == "function" then
		hooksecurefunc("WorldStateScoreFrameTab_OnClick", ScheduleRender)
	end
	if type(SortBattlefieldScoreData) == "function" then
		hooksecurefunc("SortBattlefieldScoreData", ScheduleRender)
	end
	if type(WorldStateScoreFrame_Update) == "function" then
		hooksecurefunc("WorldStateScoreFrame_Update", ScheduleRender)
	end

	WorldStateScoreFrame_Resize()
end

local function FindTopScoreIndexes()
	local topDamageIndex
	local topHealingIndex
	local topDamage = 0
	local topHealing = 0
	local scoreCount = GetNumBattlefieldScores()

	for index = 1, scoreCount do
		local name, _, _, _, _, _, _, _, _, _, damage, healing =
			GetBattlefieldScore(index)
		if name and damage and damage > topDamage then
			topDamage = damage
			topDamageIndex = index
		end
		if name and healing and healing > topHealing then
			topHealing = healing
			topHealingIndex = index
		end
	end

	return topDamageIndex, topHealingIndex, topDamage, topHealing
end

local function GetCompletedBattlegroundWinner()
	if type(GetBattlefieldWinner) ~= "function" then
		return
	end
	local success, winner = pcall(GetBattlefieldWinner)
	if not success then
		return
	end
	winner = tonumber(winner)
	if winner == 0 or winner == 1 then
		return winner
	end
end

local function GetRankingScoreNumber(value)
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

local function RecordBattlegroundUtility(...)
	if not wasInBattleground then
		return
	end
	local _, subevent, arg3, arg4, arg5 = ...
	if subevent ~= "SPELL_INTERRUPT"
		and subevent ~= "SPELL_DISPEL"
		and subevent ~= "SPELL_STOLEN"
	then
		return
	end
	local sourceGUID, sourceName
	if type(arg3) == "boolean" then
		sourceGUID = arg4
		sourceName = arg5
	else
		sourceGUID = arg3
		sourceName = arg4
	end
	if sourceGUID then
		rankingUtilityByGUID[sourceGUID] =
			(tonumber(rankingUtilityByGUID[sourceGUID]) or 0) + 1
	end
	if sourceName then
		local normalized = string.lower(tostring(sourceName))
		rankingUtilityByName[normalized] =
			(tonumber(rankingUtilityByName[normalized]) or 0) + 1
	end
end

local function GetBattlegroundUtility(guid, name)
	if guid and rankingUtilityByGUID[guid] then
		return rankingUtilityByGUID[guid]
	end
	return name and rankingUtilityByName[string.lower(tostring(name))] or 0
end

local function HasExactSpecialization(participant)
	local exact = participant
		and participant.specializationClassToken
		and participant.specializationID
		and participant.specialization
		and participant.specialization ~= "?"
		and participant.specialization ~= "Unknown"
	if not exact then
		return false
	end
	if participant.scoreboardClassToken
		and string.upper(tostring(participant.scoreboardClassToken))
			~= string.upper(tostring(participant.specializationClassToken))
	then
		return false
	end
	return true
end

local function MergeSpecializationData(participant, data)
	if not participant or not data or not HasExactSpecialization(data) then
		return
	end
	participant.specialization = data.specialization
	participant.specializationID = data.specializationID
	participant.specializationClassToken = data.specializationClassToken
	participant.specializationTexture = data.specializationTexture
	participant.specializationTexCoords = data.specializationTexCoords
	participant.role = data.role
	participant.guid = data.guid
	participant.level = data.level
end

local function ReadObjectiveScore(scoreIndex)
	if type(GetNumBattlefieldStats) ~= "function"
		or type(GetBattlefieldStatData) ~= "function"
	then
		return
	end
	local success, statCount = pcall(GetNumBattlefieldStats)
	statCount = success and tonumber(statCount) or 0
	if statCount <= 0 then
		return
	end
	local total = 0
	for statIndex = 1, statCount do
		local read, value = pcall(GetBattlefieldStatData, scoreIndex, statIndex)
		if read and tonumber(value) and tonumber(value) > 0 then
			total = total + tonumber(value)
		end
	end
	return total
end

local function ReadRankingParticipant(scoreIndex)
	local name, killingBlows, honorableKills, deaths, _, team, _, _, _, classToken, damage, healing =
		GetBattlefieldScore(scoreIndex)
	if not name then
		return
	end

	local participant = {
		name = name,
		team = team,
		killingBlows = GetRankingScoreNumber(killingBlows),
		honorableKills = GetRankingScoreNumber(honorableKills),
		deaths = GetRankingScoreNumber(deaths),
		damage = GetRankingScoreNumber(damage),
		healing = GetRankingScoreNumber(healing),
		objectives = ReadObjectiveScore(scoreIndex),
		scoreboardClassToken = classToken,
	}
	local data = API and API.GetPlayerData and API.GetPlayerData(name)
	MergeSpecializationData(participant, data)
	participant.utility = GetBattlegroundUtility(participant.guid, participant.name)
	return participant
end

local function GetRankingParticipantKey(participant)
	return tostring(participant.team == nil and "?" or participant.team)
		.. "|" .. string.lower(tostring(participant.name or "?"))
end

local function MergeRankingParticipant(participant)
	if not participant or not participant.name then
		return
	end
	local key = GetRankingParticipantKey(participant)
	local normalizedName = string.lower(tostring(participant.name))
	local unknownTeamKey = "?|" .. normalizedName
	local unknownTeamRecord
	if participant.team ~= nil and key ~= unknownTeamKey then
		unknownTeamRecord = rankingParticipants[unknownTeamKey]
		rankingParticipants[unknownTeamKey] = nil
	end
	local runtime = GetBattlegroundRuntimeSeconds()
	local existing = rankingParticipants[key]
	if not existing and unknownTeamRecord then
		existing = unknownTeamRecord
		existing.participantKey = key
		rankingParticipants[key] = existing
	elseif existing and unknownTeamRecord then
		existing.firstSeenRuntime = math.min(
			tonumber(existing.firstSeenRuntime) or runtime,
			tonumber(unknownTeamRecord.firstSeenRuntime) or runtime
		)
		existing.lastSeenRuntime = math.max(
			tonumber(existing.lastSeenRuntime) or 0,
			tonumber(unknownTeamRecord.lastSeenRuntime) or 0
		)
		for _, field in ipairs(RANKING_COUNTER_FIELDS) do
			local value = unknownTeamRecord[field]
			if value ~= nil and (
				existing[field] == nil or value > existing[field]
			) then
				existing[field] = value
			end
		end
		existing.scoreboardClassToken = existing.scoreboardClassToken
			or unknownTeamRecord.scoreboardClassToken
		MergeSpecializationData(existing, unknownTeamRecord)
	end
	if not existing then
		local firstSeenRuntime = runtime
		local localPlayerName = type(UnitName) == "function"
			and UnitName("player")
		local isLocalPlayer = localPlayerName
			and string.lower(GetDisplayName(localPlayerName))
				== string.lower(GetDisplayName(participant.name))
		if isLocalPlayer
			and (tonumber(matchEnteredRuntime) or 0)
				> INITIAL_ROSTER_GRACE_SECONDS
		then
			firstSeenRuntime = matchEnteredRuntime
		elseif runtime <= 0
			or runtime - (tonumber(matchEnteredRuntime) or 0)
				<= INITIAL_ROSTER_GRACE_SECONDS
		then
			firstSeenRuntime = 0
		end
		existing = {
			participantKey = key,
			name = participant.name,
			team = participant.team,
			firstSeenRuntime = firstSeenRuntime,
		}
		rankingParticipants[key] = existing
	end
	existing.lastSeenRuntime = math.max(
		tonumber(existing.lastSeenRuntime) or 0,
		runtime
	)

	existing.name = participant.name or existing.name
	if participant.team ~= nil then
		existing.team = participant.team
	end
	existing.scoreboardClassToken = participant.scoreboardClassToken
		or existing.scoreboardClassToken
	for _, field in ipairs(RANKING_COUNTER_FIELDS) do
		local value = participant[field]
		if value ~= nil and (
			existing[field] == nil or value > existing[field]
		) then
			existing[field] = value
		end
	end
	MergeSpecializationData(existing, participant)
end

local function CaptureRankingParticipants()
	if type(GetNumBattlefieldScores) ~= "function"
		or type(GetBattlefieldScore) ~= "function"
	then
		return
	end
	local scoreCount = GetNumBattlefieldScores() or 0
	for index = 1, scoreCount do
		MergeRankingParticipant(ReadRankingParticipant(index))
	end
end

local function BuildRankingSnapshot(winner)
	CaptureRankingParticipants()
	local finalRuntime = GetBattlegroundRuntimeSeconds()
	local participants = {}
	for _, participant in pairs(rankingParticipants) do
		local data = API and API.GetPlayerData
			and API.GetPlayerData(participant.name)
		MergeSpecializationData(participant, data)
		local participationRatio = 1
		if finalRuntime > 0 then
			local firstSeen = math.max(
				0,
				tonumber(participant.firstSeenRuntime) or 0
			)
			local lastSeen = math.min(
				finalRuntime,
				tonumber(participant.lastSeenRuntime) or finalRuntime
			)
			participationRatio = math.max(
				0,
				math.min(1, (lastSeen - firstSeen) / finalRuntime)
			)
		end
		participants[#participants + 1] = {
			participantKey = participant.participantKey,
			name = participant.name,
			team = participant.team,
			guid = participant.guid,
			level = participant.level,
			role = participant.role,
			killingBlows = participant.killingBlows,
			honorableKills = participant.honorableKills,
			deaths = participant.deaths,
			damage = participant.damage,
			healing = participant.healing,
			objectives = participant.objectives,
			utility = participant.utility,
			scoreboardClassToken = participant.scoreboardClassToken,
			specialization = participant.specialization,
			specializationID = participant.specializationID,
			specializationClassToken =
				participant.specializationClassToken,
			specializationTexture = participant.specializationTexture,
			specializationTexCoords = participant.specializationTexCoords,
			participationRatio = participationRatio,
			firstSeenRuntime = participant.firstSeenRuntime,
			lastSeenRuntime = participant.lastSeenRuntime,
		}
	end
	table.sort(participants, function(left, right)
		return tostring(left.participantKey) < tostring(right.participantKey)
	end)
	return {
		winner = winner,
		elapsedSeconds = finalRuntime,
		participants = participants,
	}
end

local function HasUnresolvedEligibleParticipant(matchSnapshot, valueField)
	local globalTop = 0
	for _, participant in ipairs(matchSnapshot.participants or {}) do
		local participation = tonumber(participant.participationRatio) or 1
		local value = GetRankingScoreNumber(participant[valueField]) or 0
		if participation >= MIN_RANKING_PARTICIPATION then
			value = value / participation
		else
			value = 0
		end
		if value > globalTop then
			globalTop = value
		end
	end
	if globalTop <= 0 then
		return false
	end
	for _, participant in ipairs(matchSnapshot.participants or {}) do
		local participation = tonumber(participant.participationRatio) or 1
		local value = GetRankingScoreNumber(participant[valueField]) or 0
		if participation >= MIN_RANKING_PARTICIPATION then
			value = value / participation
		else
			value = 0
		end
		if not HasExactSpecialization(participant)
			and (value / globalTop) > RANKING_PROXIMITY_FLOOR
		then
			return true
		end
	end
	return false
end

local function BuildRankingCandidate(scoreIndex, category)
	if not scoreIndex then
		return
	end
	local participant = ReadRankingParticipant(scoreIndex)
	if not participant then
		return
	end
	participant.classToken = participant.scoreboardClassToken
	participant.value = category == "healing"
		and (participant.healing or 0)
		or (participant.damage or 0)
	return participant
end

local function BuildMatchSignature(winner, damageCandidate, healingCandidate)
	local totalDamage = 0
	local totalHealing = 0
	local scoreCount = GetNumBattlefieldScores()
	for index = 1, scoreCount do
		local _, _, _, _, _, _, _, _, _, _, damage, healing =
			GetBattlefieldScore(index)
		totalDamage = totalDamage + (tonumber(damage) or 0)
		totalHealing = totalHealing + (tonumber(healing) or 0)
	end

	local zoneName = type(GetRealZoneText) == "function" and GetRealZoneText()
		or (type(GetZoneText) == "function" and GetZoneText())
		or "Battleground"
	return table.concat({
		tostring(zoneName),
		tostring(winner),
		tostring(scoreCount),
		tostring(damageCandidate and damageCandidate.name or "?"),
		tostring(damageCandidate and damageCandidate.value or 0),
		tostring(healingCandidate and healingCandidate.name or "?"),
		tostring(healingCandidate and healingCandidate.value or 0),
		tostring(totalDamage),
		tostring(totalHealing),
	}, "|")
end

local function BuildScoreStabilitySignature(matchSignature, matchSnapshot)
	local values = { tostring(matchSignature or "") }
	for _, participant in ipairs(matchSnapshot.participants or {}) do
		values[#values + 1] = table.concat({
			tostring(participant.participantKey or participant.name or "?"),
			tostring(participant.deaths),
			tostring(participant.damage),
			tostring(participant.healing),
		}, ":")
	end
	return table.concat(values, "|")
end

local TryRecordCompletedBattleground

local function FinalizePendingBattleground()
	if matchRecorded
		or not pendingMatchSignature
		or not pendingMatchSnapshot
		or not API
		or type(API.RecordBattlegroundResult) ~= "function"
	then
		return false
	end
	API.RecordBattlegroundResult(pendingMatchSignature, pendingMatchSnapshot)
	matchRecorded = true
	return true
end

local function ScheduleRecordingRetry()
	if recordAttemptScheduled then
		return
	end
	if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
		return
	end

	recordAttemptScheduled = true
	local generation = recordGeneration
	C_Timer.After(RECORDING_RETRY_INTERVAL, function()
		recordAttemptScheduled = false
		if generation == recordGeneration then
			TryRecordCompletedBattleground()
		end
	end)
end

TryRecordCompletedBattleground = function()
	if matchRecorded or not IsBattleground() or not API
		or type(API.RecordBattlegroundResult) ~= "function"
	then
		return
	end

	local winner = GetCompletedBattlegroundWinner()
	if winner == nil then
		observedActiveMatch = true
		return
	end
	-- GetBattlefieldWinner can briefly retain the previous result while the
	-- next battleground loads. A result is accepted only after this instance
	-- has first been observed with no winner.
	if not observedActiveMatch then
		ScheduleRecordingRetry()
		return
	end
	if not finishDetectedAt then
		finishDetectedAt = GetTime()
		if type(RequestBattlefieldScoreData) == "function" then
			pcall(RequestBattlefieldScoreData)
		end
	end

	if API.ScanFriendlyRoster then
		API.ScanFriendlyRoster()
	end
	if API.ScanEnemyReferences then
		API.ScanEnemyReferences()
	end

	local topDamageIndex, topHealingIndex = FindTopScoreIndexes()
	local damageCandidate = BuildRankingCandidate(topDamageIndex, "dps")
	local healingCandidate = BuildRankingCandidate(topHealingIndex, "healing")
	local matchSnapshot = BuildRankingSnapshot(winner)
	local waitingForIdentification = HasUnresolvedEligibleParticipant(
		matchSnapshot,
		"damage"
	) or HasUnresolvedEligibleParticipant(matchSnapshot, "healing")
	local signature = BuildMatchSignature(winner, damageCandidate, healingCandidate)
	local stabilitySignature = BuildScoreStabilitySignature(
		signature,
		matchSnapshot
	)
	pendingMatchSignature = signature
	pendingMatchSnapshot = matchSnapshot
	local now = GetTime()
	if lastScoreSnapshotSignature ~= stabilitySignature then
		lastScoreSnapshotSignature = stabilitySignature
		scoreSnapshotStableSince = now
	end
	local elapsedSinceFinish = GetTime() - finishDetectedAt
	if elapsedSinceFinish < RECORDING_SCORE_SETTLE_SECONDS
		or not scoreSnapshotStableSince
		or (now - scoreSnapshotStableSince) < RECORDING_SCORE_SETTLE_SECONDS
		or (waitingForIdentification and elapsedSinceFinish < RECORDING_GRACE_SECONDS)
	then
		ScheduleRecordingRetry()
		return
	end

	FinalizePendingBattleground()
end

local function ResetMatchTracking()
	scorePollGeneration = scorePollGeneration + 1
	recordGeneration = recordGeneration + 1
	matchRecorded = false
	finishDetectedAt = nil
	recordAttemptScheduled = false
	rankingParticipants = {}
	lastScoreSnapshotSignature = nil
	scoreSnapshotStableSince = nil
	pendingMatchSignature = nil
	pendingMatchSnapshot = nil
	rankingUtilityByGUID = {}
	rankingUtilityByName = {}
	observedActiveMatch = false
	matchEnteredRuntime = IsBattleground()
		and GetBattlegroundRuntimeSeconds() or 0
end

local function ScheduleRankingScorePolling()
	if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
		return
	end
	local generation = scorePollGeneration
	local Poll
	Poll = function()
		if generation ~= scorePollGeneration or not IsBattleground() then
			return
		end
		if type(RequestBattlefieldScoreData) == "function" then
			pcall(RequestBattlefieldScoreData)
		end
		C_Timer.After(RANKING_SCORE_POLL_INTERVAL, Poll)
	end
	C_Timer.After(RANKING_SCORE_POLL_INTERVAL, Poll)
end

local function RenderScoreboard()
	if not initialized
		or not IsBattleground()
		or not WorldStateScoreFrame:IsShown()
	then
		return
	end

	if API and API.ScanFriendlyRoster then
		API.ScanFriendlyRoster()
	end

	local topDamageIndex, topHealingIndex = FindTopScoreIndexes()
	local offset = FauxScrollFrame_GetOffset(WorldStateScoreScrollFrame) or 0
	local scoreCount = GetNumBattlefieldScores()

	for rowIndex = 1, MAX_ROWS do
		local row = rows[rowIndex]
		local scoreIndex = offset + rowIndex
		if row and row.originalName then
			-- ElvUI writes this FontString again during each native scoreboard update.
			row.originalName:SetAlpha(0)
		end
		if row and scoreIndex <= scoreCount then
			local name, _, _, _, _, _, _, _, _, classToken =
				GetBattlefieldScore(scoreIndex)
			if name then
				local data = API and API.GetPlayerData and API.GetPlayerData(name)
				local specialization = data and data.specialization or "?"
				local level = data and data.level or "?"
				local role = data and data.role
				local colorCode = GetClassColorCode(classToken)
				local displayName = GetDisplayName(name)

				if API and API.ApplySpecializationTexture then
					API.ApplySpecializationTexture(row.specIcon, data, true)
				else
					row.specIcon:SetTexture(UNKNOWN_ROLE_TEXTURE)
					row.specIcon:SetTexCoord(0, 1, 0, 1)
					row.specIcon:Show()
				end
				row.classButton.tooltip = specialization ~= "?"
					and specialization
					or "Unknown specialization"

				SetRoleTexture(row.roleIcon, role)
				row.nameText:SetText(
					"|c" .. colorCode .. displayName .. "|r "
						.. "|cffaaaaaa(" .. specialization .. ", " .. level .. ")|r"
				)
				row.nameText:Show()
				PositionAwards(
					row,
					scoreIndex == topDamageIndex,
					scoreIndex == topHealingIndex
				)
			else
				row.nameText:Hide()
				row.roleIcon:Hide()
				row.specIcon:Hide()
				row.topDamage:Hide()
				row.topHealing:Hide()
			end
		elseif row then
			row.nameText:Hide()
			row.roleIcon:Hide()
			row.specIcon:Hide()
			row.topDamage:Hide()
			row.topHealing:Hide()
		end
	end
end

renderWorker:SetScript("OnUpdate", function(self)
	self:Hide()
	if renderPending then
		renderPending = false
		RenderScoreboard()
	end
end)
renderWorker:Hide()

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UPDATE_BATTLEFIELD_SCORE")
eventFrame:RegisterEvent("UPDATE_WORLD_STATES")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
pcall(eventFrame.RegisterEvent, eventFrame, "COMBAT_LOG_EVENT_UNFILTERED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "COMBAT_LOG_EVENT_UNFILTERED" then
		RecordBattlegroundUtility(...)
		return
	end
	local inBattleground = IsBattleground()
	if event == "PLAYER_LOGOUT" or event == "PLAYER_LEAVING_WORLD" then
		if inBattleground then
			TryRecordCompletedBattleground()
			FinalizePendingBattleground()
		end
		return
	end
	if event == "PLAYER_ENTERING_WORLD" or inBattleground ~= wasInBattleground then
		if wasInBattleground and not inBattleground then
			FinalizePendingBattleground()
		end
		ResetMatchTracking()
		if inBattleground then
			ScheduleRankingScorePolling()
		end
	end
	wasInBattleground = inBattleground
	if inBattleground then
		CaptureRankingParticipants()
		TryRecordCompletedBattleground()
	end
	ScheduleRender()
end)

if WorldStateScoreFrame then
	WorldStateScoreFrame:HookScript("OnShow", function()
		InitializeScoreboard()
		TryRecordCompletedBattleground()
		ScheduleRender()
	end)
end

CoAAnalytics_RefreshScoreboard = function()
	ScheduleRender()
	TryRecordCompletedBattleground()
end

if CoAAnalyticsAddon and CoAAnalyticsAddon.Events then
	CoAAnalyticsAddon.Events:Register(
		"PLAYER_DATA_UPDATED",
		CoAAnalytics_RefreshScoreboard
	)
end

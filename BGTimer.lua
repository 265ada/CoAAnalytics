local BGTimer = {}
CoAAnalyticsAddon.Modules.BGTimer = BGTimer

local CTF_MAX_DURATION_SECONDS = 25 * 60
local UPDATE_INTERVAL = 1
local MAX_ALWAYS_UP_FRAMES = 10

local frame
local timerText
local elapsedSinceUpdate = 0

local CTF_ZONE_NAMES = {
	["warsong gulch"] = true,
	["winter warsong gulch"] = true,
	["warsong gulch winter"] = true,
	["twin peaks"] = true,
	["goulet des chanteguerres"] = true,
	["pics-jumeaux"] = true,
}

local function IsBattleground()
	local inInstance, instanceType = IsInInstance()
	if not inInstance or instanceType ~= "pvp" then
		return false
	end
	return not (type(IsActiveBattlefieldArena) == "function"
		and IsActiveBattlefieldArena())
end

local function GetRuntimeSeconds()
	if type(GetBattlefieldInstanceRunTime) ~= "function" then
		return
	end
	local success, milliseconds = pcall(GetBattlefieldInstanceRunTime)
	milliseconds = success and tonumber(milliseconds) or 0
	if milliseconds <= 0 then
		return
	end
	return milliseconds / 1000
end

local function HasThreeCaptureObjective()
	local frameCount = tonumber(NUM_ALWAYS_UP_UI_FRAMES)
		or MAX_ALWAYS_UP_FRAMES
	frameCount = math.max(frameCount, MAX_ALWAYS_UP_FRAMES)
	for index = 1, frameCount do
		local textRegion = _G["AlwaysUpFrame" .. index .. "Text"]
		local text = textRegion and textRegion:GetText()
		if text and string.find(text, "%d+%s*/%s*3") then
			return true
		end
	end
	return false
end

local function IsCaptureTheFlagBattleground()
	local zoneName = type(GetRealZoneText) == "function"
		and GetRealZoneText() or nil
	if zoneName and CTF_ZONE_NAMES[string.lower(zoneName)] then
		return true
	end
	return HasThreeCaptureObjective()
end

local function HasWinner()
	if type(GetBattlefieldWinner) ~= "function" then
		return false
	end
	local success, winner = pcall(GetBattlefieldWinner)
	winner = success and tonumber(winner) or nil
	return winner == 0 or winner == 1
end

local function FormatRemaining(seconds)
	seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
	return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function ApplyTimerColor(remaining)
	if remaining <= 60 then
		timerText:SetTextColor(1, 0.18, 0.18)
	elseif remaining <= 300 then
		timerText:SetTextColor(1, 0.55, 0.10)
	else
		timerText:SetTextColor(1, 0.82, 0.12)
	end
end

local function ApplyAnchor()
	if not frame then
		return
	end
	local anchor
	local frameCount = tonumber(NUM_ALWAYS_UP_UI_FRAMES)
		or MAX_ALWAYS_UP_FRAMES
	frameCount = math.max(frameCount, MAX_ALWAYS_UP_FRAMES)
	for index = 1, frameCount do
		local candidate = _G["AlwaysUpFrame" .. index]
		if candidate and candidate:IsShown() then
			anchor = candidate
		end
	end
	frame:ClearAllPoints()
	if anchor then
		frame:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
	elseif _G.ElvUI_PvPHolder then
		frame:SetPoint("TOP", _G.ElvUI_PvPHolder, "BOTTOM", 0, -2)
	else
		frame:SetPoint("TOP", UIParent, "TOP", 0, -78)
	end
end

local function Refresh()
	if not frame or not IsBattleground()
		or not IsCaptureTheFlagBattleground() or HasWinner()
	then
		if frame then
			frame:Hide()
		end
		return
	end
	local runtime = GetRuntimeSeconds()
	if not runtime then
		frame:Hide()
		return
	end
	local remaining = math.max(0, CTF_MAX_DURATION_SECONDS - runtime)
	ApplyAnchor()
	timerText:SetText(FormatRemaining(remaining))
	ApplyTimerColor(remaining)
	frame:Show()
end

local function CreateTimer()
	if frame then
		return
	end
	frame = CreateFrame("Frame", "CoAAnalyticsBGTimer", UIParent)
	frame:SetWidth(84)
	frame:SetHeight(22)
	frame:SetFrameStrata("MEDIUM")
	frame:SetFrameLevel(25)
	frame:EnableMouse(false)
	timerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	timerText:SetPoint("CENTER")
	timerText:SetJustifyH("CENTER")
	frame:SetScript("OnUpdate", function(_, elapsed)
		elapsedSinceUpdate = elapsedSinceUpdate + elapsed
		if elapsedSinceUpdate >= UPDATE_INTERVAL then
			elapsedSinceUpdate = elapsedSinceUpdate - UPDATE_INTERVAL
			Refresh()
		end
	end)
	frame:Hide()
end

function BGTimer.Refresh()
	CreateTimer()
	Refresh()
end

function BGTimer.Initialize()
	CreateTimer()
	if type(WorldStateAlwaysUpFrame_Update) == "function"
		and type(hooksecurefunc) == "function"
	then
		hooksecurefunc("WorldStateAlwaysUpFrame_Update", BGTimer.Refresh)
	end
	BGTimer.Refresh()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("UPDATE_WORLD_STATES")
eventFrame:SetScript("OnEvent", function()
	if frame then
		Refresh()
	end
end)

local API = CoAAnalyticsAPI
local PvE = CoAAnalyticsPvE
local Overlay = {}
CoAAnalyticsAddon.Modules.DungeonOverlay = Overlay

local WIDTH = 220
local HEADER_HEIGHT = 27
local ROW_HEIGHT = 21
local MAX_ROWS = 10

local addonDB
local frame
local titleText
local averageText
local shareButton
local shareSenderFrame
local shareQueue
local shareChannel
local shareElapsed = 0
local rows = {}

local SHARE_INTERVAL = 0.35

local function Notify(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cff12c98aCoA Analytics:|r " .. tostring(message or "")
		)
	end
end

local function BuildShareMessages(snapshot)
	if not snapshot or not snapshot.averageRating or not snapshot.rows
		or #snapshot.rows == 0
	then
		return nil
	end

	local messages = {
		"CoA Analytics - Group " .. PvE.FormatRating(snapshot.averageRating) .. "/10",
	}
	for index = 1, #snapshot.rows do
		local data = snapshot.rows[index]
		if data and data.name and data.rating then
			messages[#messages + 1] = tostring(index) .. ". "
				.. tostring(data.name) .. " - " .. PvE.FormatRating(data.rating) .. "/10"
		end
	end

	if #messages <= 1 then
		return nil
	end
	return messages
end

local function FinishShareQueue()
	shareQueue = nil
	shareChannel = nil
	shareElapsed = 0
	if shareSenderFrame then
		shareSenderFrame:Hide()
	end
	if shareButton then
		shareButton:Enable()
	end
end

local function StartShareQueue(messages, channel)
	if shareQueue then
		Notify("a share is already in progress")
		return
	end
	shareQueue = messages
	shareChannel = channel
	shareElapsed = SHARE_INTERVAL
	if shareButton then
		shareButton:Disable()
	end
	if not shareSenderFrame then
		shareSenderFrame = CreateFrame("Frame")
		shareSenderFrame:SetScript("OnUpdate", function(self, elapsed)
			if not shareQueue or #shareQueue == 0 then
				FinishShareQueue()
				return
			end
			shareElapsed = shareElapsed + elapsed
			if shareElapsed < SHARE_INTERVAL then
				return
			end
			shareElapsed = 0
			local message = table.remove(shareQueue, 1)
			SendChatMessage(message, shareChannel)
			if #shareQueue == 0 then
				FinishShareQueue()
			end
		end)
	end
	shareSenderFrame:Show()
end

local function ShareCurrentRanking()
	local snapshot = PvE and PvE.GetCurrentDungeonSnapshot
		and PvE.GetCurrentDungeonSnapshot()
	local messages = BuildShareMessages(snapshot)
	if not messages then
		Notify("no dungeon ranking to share")
		return
	end

	if GetNumRaidMembers and GetNumRaidMembers() > 0 then
		StartShareQueue(messages, "RAID")
	elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
		StartShareQueue(messages, "PARTY")
	else
		for index = 1, #messages do
			Notify(messages[index])
		end
	end
end

local function IsInsideDungeon()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "party"
end

local function GetPosition()
	local position = addonDB and addonDB.dungeonOverlayPosition
	if type(position) == "table" then
		return position.point or "RIGHT",
			position.relativePoint or position.point or "RIGHT",
			tonumber(position.x) or -40,
			tonumber(position.y) or 80
	end
	return "RIGHT", "RIGHT", -40, 80
end

local function ApplyPosition()
	if not frame then
		return
	end
	local point, relativePoint, x, y = GetPosition()
	frame:ClearAllPoints()
	frame:SetPoint(point, UIParent, relativePoint, x, y)
end

local function SavePosition()
	if not frame or not addonDB then
		return
	end
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	addonDB.dungeonOverlayPosition = {
		point = point or "RIGHT",
		relativePoint = relativePoint or point or "RIGHT",
		x = tonumber(x) or 0,
		y = tonumber(y) or 0,
	}
end

local function CreateRow(index)
	local row = CreateFrame("Frame", nil, frame)
	row:SetHeight(ROW_HEIGHT)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -HEADER_HEIGHT - (index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -HEADER_HEIGHT - (index - 1) * ROW_HEIGHT)

	row.background = row:CreateTexture(nil, "BACKGROUND")
	row.background:SetAllPoints(row)
	row.background:SetTexture("Interface\\Buttons\\WHITE8X8")
	if index % 2 == 0 then
		row.background:SetVertexColor(0.09, 0.10, 0.13, 0.82)
	else
		row.background:SetVertexColor(0.04, 0.05, 0.07, 0.76)
	end

	row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.nameText:SetPoint("LEFT", row, "LEFT", 28, 0)
	row.nameText:SetWidth(133)
	row.nameText:SetJustifyH("LEFT")
	row.nameText:SetWordWrap(false)

	row.roleIcon = row:CreateTexture(nil, "OVERLAY")
	row.roleIcon:SetWidth(16)
	row.roleIcon:SetHeight(16)
	row.roleIcon:SetPoint("LEFT", row, "LEFT", 7, 0)

	row.ratingText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.ratingText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
	row.ratingText:SetWidth(43)
	row.ratingText:SetJustifyH("RIGHT")

	row:Hide()
	return row
end

local function CreateOverlay()
	if frame then
		return frame
	end

	frame = CreateFrame("Frame", "CoAAnalyticsDungeonOverlay", UIParent)
	frame:SetWidth(WIDTH)
	frame:SetHeight(HEADER_HEIGHT + ROW_HEIGHT)
	frame:SetFrameStrata("MEDIUM")
	frame:SetFrameLevel(20)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.02, 0.03, 0.05, 0.90)
	frame:SetBackdropBorderColor(0.12, 0.72, 0.55, 0.90)
	frame:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition()
	end)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Dungeon Performance", 0.10, 0.72, 0.52)
		GameTooltip:AddLine("Drag to move", 0.78, 0.82, 0.90)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", 9, -8)
	titleText:SetWidth(125)
	titleText:SetJustifyH("LEFT")
	titleText:SetWordWrap(false)
	titleText:SetText("Dungeon Performance")

	averageText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	averageText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -9, -8)
	averageText:SetWidth(50)
	averageText:SetJustifyH("RIGHT")

	shareButton = CreateFrame("Button", nil, frame)
	shareButton:SetWidth(18)
	shareButton:SetHeight(18)
	shareButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -62, -4)
	shareButton:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
	shareButton:SetPushedTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Down")
	shareButton:SetDisabledTexture(
		"Interface\\Buttons\\UI-GuildButton-PublicNote-Disabled"
	)
	shareButton:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
	shareButton:SetScript("OnClick", ShareCurrentRanking)
	shareButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Share the ranking", 0.10, 0.72, 0.52)
		GameTooltip:AddLine(
			"Sends the group rating, then one line per player.",
			0.78, 0.82, 0.90,
			true
		)
		GameTooltip:Show()
	end)
	shareButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	for index = 1, MAX_ROWS do
		rows[index] = CreateRow(index)
	end

	ApplyPosition()
	frame:Hide()
	return frame
end

local function UpdateRows(snapshot)
	local snapshotRows = snapshot and snapshot.rows or {}
	local visibleCount = math.min(#snapshotRows, MAX_ROWS)
	for index = 1, MAX_ROWS do
		local row = rows[index]
		local data = snapshotRows[index]
		if data then
			local color = RAID_CLASS_COLORS[data.classToken]
				or { r = 0.85, g = 0.85, b = 0.85 }
			if data.role and API and API.ApplyRoleTexture then
				API.ApplyRoleTexture(row.roleIcon, data.role)
				row.roleIcon:Show()
			else
				row.roleIcon:Hide()
			end
			row.nameText:SetText(tostring(data.name or "Unknown player"))
			row.nameText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
			if data.rating then
				row.ratingText:SetText(PvE.FormatRating(data.rating))
				if PvE and PvE.GetRatingColor then
					row.ratingText:SetTextColor(PvE.GetRatingColor(data.rating))
				else
					row.ratingText:SetTextColor(1, 1, 1)
				end
			else
				row.ratingText:SetText("--")
				row.ratingText:SetTextColor(0.58, 0.62, 0.70)
			end
			row:Show()
		else
			row.roleIcon:Hide()
			row:Hide()
		end
	end

	if visibleCount == 0 then
		local row = rows[1]
		row.roleIcon:Hide()
		row.nameText:SetText("Collecting...")
		row.nameText:SetTextColor(0.68, 0.72, 0.78)
		row.ratingText:SetText("--")
		row.ratingText:SetTextColor(0.58, 0.62, 0.70)
		row:Show()
		visibleCount = 1
	end
	frame:SetHeight(HEADER_HEIGHT + visibleCount * ROW_HEIGHT + 5)
end

function Overlay.Refresh(snapshot)
	CreateOverlay()
	if not addonDB
		or not addonDB.showDungeonPerformanceOverlay
		or not IsInsideDungeon()
	then
		frame:Hide()
		return
	end

	if not snapshot and PvE and PvE.GetCurrentDungeonSnapshot then
		snapshot = PvE.GetCurrentDungeonSnapshot()
	end
	UpdateRows(snapshot)
	local instanceName = snapshot and snapshot.instanceName
	titleText:SetText(instanceName and tostring(instanceName) or "Dungeon Performance")
	if snapshot and snapshot.averageRating then
		averageText:SetText(PvE.FormatRating(snapshot.averageRating) .. "/10")
		if PvE and PvE.GetRatingColor then
			averageText:SetTextColor(PvE.GetRatingColor(snapshot.averageRating))
		end
	else
		averageText:SetText("--/10")
		averageText:SetTextColor(0.58, 0.62, 0.70)
	end
	if not shareQueue and snapshot and snapshot.averageRating and snapshot.rows
		and #snapshot.rows > 0
	then
		shareButton:Enable()
	else
		shareButton:Disable()
	end
	frame:Show()
end

function Overlay.ApplySettings()
	Overlay.Refresh()
end

function Overlay.ResetPosition()
	if addonDB then
		addonDB.dungeonOverlayPosition = nil
	end
	ApplyPosition()
end

function Overlay.Initialize()
	addonDB = API and API.GetDatabase and API.GetDatabase()
	if not addonDB then
		return false
	end
	CreateOverlay()
	Overlay.Refresh()
	return true
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:SetScript("OnEvent", function()
	if addonDB then
		Overlay.Refresh()
	end
end)

CoAAnalyticsAddon.Events:Register(
	"PVE_DUNGEON_SNAPSHOT_UPDATED",
	function(snapshot)
		if addonDB and addonDB.showDungeonPerformanceOverlay then
			Overlay.Refresh(snapshot)
		end
	end
)

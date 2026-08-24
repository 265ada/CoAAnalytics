local API = CoAAnalyticsAPI
local MinimapModule = {}
CoAAnalyticsAddon.Modules.Minimap = MinimapModule

local config = API and API.Config or {}
local MINIMAP_BUTTON_RADIUS = config.MINIMAP_BUTTON_RADIUS or 80
local ROLE_FALLBACK_TEXTURES = config.ROLE_FALLBACK_TEXTURES or {}
local addonDB
local minimapButton

local function Atan2(y, x)
	if x > 0 then
		return math.atan(y / x)
	elseif x < 0 and y >= 0 then
		return math.atan(y / x) + math.pi
	elseif x < 0 and y < 0 then
		return math.atan(y / x) - math.pi
	elseif x == 0 and y > 0 then
		return math.pi / 2
	elseif x == 0 and y < 0 then
		return -math.pi / 2
	end
	return 0
end

local function NormalizeAngle(angle)
	angle = (tonumber(angle) or 0) % 360
	if angle < 0 then
		angle = angle + 360
	end
	return angle
end

local function GetAngularDistance(left, right)
	local distance = math.abs(NormalizeAngle(left) - NormalizeAngle(right))
	if distance > 180 then
		distance = 360 - distance
	end
	return distance
end

local function AvoidMiniButtonCollision()
	-- CoAMiniButton and CoA Analytics historically used the same angle and the
	-- same radius. Its launcher, higher in the display stack, therefore covered
	-- our single button perfectly without ever collecting it.
	local collectorDB = _G.CoAMiniButtonDB
	if type(collectorDB) ~= "table" then
		return
	end

	local collectorAngle = tonumber(collectorDB.angle)
	local collectorRadius = tonumber(collectorDB.radius)
	if not collectorAngle or not collectorRadius then
		return
	end

	local currentAngle = tonumber(addonDB.minimapButtonAngle) or 225
	local sameRing = math.abs(collectorRadius - MINIMAP_BUTTON_RADIUS) < 36
	if sameRing and GetAngularDistance(currentAngle, collectorAngle) < 28 then
		-- Shifting to the left of the minimap keeps both launchers reachable.
		-- The new position is saved and stays draggable.
		addonDB.minimapButtonAngle = NormalizeAngle(collectorAngle - 45)
	end
end

local function SetMinimapButtonPosition()
	if not minimapButton or not addonDB then
		return
	end

	local angle = math.rad(addonDB.minimapButtonAngle or 225)
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint(
		"CENTER",
		Minimap,
		"CENTER",
		math.cos(angle) * MINIMAP_BUTTON_RADIUS,
		math.sin(angle) * MINIMAP_BUTTON_RADIUS
	)
end

local function UpdateMinimapButtonDrag()
	local cursorX, cursorY = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	cursorX = cursorX / scale
	cursorY = cursorY / scale

	local centerX, centerY = Minimap:GetCenter()
	if not centerX or not centerY then
		return
	end

	addonDB.minimapButtonAngle = math.deg(
		Atan2(cursorY - centerY, cursorX - centerX)
	)
	SetMinimapButtonPosition()
end

local function CreateMinimapButton()
	if minimapButton or not Minimap then
		return
	end

	local button = CreateFrame(
		"Button",
		"CoAAnalyticsMinimapButton",
		Minimap
	)
	-- CoAMiniButton automatically gathers the minimap's children. This flag
	-- deliberately keeps the CoA Analytics button around the map.
	button.coaMiniButtonIgnore = true
	button:SetWidth(32)
	button:SetHeight(32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
	button:SetClampedToScreen(true)
	button:RegisterForClicks("LeftButtonUp")
	button:RegisterForDrag("LeftButton")

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetWidth(22)
	icon:SetHeight(22)
	icon:SetPoint("CENTER", button, "CENTER", 0, 0)
	icon:SetTexture(ROLE_FALLBACK_TEXTURES.SUPPORT)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetWidth(54)
	border:SetHeight(54)
	border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetWidth(32)
	highlight:SetHeight(32)
	highlight:SetPoint("CENTER", button, "CENTER", 0, 0)
	highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	highlight:SetBlendMode("ADD")

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("CoA Analytics", 0, 0.73, 0.47)
		GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
		GameTooltip:AddLine("Drag: move the button", 0.72, 0.72, 0.72)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", UpdateMinimapButtonDrag)
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		SetMinimapButtonPosition()
	end)
	button:SetScript("OnClick", function()
		local UI = CoAAnalyticsAddon.Modules.UI
		if UI and UI.Toggle then
			UI.Toggle()
		end
	end)

	minimapButton = button
	SetMinimapButtonPosition()
	button:Show()
end

function MinimapModule.Initialize()
	addonDB = API and API.GetDatabase and API.GetDatabase()
	if not addonDB then
		return false
	end
	AvoidMiniButtonCollision()
	CreateMinimapButton()
	return minimapButton ~= nil
end

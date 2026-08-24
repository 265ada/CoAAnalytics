local API = CoAAnalyticsAPI
local UI = CoAAnalyticsUI or {}
CoAAnalyticsUI = UI
CoAAnalyticsAddon.Modules.UI = UI

local config = API and API.Config or {}
local ADDON_VERSION = API and API.VERSION or "?"
local RANKING_VISIBLE_ROWS = config.RANKING_VISIBLE_ROWS or 7
local RANKING_ROW_HEIGHT = config.RANKING_ROW_HEIGHT or 33
local RANKING_TABLE_LEFT_INSET = config.RANKING_TABLE_LEFT_INSET or 12
local RANKING_TABLE_RIGHT_INSET = config.RANKING_TABLE_RIGHT_INSET or 24
local RANKING_SCORE_RIGHT_INSET = config.RANKING_SCORE_RIGHT_INSET or 83
local RANKING_PERCENT_RIGHT_INSET = config.RANKING_PERCENT_RIGHT_INSET or 10
local RANKING_POINT_EPSILON = config.RANKING_POINT_EPSILON or 0.000000001
local CalculateSpecializationRanking = API.CalculateSpecializationRanking
local PLAYER_RANKING_PRIOR_MATCHES = config.PLAYER_RANKING_PRIOR_MATCHES or 10
local PLAYER_RANKING_UNCERTAINTY_MARGIN =
	config.PLAYER_RANKING_UNCERTAINTY_MARGIN or 6
local PLAYER_RANKING_PLACEMENT_MATCHES =
	config.PLAYER_RANKING_PLACEMENT_MATCHES or 3
local PLAYER_SEARCH_MAX_SUGGESTIONS = config.PLAYER_SEARCH_MAX_SUGGESTIONS or 8
local ICON_POSITION_OPTIONS = config.ICON_POSITION_OPTIONS or {}

local NormalizePlayerName = API.NormalizePlayerName
local InitializeRankingDatabase = API.InitializeRankingDatabase
local CopyTextureCoordinates = API.CopyTextureCoordinates
local ClampRankingValue = API.ClampRankingValue
local ApplySpecializationTexture = API.ApplySpecializationTexture
local RefreshVisibleIconLayouts = API.RefreshVisibleIconLayouts

local addonDB
local ui = {
	playerSearchSuggestionButtons = {},
	playerSearchSuggestions = {},
	playerSearchSelection = 0,
	playerSearchIndex = {},
	playerSearchIndexDirty = true,
	rankingRows = {},
	playerRankingRows = {},
	activeSettingsTab = "ranking",
	activeSettingsMode = "general",
	activeRankingCategory = "dps",
	activeRankingMode = "specializations",
	activePlayerRankingCategory = "dps",
	activePlayerDpsFilter = "all",
}

local function GetPositionLabel(value)
	for _, option in ipairs(ICON_POSITION_OPTIONS) do
		if option.value == value then
			return option.text
		end
	end
	return "Above - center"
end

local function RefreshSettingsControls()
	if not addonDB then
		return
	end

	if ui.rolePositionDropdown then
		UIDropDownMenu_SetSelectedValue(
			ui.rolePositionDropdown,
			addonDB.roleIconPosition
		)
		UIDropDownMenu_SetText(
			ui.rolePositionDropdown,
			GetPositionLabel(addonDB.roleIconPosition)
		)
	end
	if ui.specPositionDropdown then
		UIDropDownMenu_SetSelectedValue(
			ui.specPositionDropdown,
			addonDB.specIconPosition
		)
		UIDropDownMenu_SetText(
			ui.specPositionDropdown,
			GetPositionLabel(addonDB.specIconPosition)
		)
	end
	if ui.showSpecCheckButton then
		ui.showSpecCheckButton:SetChecked(addonDB.showSpecIcon and 1 or nil)
	end
	if ui.showDungeonOverlayCheckButton then
		ui.showDungeonOverlayCheckButton:SetChecked(
			addonDB.showDungeonPerformanceOverlay and 1 or nil
		)
	end
	if ui.diagnosticStatusText and CoAAnalyticsPvE
		and CoAAnalyticsPvE.GetDungeonDiagnosticStatus
	then
		local status = CoAAnalyticsPvE.GetDungeonDiagnosticStatus()
		if status.active then
			ui.diagnosticStatusText:SetText("Diagnostic active for the current dungeon")
			ui.diagnosticStatusText:SetTextColor(0.18, 0.90, 0.45)
			ui.diagnosticToggleButton:SetText("Disable")
		elseif status.armed then
			ui.diagnosticStatusText:SetText("Continuous tracking active for the next dungeon")
			ui.diagnosticStatusText:SetTextColor(0.95, 0.78, 0.18)
			ui.diagnosticToggleButton:SetText("Disable")
		elseif status.last then
			ui.diagnosticStatusText:SetText(
				"Reports kept: " .. tostring(status.count or 1)
					.. "/" .. tostring(status.limit or 10)
					.. " | Last: " .. tostring(status.last.instanceName or "Dungeon")
			)
			ui.diagnosticStatusText:SetTextColor(0.38, 0.72, 0.95)
			ui.diagnosticToggleButton:SetText("Record the next one")
		else
			ui.diagnosticStatusText:SetText("No diagnostic recorded")
			ui.diagnosticStatusText:SetTextColor(0.62, 0.66, 0.72)
			ui.diagnosticToggleButton:SetText("Record the next one")
		end
		if ui.clearDiagnosticButton then
			if status.last then
				ui.clearDiagnosticButton:Enable()
			else
				ui.clearDiagnosticButton:Disable()
			end
		end
		if ui.exportDiagnosticButton then
			if status.last then
				ui.exportDiagnosticButton:Enable()
			else
				ui.exportDiagnosticButton:Disable()
			end
		end
	end
end

local function CreatePositionDropdown(parent, globalName, settingKey, x, y)
	local dropdown = CreateFrame(
		"Frame",
		globalName,
		parent,
		"UIDropDownMenuTemplate"
	)
	dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	UIDropDownMenu_SetWidth(dropdown, 160)

	UIDropDownMenu_Initialize(dropdown, function()
		for _, option in ipairs(ICON_POSITION_OPTIONS) do
			local value = option.value
			local label = option.text
			local info = UIDropDownMenu_CreateInfo()
			info.text = label
			info.value = value
			info.checked = addonDB and addonDB[settingKey] == value
			info.func = function()
				addonDB[settingKey] = value
				UIDropDownMenu_SetSelectedValue(dropdown, value)
				UIDropDownMenu_SetText(dropdown, label)
				CloseDropDownMenus()
				RefreshVisibleIconLayouts()
			end
			UIDropDownMenu_AddButton(info)
		end
	end)

	return dropdown
end

local function CreateSolidTexture(parent, layer, r, g, b, a)
	local texture = parent:CreateTexture(nil, layer or "BACKGROUND")
	texture:SetTexture("Interface\\Buttons\\WHITE8X8")
	texture:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
	return texture
end

local function CreateModernTab(parent, label, accentR, accentG, accentB)
	local button = CreateFrame("Button", nil, parent)
	button:SetWidth(150)
	button:SetHeight(28)
	button.background = CreateSolidTexture(button, "BACKGROUND", 0.10, 0.11, 0.13, 0.95)
	button.background:SetAllPoints(button)
	button.accent = CreateSolidTexture(button, "ARTWORK", accentR, accentG, accentB, 1)
	button.accent:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
	button.accent:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
	button.accent:SetHeight(2)
	button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	button.text:SetPoint("CENTER", button, "CENTER", 0, 1)
	button.text:SetText(label)
	button.accentColor = { accentR, accentG, accentB }
	button:SetScript("OnEnter", function(self)
		if not self.active then
			self.background:SetVertexColor(0.16, 0.17, 0.20, 1)
		end
	end)
	button:SetScript("OnLeave", function(self)
		if not self.active then
			self.background:SetVertexColor(0.10, 0.11, 0.13, 0.95)
		end
	end)
	return button
end

local function SetModernTabActive(button, active)
	if not button then
		return
	end
	button.active = active and true or false
	if active then
		button.background:SetVertexColor(0.20, 0.21, 0.24, 1)
		button.accent:Show()
		button.text:SetTextColor(1, 1, 1)
	else
		button.background:SetVertexColor(0.10, 0.11, 0.13, 0.95)
		button.accent:Hide()
		button.text:SetTextColor(0.68, 0.70, 0.74)
	end
end

-- Conquest of Azeroth renamed several classes without changing their internal
-- token, so the stored history and the game's own UI disagree. Without this the
-- addon title-cases the raw token and shows "Sonofarugal" or "Monk" for classes
-- the player knows as Bloodmage and Templar.
local CLASS_TOKEN_DISPLAY_NAMES = {
	SONOFARUGAL = "Bloodmage",
	PROPHET = "Venomancer",
	SPIRITMAGE = "Runemaster",
	MONK = "Templar",
	DEMONHUNTER = "Felsworn",
	WILDWALKER = "Primalist",
	KNIGHTOFXOROTH = "Knight of Xoroth",
	WITCHDOCTOR = "Witch Doctor",
	WITCHHUNTER = "Witch Hunter",
	SUNCLERIC = "Sun Cleric",
	FLESHWARDEN = "Fleshwarden",
}

local function GetRankingClassName(classToken)
	if not classToken then
		return "Unknown class"
	end
	local override = CLASS_TOKEN_DISPLAY_NAMES[string.upper(tostring(classToken))]
	if override then
		return override
	end
	local localized = LOCALIZED_CLASS_NAMES_MALE
		and LOCALIZED_CLASS_NAMES_MALE[classToken]
	if localized and localized ~= "" then
		return localized
	end

	local name = string.lower(tostring(classToken)):gsub("_", " ")
	return (name:gsub("(%a)([%w']*)", function(first, rest)
		return string.upper(first) .. rest
	end))
end

local function CreateRankingSummaryCard(parent, x, label, r, g, b)
	local card = CreateFrame("Frame", nil, parent)
	card:SetWidth(176)
	card:SetHeight(50)
	card:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -42)
	card:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 10,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	card:SetBackdropColor(0.055, 0.06, 0.075, 0.96)
	card:SetBackdropBorderColor(0.18, 0.19, 0.22, 0.9)
	local accent = CreateSolidTexture(card, "ARTWORK", r, g, b, 1)
	accent:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -4)
	accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 4, 4)
	accent:SetWidth(3)
	card.value = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	card.value:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -8)
	card.value:SetText("0")
	card.label = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.label:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 14, 8)
	card.label:SetText(label)
	card:EnableMouse(true)
	card:SetScript("OnEnter", function(self)
		if not self.tooltipText then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(self.tooltipTitle or label)
		GameTooltip:AddLine(self.tooltipText, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	card:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return card
end

local function CreateRankingColumnHeader(parent, label, tooltipText, width)
	local header = CreateFrame("Button", nil, parent)
	header:SetWidth(width or 90)
	header:SetHeight(20)
	header.text = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	header.text:SetAllPoints(header)
	header.text:SetJustifyH("LEFT")
	header.text:SetText(label)
	header.tooltipText = tooltipText
	header:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(label, 1, 0.82, 0.20)
		GameTooltip:AddLine(self.tooltipText or "", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	header:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return header
end

local function CreateRankingRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetFrameLevel(parent:GetFrameLevel() + 2)
	local offsetY = -132 - ((index - 1) * RANKING_ROW_HEIGHT)
	row:SetPoint(
		"TOPLEFT",
		parent,
		"TOPLEFT",
		RANKING_TABLE_LEFT_INSET,
		offsetY
	)
	row:SetPoint(
		"TOPRIGHT",
		parent,
		"TOPRIGHT",
		-RANKING_TABLE_RIGHT_INSET,
		offsetY
	)
	row:SetHeight(RANKING_ROW_HEIGHT - 2)
	row.background = CreateSolidTexture(
		row,
		"BACKGROUND",
		index % 2 == 0 and 0.075 or 0.055,
		index % 2 == 0 and 0.08 or 0.06,
		index % 2 == 0 and 0.095 or 0.075,
		0.96
	)
	row.background:SetAllPoints(row)
	row.progress = CreateSolidTexture(row, "BORDER", 0.92, 0.64, 0.12, 0.20)
	row.progress:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
	row.progress:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)

	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.rank:SetPoint("LEFT", row, "LEFT", 8, 0)
	row.rank:SetWidth(28)
	row.rank:SetJustifyH("CENTER")

	row.icon = row:CreateTexture(nil, "OVERLAY")
	row.icon:SetWidth(24)
	row.icon:SetHeight(24)
	row.icon:SetPoint("LEFT", row, "LEFT", 41, 0)

	row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.classText:SetPoint("LEFT", row, "LEFT", 74, 5)
	row.classText:SetWidth(125)
	row.classText:SetJustifyH("LEFT")
	row.classText:SetWordWrap(false)

	row.specText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.specText:SetPoint("LEFT", row, "LEFT", 74, -8)
	row.specText:SetWidth(270)
	row.specText:SetJustifyH("LEFT")
	row.specText:SetWordWrap(false)

	row.scoreText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.scoreText:SetPoint(
		"RIGHT",
		row,
		"RIGHT",
		-RANKING_SCORE_RIGHT_INSET,
		0
	)
	row.scoreText:SetWidth(90)
	row.scoreText:SetJustifyH("RIGHT")

	row.percentText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.percentText:SetPoint(
		"RIGHT",
		row,
		"RIGHT",
		-RANKING_PERCENT_RIGHT_INSET,
		0
	)
	row.percentText:SetWidth(66)
	row.percentText:SetJustifyH("RIGHT")

	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		if not self.entry or not self.rankingResult then
			return
		end
		local result = self.rankingResult
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(
			GetRankingClassName(self.entry.classToken)
				.. " - " .. tostring(self.entry.specialization or "?")
		)
		GameTooltip:AddLine(
			string.format(
				"Smoothed score: %.3f point per appearance",
				tonumber(result.score) or 0
			),
			0.95,
			0.72,
			0.18
		)
		GameTooltip:AddLine(
			"The score compares average performance, not total attendance. Five virtual appearances at the mean stabilize small samples.",
			1,
			1,
			1,
			true
		)
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(
			string.format(
				"Raw mean: %.3f - Points accumulated: %.2f",
				tonumber(result.rawScore) or 0,
				tonumber(result.points) or 0
			),
			0.72,
			0.78,
			0.86
		)
		GameTooltip:AddLine(
			string.format(
				"Share of the ranking: %.1f%%",
				tonumber(self.performanceShare) or 0
			),
			0.95,
			0.72,
			0.18
		)
		GameTooltip:AddLine(
			"This specialization's share of the summed normalized scores. Frequent attendance raises reliability, but no longer raises this percentage directly.",
			1,
			1,
			1,
			true
		)
		local top1 = tonumber(self.entry.top1Finishes)
			or tonumber(self.entry.wins)
			or 0
		GameTooltip:AddLine(
			"Top 1: " .. tostring(top1),
			0.92,
			0.74,
			0.28,
			true
		)
		GameTooltip:AddLine(
			"Close to best (>= 90%): "
				.. tostring(self.entry.nearTopBGs or 0),
			0.72,
			0.78,
			0.86
		)
		GameTooltip:AddLine(
			"Sample: " .. tostring(self.entry.appearances or 0)
				.. string.format(
					" BGs (accumulated weight %.2f)",
					tonumber(result.appearanceWeight) or 0
				),
			0.72,
			0.78,
			0.86,
			true
		)
		if self.entry.lastPlayer then
			GameTooltip:AddLine(
				"Last credited performance: "
					.. tostring(self.entry.lastPlayer),
				0.65,
				0.68,
				0.74
			)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	row:Hide()
	return row
end

local function RefreshSpecializationRankingPanel()
	if not addonDB or not ui.rankingPanel or not ui.rankingScrollFrame then
		return
	end
	InitializeRankingDatabase()

	local rankings = addonDB.rankings
	local category = rankings[ui.activeRankingCategory]
	local analyzedBGs = tonumber(category.analyzedBGs) or 0
	local totalWeight = tonumber(category.totalWeight) or 0
	local entries, rankingStats = CalculateSpecializationRanking(category)
	local rankedSpecializationCount = #entries

	local averageMatchWeight = analyzedBGs > 0
		and (totalWeight / analyzedBGs) * 100
		or 0
	ui.rankingSummaryAnalyzed.value:SetText(tostring(analyzedBGs))
	ui.rankingSummaryBalance.value:SetText(string.format("%.0f%%", averageMatchWeight))
	ui.rankingSummarySpecializations.value:SetText(
		tostring(rankedSpecializationCount)
	)
	if ui.rankingMethodologyText then
		ui.rankingMethodologyText:SetText(string.format(
			"Score = performance per appearance, smoothed with %.0f virtual BGs at the mean. "
				.. "Playing often raises reliability, not the score. Average BG influence: %.0f%%; stomps count for less.",
			rankingStats.priorWeight or 0,
			averageMatchWeight
		))
	end

	FauxScrollFrame_Update(
		ui.rankingScrollFrame,
		#entries,
		RANKING_VISIBLE_ROWS,
		RANKING_ROW_HEIGHT
	)
	local offset = FauxScrollFrame_GetOffset(ui.rankingScrollFrame) or 0
	local leadingScore = entries[1]
		and (tonumber(entries[1].score) or 0)
		or 0
	for rowIndex = 1, RANKING_VISIBLE_ROWS do
		local row = ui.rankingRows[rowIndex]
		local rankingIndex = offset + rowIndex
		local result = entries[rankingIndex]
		local entry = result and result.entry
		if row and entry then
			local score = tonumber(result.score) or 0
			local percent = (tonumber(result.share) or 0) * 100
			local relativeStrength = leadingScore > 0 and score / leadingScore or 0
			local color = RAID_CLASS_COLORS[entry.classToken]
				or { r = 0.85, g = 0.85, b = 0.85 }
			row.entry = entry
			row.rankingResult = result
			row.rank:SetText(tostring(rankingIndex))
			if rankingIndex == 1 then
				row.rank:SetTextColor(1, 0.78, 0.18)
			elseif rankingIndex == 2 then
				row.rank:SetTextColor(0.78, 0.82, 0.88)
			elseif rankingIndex == 3 then
				row.rank:SetTextColor(0.80, 0.48, 0.23)
			else
				row.rank:SetTextColor(0.65, 0.68, 0.74)
			end
			ApplySpecializationTexture(row.icon, entry, true)
			row.classText:SetText(GetRankingClassName(entry.classToken))
			row.classText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
			local top1 = tonumber(entry.top1Finishes)
				or tonumber(entry.wins)
				or 0
			row.specText:SetText(
				tostring(entry.specialization or "?")
					.. "  |cff8f949e- Top 1: " .. tostring(top1)
					.. " - " .. tostring(entry.appearances or 0) .. " BG|r"
			)
			row.scoreText:SetText(string.format("%.2f pt/BG", score))
			row.percentText:SetText(string.format("%.1f%%", percent))
			row.performanceShare = percent
			row.progress:SetVertexColor(
				ui.activeRankingCategory == "dps" and 0.95 or 0.20,
				ui.activeRankingCategory == "dps" and 0.58 or 0.82,
				ui.activeRankingCategory == "dps" and 0.10 or 0.42,
				0.20
			)
			local rowWidth = row:GetWidth()
			if not rowWidth or rowWidth <= 0 then
				rowWidth = math.max(
					1,
					(ui.rankingPanel:GetWidth() or 0)
						- RANKING_TABLE_LEFT_INSET
						- RANKING_TABLE_RIGHT_INSET
				)
			end
			row.progress:SetWidth(
				math.max(1, math.floor(rowWidth * relativeStrength))
			)
			row:Show()
		elseif row then
			row.entry = nil
			row.rankingResult = nil
			row.performanceShare = nil
			row:Hide()
		end
	end

	if #entries == 0 then
		ui.rankingNoDataText:Show()
	else
		ui.rankingNoDataText:Hide()
	end
end

local PLAYER_ROLE_LABELS = {
	MELEE_DAMAGER = "Melee DPS",
	RANGED_DAMAGER = "Ranged DPS",
	DAMAGER = "DPS",
	HEALER = "Healer",
	TANK = "Tank",
	SUPPORT = "Support",
}

local function GetPlayerConfidence(appearances)
	appearances = tonumber(appearances) or 0
	if appearances < 5 then
		return "Provisional", { 0.95, 0.62, 0.18 }
	elseif appearances < 20 then
		return "Medium", { 0.38, 0.72, 0.95 }
	end
	return "Reliable", { 0.18, 0.82, 0.46 }
end

local function GetActivePlayerRoleKeys()
	if ui.activePlayerRankingCategory == "healing" then
		return { "HEALER" }
	elseif ui.activePlayerRankingCategory == "tank" then
		return { "TANK" }
	elseif ui.activePlayerRankingCategory == "support" then
		return { "SUPPORT" }
	elseif ui.activePlayerDpsFilter == "melee" then
		return { "MELEE_DAMAGER" }
	elseif ui.activePlayerDpsFilter == "ranged" then
		return { "RANGED_DAMAGER" }
	end
	return { "MELEE_DAMAGER", "RANGED_DAMAGER", "DAMAGER" }
end

local function MergePlayerSpecializations(target, source)
	target.specializations = target.specializations or {}
	for key, specialization in pairs(source.specializations or {}) do
		local existing = target.specializations[key]
		if not existing then
			existing = {
				classToken = specialization.classToken,
				specializationID = specialization.specializationID,
				specialization = specialization.specialization,
				specializationTexture = specialization.specializationTexture,
				specializationTexCoords = CopyTextureCoordinates(
					specialization.specializationTexCoords
				),
				appearances = 0,
			}
			target.specializations[key] = existing
		end
		existing.appearances = (tonumber(existing.appearances) or 0)
			+ (tonumber(specialization.appearances) or 0)
		if existing.appearances >= (tonumber(target.mainSpecializationAppearances) or 0) then
			target.classToken = existing.classToken or target.classToken
			target.specializationID = existing.specializationID
			target.specialization = existing.specialization
			target.specializationTexture = existing.specializationTexture
			target.specializationTexCoords = CopyTextureCoordinates(
				existing.specializationTexCoords
			)
			target.mainSpecializationAppearances = existing.appearances
		end
	end
end

local function FormatPlayerLastSeen(timestamp)
	timestamp = tonumber(timestamp)
	if not timestamp or timestamp <= 0 then
		return "Unknown"
	end
	local elapsed = math.max(0, time() - timestamp)
	if elapsed < 60 then
		return "Just now"
	elseif elapsed < 3600 then
		return tostring(math.floor(elapsed / 60)) .. " min ago"
	elseif elapsed < 86400 then
		return tostring(math.floor(elapsed / 3600)) .. " h ago"
	elseif elapsed < 604800 then
		return tostring(math.floor(elapsed / 86400)) .. " d ago"
	end
	if type(date) == "function" then
		return date("%Y-%m-%d", timestamp)
	end
	return "Older"
end

local function BuildPlayerRankingEntries()
	InitializeRankingDatabase()
	local rankings = addonDB and addonDB.rankings
	local playerRankings = rankings and rankings.players
	if not playerRankings then
		return {}, 0
	end
	local merged = {}
	for _, roleKey in ipairs(GetActivePlayerRoleKeys()) do
		local category = playerRankings.categories[roleKey]
		for key, source in pairs(category and category.entries or {}) do
			local entry = merged[key]
			if not entry then
				entry = {
					key = key,
					name = source.name,
					guid = source.guid,
					level = source.level,
					classToken = source.classToken,
					role = roleKey,
					scoreSum = 0,
					scoreWeight = 0,
					appearances = 0,
					participationTotal = 0,
					comparableBGs = 0,
					nearTopBGs = 0,
					top1Finishes = 0,
					specializations = {},
				}
				merged[key] = entry
			end
			entry.name = source.name or entry.name
			entry.guid = source.guid or entry.guid
			entry.level = source.level or entry.level
			entry.classToken = source.classToken or entry.classToken
			entry.scoreSum = entry.scoreSum + (tonumber(source.scoreSum) or 0)
			entry.scoreWeight = entry.scoreWeight + (tonumber(source.scoreWeight) or 0)
			entry.appearances = entry.appearances + (tonumber(source.appearances) or 0)
			entry.participationTotal = entry.participationTotal
				+ (tonumber(source.participationTotal)
					or tonumber(source.appearances) or 0)
			entry.lastSeen = math.max(
				tonumber(entry.lastSeen) or 0,
				tonumber(source.lastSeen) or 0
			)
			entry.comparableBGs = entry.comparableBGs
				+ (tonumber(source.comparableBGs) or 0)
			entry.nearTopBGs = entry.nearTopBGs + (tonumber(source.nearTopBGs) or 0)
			entry.top1Finishes = entry.top1Finishes
				+ (tonumber(source.top1Finishes) or 0)
			if (tonumber(source.appearances) or 0)
				>= (tonumber(entry.primaryRoleAppearances) or 0)
			then
				entry.role = roleKey
				entry.primaryRoleAppearances = tonumber(source.appearances) or 0
				entry.lastScore = source.lastScore
				entry.lastDamage = source.lastDamage
				entry.lastHealing = source.lastHealing
				entry.lastDeaths = source.lastDeaths
				entry.lastObjectives = source.lastObjectives
				entry.lastUtility = source.lastUtility
				entry.lastLevel = source.lastLevel
				entry.lastLevelFactor = source.lastLevelFactor
				entry.lastLevelReference = source.lastLevelReference
				entry.lastParticipationRatio = source.lastParticipationRatio
				entry.normalizationVersion = source.normalizationVersion
			end
			MergePlayerSpecializations(entry, source)
		end
	end

	local query = ui.playerSearchBox and NormalizePlayerName(ui.playerSearchBox:GetText())
	query = query and string.gsub(query, "^%s+", "")
	query = query and string.gsub(query, "%s+$", "")
	local rankedEntries = {}
	local provisionalEntries = {}
	for _, entry in pairs(merged) do
		if entry.scoreWeight > 0 and entry.appearances > 0 then
			local rawScore = entry.scoreSum / entry.scoreWeight
			local reliability = entry.scoreWeight
				/ (entry.scoreWeight + PLAYER_RANKING_PRIOR_MATCHES)
			entry.rawScore = rawScore
			entry.smoothedScore = 100 + (rawScore - 100) * reliability
			-- Une estimation ramenee vers 100 favorise sinon artificiellement les
			-- nouveaux joueurs : avec un seul BG, meme une performance moyenne peut
			-- passer devant un joueur deja mesure plusieurs fois. Le classement
			-- utilise donc une borne prudente dont la marge disparait avec les BG.
			entry.uncertaintyMargin = PLAYER_RANKING_UNCERTAINTY_MARGIN
				/ math.sqrt(math.max(entry.scoreWeight, 0.25))
			entry.score = entry.smoothedScore - entry.uncertaintyMargin
			entry.averageParticipation = entry.appearances > 0
				and entry.participationTotal / entry.appearances or 1
			entry.regularityAvailable = entry.comparableBGs > 0
			entry.regularity = entry.regularityAvailable
				and (100 * entry.nearTopBGs / entry.comparableBGs) or 0
			entry.confidence, entry.confidenceColor =
				GetPlayerConfidence(entry.appearances)
			entry.placementComplete =
				entry.appearances >= PLAYER_RANKING_PLACEMENT_MATCHES
			if entry.placementComplete then
				rankedEntries[#rankedEntries + 1] = entry
			else
				entry.confidence = string.format(
					"Placement %d/%d",
					entry.appearances,
					PLAYER_RANKING_PLACEMENT_MATCHES
				)
				entry.confidenceColor = { 0.95, 0.62, 0.18 }
				provisionalEntries[#provisionalEntries + 1] = entry
			end
		end
	end
	local function SortPlayerEntries(left, right)
		if math.abs(left.score - right.score) > RANKING_POINT_EPSILON then
			return left.score > right.score
		end
		if left.regularity ~= right.regularity then
			return left.regularity > right.regularity
		end
		if left.appearances ~= right.appearances then
			return left.appearances > right.appearances
		end
		return tostring(left.name or "") < tostring(right.name or "")
	end
	table.sort(rankedEntries, SortPlayerEntries)
	table.sort(provisionalEntries, SortPlayerEntries)
	local allEntries = {}
	for _, entry in ipairs(rankedEntries) do
		allEntries[#allEntries + 1] = entry
	end
	for _, entry in ipairs(provisionalEntries) do
		allEntries[#allEntries + 1] = entry
	end
	local entries = {}
	for index, entry in ipairs(allEntries) do
		entry.overallRank = entry.placementComplete and index or nil
		local normalizedName = NormalizePlayerName(entry.name) or ""
		if not query or query == ""
			or string.find(normalizedName, query, 1, true)
		then
			entries[#entries + 1] = entry
		end
	end
	local leader = rankedEntries[1] or provisionalEntries[1]
	return entries, #rankedEntries, leader and leader.score or 100
end

local function SetPlayerRankBadge(row, rank)
	if not rank then
		row.rankText:SetText("-")
		row.rankIcon:SetVertexColor(0.36, 0.40, 0.48)
		return
	end
	row.rankText:SetText(tostring(rank))
	if rank == 1 then
		row.rankIcon:SetVertexColor(1, 0.76, 0.12)
	elseif rank == 2 then
		row.rankIcon:SetVertexColor(0.78, 0.84, 0.92)
	elseif rank == 3 then
		row.rankIcon:SetVertexColor(0.82, 0.44, 0.18)
	else
		row.rankIcon:SetVertexColor(0.36, 0.40, 0.48)
	end
end

local function CreatePlayerRankingRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetFrameLevel(parent:GetFrameLevel() + 2)
	local offsetY = -132 - ((index - 1) * RANKING_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", RANKING_TABLE_LEFT_INSET, offsetY)
	row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -RANKING_TABLE_RIGHT_INSET, offsetY)
	row:SetHeight(RANKING_ROW_HEIGHT - 2)
	row.background = CreateSolidTexture(
		row,
		"BACKGROUND",
		index % 2 == 0 and 0.075 or 0.055,
		index % 2 == 0 and 0.08 or 0.06,
		index % 2 == 0 and 0.095 or 0.075,
		0.96
	)
	row.background:SetAllPoints(row)
	row.progress = CreateSolidTexture(row, "BORDER", 0.68, 0.43, 0.95, 0.17)
	row.progress:SetPoint("TOPLEFT")
	row.progress:SetPoint("BOTTOMLEFT")
	row.progress:SetWidth(1)

	row.rankIcon = row:CreateTexture(nil, "OVERLAY")
	row.rankIcon:SetTexture("Interface\\AchievementFrame\\UI-Achievement-TinyShield")
	row.rankIcon:SetWidth(25)
	row.rankIcon:SetHeight(25)
	row.rankIcon:SetPoint("LEFT", 6, 0)
	row.rankText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.rankText:SetPoint("CENTER", row.rankIcon, "CENTER", 0, 0)

	row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.nameText:SetPoint("LEFT", 42, 0)
	row.nameText:SetWidth(148)
	row.nameText:SetJustifyH("LEFT")
	row.nameText:SetWordWrap(false)

	row.specButton = CreateFrame("Button", nil, row)
	row.specButton:SetWidth(24)
	row.specButton:SetHeight(24)
	row.specButton:SetPoint("LEFT", 194, 0)
	row.specButton.texture = row.specButton:CreateTexture(nil, "OVERLAY")
	row.specButton.texture:SetAllPoints()
	row.specButton:SetScript("OnEnter", function(self)
		local entry = self.entry
		if not entry then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Observed specializations", 1, 0.82, 0.20)
		local specializations = {}
		for _, specialization in pairs(entry.specializations or {}) do
			specializations[#specializations + 1] = specialization
		end
		table.sort(specializations, function(left, right)
			return (tonumber(left.appearances) or 0)
				> (tonumber(right.appearances) or 0)
		end)
		for _, specialization in ipairs(specializations) do
			GameTooltip:AddLine(
				GetRankingClassName(specialization.classToken)
					.. " - " .. tostring(specialization.specialization or "?")
					.. " : " .. tostring(specialization.appearances or 0) .. " BG",
				1,
				1,
				1
			)
		end
		GameTooltip:Show()
	end)
	row.specButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

	row.lastSeenText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.lastSeenText:SetPoint("LEFT", 238, 0)
	row.lastSeenText:SetWidth(142)
	row.lastSeenText:SetJustifyH("LEFT")
	row.lastSeenText:SetWordWrap(false)

	row.scoreText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.scoreText:SetPoint("RIGHT", -315, 0)
	row.scoreText:SetWidth(62)
	row.scoreText:SetJustifyH("RIGHT")
	row.regularityText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.regularityText:SetPoint("RIGHT", -220, 0)
	row.regularityText:SetWidth(72)
	row.regularityText:SetJustifyH("RIGHT")
	row.matchesText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.matchesText:SetPoint("RIGHT", -145, 0)
	row.matchesText:SetWidth(46)
	row.matchesText:SetJustifyH("RIGHT")
	row.confidenceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.confidenceText:SetPoint("RIGHT", -8, 0)
	row.confidenceText:SetWidth(118)
	row.confidenceText:SetJustifyH("RIGHT")

	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		local entry = self.entry
		if not entry then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(tostring(entry.name or "Player"), 1, 0.82, 0.20)
		GameTooltip:AddLine(
			string.format("Ranking score: %.1f", entry.score),
			1,
			1,
			1
		)
		GameTooltip:AddLine(
			string.format(
				"Smoothed estimate: %.1f (raw %.1f)",
				entry.smoothedScore,
				entry.rawScore
			),
			0.72,
			0.80,
			0.90
		)
		GameTooltip:AddLine(
			string.format(
				"Uncertainty margin: -%.1f point(s)",
				entry.uncertaintyMargin
			),
			0.72,
			0.80,
			0.90
		)
		GameTooltip:AddLine(
			entry.regularityAvailable
				and string.format("Consistency: %.1f%% (%d/%d comparable BGs)", entry.regularity, entry.nearTopBGs, entry.comparableBGs)
				or "Consistency: waiting for an opponent in the same role",
			0.72,
			0.80,
			0.90
		)
		GameTooltip:AddLine("Role top finishes: " .. tostring(entry.top1Finishes or 0), 0.72, 0.80, 0.90)
		GameTooltip:AddLine(
			"Last seen: " .. FormatPlayerLastSeen(entry.lastSeen),
			0.72,
			0.80,
			0.90
		)
		if entry.lastParticipationRatio then
			GameTooltip:AddLine(
				string.format(
					"Attendance in last BG: %.0f%%",
					100 * entry.lastParticipationRatio
				),
				0.72,
				0.80,
				0.90
			)
		end
		if entry.lastLevel and entry.lastLevelReference and entry.lastLevelFactor then
			GameTooltip:AddLine(
				string.format(
					"Last BG: level %d, role median %.1f, coefficient x%.2f",
					entry.lastLevel,
					entry.lastLevelReference,
					entry.lastLevelFactor
				),
				0.72,
				0.80,
				0.90
			)
		end
		if not entry.placementComplete then
			GameTooltip:AddLine(
				string.format(
					"Placement: %d/%d valid BGs before an official rank.",
					entry.appearances,
					PLAYER_RANKING_PLACEMENT_MATCHES
				),
				0.95,
				0.62,
				0.18,
				true
			)
		end
		GameTooltip:AddLine("Confidence: " .. tostring(entry.confidence), 0.72, 0.80, 0.90)
		GameTooltip:AddLine("The stomp coefficient reduces the influence of the whole battleground, never that of a single player.", 0.58, 0.64, 0.72, true)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	row:Hide()
	return row
end

local function RebuildPlayerSearchIndex()
	if not ui.playerSearchIndexDirty then
		return
	end
	ui.playerSearchIndex = {}
	local unique = {}
	local playerRankings = addonDB and addonDB.rankings
		and addonDB.rankings.players
	for roleKey, category in pairs(playerRankings and playerRankings.categories or {}) do
		for key, entry in pairs(category.entries or {}) do
			local candidate = unique[key]
			if not candidate or (tonumber(entry.appearances) or 0)
				> (tonumber(candidate.appearances) or 0)
			then
				unique[key] = {
					key = key,
					name = entry.name,
					classToken = entry.classToken,
					specialization = entry.specialization,
					role = roleKey,
					appearances = tonumber(entry.appearances) or 0,
				}
			end
		end
	end
	for _, candidate in pairs(unique) do
		ui.playerSearchIndex[#ui.playerSearchIndex + 1] = candidate
	end
	table.sort(ui.playerSearchIndex, function(left, right)
		return tostring(left.name or "") < tostring(right.name or "")
	end)
	ui.playerSearchIndexDirty = false
end

local function SetSearchSuggestionHighlight()
	for index, button in ipairs(ui.playerSearchSuggestionButtons) do
		button.background:SetVertexColor(
			0.15,
			0.17,
			0.22,
			index == ui.playerSearchSelection and 1 or 0.92
		)
	end
end

local function SelectPlayerSearchSuggestion(index)
	local suggestion = ui.playerSearchSuggestions[index]
	if not suggestion or not ui.playerSearchBox then
		return
	end
	if suggestion.role == "HEALER" then
		ui.activePlayerRankingCategory = "healing"
	elseif suggestion.role == "TANK" then
		ui.activePlayerRankingCategory = "tank"
	elseif suggestion.role == "SUPPORT" then
		ui.activePlayerRankingCategory = "support"
	else
		ui.activePlayerRankingCategory = "dps"
		ui.activePlayerDpsFilter = "all"
		if ui.playerDpsFilterDropdown then
			UIDropDownMenu_SetSelectedValue(ui.playerDpsFilterDropdown, "all")
			UIDropDownMenu_SetText(ui.playerDpsFilterDropdown, "All DPS")
		end
	end
	ui.playerSearchBox:SetText(tostring(suggestion.name or ""))
	ui.playerSearchBox:ClearFocus()
	ui.playerSearchSuggestionsFrame:Hide()
	ui.SetPlayerRankingCategory(ui.activePlayerRankingCategory)
end

local function RefreshPlayerSearchSuggestions()
	if not ui.playerSearchSuggestionsFrame or not ui.playerSearchBox then
		return
	end
	RebuildPlayerSearchIndex()
	local query = NormalizePlayerName(ui.playerSearchBox:GetText()) or ""
	query = string.gsub(query, "^%s+", "")
	query = string.gsub(query, "%s+$", "")
	ui.playerSearchSuggestions = {}
	if string.len(query) < 2 then
		ui.playerSearchSuggestionsFrame:Hide()
		return
	end
	local matches = {}
	for _, candidate in ipairs(ui.playerSearchIndex) do
		local name = NormalizePlayerName(candidate.name) or ""
		local position = string.find(name, query, 1, true)
		if position then
			candidate.searchPriority = position == 1 and 0 or 1
			matches[#matches + 1] = candidate
		end
	end
	table.sort(matches, function(left, right)
		if left.searchPriority ~= right.searchPriority then
			return left.searchPriority < right.searchPriority
		end
		if left.appearances ~= right.appearances then
			return left.appearances > right.appearances
		end
		return tostring(left.name or "") < tostring(right.name or "")
	end)
	for index = 1, math.min(#matches, PLAYER_SEARCH_MAX_SUGGESTIONS) do
		ui.playerSearchSuggestions[index] = matches[index]
	end
	ui.playerSearchSelection = #ui.playerSearchSuggestions > 0 and 1 or 0
	for index, button in ipairs(ui.playerSearchSuggestionButtons) do
		local suggestion = ui.playerSearchSuggestions[index]
		if suggestion then
			button.suggestionIndex = index
			button.nameText:SetText(tostring(suggestion.name or "?"))
			local color = RAID_CLASS_COLORS[suggestion.classToken]
				or { r = 0.86, g = 0.86, b = 0.86 }
			button.nameText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
			button.detailText:SetText(
				tostring(PLAYER_ROLE_LABELS[suggestion.role] or "Role")
					.. " - " .. tostring(suggestion.appearances or 0) .. " BG"
			)
			button:Show()
		else
			button:Hide()
		end
	end
	SetSearchSuggestionHighlight()
	if #ui.playerSearchSuggestions > 0 then
		ui.playerSearchSuggestionsFrame:SetHeight(#ui.playerSearchSuggestions * 24 + 6)
		ui.playerSearchSuggestionsFrame:Show()
	else
		ui.playerSearchSuggestionsFrame:Hide()
	end
end

ui.RefreshPlayerRankingPanel = function()
	if not addonDB or not ui.playerRankingPanel or not ui.playerRankingScrollFrame then
		return
	end
	local entries, totalPlayers, leaderScore = BuildPlayerRankingEntries()
	local rankings = addonDB.rankings
	local playerRankings = rankings.players
	local totalBGs = tonumber(playerRankings.totalBattlegrounds) or 0
	local averageMatchWeight = (tonumber(rankings.stompEvaluatedBGs) or 0) > 0
		and (tonumber(rankings.matchWeightTotal) or 0)
			/ (tonumber(rankings.stompEvaluatedBGs) or 1) * 100
		or 0
	ui.playerRankingSummaryAnalyzed.value:SetText(tostring(totalBGs))
	ui.playerRankingSummaryBalance.value:SetText(string.format("%.0f%%", averageMatchWeight))
	ui.playerRankingSummaryPlayers.value:SetText(tostring(totalPlayers))
	ui.playerRankingMethodologyText:SetText(
		"Official rank after 3 valid battlegrounds. Mid-match arrivals are corrected to time played and weigh less in the history; under 25% attendance or zero primary activity is ignored."
	)

	FauxScrollFrame_Update(
		ui.playerRankingScrollFrame,
		#entries,
		RANKING_VISIBLE_ROWS,
		RANKING_ROW_HEIGHT
	)
	local offset = FauxScrollFrame_GetOffset(ui.playerRankingScrollFrame) or 0
	for rowIndex = 1, RANKING_VISIBLE_ROWS do
		local row = ui.playerRankingRows[rowIndex]
		local rankingIndex = offset + rowIndex
		local entry = entries[rankingIndex]
		if entry then
			row.entry = entry
			row.specButton.entry = entry
			SetPlayerRankBadge(row, entry.overallRank)
			local color = RAID_CLASS_COLORS[entry.classToken]
				or { r = 0.86, g = 0.86, b = 0.86 }
			row.nameText:SetText(tostring(entry.name or "Player"))
			row.nameText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
			ApplySpecializationTexture(row.specButton.texture, entry, true)
			row.lastSeenText:SetText(FormatPlayerLastSeen(entry.lastSeen))
			row.scoreText:SetText(string.format("%.1f", entry.score))
			row.regularityText:SetText(
				entry.regularityAvailable and string.format("%.0f%%", entry.regularity)
					or "--"
			)
			row.matchesText:SetText(tostring(entry.appearances))
			row.confidenceText:SetText(entry.confidence)
			row.confidenceText:SetTextColor(unpack(entry.confidenceColor))
			local relative = leaderScore > 0 and entry.score / leaderScore or 0
			local rowWidth = math.max(1, row:GetWidth() or 1)
			row.progress:SetWidth(math.max(1, math.floor(rowWidth * ClampRankingValue(relative, 0, 1))))
			row:Show()
		else
			row.entry = nil
			row.specButton.entry = nil
			row:Hide()
		end
	end
	if #entries == 0 then
		ui.playerRankingNoDataText:Show()
	else
		ui.playerRankingNoDataText:Hide()
	end
end

ui.RefreshRankingPanel = function()
	if ui.activeRankingMode == "players" then
		ui.RefreshPlayerRankingPanel()
	else
		RefreshSpecializationRankingPanel()
	end
end

local function SetRankingMode(mode)
	ui.activeRankingMode = mode == "players" and "players" or "specializations"
	SetModernTabActive(
		ui.specializationRankingTabButton,
		ui.activeRankingMode == "specializations"
	)
	SetModernTabActive(ui.playerRankingTabButton, ui.activeRankingMode == "players")
	if ui.activeRankingMode == "players" then
		ui.specializationRankingPanel:Hide()
		ui.playerRankingPanel:Show()
		ui.SetPlayerRankingCategory(ui.activePlayerRankingCategory)
	else
		ui.playerRankingPanel:Hide()
		if ui.playerSearchSuggestionsFrame then
			ui.playerSearchSuggestionsFrame:Hide()
		end
		ui.specializationRankingPanel:Show()
		ui.SetRankingCategory(ui.activeRankingCategory)
	end
end

ui.SetRankingCategory = function(categoryKey)
	ui.activeRankingCategory = categoryKey == "healing" and "healing" or "dps"
	SetModernTabActive(ui.damageRankingTabButton, ui.activeRankingCategory == "dps")
	SetModernTabActive(ui.healingRankingTabButton, ui.activeRankingCategory == "healing")
	ui.RefreshRankingPanel()
end

ui.SetPlayerRankingCategory = function(categoryKey)
	if categoryKey == "healing" or categoryKey == "tank"
		or categoryKey == "support"
	then
		ui.activePlayerRankingCategory = categoryKey
	else
		ui.activePlayerRankingCategory = "dps"
	end
	SetModernTabActive(ui.playerDpsTabButton, ui.activePlayerRankingCategory == "dps")
	SetModernTabActive(ui.playerHealingTabButton, ui.activePlayerRankingCategory == "healing")
	SetModernTabActive(ui.playerTankTabButton, ui.activePlayerRankingCategory == "tank")
	SetModernTabActive(ui.playerSupportTabButton, ui.activePlayerRankingCategory == "support")
	if ui.playerDpsFilterDropdown then
		if ui.activePlayerRankingCategory == "dps" then
			ui.playerDpsFilterDropdown:Show()
		else
			ui.playerDpsFilterDropdown:Hide()
		end
	end
	local scrollBar = _G["CoAAnalyticsPlayerRankingScrollFrameScrollBar"]
	if scrollBar then
		scrollBar:SetValue(0)
	end
	ui.RefreshRankingPanel()
end

local function SetSettingsMode(mode)
	if mode == "nameplates" then
		ui.activeSettingsMode = "nameplates"
	else
		ui.activeSettingsMode = "general"
	end
	SetModernTabActive(
		ui.generalSettingsTabButton,
		ui.activeSettingsMode == "general"
	)
	SetModernTabActive(
		ui.nameplateSettingsTabButton,
		ui.activeSettingsMode == "nameplates"
	)
	if ui.generalSettingsPanel then
		if ui.activeSettingsMode == "general" then
			ui.generalSettingsPanel:Show()
		else
			ui.generalSettingsPanel:Hide()
		end
	end
	if ui.nameplateOptionsPanel then
		if ui.activeSettingsMode == "nameplates" then
			ui.nameplateOptionsPanel:Show()
		else
			ui.nameplateOptionsPanel:Hide()
		end
	end
end

local function SetSettingsSection(section)
	if section == "nameplates" then
		ui.activeSettingsMode = "nameplates"
		ui.activeSettingsTab = "settings"
	elseif section == "settings" or section == "pve" or section == "pvesession" then
		ui.activeSettingsTab = section
	else
		ui.activeSettingsTab = "ranking"
	end
	SetModernTabActive(ui.nameplateTabButton, ui.activeSettingsTab == "settings")
	SetModernTabActive(ui.rankingTabButton, ui.activeSettingsTab == "ranking")
	SetModernTabActive(ui.pveRankingTabButton, ui.activeSettingsTab == "pve")
	SetModernTabActive(ui.pveSessionTabButton, ui.activeSettingsTab == "pvesession")
	-- Toujours repartir d'un etat exclusif. Si un module optionnel manque ou si
	-- une creation precedente a ete interrompue, aucun panneau ne doit rester
	-- superpose au panneau actif.
	ui.nameplateSettingsPanel:Hide()
	ui.rankingPanel:Hide()
	if ui.pveRankingPanel then
		ui.pveRankingPanel:Hide()
	end
	if ui.pveSessionPanel then
		ui.pveSessionPanel:Hide()
	end
	if ui.activeSettingsTab == "ranking" then
		ui.rankingPanel:Show()
		SetRankingMode(ui.activeRankingMode)
	elseif ui.activeSettingsTab == "pve" then
		if ui.pveRankingPanel then
			ui.pveRankingPanel:Show()
			if CoAAnalyticsPvE and CoAAnalyticsPvE.RefreshPanel then
				CoAAnalyticsPvE.RefreshPanel()
			end
		end
	elseif ui.activeSettingsTab == "pvesession" then
		if ui.pveSessionPanel then
			ui.pveSessionPanel:Show()
			if CoAAnalyticsPvE and CoAAnalyticsPvE.RefreshSessionPanel then
				CoAAnalyticsPvE.RefreshSessionPanel()
			end
		end
	else
		ui.nameplateSettingsPanel:Show()
		SetSettingsMode(ui.activeSettingsMode)
	end
end

local function CreateSettingsFrame()
	if ui.settingsFrame then
		return ui.settingsFrame
	end

	local frame = CreateFrame(
		"Frame",
		"CoAAnalyticsSettingsFrame",
		UIParent
	)
	-- Un Frame nouvellement cree est visible par defaut. Le masquer tout de
	-- suite evite une interface partielle si une API du client est absente.
	frame:Hide()
	frame:SetWidth(760)
	frame:SetHeight(560)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 14,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.025, 0.028, 0.038, 0.98)
	frame:SetBackdropBorderColor(0.20, 0.22, 0.27, 1)

	local titleAccent = CreateSolidTexture(frame, "ARTWORK", 0.10, 0.72, 0.52, 1)
	titleAccent:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -42)
	titleAccent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -42)
	titleAccent:SetHeight(1)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -17)
	title:SetText("CoA Analytics")

	local version = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 8, -1)
	version:SetText("v" .. ADDON_VERSION)

	ui.rankingTabButton = CreateModernTab(frame, "BG Ranking", 0.95, 0.61, 0.12)
	ui.rankingTabButton:SetWidth(150)
	ui.rankingTabButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -52)
	ui.pveRankingTabButton = CreateModernTab(frame, "PvE Ranking", 0.30, 0.62, 0.95)
	ui.pveRankingTabButton:SetWidth(145)
	ui.pveRankingTabButton:SetPoint("LEFT", ui.rankingTabButton, "RIGHT", 8, 0)
	ui.pveSessionTabButton = CreateModernTab(frame, "PvE Performance", 0.68, 0.43, 0.95)
	ui.pveSessionTabButton:SetWidth(145)
	ui.pveSessionTabButton:SetPoint("LEFT", ui.pveRankingTabButton, "RIGHT", 8, 0)
	ui.nameplateTabButton = CreateModernTab(frame, "Settings", 0.10, 0.72, 0.52)
	ui.nameplateTabButton:SetWidth(125)
	ui.nameplateTabButton:SetPoint("LEFT", ui.pveSessionTabButton, "RIGHT", 8, 0)

	ui.nameplateSettingsPanel = CreateFrame("Frame", nil, frame)
	ui.nameplateSettingsPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -88)
	ui.nameplateSettingsPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 18)
	ui.nameplateSettingsPanel:Hide()

	ui.generalSettingsTabButton = CreateModernTab(
		ui.nameplateSettingsPanel,
		"General",
		0.10,
		0.72,
		0.52
	)
	ui.generalSettingsTabButton:SetWidth(150)
	ui.generalSettingsTabButton:SetPoint(
		"TOPLEFT",
		ui.nameplateSettingsPanel,
		"TOPLEFT",
		8,
		-6
	)
	ui.nameplateSettingsTabButton = CreateModernTab(
		ui.nameplateSettingsPanel,
		"Nameplates",
		0.10,
		0.72,
		0.52
	)
	ui.nameplateSettingsTabButton:SetWidth(150)
	ui.nameplateSettingsTabButton:SetPoint(
		"LEFT",
		ui.generalSettingsTabButton,
		"RIGHT",
		7,
		0
	)

	ui.generalSettingsPanel = CreateFrame("Frame", nil, ui.nameplateSettingsPanel)
	ui.generalSettingsPanel:SetPoint("TOPLEFT", ui.nameplateSettingsPanel, "TOPLEFT", 0, -42)
	ui.generalSettingsPanel:SetPoint("BOTTOMRIGHT", ui.nameplateSettingsPanel, "BOTTOMRIGHT", 0, 0)
	ui.generalSettingsPanel:Hide()
	ui.nameplateOptionsPanel = CreateFrame("Frame", nil, ui.nameplateSettingsPanel)
	ui.nameplateOptionsPanel:SetPoint("TOPLEFT", ui.nameplateSettingsPanel, "TOPLEFT", 0, -42)
	ui.nameplateOptionsPanel:SetPoint("BOTTOMRIGHT", ui.nameplateSettingsPanel, "BOTTOMRIGHT", 0, 0)
	ui.nameplateOptionsPanel:Hide()

	local overlayCard = CreateFrame("Frame", nil, ui.generalSettingsPanel)
	overlayCard:SetPoint("TOPLEFT", ui.generalSettingsPanel, "TOPLEFT", 8, -8)
	overlayCard:SetPoint("TOPRIGHT", ui.generalSettingsPanel, "TOPRIGHT", -8, -8)
	overlayCard:SetHeight(210)
	overlayCard:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 10,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	overlayCard:SetBackdropColor(0.05, 0.055, 0.07, 0.96)
	overlayCard:SetBackdropBorderColor(0.16, 0.18, 0.22, 1)

	local overlayTitle = overlayCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	overlayTitle:SetPoint("TOPLEFT", overlayCard, "TOPLEFT", 22, -20)
	overlayTitle:SetText("On-screen dungeon performance")
	local overlayDescription = overlayCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	overlayDescription:SetPoint("TOPLEFT", overlayCard, "TOPLEFT", 22, -50)
	overlayDescription:SetPoint("TOPRIGHT", overlayCard, "TOPRIGHT", -22, -50)
	overlayDescription:SetHeight(45)
	overlayDescription:SetJustifyH("LEFT")
	overlayDescription:SetWordWrap(true)
	overlayDescription:SetText(
		"Shows a compact, movable list in dungeons only: class-colored name and a rating out of 10. "
			.. "The widget reuses the PvE snapshot refreshed every second, with no extra collection."
	)

	ui.showDungeonOverlayCheckButton = CreateFrame(
		"CheckButton",
		"CoAAnalyticsShowDungeonOverlayCheckButton",
		overlayCard,
		"UICheckButtonTemplate"
	)
	ui.showDungeonOverlayCheckButton:SetWidth(24)
	ui.showDungeonOverlayCheckButton:SetHeight(24)
	ui.showDungeonOverlayCheckButton:SetPoint("TOPLEFT", overlayCard, "TOPLEFT", 21, -108)
	local overlayCheckLabel = overlayCard:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	overlayCheckLabel:SetPoint("LEFT", ui.showDungeonOverlayCheckButton, "RIGHT", 4, 0)
	overlayCheckLabel:SetText("Show the dungeon performance widget")
	ui.showDungeonOverlayCheckButton:SetScript("OnClick", function(self)
		addonDB.showDungeonPerformanceOverlay = self:GetChecked() and true or false
		local overlay = CoAAnalyticsAddon.Modules.DungeonOverlay
		if overlay and overlay.ApplySettings then
			overlay.ApplySettings()
		end
	end)

	local resetOverlayButton = CreateFrame(
		"Button",
		nil,
		overlayCard,
		"UIPanelButtonTemplate"
	)
	resetOverlayButton:SetWidth(150)
	resetOverlayButton:SetHeight(24)
	resetOverlayButton:SetPoint("BOTTOMLEFT", overlayCard, "BOTTOMLEFT", 22, 18)
	resetOverlayButton:SetText("Reset position")
	resetOverlayButton:SetScript("OnClick", function()
		local overlay = CoAAnalyticsAddon.Modules.DungeonOverlay
		if overlay and overlay.ResetPosition then
			overlay.ResetPosition()
		end
	end)

	local diagnosticCard = CreateFrame("Frame", nil, ui.generalSettingsPanel)
	diagnosticCard:SetPoint("TOPLEFT", overlayCard, "BOTTOMLEFT", 0, -12)
	diagnosticCard:SetPoint("TOPRIGHT", overlayCard, "BOTTOMRIGHT", 0, -12)
	diagnosticCard:SetHeight(190)
	diagnosticCard:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 10,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	diagnosticCard:SetBackdropColor(0.05, 0.055, 0.07, 0.96)
	diagnosticCard:SetBackdropBorderColor(0.16, 0.18, 0.22, 1)

	local diagnosticTitle = diagnosticCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	diagnosticTitle:SetPoint("TOPLEFT", diagnosticCard, "TOPLEFT", 22, -18)
	diagnosticTitle:SetText("Dungeon diagnostic history")
	local diagnosticDescription = diagnosticCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	diagnosticDescription:SetPoint("TOPLEFT", diagnosticCard, "TOPLEFT", 22, -45)
	diagnosticDescription:SetPoint("TOPRIGHT", diagnosticCard, "TOPRIGHT", -22, -45)
	diagnosticDescription:SetHeight(38)
	diagnosticDescription:SetJustifyH("LEFT")
	diagnosticDescription:SetWordWrap(true)
	diagnosticDescription:SetText(
		"Once enabled, records up to 10 successive dungeons in CoAAnalytics.lua. "
			.. "The oldest are replaced and no dungeon is duplicated."
	)

	ui.diagnosticStatusText = diagnosticCard:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ui.diagnosticStatusText:SetPoint("TOPLEFT", diagnosticCard, "TOPLEFT", 22, -92)
	ui.diagnosticStatusText:SetText("No diagnostic recorded")
	local diagnosticPath = diagnosticCard:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	diagnosticPath:SetPoint("TOPLEFT", diagnosticCard, "TOPLEFT", 22, -115)
	diagnosticPath:SetPoint("TOPRIGHT", diagnosticCard, "TOPRIGHT", -22, -115)
	diagnosticPath:SetJustifyH("LEFT")
	diagnosticPath:SetText(
		"Export writes the file to: WTF\\Account\\<account>\\SavedVariables\\CoAAnalytics.lua"
	)

	ui.diagnosticToggleButton = CreateFrame("Button", nil, diagnosticCard, "UIPanelButtonTemplate")
	ui.diagnosticToggleButton:SetWidth(180)
	ui.diagnosticToggleButton:SetHeight(24)
	ui.diagnosticToggleButton:SetPoint("BOTTOMLEFT", diagnosticCard, "BOTTOMLEFT", 22, 18)
	ui.diagnosticToggleButton:SetText("Record the next one")
	ui.diagnosticToggleButton:SetScript("OnClick", function()
		if not CoAAnalyticsPvE or not CoAAnalyticsPvE.GetDungeonDiagnosticStatus then
			return
		end
		local status = CoAAnalyticsPvE.GetDungeonDiagnosticStatus()
		CoAAnalyticsPvE.SetDungeonDiagnosticEnabled(not (status.active or status.armed))
		RefreshSettingsControls()
	end)

	ui.clearDiagnosticButton = CreateFrame("Button", nil, diagnosticCard, "UIPanelButtonTemplate")
	ui.clearDiagnosticButton:SetWidth(150)
	ui.clearDiagnosticButton:SetHeight(24)
	ui.clearDiagnosticButton:SetPoint("BOTTOMRIGHT", diagnosticCard, "BOTTOMRIGHT", -22, 18)
	ui.clearDiagnosticButton:SetText("Clear all")
	ui.clearDiagnosticButton:SetScript("OnClick", function()
		if CoAAnalyticsPvE and CoAAnalyticsPvE.ClearDungeonDiagnostic then
			CoAAnalyticsPvE.ClearDungeonDiagnostic()
			RefreshSettingsControls()
		end
	end)

	ui.exportDiagnosticButton = CreateFrame(
		"Button", nil, diagnosticCard, "UIPanelButtonTemplate"
	)
	ui.exportDiagnosticButton:SetWidth(160)
	ui.exportDiagnosticButton:SetHeight(24)
	ui.exportDiagnosticButton:SetPoint(
		"LEFT", ui.diagnosticToggleButton, "RIGHT", 10, 0
	)
	ui.exportDiagnosticButton:SetText("Export reports")
	ui.exportDiagnosticButton:SetScript("OnClick", function()
		StaticPopup_Show("COA_ANALYTICS_EXPORT_DUNGEON_DIAGNOSTIC")
	end)

	if not StaticPopupDialogs["COA_ANALYTICS_EXPORT_DUNGEON_DIAGNOSTIC"] then
		StaticPopupDialogs["COA_ANALYTICS_EXPORT_DUNGEON_DIAGNOSTIC"] = {
			text = "Export the stored diagnostics? The interface will reload automatically so the file can be written.",
			button1 = "Export",
			button2 = CANCEL,
			OnAccept = function()
				if CoAAnalyticsPvE and CoAAnalyticsPvE.ExportDungeonDiagnostic then
					CoAAnalyticsPvE.ExportDungeonDiagnostic()
				end
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
	end

	local configurationCard = CreateFrame("Frame", nil, ui.nameplateOptionsPanel)
	configurationCard:SetPoint("TOPLEFT", ui.nameplateOptionsPanel, "TOPLEFT", 8, -8)
	configurationCard:SetPoint("TOPRIGHT", ui.nameplateOptionsPanel, "TOPRIGHT", -8, -8)
	configurationCard:SetHeight(300)
	configurationCard:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 10,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	configurationCard:SetBackdropColor(0.05, 0.055, 0.07, 0.96)
	configurationCard:SetBackdropBorderColor(0.16, 0.18, 0.22, 1)

	local sectionTitle = configurationCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	sectionTitle:SetPoint("TOPLEFT", configurationCard, "TOPLEFT", 22, -20)
	sectionTitle:SetText("Display above players")

	local description = configurationCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	description:SetPoint("TOPLEFT", configurationCard, "TOPLEFT", 22, -48)
	description:SetPoint("TOPRIGHT", configurationCard, "TOPRIGHT", -22, -48)
	description:SetHeight(38)
	description:SetJustifyH("LEFT")
	description:SetWordWrap(true)
	description:SetText(
		"Icon placement on enemy nameplates. "
			.. "If both use the same slot, they are aligned automatically."
	)

	local roleLabel = configurationCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	roleLabel:SetPoint("TOPLEFT", configurationCard, "TOPLEFT", 26, -108)
	roleLabel:SetText("Role icon")

	ui.rolePositionDropdown = CreatePositionDropdown(
		configurationCard,
		"CoAAnalyticsRolePositionDropDown",
		"roleIconPosition",
		310,
		-91
	)

	local specLabel = configurationCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	specLabel:SetPoint("TOPLEFT", configurationCard, "TOPLEFT", 26, -158)
	specLabel:SetText("Specialization icon")

	ui.specPositionDropdown = CreatePositionDropdown(
		configurationCard,
		"CoAAnalyticsSpecPositionDropDown",
		"specIconPosition",
		310,
		-141
	)

	ui.showSpecCheckButton = CreateFrame(
		"CheckButton",
		"CoAAnalyticsShowSpecCheckButton",
		configurationCard,
		"UICheckButtonTemplate"
	)
	ui.showSpecCheckButton:SetWidth(24)
	ui.showSpecCheckButton:SetHeight(24)
	ui.showSpecCheckButton:SetPoint("TOPLEFT", configurationCard, "TOPLEFT", 21, -199)
	local checkLabel = configurationCard:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	checkLabel:SetPoint(
		"LEFT",
		ui.showSpecCheckButton,
		"RIGHT",
		4,
		0
	)
	checkLabel:SetText("Show the specialization icon")
	ui.showSpecCheckButton:SetScript("OnClick", function(self)
		addonDB.showSpecIcon = self:GetChecked() and true or false
		RefreshVisibleIconLayouts()
	end)

	local resetButton = CreateFrame(
		"Button",
		nil,
		configurationCard,
		"UIPanelButtonTemplate"
	)
	resetButton:SetWidth(120)
	resetButton:SetHeight(24)
	resetButton:SetPoint("BOTTOMLEFT", configurationCard, "BOTTOMLEFT", 22, 18)
	resetButton:SetText("Defaults")
	resetButton:SetScript("OnClick", function()
		addonDB.roleIconPosition = "ABOVE_CENTER"
		addonDB.specIconPosition = "ABOVE_RIGHT"
		addonDB.showSpecIcon = true
		RefreshSettingsControls()
		RefreshVisibleIconLayouts()
	end)

	local compatibility = ui.nameplateOptionsPanel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontDisableSmall"
	)
	compatibility:SetPoint("TOPLEFT", configurationCard, "BOTTOMLEFT", 14, -20)
	compatibility:SetPoint("TOPRIGHT", configurationCard, "BOTTOMRIGHT", -14, -20)
	compatibility:SetJustifyH("LEFT")
	compatibility:SetText(
		"Compatible with Blizzard and ElvUI nameplates. "
			.. "Changes are applied immediately."
	)

	ui.rankingPanel = CreateFrame("Frame", nil, frame)
	ui.rankingPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -88)
	ui.rankingPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 18)
	ui.rankingPanel:Hide()

	ui.specializationRankingTabButton = CreateModernTab(
		ui.rankingPanel,
		"Specializations",
		0.95,
		0.61,
		0.12
	)
	ui.specializationRankingTabButton:SetWidth(150)
	ui.specializationRankingTabButton:SetPoint("TOPLEFT", ui.rankingPanel, "TOPLEFT", 8, -6)
	ui.playerRankingTabButton = CreateModernTab(
		ui.rankingPanel,
		"Players",
		0.68,
		0.43,
		0.95
	)
	ui.playerRankingTabButton:SetWidth(120)
	ui.playerRankingTabButton:SetPoint("LEFT", ui.specializationRankingTabButton, "RIGHT", 7, 0)

	ui.specializationRankingPanel = CreateFrame("Frame", nil, ui.rankingPanel)
	ui.specializationRankingPanel:SetPoint("TOPLEFT", ui.rankingPanel, "TOPLEFT", 0, -36)
	ui.specializationRankingPanel:SetPoint("BOTTOMRIGHT", ui.rankingPanel, "BOTTOMRIGHT", 0, 0)
	ui.playerRankingPanel = CreateFrame("Frame", nil, ui.rankingPanel)
	ui.playerRankingPanel:SetPoint("TOPLEFT", ui.rankingPanel, "TOPLEFT", 0, -36)
	ui.playerRankingPanel:SetPoint("BOTTOMRIGHT", ui.rankingPanel, "BOTTOMRIGHT", 0, 0)

	ui.damageRankingTabButton = CreateModernTab(
		ui.specializationRankingPanel,
		"Damage",
		0.95,
		0.58,
		0.10
	)
	ui.damageRankingTabButton:SetWidth(120)
	ui.damageRankingTabButton:SetPoint("TOPLEFT", ui.specializationRankingPanel, "TOPLEFT", 8, -6)
	ui.healingRankingTabButton = CreateModernTab(
		ui.specializationRankingPanel,
		"Healing",
		0.20,
		0.82,
		0.42
	)
	ui.healingRankingTabButton:SetWidth(120)
	ui.healingRankingTabButton:SetPoint("LEFT", ui.damageRankingTabButton, "RIGHT", 7, 0)

	local rankingHint = ui.specializationRankingPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	rankingHint:SetPoint("TOPRIGHT", ui.specializationRankingPanel, "TOPRIGHT", -10, -15)
	rankingHint:SetWidth(310)
	rankingHint:SetJustifyH("RIGHT")
	rankingHint:SetText("Ranked by cumulative battleground performance")

	ui.rankingSummaryAnalyzed = CreateRankingSummaryCard(
		ui.specializationRankingPanel,
		8,
		"BGs analyzed",
		0.10,
		0.72,
		0.52
	)
	ui.rankingSummaryAnalyzed.tooltipText =
		"Complete battlegrounds that distributed points in the current tab."
	ui.rankingSummaryBalance = CreateRankingSummaryCard(
		ui.specializationRankingPanel,
		202,
		"Average influence",
		0.30,
		0.62,
		0.95
	)
	ui.rankingSummaryBalance.tooltipText =
		"A balanced battleground counts at 100%, i.e. 1 point. The larger the gap in deaths and damage between the teams, the more the battleground's influence is reduced, down to 25%. The same coefficient is applied to every specialization in the match."
	ui.rankingSummarySpecializations = CreateRankingSummaryCard(
		ui.specializationRankingPanel,
		396,
		"Specializations ranked",
		0.68,
		0.43,
		0.95
	)
	ui.rankingSummarySpecializations.tooltipText =
		"Number of specializations that have already received points in the current tab."

	local rankHeader = CreateRankingColumnHeader(
		ui.specializationRankingPanel,
		"RANK",
		"Position by average performance per appearance, after statistical smoothing.",
		55
	)
	rankHeader:SetPoint("TOPLEFT", ui.specializationRankingPanel, "TOPLEFT", 20, -103)
	local identityHeader = CreateRankingColumnHeader(
		ui.specializationRankingPanel,
		"CLASS / SPECIALIZATION",
		"CoA class and specialization grouped anonymously. No player name is kept in this view.",
		250
	)
	identityHeader:SetPoint("TOPLEFT", ui.specializationRankingPanel, "TOPLEFT", 86, -103)
	local scoreHeader = CreateRankingColumnHeader(
		ui.specializationRankingPanel,
		"SCORE",
		"Average points per appearance. The score is smoothed with five virtual battlegrounds at the mean so a small sample cannot dominate the ranking.",
		80
	)
	scoreHeader.text:SetJustifyH("RIGHT")
	scoreHeader:SetPoint(
		"TOPRIGHT",
		ui.specializationRankingPanel,
		"TOPRIGHT",
		-(RANKING_TABLE_RIGHT_INSET + RANKING_SCORE_RIGHT_INSET),
		-103
	)
	local percentHeader = CreateRankingColumnHeader(
		ui.specializationRankingPanel,
		"SHARE (%)",
		"The specialization's share of the summed normalized scores. Attendance count no longer grants extra points directly.",
		76
	)
	percentHeader.text:SetJustifyH("RIGHT")
	percentHeader:SetPoint(
		"TOPRIGHT",
		ui.specializationRankingPanel,
		"TOPRIGHT",
		-(RANKING_TABLE_RIGHT_INSET + RANKING_PERCENT_RIGHT_INSET),
		-103
	)

	ui.rankingScrollFrame = CreateFrame(
		"ScrollFrame",
		"CoAAnalyticsRankingScrollFrame",
		ui.specializationRankingPanel,
		"FauxScrollFrameTemplate"
	)
	ui.rankingScrollFrame:SetPoint("TOPLEFT", ui.specializationRankingPanel, "TOPLEFT", 8, -130)
	ui.rankingScrollFrame:SetPoint("BOTTOMRIGHT", ui.specializationRankingPanel, "BOTTOMRIGHT", -24, 46)
	ui.rankingScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(
			self,
			offset,
			RANKING_ROW_HEIGHT,
			ui.RefreshRankingPanel
		)
	end)
	for index = 1, RANKING_VISIBLE_ROWS do
		ui.rankingRows[index] = CreateRankingRow(ui.specializationRankingPanel, index)
	end

	ui.rankingNoDataText = ui.specializationRankingPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.rankingNoDataText:SetPoint("CENTER", ui.specializationRankingPanel, "CENTER", 0, -40)
	ui.rankingNoDataText:SetText(
		"No smoothed score yet.\nRanking begins at the end of the next complete battleground."
	)

	ui.rankingMethodologyText = ui.specializationRankingPanel:CreateFontString(
		nil,
		"OVERLAY",
		"GameFontDisableSmall"
	)
	ui.rankingMethodologyText:SetPoint(
		"BOTTOMLEFT",
		ui.specializationRankingPanel,
		"BOTTOMLEFT",
		12,
		9
	)
	ui.rankingMethodologyText:SetWidth(455)
	ui.rankingMethodologyText:SetHeight(42)
	ui.rankingMethodologyText:SetJustifyH("LEFT")
	ui.rankingMethodologyText:SetJustifyV("BOTTOM")
	ui.rankingMethodologyText:SetWordWrap(true)

	local clearRankingButton = CreateFrame(
		"Button",
		nil,
		ui.specializationRankingPanel,
		"UIPanelButtonTemplate"
	)
	clearRankingButton:SetWidth(130)
	clearRankingButton:SetHeight(23)
	clearRankingButton:SetPoint("BOTTOMRIGHT", ui.specializationRankingPanel, "BOTTOMRIGHT", -8, 7)
	clearRankingButton:SetText("Reset")
	clearRankingButton:SetScript("OnClick", function()
		StaticPopup_Show("COA_ANALYTICS_RESET_BG_RANKINGS")
	end)

	ui.playerDpsTabButton = CreateModernTab(ui.playerRankingPanel, "DPS", 0.95, 0.58, 0.10)
	ui.playerDpsTabButton:SetWidth(72)
	ui.playerDpsTabButton:SetPoint("TOPLEFT", ui.playerRankingPanel, "TOPLEFT", 8, -6)
	ui.playerHealingTabButton = CreateModernTab(ui.playerRankingPanel, "Healing", 0.20, 0.82, 0.42)
	ui.playerHealingTabButton:SetWidth(72)
	ui.playerHealingTabButton:SetPoint("LEFT", ui.playerDpsTabButton, "RIGHT", 6, 0)
	ui.playerTankTabButton = CreateModernTab(ui.playerRankingPanel, "Tanks", 0.30, 0.62, 0.95)
	ui.playerTankTabButton:SetWidth(72)
	ui.playerTankTabButton:SetPoint("LEFT", ui.playerHealingTabButton, "RIGHT", 6, 0)
	ui.playerSupportTabButton = CreateModernTab(ui.playerRankingPanel, "Supports", 0.68, 0.43, 0.95)
	ui.playerSupportTabButton:SetWidth(82)
	ui.playerSupportTabButton:SetPoint("LEFT", ui.playerTankTabButton, "RIGHT", 6, 0)

	ui.playerDpsFilterDropdown = CreateFrame(
		"Frame",
		"CoAAnalyticsPlayerDpsFilterDropDown",
		ui.playerRankingPanel,
		"UIDropDownMenuTemplate"
	)
	ui.playerDpsFilterDropdown:SetPoint("TOPLEFT", ui.playerRankingPanel, "TOPLEFT", 330, 1)
	UIDropDownMenu_SetWidth(ui.playerDpsFilterDropdown, 82)
	UIDropDownMenu_Initialize(ui.playerDpsFilterDropdown, function()
		local options = {
			{ value = "all", text = "All DPS" },
			{ value = "melee", text = "Melee" },
			{ value = "ranged", text = "Ranged" },
		}
		for _, option in ipairs(options) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = option.text
			info.value = option.value
			info.checked = ui.activePlayerDpsFilter == option.value
			info.func = function()
				ui.activePlayerDpsFilter = option.value
				UIDropDownMenu_SetSelectedValue(ui.playerDpsFilterDropdown, option.value)
				UIDropDownMenu_SetText(ui.playerDpsFilterDropdown, option.text)
				local scrollBar = _G["CoAAnalyticsPlayerRankingScrollFrameScrollBar"]
				if scrollBar then scrollBar:SetValue(0) end
				ui.RefreshRankingPanel()
			end
			UIDropDownMenu_AddButton(info)
		end
	end)
	UIDropDownMenu_SetSelectedValue(ui.playerDpsFilterDropdown, "all")
	UIDropDownMenu_SetText(ui.playerDpsFilterDropdown, "All DPS")

	ui.playerSearchBox = CreateFrame(
		"EditBox",
		"CoAAnalyticsPlayerSearchBox",
		ui.playerRankingPanel,
		"InputBoxTemplate"
	)
	ui.playerSearchBox:SetWidth(190)
	ui.playerSearchBox:SetHeight(24)
	ui.playerSearchBox:SetPoint("TOPRIGHT", ui.playerRankingPanel, "TOPRIGHT", -10, -9)
	ui.playerSearchBox:SetAutoFocus(false)
	ui.playerSearchBox:SetMaxLetters(40)
	ui.playerSearchPlaceholder = ui.playerSearchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ui.playerSearchPlaceholder:SetPoint("LEFT", ui.playerSearchBox, "LEFT", 7, 0)
	ui.playerSearchPlaceholder:SetText("Search for a player...")
	ui.playerSearchBox:SetScript("OnEditFocusGained", function()
		ui.playerSearchPlaceholder:Hide()
	end)
	ui.playerSearchBox:SetScript("OnEditFocusLost", function(self)
		if self:GetText() == "" then ui.playerSearchPlaceholder:Show() end
	end)
	ui.playerSearchBox:SetScript("OnTextChanged", function(self)
		if self:GetText() == "" and not self:HasFocus() then
			ui.playerSearchPlaceholder:Show()
		else
			ui.playerSearchPlaceholder:Hide()
		end
		local scrollBar = _G["CoAAnalyticsPlayerRankingScrollFrameScrollBar"]
		if scrollBar then scrollBar:SetValue(0) end
		RefreshPlayerSearchSuggestions()
		if ui.activeRankingMode == "players" then ui.RefreshPlayerRankingPanel() end
	end)
	-- OnArrowPressed n'existe pas sur le client Ascension 3.3.5. La touche
	-- Tab fournit la navigation clavier sans interrompre la creation de l'UI.
	ui.playerSearchBox:SetScript("OnTabPressed", function()
		if #ui.playerSearchSuggestions == 0 then return end
		ui.playerSearchSelection = ui.playerSearchSelection + 1
		if ui.playerSearchSelection > #ui.playerSearchSuggestions then
			ui.playerSearchSelection = 1
		end
		SetSearchSuggestionHighlight()
	end)
	ui.playerSearchBox:SetScript("OnEnterPressed", function(self)
		if ui.playerSearchSelection > 0 then
			SelectPlayerSearchSuggestion(ui.playerSearchSelection)
		elseif #ui.playerSearchSuggestions > 0 then
			SelectPlayerSearchSuggestion(1)
		else
			self:ClearFocus()
		end
	end)
	ui.playerSearchBox:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
		ui.playerSearchSuggestionsFrame:Hide()
	end)

	ui.playerSearchSuggestionsFrame = CreateFrame("Frame", nil, ui.playerRankingPanel)
	ui.playerSearchSuggestionsFrame:SetWidth(224)
	ui.playerSearchSuggestionsFrame:SetPoint("TOPRIGHT", ui.playerSearchBox, "BOTTOMRIGHT", 0, -2)
	ui.playerSearchSuggestionsFrame:SetFrameStrata("TOOLTIP")
	ui.playerSearchSuggestionsFrame:SetFrameLevel(50)
	ui.playerSearchSuggestionsFrame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 10,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	ui.playerSearchSuggestionsFrame:SetBackdropColor(0.025, 0.03, 0.045, 0.99)
	ui.playerSearchSuggestionsFrame:SetBackdropBorderColor(0.24, 0.27, 0.34, 1)
	for index = 1, PLAYER_SEARCH_MAX_SUGGESTIONS do
		local button = CreateFrame("Button", nil, ui.playerSearchSuggestionsFrame)
		button:SetHeight(24)
		button:SetPoint("TOPLEFT", ui.playerSearchSuggestionsFrame, "TOPLEFT", 3, -3 - (index - 1) * 24)
		button:SetPoint("TOPRIGHT", ui.playerSearchSuggestionsFrame, "TOPRIGHT", -3, -3 - (index - 1) * 24)
		button.background = CreateSolidTexture(button, "BACKGROUND", 0.15, 0.17, 0.22, 0.92)
		button.background:SetAllPoints()
		button.nameText = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		button.nameText:SetPoint("LEFT", 7, 0)
		button.nameText:SetWidth(122)
		button.nameText:SetJustifyH("LEFT")
		button.detailText = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		button.detailText:SetPoint("RIGHT", -7, 0)
		button.detailText:SetWidth(92)
		button.detailText:SetJustifyH("RIGHT")
		button:SetScript("OnEnter", function(self)
			ui.playerSearchSelection = self.suggestionIndex or 0
			SetSearchSuggestionHighlight()
		end)
		button:SetScript("OnClick", function(self)
			SelectPlayerSearchSuggestion(self.suggestionIndex)
		end)
		ui.playerSearchSuggestionButtons[index] = button
	end
	ui.playerSearchSuggestionsFrame:Hide()

	ui.playerRankingSummaryAnalyzed = CreateRankingSummaryCard(
		ui.playerRankingPanel, 8, "BGs collected", 0.10, 0.72, 0.52
	)
	ui.playerRankingSummaryAnalyzed.tooltipText =
		"Number of battlegrounds recorded since the individual ranking was enabled. The old anonymous history contains no recoverable names."
	ui.playerRankingSummaryBalance = CreateRankingSummaryCard(
		ui.playerRankingPanel, 202, "Average influence", 0.30, 0.62, 0.95
	)
	ui.playerRankingSummaryBalance.tooltipText =
		"Average battleground weight. A stomp influences the ranking less, with the same coefficient for every player in the match."
	ui.playerRankingSummaryPlayers = CreateRankingSummaryCard(
		ui.playerRankingPanel, 396, "Players ranked", 0.68, 0.43, 0.95
	)
	ui.playerRankingSummaryPlayers.tooltipText =
		"Number of characters that have finished the three placement battlegrounds in the displayed role and filter."

	local playerRankHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"RANK",
		"Official position after three placement battlegrounds. Players still in placement show a dash.",
		48
	)
	playerRankHeader:SetPoint("TOPLEFT", ui.playerRankingPanel, "TOPLEFT", 18, -103)
	local playerNameHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"PLAYER",
		"Full character name, colored by class. The adjacent icon shows their specializations on hover.",
		190
	)
	playerNameHeader:SetPoint("TOPLEFT", ui.playerRankingPanel, "TOPLEFT", 54, -103)
	local playerLastSeenHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"LAST SEEN",
		"When you last met this character in a recorded battleground.",
		142
	)
	playerLastSeenHeader:SetPoint(
		"TOPLEFT",
		ui.playerRankingPanel,
		"TOPLEFT",
		250,
		-103
	)
	local playerScoreHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"SCORE",
		"Ranking score = performance relative to the role average, corrected for level and the percentage of the battleground actually played, then smoothed with 10 virtual battlegrounds and an uncertainty margin. A player present under 25% of the time, or with no damage/healing relevant to their role, is not recorded.",
		64
	)
	playerScoreHeader.text:SetJustifyH("RIGHT")
	playerScoreHeader:SetPoint("TOPRIGHT", ui.playerRankingPanel, "TOPRIGHT", -339, -103)
	local playerRegularityHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"CONSISTENCY",
		"Percentage of battlegrounds where the player reaches at least 90% of the best score in their role.",
		86
	)
	playerRegularityHeader.text:SetJustifyH("RIGHT")
	playerRegularityHeader:SetPoint("TOPRIGHT", ui.playerRankingPanel, "TOPRIGHT", -244, -103)
	local playerMatchesHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"BG",
		"Number of valid battlegrounds observed in this role. Three are required to receive an official rank.",
		48
	)
	playerMatchesHeader.text:SetJustifyH("RIGHT")
	playerMatchesHeader:SetPoint("TOPRIGHT", ui.playerRankingPanel, "TOPRIGHT", -169, -103)
	local playerConfidenceHeader = CreateRankingColumnHeader(
		ui.playerRankingPanel,
		"CONFIDENCE",
		"Placement up to 3 battlegrounds, then provisional confidence before 5, medium from 5 to 19, and reliable from 20 onward.",
		120
	)
	playerConfidenceHeader.text:SetJustifyH("RIGHT")
	playerConfidenceHeader:SetPoint("TOPRIGHT", ui.playerRankingPanel, "TOPRIGHT", -32, -103)

	ui.playerRankingScrollFrame = CreateFrame(
		"ScrollFrame",
		"CoAAnalyticsPlayerRankingScrollFrame",
		ui.playerRankingPanel,
		"FauxScrollFrameTemplate"
	)
	ui.playerRankingScrollFrame:SetPoint("TOPLEFT", ui.playerRankingPanel, "TOPLEFT", 8, -130)
	ui.playerRankingScrollFrame:SetPoint("BOTTOMRIGHT", ui.playerRankingPanel, "BOTTOMRIGHT", -24, 46)
	ui.playerRankingScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(
			self,
			offset,
			RANKING_ROW_HEIGHT,
			ui.RefreshPlayerRankingPanel
		)
	end)
	for index = 1, RANKING_VISIBLE_ROWS do
		ui.playerRankingRows[index] = CreatePlayerRankingRow(ui.playerRankingPanel, index)
	end
	ui.playerRankingNoDataText = ui.playerRankingPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ui.playerRankingNoDataText:SetPoint("CENTER", ui.playerRankingPanel, "CENTER", 0, -40)
	ui.playerRankingNoDataText:SetText(
		"No player ranked in this category.\n"
			.. "Individual ranking begins at the end of the next complete battleground."
	)
	ui.playerRankingMethodologyText = ui.playerRankingPanel:CreateFontString(
		nil, "OVERLAY", "GameFontDisableSmall"
	)
	ui.playerRankingMethodologyText:SetPoint("BOTTOMLEFT", ui.playerRankingPanel, "BOTTOMLEFT", 12, 9)
	ui.playerRankingMethodologyText:SetWidth(540)
	ui.playerRankingMethodologyText:SetHeight(42)
	ui.playerRankingMethodologyText:SetJustifyH("LEFT")
	ui.playerRankingMethodologyText:SetJustifyV("BOTTOM")
	ui.playerRankingMethodologyText:SetWordWrap(true)
	local clearPlayerRankingButton = CreateFrame(
		"Button", nil, ui.playerRankingPanel, "UIPanelButtonTemplate"
	)
	clearPlayerRankingButton:SetWidth(130)
	clearPlayerRankingButton:SetHeight(23)
	clearPlayerRankingButton:SetPoint("BOTTOMRIGHT", ui.playerRankingPanel, "BOTTOMRIGHT", -8, 7)
	clearPlayerRankingButton:SetText("Reset")
	clearPlayerRankingButton:SetScript("OnClick", function()
		StaticPopup_Show("COA_ANALYTICS_RESET_BG_PLAYERS")
	end)

	if not StaticPopupDialogs["COA_ANALYTICS_RESET_BG_RANKINGS"] then
		StaticPopupDialogs["COA_ANALYTICS_RESET_BG_RANKINGS"] = {
			text = "Erase both the per-specialization and per-player BG rankings?",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				local lastMatchSignature = addonDB.rankings
					and addonDB.rankings.lastMatchSignature
				addonDB.rankings = nil
				InitializeRankingDatabase()
				addonDB.rankings.lastMatchSignature = lastMatchSignature
				ui.playerSearchIndexDirty = true
				ui.playerSearchIndex = {}
				if ui.playerSearchBox then ui.playerSearchBox:SetText("") end
				local scrollBar = _G["CoAAnalyticsRankingScrollFrameScrollBar"]
				if scrollBar then
					scrollBar:SetValue(0)
				end
				local playerScrollBar =
					_G["CoAAnalyticsPlayerRankingScrollFrameScrollBar"]
				if playerScrollBar then
					playerScrollBar:SetValue(0)
				end
				ui.RefreshRankingPanel()
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
	end
	if not StaticPopupDialogs["COA_ANALYTICS_RESET_BG_PLAYERS"] then
		StaticPopupDialogs["COA_ANALYTICS_RESET_BG_PLAYERS"] = {
			text = "Erase only the individual player ranking? The per-specialization ranking will be kept.",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				if addonDB and addonDB.rankings then
					addonDB.rankings.players = nil
					InitializeRankingDatabase()
					ui.playerSearchIndexDirty = true
					ui.playerSearchIndex = {}
					if ui.playerSearchBox then ui.playerSearchBox:SetText("") end
					local scrollBar =
						_G["CoAAnalyticsPlayerRankingScrollFrameScrollBar"]
					if scrollBar then scrollBar:SetValue(0) end
					ui.RefreshRankingPanel()
				end
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
	end

	if CoAAnalyticsPvE and CoAAnalyticsPvE.CreatePanel then
		ui.pveRankingPanel = CoAAnalyticsPvE.CreatePanel(frame)
	end
	if CoAAnalyticsPvE and CoAAnalyticsPvE.CreateSessionPanel then
		ui.pveSessionPanel = CoAAnalyticsPvE.CreateSessionPanel(frame)
	end

	ui.nameplateTabButton:SetScript("OnClick", function()
		SetSettingsSection("settings")
	end)
	ui.generalSettingsTabButton:SetScript("OnClick", function()
		SetSettingsMode("general")
	end)
	ui.nameplateSettingsTabButton:SetScript("OnClick", function()
		SetSettingsMode("nameplates")
	end)
	ui.rankingTabButton:SetScript("OnClick", function()
		SetSettingsSection("ranking")
	end)
	ui.pveRankingTabButton:SetScript("OnClick", function()
		SetSettingsSection("pve")
	end)
	ui.pveSessionTabButton:SetScript("OnClick", function()
		SetSettingsSection("pvesession")
	end)
	ui.specializationRankingTabButton:SetScript("OnClick", function()
		SetRankingMode("specializations")
	end)
	ui.playerRankingTabButton:SetScript("OnClick", function()
		SetRankingMode("players")
	end)
	ui.damageRankingTabButton:SetScript("OnClick", function()
		ui.SetRankingCategory("dps")
	end)
	ui.healingRankingTabButton:SetScript("OnClick", function()
		ui.SetRankingCategory("healing")
	end)
	ui.playerDpsTabButton:SetScript("OnClick", function()
		ui.SetPlayerRankingCategory("dps")
	end)
	ui.playerHealingTabButton:SetScript("OnClick", function()
		ui.SetPlayerRankingCategory("healing")
	end)
	ui.playerTankTabButton:SetScript("OnClick", function()
		ui.SetPlayerRankingCategory("tank")
	end)
	ui.playerSupportTabButton:SetScript("OnClick", function()
		ui.SetPlayerRankingCategory("support")
	end)

	local closeButton = CreateFrame(
		"Button",
		nil,
		frame,
		"UIPanelCloseButton"
	)
	closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

	frame:SetScript("OnShow", function()
		RefreshSettingsControls()
		SetSettingsSection(ui.activeSettingsTab)
	end)
	frame:Hide()
	ui.settingsFrame = frame
	table.insert(UISpecialFrames, "CoAAnalyticsSettingsFrame")
	return frame
end

local function ToggleSettingsFrame()
	local frame = CreateSettingsFrame()
	if frame:IsShown() then
		frame:Hide()
	else
		ui.activeSettingsTab = "ranking"
		frame:Show()
	end
end

-- Le bouton de minimap est charge depuis Minimap.lua.

function UI.Initialize()
	addonDB = API and API.GetDatabase and API.GetDatabase()
	if not addonDB then
		return false
	end
	return true
end

function UI.NotifyRankingChanged()
	ui.playerSearchIndexDirty = true
	if ui.RefreshRankingPanel then
		ui.RefreshRankingPanel()
	end
end

function UI.Open(section, rankingMode)
	addonDB = API and API.GetDatabase and API.GetDatabase() or addonDB
	if not addonDB then
		return
	end
	if rankingMode == "players" or rankingMode == "specializations" then
		ui.activeRankingMode = rankingMode
	end
	if section == "nameplates" then
		ui.activeSettingsMode = "nameplates"
		ui.activeSettingsTab = "settings"
	elseif section == "settings" or section == "pve" or section == "pvesession" then
		ui.activeSettingsTab = section
	else
		ui.activeSettingsTab = "ranking"
	end
	local frame = CreateSettingsFrame()
	frame:Show()
	SetSettingsSection(ui.activeSettingsTab)
end

function UI.Toggle()
	addonDB = API and API.GetDatabase and API.GetDatabase() or addonDB
	if addonDB then
		ToggleSettingsFrame()
	end
end

function UI.RefreshSettings()
	RefreshSettingsControls()
end

API.GetClassDisplayName = GetRankingClassName

CoAAnalyticsAddon.Events:Register("BG_RANKING_UPDATED", UI.NotifyRankingChanged)
CoAAnalyticsAddon.Events:Register("PVE_DIAGNOSTIC_STATUS_UPDATED", function()
	RefreshSettingsControls()
end)

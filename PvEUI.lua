local API = CoAAnalyticsAPI
local PvE = CoAAnalyticsPvE

local VISIBLE_ROWS = 7
local ROW_HEIGHT = 34
local SESSION_VISIBLE_ROWS = 7
local SESSION_ROW_HEIGHT = 34
local RANKING_PROGRESS_ALPHA = 0.38
local SESSION_PROGRESS_ALPHA = 0.36

local panel
local rows = {}
local scrollFrame
local noDataText
local methodologyText
local summarySamples
local summaryReference
local summarySpecs
local roleButtons = {}
local scopeButtons = {}
local activeCategory = "dps"
local activeScope = "all"
local sessionPanel
local sessionRows = {}
local sessionScrollFrame
local sessionNoDataText
local sessionMethodologyText
local sessionStatusText
local sessionPaceText
local sessionSummaryInstance
local sessionSummaryCombat
local sessionSummaryRating

local function Clamp(value, minimum, maximum)
	value = tonumber(value) or 0
	if value < minimum then return minimum end
	if value > maximum then return maximum end
	return value
end

local function SafeNumber(value)
	value = tonumber(value)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return value
end

local function CreateSolidTexture(parent, layer, r, g, b, a)
	local texture = parent:CreateTexture(nil, layer or "ARTWORK")
	texture:SetTexture(1, 1, 1, a or 1)
	texture:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
	return texture
end

local function CreateTab(parent, label, r, g, b)
	local button = CreateFrame("Button", nil, parent)
	button:SetWidth(110)
	button:SetHeight(34)
	button:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background" })
	button:SetBackdropColor(0.09, 0.10, 0.13, 0.96)
	button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	button.text:SetPoint("CENTER")
	button.text:SetText(label)
	button.accent = CreateSolidTexture(button, "OVERLAY", r, g, b, 1)
	button.accent:SetPoint("BOTTOMLEFT", 0, 0)
	button.accent:SetPoint("BOTTOMRIGHT", 0, 0)
	button.accent:SetHeight(3)
	button.activeColor = { r, g, b }
	return button
end

local function SetTabActive(button, active)
	if not button then
		return
	end
	button:SetBackdropColor(
		active and 0.16 or 0.07,
		active and 0.17 or 0.08,
		active and 0.21 or 0.10,
		0.98
	)
	button.accent:SetAlpha(active and 1 or 0.18)
	button.text:SetTextColor(active and 1 or 0.68, active and 1 or 0.70, active and 1 or 0.75)
end

local function CreateSummaryCard(parent, x, label, r, g, b)
	local card = CreateFrame("Frame", nil, parent)
	card:SetWidth(210)
	card:SetHeight(62)
	card:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -52)
	card:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 9,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	card:SetBackdropColor(0.04, 0.045, 0.06, 0.96)
	card:SetBackdropBorderColor(0.14, 0.16, 0.20, 1)
	local accent = CreateSolidTexture(card, "ARTWORK", r, g, b, 1)
	accent:SetWidth(4)
	accent:SetPoint("TOPLEFT", 4, -4)
	accent:SetPoint("BOTTOMLEFT", 4, 4)
	card.value = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	card.value:SetPoint("TOPLEFT", 17, -10)
	card.value:SetText("0")
	card.label = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	card.label:SetPoint("BOTTOMLEFT", 17, 10)
	card.label:SetText(label)
	return card
end

local function CreateRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(ROW_HEIGHT - 1)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -151 - (index - 1) * ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -27, -151 - (index - 1) * ROW_HEIGHT)
	row.background = CreateSolidTexture(row, "BACKGROUND", 0.07, 0.075, 0.09, 0.96)
	row.background:SetAllPoints()
	row.progress = CreateSolidTexture(
		row,
		"ARTWORK",
		0.30,
		0.62,
		0.95,
		RANKING_PROGRESS_ALPHA
	)
	row.progress:SetPoint("TOPLEFT")
	row.progress:SetPoint("BOTTOMLEFT")
	row.progress:SetWidth(1)
	row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.rank:SetPoint("LEFT", 16, 0)
	row.icon = row:CreateTexture(nil, "OVERLAY")
	row.icon:SetWidth(28)
	row.icon:SetHeight(28)
	row.icon:SetPoint("LEFT", 48, 0)
	row.classText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.classText:SetPoint("TOPLEFT", 84, -5)
	row.specText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.specText:SetPoint("BOTTOMLEFT", 84, 5)
	row.scoreText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.scoreText:SetPoint("RIGHT", -150, 0)
	row.samplesText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.samplesText:SetPoint("RIGHT", -82, 0)
	row.confidenceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.confidenceText:SetPoint("RIGHT", -9, 0)
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		if not self.entry then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(
			tostring(self.entry.specialization or "Specialization"),
			1,
			0.82,
			0.20
		)
		GameTooltip:AddLine(string.format("Stabilized score: %.1f", self.entry.score), 1, 1, 1)
		GameTooltip:AddLine(string.format("Raw index: %.1f", self.entry.rawScore), 0.72, 0.78, 0.86)
		GameTooltip:AddLine("Samples: " .. tostring(self.entry.samples), 0.72, 0.78, 0.86)
		GameTooltip:AddLine("Confidence: " .. tostring(self.entry.confidence), 0.72, 0.78, 0.86)
		GameTooltip:AddLine("Top 1 finishes: " .. tostring(self.entry.top1), 0.72, 0.78, 0.86)
		GameTooltip:AddLine("The score is pulled back toward 100 while the sample is small.", 0.58, 0.62, 0.70, true)
		if activeCategory == "dps" then
			GameTooltip:AddLine(
				"New DPS samples are corrected against the group's median level, with a bounded correction so build and gear still matter.",
				0.58,
				0.64,
				0.72,
				true
			)
			if SafeNumber(self.entry.levelAdjustedSamples) > 0 then
				GameTooltip:AddLine(
					"Level-adjusted samples: "
						.. tostring(self.entry.levelAdjustedSamples),
					0.72,
					0.78,
					0.86
				)
			end
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	row:Hide()
	return row
end

local function UpdateTabs()
	for key, button in pairs(roleButtons) do
		SetTabActive(button, key == activeCategory)
	end
	for key, button in pairs(scopeButtons) do
		SetTabActive(button, key == activeScope)
	end
end

function PvE.RefreshPanel()
	if not panel or not scrollFrame then
		return
	end
	local entries, summary = PvE.GetLeaderboard(activeCategory, activeScope)
	UpdateTabs()
	summarySamples.value:SetText(tostring(summary.samples or 0))
	summaryReference.value:SetText("100")
	summarySpecs.value:SetText(tostring(summary.specializations or 0))
	local categoryLabels = { dps = "DPS", healing = "healers", tank = "tanks" }
	local scopeLabels = { all = "dungeons and raids", dungeon = "dungeons", raid = "raid bosses" }
	local levelMethod = activeCategory == "dps"
		and " For DPS, damage is also adjusted to the group's median level." or ""
	methodologyText:SetText(
		"100 = average performance in a comparable context. The score is adjusted to the content, then stabilized with 10 virtual samples."
			.. levelMethod .. " View: " .. categoryLabels[activeCategory]
			.. " / " .. scopeLabels[activeScope] .. "."
	)

	FauxScrollFrame_Update(scrollFrame, #entries, VISIBLE_ROWS, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(scrollFrame) or 0
	local leader = entries[1] and entries[1].score or 100
	for index = 1, VISIBLE_ROWS do
		local row = rows[index]
		local rankingIndex = offset + index
		local entry = entries[rankingIndex]
		if entry then
			row.entry = entry
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
			if API and API.ApplySpecializationTexture then
				API.ApplySpecializationTexture(row.icon, entry, true)
			end
			local color = RAID_CLASS_COLORS[entry.classToken] or { r = 0.86, g = 0.86, b = 0.86 }
			local className = API and API.GetClassDisplayName
				and API.GetClassDisplayName(entry.classToken) or entry.classToken
			row.classText:SetText(className or "Unknown class")
			row.classText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
			row.specText:SetText(tostring(entry.specialization or "?"))
			row.scoreText:SetText(string.format("%.1f", entry.score))
			row.samplesText:SetText(tostring(entry.samples))
			row.confidenceText:SetText(entry.confidence)
			row.confidenceText:SetTextColor(unpack(entry.confidenceColor))
			local relative = leader > 0 and entry.score / leader or 0
			row.progress:SetWidth(math.max(1, math.floor((row:GetWidth() or 1) * Clamp(relative, 0, 1))))
			if activeCategory == "dps" then
				row.progress:SetVertexColor(
					0.95,
					0.58,
					0.10,
					RANKING_PROGRESS_ALPHA
				)
			elseif activeCategory == "healing" then
				row.progress:SetVertexColor(
					0.20,
					0.82,
					0.42,
					RANKING_PROGRESS_ALPHA
				)
			else
				row.progress:SetVertexColor(
					0.30,
					0.62,
					0.95,
					RANKING_PROGRESS_ALPHA
				)
			end
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end
	if #entries == 0 then
		noDataText:Show()
	else
		noDataText:Hide()
	end
end

local function SelectCategory(category)
	activeCategory = category
	local scrollBar = _G["CoAAnalyticsPvERankingScrollFrameScrollBar"]
	if scrollBar then
		scrollBar:SetValue(0)
	end
	PvE.RefreshPanel()
end

local function SelectScope(scope)
	activeScope = scope
	local scrollBar = _G["CoAAnalyticsPvERankingScrollFrameScrollBar"]
	if scrollBar then
		scrollBar:SetValue(0)
	end
	PvE.RefreshPanel()
end

function PvE.CreatePanel(parent)
	if panel then
		return panel
	end
	panel = CreateFrame("Frame", nil, parent)
	panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -88)
	panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -18, 18)

	roleButtons.dps = CreateTab(panel, "Damage", 0.95, 0.58, 0.10)
	roleButtons.dps:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -6)
	roleButtons.healing = CreateTab(panel, "Healing", 0.20, 0.82, 0.42)
	roleButtons.healing:SetPoint("LEFT", roleButtons.dps, "RIGHT", 7, 0)
	roleButtons.tank = CreateTab(panel, "Tanks", 0.30, 0.62, 0.95)
	roleButtons.tank:SetPoint("LEFT", roleButtons.healing, "RIGHT", 7, 0)
	roleButtons.dps:SetScript("OnClick", function() SelectCategory("dps") end)
	roleButtons.healing:SetScript("OnClick", function() SelectCategory("healing") end)
	roleButtons.tank:SetScript("OnClick", function() SelectCategory("tank") end)

	scopeButtons.raid = CreateTab(panel, "Raids", 0.68, 0.43, 0.95)
	scopeButtons.raid:SetWidth(82)
	scopeButtons.raid:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -6)
	scopeButtons.dungeon = CreateTab(panel, "Dungeons", 0.68, 0.43, 0.95)
	scopeButtons.dungeon:SetWidth(82)
	scopeButtons.dungeon:SetPoint("RIGHT", scopeButtons.raid, "LEFT", -6, 0)
	scopeButtons.all = CreateTab(panel, "All", 0.68, 0.43, 0.95)
	scopeButtons.all:SetWidth(70)
	scopeButtons.all:SetPoint("RIGHT", scopeButtons.dungeon, "LEFT", -6, 0)
	scopeButtons.all:SetScript("OnClick", function() SelectScope("all") end)
	scopeButtons.dungeon:SetScript("OnClick", function() SelectScope("dungeon") end)
	scopeButtons.raid:SetScript("OnClick", function() SelectScope("raid") end)

	summarySamples = CreateSummaryCard(panel, 8, "Samples analyzed", 0.10, 0.72, 0.52)
	summaryReference = CreateSummaryCard(panel, 238, "Average reference", 0.30, 0.62, 0.95)
	summarySpecs = CreateSummaryCard(panel, 468, "Specializations ranked", 0.68, 0.43, 0.95)

	local rankHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	rankHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, -133)
	rankHeader:SetText("RANK")
	local identityHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	identityHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 96, -133)
	identityHeader:SetText("CLASS / SPECIALIZATION")
	local scoreHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	scoreHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -165, -133)
	scoreHeader:SetText("SCORE")
	local samplesHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	samplesHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -93, -133)
	samplesHeader:SetText("NB")
	local confidenceHeader = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	confidenceHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -15, -133)
	confidenceHeader:SetText("CONFIDENCE")

	scrollFrame = CreateFrame(
		"ScrollFrame",
		"CoAAnalyticsPvERankingScrollFrame",
		panel,
		"FauxScrollFrameTemplate"
	)
	scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -149)
	scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 52)
	scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, PvE.RefreshPanel)
	end)
	for index = 1, VISIBLE_ROWS do
		rows[index] = CreateRow(panel, index)
	end

	noDataText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	noDataText:SetPoint("CENTER", panel, "CENTER", 0, -38)
	noDataText:SetText(
		"No valid PvE performance yet.\n"
			.. "Ranking begins after a completed dungeon or a defeated raid boss."
	)

	methodologyText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	methodologyText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 9)
	methodologyText:SetWidth(540)
	methodologyText:SetHeight(40)
	methodologyText:SetJustifyH("LEFT")
	methodologyText:SetJustifyV("BOTTOM")
	methodologyText:SetWordWrap(true)

	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetWidth(130)
	reset:SetHeight(23)
	reset:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 7)
	reset:SetText("Reset")
	reset:SetScript("OnClick", function()
		StaticPopup_Show("COA_ANALYTICS_RESET_PVE")
	end)
	if not StaticPopupDialogs["COA_ANALYTICS_RESET_PVE"] then
		StaticPopupDialogs["COA_ANALYTICS_RESET_PVE"] = {
			text = "Erase the entire PvE ranking history?",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				local addonDB = API and API.GetDatabase and API.GetDatabase()
				if addonDB then
					local currentDungeon = addonDB.pveRankings
						and addonDB.pveRankings.currentDungeon
					local lastDungeonDiagnostic = addonDB.pveRankings
						and addonDB.pveRankings.lastDungeonDiagnostic
					addonDB.pveRankings = nil
					local root = PvE.InitializeDatabase()
					if root then
						root.currentDungeon = currentDungeon
						root.lastDungeonDiagnostic = lastDungeonDiagnostic
					end
					PvE.RefreshPanel()
				end
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
	end

	panel:Hide()
	PvE.RefreshPanel()
	return panel
end

local SESSION_ROLE_LABELS = {
	TANK = "Tank",
	HEALER = "Healer",
	DAMAGER = "DPS",
	MELEE_DAMAGER = "Melee DPS",
	RANGED_DAMAGER = "Ranged DPS",
	SUPPORT = "Support",
}

local function FormatCompactNumber(value)
	value = SafeNumber(value)
	if value >= 1000000 then
		return string.format("%.1f M", value / 1000000)
	elseif value >= 1000 then
		return string.format("%.1f k", value / 1000)
	end
	return tostring(math.floor(value + 0.5))
end

local function FormatCombatTime(seconds)
	seconds = math.floor(SafeNumber(seconds) + 0.5)
	local minutes = math.floor(seconds / 60)
	local remaining = seconds - minutes * 60
	return string.format("%d:%02d", minutes, remaining)
end

local function GetRatingColor(rating)
	if PvE and PvE.GetRatingColor then
		return PvE.GetRatingColor(rating)
	end
	return 1, 1, 1
end

local function AddPercentLine(label, value)
	GameTooltip:AddDoubleLine(
		label,
		string.format("%.0f%%", SafeNumber(value) * 100),
		0.72, 0.78, 0.86, 1, 1, 1
	)
end

local function AddRatioLine(label, value)
	GameTooltip:AddDoubleLine(
		label,
		string.format("x%.2f", SafeNumber(value)),
		0.72, 0.78, 0.86, 1, 1, 1
	)
end

local function AddPointLine(label, value)
	GameTooltip:AddDoubleLine(
		label,
		string.format("%.1f", SafeNumber(value)),
		0.72, 0.78, 0.86, 1, 1, 1
	)
end

local function AddBonusLine(label, value)
	value = SafeNumber(value)
	if value <= 0 then
		return
	end
	GameTooltip:AddDoubleLine(
		label,
		string.format("+%.1f", value),
		0.72, 0.78, 0.86, 0.18, 0.82, 0.46
	)
end

-- Execution quality, shown for every role: the things that decide whether a
-- run goes smoothly regardless of what the damage numbers say.
local function AddExecutionLines(entry)
	local x = entry.execution
	if not x then
		return
	end
	local interrupts = math.floor(SafeNumber(x.interrupts))
	local dispels = math.floor(SafeNumber(x.dispels))
	local repeats = math.floor(SafeNumber(x.repeatedHitCount))
	if interrupts <= 0 and dispels <= 0 and repeats <= 0 then
		return
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Execution", 1, 0.82, 0.20)
	if interrupts > 0 then
		GameTooltip:AddDoubleLine("Interrupts landed", tostring(interrupts),
			0.72, 0.78, 0.86, 0.18, 0.82, 0.46)
	end
	if dispels > 0 then
		GameTooltip:AddDoubleLine("Dispels / spell steals", tostring(dispels),
			0.72, 0.78, 0.86, 0.18, 0.82, 0.46)
	end
	if repeats > 0 then
		GameTooltip:AddDoubleLine(
			"Repeat hits taken",
			tostring(repeats) .. " ("
				.. FormatCompactNumber(x.repeatedHitDamage) .. ")",
			0.72, 0.78, 0.86, 0.95, 0.62, 0.18
		)
		GameTooltip:AddDoubleLine(
			"Share of damage taken",
			string.format("%.0f%%", SafeNumber(x.avoidableShare) * 100),
			0.72, 0.78, 0.86, 0.95, 0.62, 0.18
		)
		GameTooltip:AddLine(
			"Damage from a spell that hit this character three or more times in one pull. Likely avoidable.",
			0.58, 0.64, 0.72, true
		)
	end
end

-- Shown for every role. A damage dealer who lands real saves should not have
-- that work buried under the role-specific section.
local function AddClutchLines(entry)
	local clutch = entry.clutch
	if not clutch or SafeNumber(clutch.clutchHeals) <= 0 then
		return
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Clutch healing", 1, 0.82, 0.20)
	GameTooltip:AddDoubleLine(
		"Heals on targets under 35%",
		tostring(math.floor(SafeNumber(clutch.clutchHeals))),
		0.72, 0.78, 0.86, 1, 1, 1
	)
	if SafeNumber(clutch.wipeSaves) > 0 then
		GameTooltip:AddDoubleLine(
			"Wipe-prevention saves",
			tostring(math.floor(SafeNumber(clutch.wipeSaves))),
			1, 0.82, 0.20, 0.18, 0.90, 0.45
		)
		if SafeNumber(clutch.partyWideSaves) > 0 then
			GameTooltip:AddDoubleLine(
				"Carried party-wide healing",
				tostring(math.floor(SafeNumber(clutch.partyWideSaves))) .. "x ("
					.. tostring(math.floor(SafeNumber(clutch.partyWideBestCount)))
					.. " covered)",
				1, 0.82, 0.20, 0.18, 0.90, 0.45
			)
		end
		GameTooltip:AddLine(
			"Saving the tank or healer, healing through a collapsing group, or covering most of the party as a non-healer. Weighted far above an ordinary save.",
			0.58, 0.64, 0.72, true
		)
	end
	if SafeNumber(clutch.lifeSaves) > 0 then
		GameTooltip:AddDoubleLine(
			"Likely life saves (under 20%)",
			tostring(math.floor(SafeNumber(clutch.lifeSaves))),
			0.72, 0.78, 0.86, 0.18, 0.82, 0.46
		)
	end
	GameTooltip:AddDoubleLine(
		"Healing delivered while critical",
		FormatCompactNumber(clutch.clutchHealing),
		0.72, 0.78, 0.86, 1, 1, 1
	)
	local onTank = math.floor(SafeNumber(clutch.clutchHealsOnTank))
	local onHealer = math.floor(SafeNumber(clutch.clutchHealsOnHealer))
	if onTank > 0 or onHealer > 0 then
		GameTooltip:AddDoubleLine(
			"On tank / on healer",
			tostring(onTank) .. " / " .. tostring(onHealer),
			0.72, 0.78, 0.86, 1, 1, 1
		)
	end
end

local function CreateSessionRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(SESSION_ROW_HEIGHT - 1)
	row:SetPoint(
		"TOPLEFT",
		parent,
		"TOPLEFT",
		12,
		-151 - (index - 1) * SESSION_ROW_HEIGHT
	)
	row:SetPoint(
		"TOPRIGHT",
		parent,
		"TOPRIGHT",
		-27,
		-151 - (index - 1) * SESSION_ROW_HEIGHT
	)
	row.background = CreateSolidTexture(row, "BACKGROUND", 0.07, 0.075, 0.09, 0.96)
	row.background:SetAllPoints()
	row.progress = CreateSolidTexture(
		row,
		"ARTWORK",
		0.68,
		0.43,
		0.95,
		SESSION_PROGRESS_ALPHA
	)
	row.progress:SetPoint("TOPLEFT")
	row.progress:SetPoint("BOTTOMLEFT")
	row.progress:SetWidth(1)

	row.specIcon = row:CreateTexture(nil, "OVERLAY")
	row.specIcon:SetWidth(27)
	row.specIcon:SetHeight(27)
	row.specIcon:SetPoint("LEFT", 7, 0)
	row.roleIcon = row:CreateTexture(nil, "OVERLAY")
	row.roleIcon:SetWidth(20)
	row.roleIcon:SetHeight(20)
	row.roleIcon:SetPoint("LEFT", 40, 0)
	row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.nameText:SetPoint("TOPLEFT", 67, -4)
	row.nameText:SetWidth(215)
	row.nameText:SetJustifyH("LEFT")
	row.specText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.specText:SetPoint("BOTTOMLEFT", 67, 4)
	row.specText:SetWidth(215)
	row.specText:SetJustifyH("LEFT")
	row.roleText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.roleText:SetPoint("LEFT", 292, 0)
	row.roleText:SetWidth(90)
	row.roleText:SetJustifyH("LEFT")
	row.dpsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.dpsText:SetPoint("RIGHT", -275, 0)
	row.hpsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.hpsText:SetPoint("RIGHT", -205, 0)
	row.deathsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.deathsText:SetPoint("RIGHT", -145, 0)
	row.scoreText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.scoreText:SetPoint("RIGHT", -77, 0)
	row.ratingText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	row.ratingText:SetPoint("RIGHT", -8, 0)

	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		local entry = self.entry
		if not entry then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(tostring(entry.name or "Player"), 1, 0.82, 0.20)
		GameTooltip:AddLine(
			tostring(entry.specialization or "Unknown specialization")
				.. " - " .. tostring(SESSION_ROLE_LABELS[entry.role] or "Unknown role"),
			0.78,
			0.82,
			0.90
		)
		if entry.rating then
			GameTooltip:AddLine("Rating: " .. PvE.FormatRating(entry.rating) .. " / 10", 1, 1, 1)
			GameTooltip:AddLine(string.format("Role score: %.1f", entry.score), 0.72, 0.78, 0.86)
		else
			GameTooltip:AddLine(
				entry.exclusionReason
					and ("Unranked: " .. tostring(entry.exclusionReason))
					or "Rating pending sufficient data.",
				0.72, 0.78, 0.86, true
			)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine(
			"Damage done", FormatCompactNumber(entry.damage),
			0.72, 0.78, 0.86, 1, 1, 1
		)
		GameTooltip:AddDoubleLine(
			"Effective healing", FormatCompactNumber(entry.healing),
			0.72, 0.78, 0.86, 1, 1, 1
		)
		GameTooltip:AddDoubleLine(
			"Deaths", tostring(entry.deaths or 0),
			0.72, 0.78, 0.86, 1, 1, 1
		)
		AddExecutionLines(entry)
		AddClutchLines(entry)

		if PvE.IsDamageRole(entry.role) then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Damage breakdown", 1, 0.82, 0.20)
			local breakdown = entry.dpsBreakdown
			if breakdown then
				AddPointLine("Output vs. group reference", breakdown.outputScore)
				AddPercentLine("Boss phase weight", breakdown.bossWeight)
				AddPercentLine("Trash phase weight", breakdown.trashWeight)
				AddRatioLine("Boss output ratio", breakdown.bossRatio)
				AddRatioLine("Trash output ratio", breakdown.trashRatio)
				AddPercentLine("Combat participation", breakdown.participation)
				AddPercentLine("Time alive", breakdown.aliveRate)
				AddBonusLine("Utility bonus", breakdown.utilityBonus)
				AddBonusLine("Clutch-heal bonus", breakdown.clutchBonus)
				if not breakdown.bossPhaseReliable then
					GameTooltip:AddLine(
						"Boss phase too short or isolated to score.",
						0.58, 0.64, 0.72, true
					)
				end
				if not breakdown.trashPhaseReliable then
					GameTooltip:AddLine(
						"Trash phase too short or isolated to score.",
						0.58, 0.64, 0.72, true
					)
				end
			end
			if entry.level and entry.levelReference and entry.levelFactor then
				GameTooltip:AddDoubleLine(
					"Level correction",
					string.format(
						"lvl %d vs %.1f (x%.2f)",
						entry.level, entry.levelReference, entry.levelFactor
					),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				if entry.levelSource == "details" then
					GameTooltip:AddLine(
						"Scaling taken from the Details level table, which is generated by the Ascension launcher.",
						0.18, 0.82, 0.46, true
					)
				elseif entry.levelSource == "builtin" then
					GameTooltip:AddLine(
						"Details level scaling unavailable; using the addon's own cautious curve instead.",
						0.95, 0.62, 0.18, true
					)
				end
			end
			GameTooltip:AddLine(
				"Boss weighting adapts to the dungeon and the reference is robust across DPS. The displayed DPS stays the real value; only the comparison is corrected.",
				0.58, 0.64, 0.72, true
			)

		elseif entry.role == "HEALER" then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Healing breakdown", 1, 0.82, 0.20)
			local breakdown = entry.healerBreakdown
			if breakdown then
				AddPercentLine("Stability", breakdown.stability)
				AddPercentLine("Coverage", breakdown.coverage)
				AddPercentLine("Responsiveness", breakdown.responsiveness)
				AddPercentLine("Availability", breakdown.aliveRate)
				AddPercentLine("Mana management", breakdown.manaManagement)
				AddPercentLine("Prevention", breakdown.prevention)
				if breakdown.averageUrgentRecovery then
					GameTooltip:AddDoubleLine(
						"Out of danger (65%)",
						string.format("%.1fs", SafeNumber(breakdown.averageUrgentRecovery)),
						0.72, 0.78, 0.86, 1, 1, 1
					)
				end
				if breakdown.averageRecovery then
					GameTooltip:AddDoubleLine(
						"Back to 80%",
						string.format("%.1fs", SafeNumber(breakdown.averageRecovery)),
						0.72, 0.78, 0.86, 1, 1, 1
					)
				end
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("Damage contribution", 1, 0.82, 0.20)
				GameTooltip:AddDoubleLine(
					"Damage done", FormatCompactNumber(breakdown.damageDone),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				AddRatioLine("vs. group DPS reference", breakdown.damageRatio)
				AddPercentLine("Healing-duty gate", breakdown.damageGate)
				AddBonusLine("Damage bonus", breakdown.healerDamageBonus)
				AddBonusLine("Clutch-heal bonus", breakdown.healerClutchBonus)
				if SafeNumber(breakdown.damageGate) <= 0 then
					GameTooltip:AddLine(
						"No damage credit: healing duties were not met first.",
						0.95, 0.62, 0.18, true
					)
				end
				GameTooltip:AddDoubleLine(
					"Confidence",
					string.format(
						"%.0f%% (%s)",
						SafeNumber(breakdown.opportunity) * 100,
						tostring(breakdown.confidence or "unknown")
					),
					0.72, 0.78, 0.86, 1, 1, 1
				)
			end
			GameTooltip:AddLine(
				"Overheal has almost no impact. Damage is only credited once stability, coverage and responsiveness are above par and nobody died a preventable death.",
				0.58, 0.64, 0.72, true
			)

		elseif entry.role == "TANK" then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Threat breakdown", 1, 0.82, 0.20)
			local breakdown = entry.tankBreakdown
			if breakdown then
				AddPercentLine("Threat uptime", breakdown.uptime)
				AddPercentLine("Threat lost", breakdown.lossRate)
				GameTooltip:AddDoubleLine(
					"Threat losses",
					tostring(math.floor(SafeNumber(breakdown.threatLossEvents))),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				GameTooltip:AddDoubleLine(
					"Average pickup",
					string.format("%.1fs", SafeNumber(breakdown.pickup)),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				GameTooltip:AddDoubleLine(
					"Mobs picked up",
					tostring(math.floor(SafeNumber(breakdown.pickupCount))),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				AddPointLine("Threat score", SafeNumber(breakdown.aggro) * 100)

				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("Mitigation breakdown", 1, 0.82, 0.20)
				AddPercentLine("Damage mitigated", breakdown.mitigationRate)
				AddPercentLine("Mitigated under pressure", breakdown.pressureMitigationRate)
				AddPercentLine("Attacks avoided", breakdown.avoidanceRate)
				AddPercentLine("Self-sustain vs. intake", breakdown.selfSustainRate)
				GameTooltip:AddDoubleLine(
					"Self healing / absorbs",
					FormatCompactNumber(breakdown.selfHealing)
						.. " / " .. FormatCompactNumber(breakdown.selfAbsorbs),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				GameTooltip:AddDoubleLine(
					"Raw intake",
					FormatCompactNumber(breakdown.damageTakenRaw)
						.. " (" .. FormatCompactNumber(breakdown.damageMitigated)
						.. " stopped)",
					0.72, 0.78, 0.86, 1, 1, 1
				)
				GameTooltip:AddDoubleLine(
					"Self-casts under pressure",
					tostring(math.floor(
						SafeNumber(breakdown.defensiveCastsUnderPressure)
					)),
					0.72, 0.78, 0.86, 0.78, 0.78, 0.78
				)
				AddPointLine("Mitigation score", SafeNumber(breakdown.mitigation) * 100)
				AddPointLine("Damage-taken resilience", SafeNumber(breakdown.resilience) * 100)
				AddPercentLine("Survival", breakdown.survival)
				if SafeNumber(breakdown.pressureMitigationRate)
					> SafeNumber(breakdown.mitigationRate) + 0.02
				then
					GameTooltip:AddLine(
						"Mitigation is concentrated in the dangerous windows.",
						0.18, 0.82, 0.46, true
					)
				end
			end
			GameTooltip:AddLine(
				"Mitigation is measured from the resisted, blocked and absorbed portions of every hit taken, plus avoided swings. Self-cast counts are diagnostic only; the client does not identify defensive abilities.",
				0.58, 0.64, 0.72, true
			)

		elseif entry.role == "SUPPORT" then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Support breakdown", 1, 0.82, 0.20)
			local breakdown = entry.supportBreakdown
			if breakdown and breakdown.measurable then
				GameTooltip:AddLine(
					"Graded as a hybrid: each contribution measured against that role's own reference.",
					0.58, 0.64, 0.72, true
				)
				AddRatioLine("Damage vs. DPS reference", breakdown.damageShare)
				AddRatioLine("Healing vs. healer reference", breakdown.rawHealShare)
				if SafeNumber(breakdown.rawHealShare) > SafeNumber(breakdown.healShare) then
					GameTooltip:AddLine(
						string.format(
							"Healing credit capped at %.0f%% of a dedicated healer; a hybrid cannot replace one.",
							SafeNumber(breakdown.healShare) * 100
						),
						0.58, 0.64, 0.72, true
					)
				end
				GameTooltip:AddDoubleLine(
					"Combined vs. par",
					string.format("%.2f / %.2f",
						SafeNumber(breakdown.combined), SafeNumber(breakdown.par)),
					0.72, 0.78, 0.86, 1, 1, 1
				)
				if breakdown.healerDamageMultiple then
					local multiple = SafeNumber(breakdown.healerDamageMultiple)
					GameTooltip:AddDoubleLine(
						"Damage vs. the healers",
						string.format("x%.2f", multiple),
						0.72, 0.78, 0.86,
						multiple >= 2 and 0.18 or 0.95,
						multiple >= 2 and 0.82 or 0.62,
						multiple >= 2 and 0.46 or 0.18
					)
					if SafeNumber(breakdown.dpsGate) < 1 then
						GameTooltip:AddLine(
							"Not clearly out-damaging the healers. A hybrid is a damage dealer that heals, not a second healer.",
							0.95, 0.62, 0.18, true
						)
					end
				end
				AddBonusLine("Damage + healing synergy", breakdown.synergy)
				AddRatioLine("Contribution vs. context", breakdown.contribution)
			elseif breakdown then
				AddRatioLine("Contribution vs. context", breakdown.contribution)
				AddPercentLine("Time alive", breakdown.aliveRate)
				GameTooltip:AddDoubleLine(
					"Utility per minute",
					string.format("%.1f", SafeNumber(breakdown.utilityRate)),
					0.72, 0.78, 0.86, 1, 1, 1
				)
			end
			GameTooltip:AddLine(
				"Buffs, crowd control and utility the client does not expose cannot all be scored.",
				0.58, 0.64, 0.72, true
			)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("7/10 is the expected performance for that role in this group.", 0.58, 0.64, 0.72, true)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	row:Hide()
	return row
end

function PvE.RefreshSessionPanel()
	if not sessionPanel or not sessionScrollFrame then
		return
	end
	PvE.RefreshCurrentDungeonSnapshot()
	local snapshot = PvE.GetCurrentDungeonSnapshot()
	local entries = snapshot and snapshot.rows or {}
	if snapshot then
		sessionSummaryInstance.value:SetText(tostring(snapshot.instanceName or "Dungeon"))
		sessionSummaryCombat.value:SetText(FormatCombatTime(snapshot.activeTime))
		if snapshot.averageRating then
			sessionSummaryRating.value:SetText(PvE.FormatRating(snapshot.averageRating) .. " / 10")
		else
			sessionSummaryRating.value:SetText("--")
		end
		if snapshot.active then
			sessionStatusText:SetText("LIVE TRACKING")
			sessionStatusText:SetTextColor(0.18, 0.90, 0.45)
		else
			sessionStatusText:SetText("LAST DUNGEON KEPT")
			sessionStatusText:SetTextColor(0.38, 0.72, 0.98)
		end
	else
		sessionSummaryInstance.value:SetText("None")
		sessionSummaryCombat.value:SetText("0:00")
		sessionSummaryRating.value:SetText("--")
		sessionStatusText:SetText("WAITING FOR A DUNGEON")
		sessionStatusText:SetTextColor(0.62, 0.65, 0.72)
	end

	FauxScrollFrame_Update(
		sessionScrollFrame,
		#entries,
		SESSION_VISIBLE_ROWS,
		SESSION_ROW_HEIGHT
	)
	local offset = FauxScrollFrame_GetOffset(sessionScrollFrame) or 0
	for index = 1, SESSION_VISIBLE_ROWS do
		local row = sessionRows[index]
		local entry = entries[offset + index]
		if entry then
			row.entry = entry
			if API and API.ApplySpecializationTexture then
				API.ApplySpecializationTexture(row.specIcon, entry, true)
			end
			if entry.role and API and API.ApplyRoleTexture then
				API.ApplyRoleTexture(row.roleIcon, entry.role)
				row.roleIcon:Show()
			else
				row.roleIcon:Hide()
			end
			local color = RAID_CLASS_COLORS[entry.classToken]
				or { r = 0.86, g = 0.86, b = 0.86 }
			row.nameText:SetText(tostring(entry.name or "Unknown player"))
			row.nameText:SetTextColor(color.r or 1, color.g or 1, color.b or 1)
			local className = API and API.GetClassDisplayName
				and API.GetClassDisplayName(entry.classToken) or entry.classToken
			row.specText:SetText(
				tostring(className or "Unknown class")
					.. " - " .. tostring(entry.specialization or "Unknown specialization")
			)
			row.roleText:SetText(SESSION_ROLE_LABELS[entry.role] or "Unknown")
			row.dpsText:SetText(FormatCompactNumber(entry.dps))
			row.hpsText:SetText(FormatCompactNumber(entry.hps))
			row.deathsText:SetText(tostring(math.floor(SafeNumber(entry.deaths))))
			row.scoreText:SetText(entry.score and string.format("%.0f", entry.score) or "--")
			if entry.rating then
				row.ratingText:SetText(PvE.FormatRating(entry.rating))
				local ratingR, ratingG, ratingB = GetRatingColor(entry.rating)
				row.ratingText:SetTextColor(ratingR, ratingG, ratingB)
				row.progress:SetVertexColor(
					ratingR,
					ratingG,
					ratingB,
					SESSION_PROGRESS_ALPHA
				)
				local width = math.max(1, row:GetWidth() or 1)
				row.progress:SetWidth(math.max(1, math.floor(width * entry.rating / 10)))
			else
				row.ratingText:SetText("--")
				row.ratingText:SetTextColor(0.58, 0.62, 0.70)
				row.progress:SetWidth(1)
			end
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end
	if #entries == 0 then
		sessionNoDataText:Show()
	else
		sessionNoDataText:Hide()
	end
	local pace = snapshot and snapshot.pace
	local interruptInfo = snapshot and snapshot.interrupts
	if pace then
		local paceText = string.format(
			"Pace: %d pull%s | %.0f%% of the run in combat | %s downtime",
			math.floor(SafeNumber(pace.pullCount)),
			math.floor(SafeNumber(pace.pullCount)) == 1 and "" or "s",
			SafeNumber(pace.efficiency) * 100,
			FormatCombatTime(pace.downtimeSeconds)
		)
		if interruptInfo
			and (SafeNumber(interruptInfo.interrupted)
				+ SafeNumber(interruptInfo.completed)) > 0
		then
			paceText = paceText .. string.format(
				" | %d/%d enemy casts interrupted",
				math.floor(SafeNumber(interruptInfo.interrupted)),
				math.floor(SafeNumber(interruptInfo.interrupted)
					+ SafeNumber(interruptInfo.completed))
			)
		end
		sessionPaceText:SetText(paceText)
	else
		sessionPaceText:SetText("")
	end
	sessionMethodologyText:SetText(
		"The rating compares each character against the expectations of their own role: 7/10 = expected performance, 10/10 = exceptional. "
			.. "The result stays visible after you leave and is only replaced at the start of the next dungeon."
	)
end

function PvE.CreateSessionPanel(parent)
	if sessionPanel then
		return sessionPanel
	end
	sessionPanel = CreateFrame("Frame", nil, parent)
	sessionPanel:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -88)
	sessionPanel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -18, 18)

	local title = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", sessionPanel, "TOPLEFT", 10, -15)
	title:SetText("Dungeon Performance")
	sessionStatusText = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sessionStatusText:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -10, -18)

	sessionSummaryInstance = CreateSummaryCard(sessionPanel, 8, "Dungeon tracked", 0.10, 0.72, 0.52)
	sessionSummaryInstance.value:SetWidth(180)
	sessionSummaryInstance.value:SetJustifyH("LEFT")
	sessionSummaryCombat = CreateSummaryCard(sessionPanel, 238, "Combat time", 0.30, 0.62, 0.95)
	sessionSummaryRating = CreateSummaryCard(sessionPanel, 468, "Group average rating", 0.68, 0.43, 0.95)

	local identityHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	identityHeader:SetPoint("TOPLEFT", sessionPanel, "TOPLEFT", 20, -133)
	identityHeader:SetText("CHARACTER / SPECIALIZATION")
	local roleHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	roleHeader:SetPoint("TOPLEFT", sessionPanel, "TOPLEFT", 304, -133)
	roleHeader:SetText("ROLE")
	local dpsHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	dpsHeader:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -277, -133)
	dpsHeader:SetText("DPS")
	local hpsHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hpsHeader:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -207, -133)
	hpsHeader:SetText("HPS")
	local deathsHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	deathsHeader:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -143, -133)
	deathsHeader:SetText("DEATHS")
	local scoreHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	scoreHeader:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -76, -133)
	scoreHeader:SetText("SCORE")
	local ratingHeader = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ratingHeader:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -10, -133)
	ratingHeader:SetText("RATING /10")

	sessionScrollFrame = CreateFrame(
		"ScrollFrame",
		"CoAAnalyticsPvESessionScrollFrame",
		sessionPanel,
		"FauxScrollFrameTemplate"
	)
	sessionScrollFrame:SetPoint("TOPLEFT", sessionPanel, "TOPLEFT", 8, -149)
	sessionScrollFrame:SetPoint("BOTTOMRIGHT", sessionPanel, "BOTTOMRIGHT", -24, 52)
	sessionScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(
			self,
			offset,
			SESSION_ROW_HEIGHT,
			PvE.RefreshSessionPanel
		)
	end)
	for index = 1, SESSION_VISIBLE_ROWS do
		sessionRows[index] = CreateSessionRow(sessionPanel, index)
	end

	sessionNoDataText = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	sessionNoDataText:SetPoint("CENTER", sessionPanel, "CENTER", 0, -35)
	sessionNoDataText:SetText(
		"No dungeon recorded yet.\n"
			.. "Tracking starts automatically when you enter the next dungeon."
	)
	sessionPaceText = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sessionPaceText:SetPoint("TOPLEFT", sessionPanel, "TOPLEFT", 20, -119)
	sessionPaceText:SetPoint("TOPRIGHT", sessionPanel, "TOPRIGHT", -12, -119)
	sessionPaceText:SetJustifyH("LEFT")
	sessionPaceText:SetTextColor(0.38, 0.72, 0.98)

	sessionMethodologyText = sessionPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	sessionMethodologyText:SetPoint("BOTTOMLEFT", sessionPanel, "BOTTOMLEFT", 12, 9)
	sessionMethodologyText:SetPoint("BOTTOMRIGHT", sessionPanel, "BOTTOMRIGHT", -12, 9)
	sessionMethodologyText:SetHeight(40)
	sessionMethodologyText:SetJustifyH("LEFT")
	sessionMethodologyText:SetJustifyV("BOTTOM")
	sessionMethodologyText:SetWordWrap(true)

	sessionPanel:Hide()
	PvE.RefreshSessionPanel()
	return sessionPanel
end

function PvE.IsRankingPanelShown()
	return panel and panel:IsShown() or false
end

function PvE.IsSessionPanelShown()
	return sessionPanel and sessionPanel:IsShown() or false
end

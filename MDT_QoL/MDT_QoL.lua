local addonName = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

local UPDATE_INTERVAL_SECONDS = 0.1
local FONT_SIZE = 16
local HOOK_RETRY_DELAY_SECONDS = 0.25
local HOOK_RETRY_MAX_ATTEMPTS = 40
local LABEL_HORIZONTAL_PADDING = 7
local LABEL_VERTICAL_PADDING = 4
local LABEL_ROUNDED_CAP_WIDTH = math.floor((FONT_SIZE + (2 * LABEL_VERTICAL_PADDING)) / 2)
local LABEL_Y_OFFSET = -4
local LABEL_BACKGROUND_ALPHA = 0.55
local ROUNDED_CAP_TEXTURE = "Interface\\AddOns\\MythicDungeonTools\\Textures\\Circle_White"
local SEARCH_BOX_WIDTH = 320
local SEARCH_BOX_HEIGHT = 20
local SEARCH_RESULT_ROW_HEIGHT = 18
local SEARCH_RESULT_MAX_ROWS = 8
local SEARCH_RIGHT_OFFSET = -70
local SEARCH_PLACEHOLDER_TEXT = "Search spell, ID, or enemy"
local SEARCH_CLICK_HINT_TEXT = "Click result to open Enemy Info"
local SEARCH_TITLE_TEXT = "Spell Search"
local SEARCH_NO_RESULTS_TEXT = "No matches"

local ENEMY_INFO_MOUSE_BUTTON = "RightButton" -- Ctrl + RightClick

local FONT_CANDIDATES = {
  "Interface\\AddOns\\MDT_QoL\\Fonts\\PTSansNarrow.ttf",
  "Interface\\AddOns\\MDT_QoL\\Fonts\\PTSansNarrow-Regular.ttf",
  "Interface\\AddOns\\MDT_QoL\\Fonts\\PTSansNarrowBold.ttf",
  "Interface\\AddOns\\SharedMedia\\fonts\\PTSansNarrow.ttf",
  "Fonts\\FRIZQT__.TTF",
}

local state = {
  enabled = false,
  elapsed = 0,
  labelsByPull = {},
  fallbackAnchorsByPull = {},
  enemyInfoHooked = false,
  rightButtonDown = false,
  suppressEnemyInfoCloseUntilRightButtonRelease = false,
  spellSearchUI = nil,
  spellSearchRows = {},
  spellSearchResultEntries = nil,
  spellSearchIndexByDungeon = {},
  spellSearchLastDungeonIdx = nil,
}

local function applyPercentFont(fontString)
  for _, fontPath in ipairs(FONT_CANDIDATES) do
    local ok, applied = pcall(fontString.SetFont, fontString, fontPath, FONT_SIZE, "OUTLINE")
    if ok and applied then
      return
    end
  end

  -- Fallback for client/font-path changes in new patches.
  local fallbackFontObject = GameFontNormalSmall or GameFontNormal or SystemFont_Shadow_Med1
  if fallbackFontObject then
    pcall(fontString.SetFontObject, fontString, fallbackFontObject)
  end
end

local function trimText(value)
  if type(value) ~= "string" then
    return ""
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeText(value)
  return string.lower(trimText(value))
end

local function getLocalizedEnemyName(mdt, enemyData)
  if not enemyData then
    return "Unknown enemy"
  end
  local enemyName = enemyData.name
  if mdt and mdt.L and enemyName and mdt.L[enemyName] then
    return mdt.L[enemyName]
  end
  return enemyName or "Unknown enemy"
end

local function getSpellNameById(spellId)
  if C_Spell and type(C_Spell.GetSpellName) == "function" then
    local name = C_Spell.GetSpellName(spellId)
    if name and name ~= "" then
      return name
    end
  end
  if type(GetSpellInfo) == "function" then
    local name = GetSpellInfo(spellId)
    if name and name ~= "" then
      return name
    end
  end
  return string.format("Spell #%d", spellId)
end

local function getSpellSearchDungeonIdx(mdt)
  local db = mdt and mdt.GetDB and mdt:GetDB()
  return db and db.currentDungeonIdx or nil
end

local function buildSpellSearchIndexForDungeon(mdt, dungeonIdx)
  if not mdt or not dungeonIdx then
    return {}
  end

  local enemies = mdt.dungeonEnemies and mdt.dungeonEnemies[dungeonIdx]
  if type(enemies) ~= "table" then
    return {}
  end

  local entries = {}
  local seen = {}

  local function addSpells(enemyIdx, enemyData, spellsTable, sourceLabel)
    if type(spellsTable) ~= "table" then
      return
    end

    for spellId in pairs(spellsTable) do
      local numericSpellId = tonumber(spellId)
      local numericEnemyIdx = tonumber(enemyIdx)
      if numericSpellId and numericEnemyIdx then
        local uniqueKey = tostring(numericEnemyIdx) .. ":" .. tostring(numericSpellId)
        if not seen[uniqueKey] then
          local spellName = getSpellNameById(numericSpellId)
          local enemyName = getLocalizedEnemyName(mdt, enemyData)
          entries[#entries + 1] = {
            spellId = numericSpellId,
            spellName = spellName,
            spellNameNormalized = normalizeText(spellName),
            enemyIdx = numericEnemyIdx,
            enemyName = enemyName,
            enemyNameNormalized = normalizeText(enemyName),
            sourceLabel = sourceLabel,
          }
          seen[uniqueKey] = true
        end
      end
    end
  end

  for enemyIdx, enemyData in pairs(enemies) do
    addSpells(enemyIdx, enemyData, enemyData and enemyData.spells, "spell")
    addSpells(enemyIdx, enemyData, enemyData and enemyData.powers, "power")
  end

  table.sort(entries, function(left, right)
    if left.spellNameNormalized ~= right.spellNameNormalized then
      return left.spellNameNormalized < right.spellNameNormalized
    end
    if left.enemyNameNormalized ~= right.enemyNameNormalized then
      return left.enemyNameNormalized < right.enemyNameNormalized
    end
    if left.spellId ~= right.spellId then
      return left.spellId < right.spellId
    end
    return left.enemyIdx < right.enemyIdx
  end)

  return entries
end

local function getSpellSearchIndex(mdt)
  local dungeonIdx = getSpellSearchDungeonIdx(mdt)
  if not dungeonIdx then
    return nil
  end

  local index = state.spellSearchIndexByDungeon[dungeonIdx]
  if index then
    return index
  end

  index = buildSpellSearchIndexForDungeon(mdt, dungeonIdx)
  state.spellSearchIndexByDungeon[dungeonIdx] = index
  return index
end

local function clearSpellSearchRows()
  for _, row in ipairs(state.spellSearchRows) do
    row.entry = nil
    row:Hide()
  end
end

local function hideSpellSearchResults()
  local ui = state.spellSearchUI
  if not ui then
    return
  end

  ui.title:SetText(SEARCH_TITLE_TEXT)
  clearSpellSearchRows()
  ui.results:Hide()
  state.spellSearchResultEntries = nil
end

local function openEnemyInfoForEnemyIdx(enemyIdx)
  local mdt = _G.MDT
  if not mdt or type(mdt.ShowEnemyInfoFrame) ~= "function" then
    return
  end
  mdt:ShowEnemyInfoFrame({ enemyIdx = enemyIdx })
end

local function updateSpellSearchResults()
  local ui = state.spellSearchUI
  if not ui then
    return
  end

  local mdt = _G.MDT
  if not mdt then
    hideSpellSearchResults()
    return
  end

  local query = trimText(ui.editBox:GetText() or "")
  if query == "" then
    hideSpellSearchResults()
    return
  end

  local searchText = string.lower(query)
  local queryIsNumber = tonumber(searchText) ~= nil
  local index = getSpellSearchIndex(mdt) or {}
  local matches = {}

  for _, entry in ipairs(index) do
    local nameMatch = entry.spellNameNormalized:find(searchText, 1, true) ~= nil
    local enemyMatch = entry.enemyNameNormalized:find(searchText, 1, true) ~= nil
    local idMatch = queryIsNumber and tostring(entry.spellId):find(searchText, 1, true) ~= nil
    if nameMatch or enemyMatch or idMatch then
      matches[#matches + 1] = entry
    end
  end

  state.spellSearchResultEntries = matches
  clearSpellSearchRows()

  if #matches == 0 then
    ui.title:SetText(SEARCH_NO_RESULTS_TEXT)
    ui.results:SetHeight(30)
    ui.results:Show()
    return
  end

  local visibleCount = math.min(#matches, SEARCH_RESULT_MAX_ROWS)
  if #matches > visibleCount then
    ui.title:SetText(string.format("%s (%d, showing %d)", SEARCH_TITLE_TEXT, #matches, visibleCount))
  else
    ui.title:SetText(string.format("%s (%d)", SEARCH_TITLE_TEXT, #matches))
  end

  for indexRow = 1, visibleCount do
    local row = state.spellSearchRows[indexRow]
    local entry = matches[indexRow]
    local sourcePrefix = entry.sourceLabel == "power" and "[Power] " or ""
    row.text:SetText(string.format("%s%s (%d) - %s", sourcePrefix, entry.spellName, entry.spellId, entry.enemyName))
    row.entry = entry
    row:Show()
  end

  local resultsHeight = 26 + (visibleCount * SEARCH_RESULT_ROW_HEIGHT)
  ui.results:SetHeight(resultsHeight)
  ui.results:Show()
end

local function refreshSpellSearchForDungeonChange()
  local ui = state.spellSearchUI
  local mdt = _G.MDT
  if not ui or not mdt then
    return
  end

  local currentDungeonIdx = getSpellSearchDungeonIdx(mdt)
  if state.spellSearchLastDungeonIdx == currentDungeonIdx then
    return
  end
  state.spellSearchLastDungeonIdx = currentDungeonIdx

  if trimText(ui.editBox:GetText() or "") ~= "" then
    updateSpellSearchResults()
  else
    hideSpellSearchResults()
  end
end

local function installSpellSearchUI()
  if state.spellSearchUI then
    return true
  end

  local mdt = _G.MDT
  local mainFrame = mdt and mdt.main_frame
  local topPanel = mainFrame and mainFrame.topPanel
  if not topPanel then
    return false
  end

  local searchContainer = CreateFrame("Frame", nil, topPanel)
  searchContainer:SetSize(SEARCH_BOX_WIDTH, SEARCH_BOX_HEIGHT + 4)
  searchContainer:SetPoint("RIGHT", topPanel, "RIGHT", SEARCH_RIGHT_OFFSET, 0)
  searchContainer:SetFrameStrata("HIGH")
  searchContainer:SetFrameLevel(topPanel:GetFrameLevel() + 30)
  local searchBackground = searchContainer:CreateTexture(nil, "BACKGROUND", nil, -1)
  searchBackground:SetAllPoints()
  searchBackground:SetColorTexture(0, 0, 0, 0.35)

  local editBox = CreateFrame("EditBox", nil, searchContainer, "InputBoxTemplate")
  editBox:SetAutoFocus(false)
  editBox:SetSize(SEARCH_BOX_WIDTH - 18, SEARCH_BOX_HEIGHT)
  editBox:SetPoint("CENTER", searchContainer, "CENTER", 0, -1)
  editBox:SetTextInsets(2, 2, 0, 0)
  editBox:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
    updateSpellSearchResults()
  end)
  editBox:SetScript("OnEnterPressed", function(self)
    local entries = state.spellSearchResultEntries
    if entries and entries[1] then
      openEnemyInfoForEnemyIdx(entries[1].enemyIdx)
      self:ClearFocus()
    end
  end)

  local placeholder = searchContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  placeholder:SetJustifyH("LEFT")
  placeholder:SetPoint("LEFT", editBox, "LEFT", 6, 0)
  placeholder:SetText(SEARCH_PLACEHOLDER_TEXT)

  local hintText = searchContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hintText:SetPoint("TOPRIGHT", searchContainer, "BOTTOMRIGHT", 0, -2)
  hintText:SetText(SEARCH_CLICK_HINT_TEXT)

  local resultsFrame = CreateFrame("Frame", nil, mainFrame)
  resultsFrame:SetWidth(SEARCH_BOX_WIDTH)
  resultsFrame:SetPoint("TOPRIGHT", searchContainer, "BOTTOMRIGHT", 0, -16)
  resultsFrame:SetFrameStrata("HIGH")
  resultsFrame:SetFrameLevel(searchContainer:GetFrameLevel() + 1)
  local resultsBackground = resultsFrame:CreateTexture(nil, "BACKGROUND", nil, -1)
  resultsBackground:SetAllPoints()
  resultsBackground:SetColorTexture(0, 0, 0, 0.8)
  resultsFrame:Hide()

  local title = resultsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 6, -6)
  title:SetPoint("TOPRIGHT", resultsFrame, "TOPRIGHT", -6, -6)
  title:SetJustifyH("LEFT")
  title:SetText(SEARCH_TITLE_TEXT)

  for rowIndex = 1, SEARCH_RESULT_MAX_ROWS do
    local row = CreateFrame("Button", nil, resultsFrame)
    row:SetPoint("TOPLEFT", resultsFrame, "TOPLEFT", 6, -8 - (rowIndex * SEARCH_RESULT_ROW_HEIGHT))
    row:SetPoint("TOPRIGHT", resultsFrame, "TOPRIGHT", -6, -8 - (rowIndex * SEARCH_RESULT_ROW_HEIGHT))
    row:SetHeight(SEARCH_RESULT_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function(self)
      if self.entry then
        openEnemyInfoForEnemyIdx(self.entry.enemyIdx)
      end
    end)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.12)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row:Hide()

    state.spellSearchRows[rowIndex] = row
  end

  editBox:SetScript("OnTextChanged", function(self)
    local currentText = trimText(self:GetText() or "")
    placeholder:SetShown(currentText == "")
    updateSpellSearchResults()
  end)

  state.spellSearchUI = {
    container = searchContainer,
    editBox = editBox,
    placeholder = placeholder,
    results = resultsFrame,
    title = title,
  }

  return true
end

local function shouldOpenEnemyInfo(button)
  return IsControlKeyDown() and button == ENEMY_INFO_MOUSE_BUTTON
end

local function shouldCloseEnemyInfo(buttonDown, wasButtonDown)
  if not (IsControlKeyDown() and buttonDown and not wasButtonDown) then
    return false
  end

  local mdt = _G.MDT
  local enemyInfoFrame = mdt and mdt.EnemyInfoFrame
  local enemyInfoWidgetFrame = enemyInfoFrame and enemyInfoFrame.frame
  if not (enemyInfoWidgetFrame and enemyInfoWidgetFrame:IsShown()) then
    return false
  end

  return MouseIsOver(enemyInfoWidgetFrame)
end

local function handleEnemyInfoCloseHotkey()
  if type(IsMouseButtonDown) ~= "function" then
    return
  end

  local buttonDown = IsMouseButtonDown(ENEMY_INFO_MOUSE_BUTTON)
  local wasButtonDown = state.rightButtonDown
  state.rightButtonDown = buttonDown

  if state.suppressEnemyInfoCloseUntilRightButtonRelease then
    if not buttonDown then
      state.suppressEnemyInfoCloseUntilRightButtonRelease = false
    end
    return
  end

  if not shouldCloseEnemyInfo(buttonDown, wasButtonDown) then
    return
  end

  local enemyInfoFrame = _G.MDT and _G.MDT.EnemyInfoFrame
  if enemyInfoFrame and type(enemyInfoFrame.Hide) == "function" then
    enemyInfoFrame:Hide()
  end
end

local function installEnemyInfoHook()
  if state.enemyInfoHooked then
    return true
  end

  local mixin = _G.MDTDungeonEnemyMixin
  if not mixin or type(mixin.OnClick) ~= "function" then
    return false
  end

  local originalOnClick = mixin.OnClick
  mixin.OnClick = function(self, button, down)
    local mdt = _G.MDT
    if mdt and shouldOpenEnemyInfo(button) then
      local db = mdt.GetDB and mdt:GetDB()
      if not (db and db.devMode) and type(mdt.ShowEnemyInfoFrame) == "function" then
        state.suppressEnemyInfoCloseUntilRightButtonRelease = true
        mdt:ShowEnemyInfoFrame(self)
        return
      end
    end

    return originalOnClick(self, button, down)
  end

  state.enemyInfoHooked = true
  return true
end

local function scheduleEnemyInfoHook(attempt)
  if installEnemyInfoHook() then
    return
  end
  if attempt >= HOOK_RETRY_MAX_ATTEMPTS then
    return
  end
  C_Timer.After(HOOK_RETRY_DELAY_SECONDS, function()
    scheduleEnemyInfoHook(attempt + 1)
  end)
end

local function hideAllLabels()
  for _, entry in pairs(state.labelsByPull) do
    entry.label:Hide()
    entry.backgroundCenter:Hide()
    entry.backgroundLeftCap:Hide()
    entry.backgroundRightCap:Hide()
  end
  for _, anchor in pairs(state.fallbackAnchorsByPull) do
    anchor:Hide()
  end
end

local function getSidebarPullProgressTexts(mdt)
  local result = {}

  local mainFrame = mdt and mdt.main_frame
  local sidePanel = mainFrame and mainFrame.sidePanel
  local pullButtons = sidePanel and sidePanel.newPullButtons
  if type(pullButtons) ~= "table" then
    return result
  end

  for rawPullIdx, pullButton in pairs(pullButtons) do
    local pullIdx = tonumber(rawPullIdx) or tonumber(pullButton and pullButton.index)
    if pullIdx then
      if type(pullButton.UpdateCountText) == "function" then
        pcall(pullButton.UpdateCountText, pullButton)
      end

      local progressFontString = pullButton.percentageFontString
      if progressFontString and type(progressFontString.GetText) == "function" then
        local text = trimText(progressFontString:GetText() or "")
        if text ~= "" then
          result[pullIdx] = text
        end
      end
    end
  end

  return result
end

local function getPullPercentText(mdt, pullIdx, sidebarProgressByPull)
  pullIdx = tonumber(pullIdx)
  if not pullIdx then
    return nil
  end

  -- Primary source: exact progress text shown by original MDT pull buttons in the right sidebar.
  local sidebarText = sidebarProgressByPull and sidebarProgressByPull[pullIdx]
  if sidebarText then
    return sidebarText
  end

  -- Fallback for early-load moments when sidebar widgets are not ready yet.
  local db = mdt.GetDB and mdt:GetDB()
  if not db or not db.currentDungeonIdx then
    return nil
  end

  local dungeonData = mdt.dungeonTotalCount and mdt.dungeonTotalCount[db.currentDungeonIdx]
  local totalForcesMax = dungeonData and dungeonData.normal
  if not totalForcesMax or totalForcesMax <= 0 then
    return nil
  end

  local pullForces = mdt:CountForces(pullIdx, true)
  if not pullForces or pullForces <= 0 then
    return nil
  end

  local cumulativeForces = mdt:CountForces(pullIdx)
  local cumulativePercent = (cumulativeForces / totalForcesMax) * 100
  return string.format("%.2f%%", cumulativePercent)
end

local function ensureLabel(anchorFrame, pullIdx)
  local entry = state.labelsByPull[pullIdx]
  if not entry then
    local backgroundCenter = anchorFrame:CreateTexture(nil, "OVERLAY", nil, -1)
    backgroundCenter:SetColorTexture(0, 0, 0, LABEL_BACKGROUND_ALPHA)

    local backgroundLeftCap = anchorFrame:CreateTexture(nil, "OVERLAY", nil, -1)
    backgroundLeftCap:SetTexture(ROUNDED_CAP_TEXTURE)
    backgroundLeftCap:SetVertexColor(0, 0, 0, LABEL_BACKGROUND_ALPHA)
    backgroundLeftCap:SetTexCoord(0, 0.5, 0, 1)

    local backgroundRightCap = anchorFrame:CreateTexture(nil, "OVERLAY", nil, -1)
    backgroundRightCap:SetTexture(ROUNDED_CAP_TEXTURE)
    backgroundRightCap:SetVertexColor(0, 0, 0, LABEL_BACKGROUND_ALPHA)
    backgroundRightCap:SetTexCoord(0.5, 1, 0, 1)

    local label = anchorFrame:CreateFontString(nil, "OVERLAY", nil)
    applyPercentFont(label)
    label:SetTextColor(1, 1, 1, 1)
    label:SetShadowColor(0, 0, 0, 1)
    label:SetShadowOffset(1, -1)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("MIDDLE")

    backgroundCenter:SetPoint("TOPLEFT", label, "TOPLEFT", -LABEL_HORIZONTAL_PADDING + LABEL_ROUNDED_CAP_WIDTH,
      LABEL_VERTICAL_PADDING)
    backgroundCenter:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", LABEL_HORIZONTAL_PADDING - LABEL_ROUNDED_CAP_WIDTH,
      -LABEL_VERTICAL_PADDING)
    backgroundLeftCap:SetPoint("TOPLEFT", label, "TOPLEFT", -LABEL_HORIZONTAL_PADDING, LABEL_VERTICAL_PADDING)
    backgroundLeftCap:SetPoint("BOTTOMRIGHT", backgroundCenter, "BOTTOMLEFT", 0, 0)
    backgroundRightCap:SetPoint("TOPLEFT", backgroundCenter, "TOPRIGHT", 0, 0)
    backgroundRightCap:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", LABEL_HORIZONTAL_PADDING, -LABEL_VERTICAL_PADDING)

    entry = {
      label = label,
      backgroundCenter = backgroundCenter,
      backgroundLeftCap = backgroundLeftCap,
      backgroundRightCap = backgroundRightCap,
    }
    state.labelsByPull[pullIdx] = entry
  end

  if entry.label:GetParent() ~= anchorFrame then
    entry.label:SetParent(anchorFrame)
    entry.backgroundCenter:SetParent(anchorFrame)
    entry.backgroundLeftCap:SetParent(anchorFrame)
    entry.backgroundRightCap:SetParent(anchorFrame)
  end

  entry.label:ClearAllPoints()
  entry.label:SetPoint("TOP", anchorFrame.fs or anchorFrame, "BOTTOM", 0, LABEL_Y_OFFSET)
  return entry
end

local function shouldShowOverlay(mdt)
  if not IsControlKeyDown() then
    return false
  end
  if not mdt or not mdt.main_frame or not mdt.main_frame:IsShown() then
    return false
  end

  local mapPanelFrame = mdt.main_frame.mapPanelFrame or _G.MDTMapPanelFrame
  return mapPanelFrame and mapPanelFrame:IsShown()
end

local function ensureFallbackAnchor(mdt, pullIdx, centerX, centerY)
  local mainFrame = mdt and mdt.main_frame
  local mapPanelFrame = (mainFrame and mainFrame.mapPanelFrame) or _G.MDTMapPanelFrame
  if not mapPanelFrame then
    return nil
  end

  local anchor = state.fallbackAnchorsByPull[pullIdx]
  if not anchor then
    anchor = CreateFrame("Frame", nil, mapPanelFrame)
    anchor:SetSize(1, 1)
    anchor:SetFrameStrata("HIGH")
    anchor:SetFrameLevel((mapPanelFrame:GetFrameLevel() or 1) + 30)
    state.fallbackAnchorsByPull[pullIdx] = anchor
  end

  if anchor:GetParent() ~= mapPanelFrame then
    anchor:SetParent(mapPanelFrame)
  end

  anchor:ClearAllPoints()
  local anchorParent = (mainFrame and mainFrame.mapPanelTile1) or _G.MDTmapPanelTile1 or mapPanelFrame
  anchor:SetPoint("CENTER", anchorParent, "TOPLEFT", centerX, centerY)
  anchor:Show()
  return anchor
end

local function collectPullCentersFromVisibleBlips(mdt)
  local centersByPull = {}
  local getCurrentPreset = mdt and mdt.GetCurrentPreset
  local preset = getCurrentPreset and mdt:GetCurrentPreset()
  local pulls = preset and preset.value and preset.value.pulls
  if type(pulls) ~= "table" then
    return centersByPull
  end

  local getDungeonEnemyBlips = mdt and mdt.GetDungeonEnemyBlips
  local blips = getDungeonEnemyBlips and mdt:GetDungeonEnemyBlips()
  if type(blips) ~= "table" then
    return centersByPull
  end

  local blipByEnemyClone = {}
  for _, blip in pairs(blips) do
    local enemyIdx = blip and tonumber(blip.enemyIdx)
    local cloneIdx = blip and tonumber(blip.cloneIdx)
    if enemyIdx and cloneIdx then
      blipByEnemyClone[enemyIdx .. ":" .. cloneIdx] = blip
    end
  end

  for rawPullIdx, pull in pairs(pulls) do
    local pullIdx = tonumber(rawPullIdx)
    if pullIdx and type(pull) == "table" then
      local totalX = 0
      local totalY = 0
      local count = 0

      for rawEnemyIdx, clones in pairs(pull) do
        local enemyIdx = tonumber(rawEnemyIdx)
        if enemyIdx and type(clones) == "table" then
          for _, rawCloneIdx in pairs(clones) do
            local cloneIdx = tonumber(rawCloneIdx)
            if cloneIdx then
              local included = true
              if type(mdt.IsCloneIncluded) == "function" then
                included = mdt:IsCloneIncluded(enemyIdx, cloneIdx)
              end

              if included then
                local blip = blipByEnemyClone[enemyIdx .. ":" .. cloneIdx]
                if blip then
                  local _, _, _, x, y = blip:GetPoint()
                  if x and y then
                    totalX = totalX + x
                    totalY = totalY + y
                    count = count + 1
                  end
                end
              end
            end
          end
        end
      end

      if count > 0 then
        centersByPull[pullIdx] = {
          x = totalX / count,
          y = totalY / count,
        }
      end
    end
  end

  return centersByPull
end

local function collectPullCentersFromPresetData(mdt)
  local centersByPull = {}
  local db = mdt and mdt.GetDB and mdt:GetDB()
  local currentDungeonIdx = db and db.currentDungeonIdx
  if not currentDungeonIdx then
    return centersByPull
  end

  local dungeonEnemies = mdt.dungeonEnemies and mdt.dungeonEnemies[currentDungeonIdx]
  if type(dungeonEnemies) ~= "table" then
    return centersByPull
  end

  local preset = mdt.GetCurrentPreset and mdt:GetCurrentPreset()
  local pulls = preset and preset.value and preset.value.pulls
  if type(pulls) ~= "table" then
    return centersByPull
  end

  local currentSubLevel = nil
  if type(mdt.GetCurrentSubLevel) == "function" then
    currentSubLevel = tonumber(mdt:GetCurrentSubLevel())
  end

  for rawPullIdx, pull in pairs(pulls) do
    local pullIdx = tonumber(rawPullIdx)
    if pullIdx and type(pull) == "table" then
      local totalX = 0
      local totalY = 0
      local count = 0

      for rawEnemyIdx, clones in pairs(pull) do
        local enemyIdx = tonumber(rawEnemyIdx)
        local enemyData = enemyIdx and dungeonEnemies[enemyIdx]
        local enemyClones = enemyData and enemyData.clones
        if enemyIdx and type(clones) == "table" and type(enemyClones) == "table" then
          for _, rawCloneIdx in pairs(clones) do
            local cloneIdx = tonumber(rawCloneIdx)
            local cloneData = cloneIdx and enemyClones[cloneIdx]
            if cloneIdx and cloneData then
              local included = true
              if type(mdt.IsCloneIncluded) == "function" then
                included = mdt:IsCloneIncluded(enemyIdx, cloneIdx)
              end

              local cloneSubLevel = tonumber(cloneData.sublevel)
              local onCurrentSubLevel = (not currentSubLevel) or (not cloneSubLevel) or (cloneSubLevel == currentSubLevel)
              if included and onCurrentSubLevel and cloneData.x and cloneData.y then
                totalX = totalX + cloneData.x
                totalY = totalY + cloneData.y
                count = count + 1
              end
            end
          end
        end
      end

      if count > 0 then
        centersByPull[pullIdx] = {
          x = totalX / count,
          y = totalY / count,
        }
      end
    end
  end

  return centersByPull
end

local function getCurrentPresetPullIndexes(mdt)
  local result = {}
  local preset = mdt and mdt.GetCurrentPreset and mdt:GetCurrentPreset()
  local pulls = preset and preset.value and preset.value.pulls
  if type(pulls) ~= "table" then
    return result
  end

  for rawPullIdx in pairs(pulls) do
    local pullIdx = tonumber(rawPullIdx)
    if pullIdx then
      result[#result + 1] = pullIdx
    end
  end

  table.sort(result)
  return result
end

local function refreshOverlay()
  local mdt = _G.MDT
  if not shouldShowOverlay(mdt) then
    hideAllLabels()
    return
  end

  local mainFrame = mdt.main_frame
  local mapPanelFrame = (mainFrame and mainFrame.mapPanelFrame) or _G.MDTMapPanelFrame
  if not mapPanelFrame then
    hideAllLabels()
    return
  end

  local sidebarProgressByPull = getSidebarPullProgressTexts(mdt)
  local directAnchorsByPull = {}
  local seen = {}
  local pullCentersByPull = nil
  local presetDataCentersByPull = nil

  for _, child in ipairs({ mapPanelFrame:GetChildren() }) do
    local pullIdx = tonumber(child.pullIdx)
    if pullIdx and child:IsShown() and child.fs then
      directAnchorsByPull[pullIdx] = child
    end
  end

  for pullIdx, text in pairs(sidebarProgressByPull) do
    local anchor = directAnchorsByPull[pullIdx]
    if not anchor then
      pullCentersByPull = pullCentersByPull or collectPullCentersFromVisibleBlips(mdt)
      presetDataCentersByPull = presetDataCentersByPull or collectPullCentersFromPresetData(mdt)
      for idx, center in pairs(presetDataCentersByPull) do
        if not pullCentersByPull[idx] then
          pullCentersByPull[idx] = center
        end
      end
      local center = pullCentersByPull[pullIdx]
      if center then
        anchor = ensureFallbackAnchor(mdt, pullIdx, center.x, center.y)
      end
    end

    if anchor then
      local entry = ensureLabel(anchor, pullIdx)
      entry.label:SetText(text)
      entry.backgroundCenter:Show()
      entry.backgroundLeftCap:Show()
      entry.backgroundRightCap:Show()
      entry.label:Show()
      seen[pullIdx] = true
    end
  end

  -- Fallback path for early-load moments when right sidebar widgets are not ready yet.
  if not next(seen) then
    for pullIdx, anchor in pairs(directAnchorsByPull) do
      local text = getPullPercentText(mdt, pullIdx, sidebarProgressByPull)
      if text then
        local entry = ensureLabel(anchor, pullIdx)
        entry.label:SetText(text)
        entry.backgroundCenter:Show()
        entry.backgroundLeftCap:Show()
        entry.backgroundRightCap:Show()
        entry.label:Show()
        seen[pullIdx] = true
      end
    end
  end

  -- Last-resort fallback: render by preset pulls + blip centers even when direct pull label anchors are unavailable.
  if not next(seen) then
    pullCentersByPull = pullCentersByPull or collectPullCentersFromVisibleBlips(mdt)
    presetDataCentersByPull = presetDataCentersByPull or collectPullCentersFromPresetData(mdt)
    for idx, center in pairs(presetDataCentersByPull) do
      if not pullCentersByPull[idx] then
        pullCentersByPull[idx] = center
      end
    end
    local presetPullIndexes = getCurrentPresetPullIndexes(mdt)
    for _, pullIdx in ipairs(presetPullIndexes) do
      local center = pullCentersByPull[pullIdx]
      if center then
        local text = getPullPercentText(mdt, pullIdx, sidebarProgressByPull)
        if text then
          local anchor = ensureFallbackAnchor(mdt, pullIdx, center.x, center.y)
          if anchor then
            local entry = ensureLabel(anchor, pullIdx)
            entry.label:SetText(text)
            entry.backgroundCenter:Show()
            entry.backgroundLeftCap:Show()
            entry.backgroundRightCap:Show()
            entry.label:Show()
            seen[pullIdx] = true
          end
        end
      end
    end
  end

  for pullIdx, entry in pairs(state.labelsByPull) do
    if not seen[pullIdx] then
      entry.label:Hide()
      entry.backgroundCenter:Hide()
      entry.backgroundLeftCap:Hide()
      entry.backgroundRightCap:Hide()
    end
  end

  for pullIdx, anchor in pairs(state.fallbackAnchorsByPull) do
    if not seen[pullIdx] then
      anchor:Hide()
    end
  end
end

local function onUpdate(_, elapsed)
  if not state.enabled then
    return
  end

  handleEnemyInfoCloseHotkey()

  state.elapsed = state.elapsed + elapsed
  if state.elapsed < UPDATE_INTERVAL_SECONDS then
    return
  end
  state.elapsed = 0

  installSpellSearchUI()
  refreshSpellSearchForDungeonChange()
  refreshOverlay()
end

local function onAddonLoaded(_, _, loadedAddonName)
  if loadedAddonName == addonName then
    state.enabled = true
    frame:SetScript("OnUpdate", onUpdate)
    scheduleEnemyInfoHook(1)
    return
  end

  if _G.MDT and not state.enemyInfoHooked then
    scheduleEnemyInfoHook(1)
  end
end

frame:SetScript("OnEvent", onAddonLoaded)

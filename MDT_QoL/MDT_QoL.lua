local addonName = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

local UPDATE_INTERVAL_SECONDS = 0.1
local FONT_SIZE = 12
local LABEL_HORIZONTAL_PADDING = 5
local LABEL_VERTICAL_PADDING = 3
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

-- Native action labels verified against MDT 6.2.15 Locales/*.lua.
local ENEMY_INFO_MENU_LABELS = {
  enUS = "Open Enemy Info", enGB = "Open Enemy Info",
  ruRU = "Открыть информацию о враге", deDE = "Gegnerinfo öffnen",
  frFR = "Informations sur l'ennemi ouvert", itIT = "Apri le informazioni sul nemico",
  esES = "Abrir información del enemigo", esMX = "Abrir información del enemigo",
  ptBR = "Abrir informações do inimigo", koKR = "몹 정보 열기",
  zhCN = "查看怪物信息", zhTW = "開啟敵方資訊",
}

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
  spellSearchUI = nil,
  spellSearchRows = {},
  spellSearchResultEntries = nil,
  spellSearchIndexByDungeon = {},
  spellSearchLastDungeonIdx = nil,
  mdt = nil,
  connection = "waiting",
  debug = false,
  hookedEnemyButtons = setmetatable({}, { __mode = "k" }),
  pendingSpells = {},
  spellSearchDirty = false,
  spellSearchSources = {},
  visibleEnemyData = {},
  visibleBlips = {},
  visibleDungeonIdx = nil,
  visibleSublevel = nil,
  menuHooked = false,
  menuRequest = nil,
  originalEnemyClicks = setmetatable({}, { __mode = "k" }),
  enemyInfoWidget = nil,
  lastEnemyInfoAction = "not used",
  suppressEnemyClickUntil = 0,
  closingEnemyInfoClick = false,
}

local function report(message)
  print("|cff33ff99MDT QoL:|r " .. message)
end

local function getMDT()
  return state.mdt or _G.MDT
end

-- MDT 6.2 keeps full dungeon data private. Read only data already attached to
-- its visible map pins; never modify MDT's files or access its private table.
local mapAdapter = { visibleMapOnly = true, dungeonEnemies = {} }
function mapAdapter:GetDB()
  local api = _G.MythicDungeonToolsAPI
  return api and api.GetDB and api:GetDB()
end
function mapAdapter:GetCurrentPreset()
  local db = self:GetDB()
  local idx = db and db.currentDungeonIdx
  local presets = db and db.presets and db.presets[idx]
  local selected = db and db.currentPreset and db.currentPreset[idx]
  return presets and presets[selected]
end
function mapAdapter:GetCurrentSubLevel()
  local preset = self:GetCurrentPreset()
  return preset and preset.value and preset.value.currentSublevel
end
function mapAdapter:GetDungeonEnemyBlips()
  return state.visibleBlips
end
function mapAdapter:IsMapSectionActive()
  local db = self:GetDB()
  return not db or not db.currentSection or db.currentSection == "maps"
end

local function resolveMDT()
  if type(_G.MDT) == "table" and type(_G.MDT.ShowEnemyInfoFrame) == "function" then
    state.mdt = _G.MDT
    state.connection = "legacy global"
    return
  end
  if _G.MythicDungeonToolsAPI then
    mapAdapter.main_frame = _G.MDTFrame
    state.mdt = mapAdapter
    state.connection = "public API + map"
    return
  end
  state.connection = "waiting for MDT"
end

local function refreshVisibleMapData()
  if getMDT() ~= mapAdapter then return end
  mapAdapter.main_frame = _G.MDTFrame
  local mainFrame = mapAdapter.main_frame
  local map = mainFrame and mainFrame.mapPanelFrame
  if not map or not mainFrame:IsShown() or not mapAdapter:IsMapSectionActive() then return end
  local db = mapAdapter:GetDB()
  local dungeonIdx = db and db.currentDungeonIdx
  if not dungeonIdx then return end
  local sublevel = mapAdapter:GetCurrentSubLevel()
  local enemies, blips = {}, {}
  local changed = state.visibleDungeonIdx ~= dungeonIdx or state.visibleSublevel ~= sublevel
  for _, child in ipairs({ map:GetChildren() }) do
    if child:IsShown() and type(child.enemyIdx) == "number" and type(child.cloneIdx) == "number"
      and type(child.data) == "table" and type(child.clone) == "table"
      and (not sublevel or not child.clone.sublevel or child.clone.sublevel == sublevel) then
      enemies[child.enemyIdx] = child.data
      blips[#blips + 1] = child
      if state.visibleEnemyData[child.enemyIdx] ~= child.data then changed = true end
    end
  end
  for idx in pairs(state.visibleEnemyData) do
    if not enemies[idx] then changed = true end
  end
  state.visibleBlips = blips
  if changed then
    mapAdapter.dungeonEnemies = { [dungeonIdx] = enemies }
    state.visibleEnemyData = enemies
    state.visibleDungeonIdx = dungeonIdx
    state.visibleSublevel = sublevel
    state.spellSearchIndexByDungeon = {}
    state.spellSearchSources = {}
    state.spellSearchDirty = true
    if state.debug then
      report(string.format("Map refreshed: dungeon %s, floor %s, %d enemy pins.",
        tostring(dungeonIdx), tostring(sublevel), #blips))
    end
  end
end

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

-- Explicit UTF-8 case folding for the cased alphabets used by WoW locales.
-- CJK characters pass unchanged. No client-dependent byte case conversion.
local lowercaseCharacters = {}
do
  local upper = "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓÔÕÖØÙÚÛÜÝÞŸŒẞ"
  local lower = "абвгдеёжзийклмнопрстуфхцчшщъыьэюяàáâãäåæçèéêëìíîïðñòóôõöøùúûüýþÿœß"
  local nextLower = lower:gmatch("[%z\1-\127\194-\244][\128-\191]*")
  for character in upper:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    lowercaseCharacters[character] = nextLower()
  end
end
local function normalizeText(value)
  local folded = trimText(value):gsub("[%z\1-\127\194-\244][\128-\191]*", lowercaseCharacters)
  return string.lower(folded)
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
  if C_Spell and type(C_Spell.RequestLoadSpellData) == "function" and state.pendingSpells[spellId] == nil then
    state.pendingSpells[spellId] = true
    C_Spell.RequestLoadSpellData(spellId)
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
            dungeonIdx = dungeonIdx,
            sublevel = mdt.GetCurrentSubLevel and mdt:GetCurrentSubLevel(),
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

  local enemies = mdt.dungeonEnemies and mdt.dungeonEnemies[dungeonIdx]
  if type(enemies) ~= "table" or not next(enemies) then return nil end
  local index = state.spellSearchSources[dungeonIdx] == enemies and state.spellSearchIndexByDungeon[dungeonIdx]
  if index then
    return index
  end

  index = buildSpellSearchIndexForDungeon(mdt, dungeonIdx)
  state.spellSearchIndexByDungeon[dungeonIdx] = index
  state.spellSearchSources[dungeonIdx] = enemies
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

local function getEnemyInfoWidget()
  local mdt = getMDT()
  if not mdt then return nil end
  if not mdt.visibleMapOnly then return mdt.EnemyInfoFrame end
  local mainFrame = mdt.main_frame
  if not mainFrame then return nil end
  local function isEnemyInfo(widget)
    return type(widget) == "table" and widget.type == "Frame" and widget.frame
      and widget.frame:GetParent() == mainFrame and widget.enemyDropDown and widget.enemyDataContainer
      and widget.tabGroup and widget.model and type(widget.Hide) == "function"
  end
  if isEnemyInfo(state.enemyInfoWidget) then return state.enemyInfoWidget end
  state.enemyInfoWidget = nil
  for _, child in ipairs({ mainFrame:GetChildren() }) do
    if isEnemyInfo(child.obj) then
      state.enemyInfoWidget = child.obj
      return child.obj
    end
  end
end

local function installMenuHook()
  if state.menuHooked then return true end
  if not (Menu and type(Menu.PopulateDescription) == "function" and type(hooksecurefunc) == "function") then
    return false
  end
  -- Observe only synchronous menu generation requested by this shortcut.
  -- Ordinary menus are untouched; descriptions are never cached.
  hooksecurefunc(Menu, "PopulateDescription", function(_, owner, description)
    local request = state.menuRequest
    if request and owner == request.owner and not request.description then
      request.description = description
    end
  end)
  state.menuHooked = true
  return true
end

local function openNativeEnemyInfo(blip, originalOnClick)
  local mdt = getMDT()
  local db = mdt and mdt:GetDB()
  if not mdt or (db and db.devMode) or state.menuRequest then return false end
  installMenuHook()
  local request = { owner = mdt.main_frame }
  state.menuRequest = request
  -- Run MDT's own handler, including its restricted-environment checks.
  local ok, message = pcall(originalOnClick, blip, "RightButton", false)
  state.menuRequest = nil
  if not ok then
    state.lastEnemyInfoAction = "MDT handler error"
    geterrorhandler()(message)
    return true
  end
  local root = request.description
  request.description = nil
  if root and type(root.EnumerateElementDescriptions) == "function"
    and MenuUtil and type(MenuUtil.GetElementText) == "function" and MenuInputContext then
    local locale = GAME_LOCALE or (GetLocale and GetLocale()) or "enUS"
    local label = ENEMY_INFO_MENU_LABELS[locale] or ENEMY_INFO_MENU_LABELS.enUS
    local match
    for _, element in root:EnumerateElementDescriptions() do
      local text = MenuUtil.GetElementText(element)
      if text == label or text == ENEMY_INFO_MENU_LABELS.enUS then
        if match then match = nil; break end
        match = element
      end
    end
    if match and type(match.Pick) == "function" then
      local pickedOK, picked = pcall(match.Pick, match, MenuInputContext.MouseButton, "LeftButton")
      if not pickedOK then
        state.lastEnemyInfoAction = "Enemy Info action error"
        geterrorhandler()(picked)
        return true
      end
      if picked then
        state.lastEnemyInfoAction = "opened through native menu"
        getEnemyInfoWidget()
        return true
      end
    end
  end
  state.lastEnemyInfoAction = "native menu fallback or MDT restriction"
  if state.debug then report("Enemy Info shortcut unavailable; use the native menu if shown.") end
  return true -- The original handler already ran: never execute it twice.
end

local function openEnemyInfoForEnemyIdx(enemyIdx, dungeonIdx, sublevel)
  local mdt = getMDT()
  if dungeonIdx and dungeonIdx ~= getSpellSearchDungeonIdx(mdt) then
    report("The dungeon changed. Search again.")
    return
  end
  if mdt and mdt.visibleMapOnly then
    if sublevel ~= mdt:GetCurrentSubLevel() then
      report("The floor changed. Search again.")
      return
    end
    local db = mdt:GetDB()
    -- A right click in dev mode edits NPCs; never simulate that action.
    if db and db.devMode then
      report("Enemy menu is unavailable while MDT developer mode is enabled.")
      return
    end
    refreshVisibleMapData()
    for _, blip in ipairs(state.visibleBlips) do
      if blip.enemyIdx == enemyIdx and type(blip.OnClick) == "function" then
        openNativeEnemyInfo(blip, state.originalEnemyClicks[blip.OnClick] or blip.OnClick)
        return
      end
    end
    report("This enemy is no longer on the current map. Search again.")
    return
  end
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

  local mdt = getMDT()
  if not mdt then
    hideSpellSearchResults()
    return
  end

  local query = trimText(ui.editBox:GetText() or "")
  if query == "" then
    hideSpellSearchResults()
    return
  end

  local searchText = normalizeText(query)
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
  local mdt = getMDT()
  if not ui or not mdt then
    return
  end

  local currentDungeonIdx = getSpellSearchDungeonIdx(mdt)
  if state.spellSearchLastDungeonIdx == currentDungeonIdx and not state.spellSearchDirty then
    return
  end
  state.spellSearchLastDungeonIdx = currentDungeonIdx
  state.spellSearchDirty = false

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

  local mdt = getMDT()
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
      openEnemyInfoForEnemyIdx(entries[1].enemyIdx, entries[1].dungeonIdx, entries[1].sublevel)
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
        openEnemyInfoForEnemyIdx(self.entry.enemyIdx, self.entry.dungeonIdx, self.entry.sublevel)
      end
    end)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row:SetScript("OnEnter", function(self)
      if self.entry and GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetSpellByID(self.entry.spellId)
        GameTooltip:Show()
      end
    end)
    row:SetScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)
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

local function isMouseInsideEnemyInfo(window)
  -- Child controls (model, spell list, text fields) can own mouse focus.
  if type(GetMouseFoci) == "function" then
    for _, focus in ipairs(GetMouseFoci()) do
      local ancestor = focus
      while ancestor do
        if ancestor == window then return true end
        ancestor = ancestor.GetParent and ancestor:GetParent()
      end
    end
    return false -- Do not close through an unrelated overlapping window.
  end
  return MouseIsOver(window)
end

local function handleEnemyInfoMouseEvent(event, button)
  if button ~= ENEMY_INFO_MOUSE_BUTTON then return end
  if event == "GLOBAL_MOUSE_UP" then
    if state.closingEnemyInfoClick then
      state.closingEnemyInfoClick = false
      state.suppressEnemyClickUntil = GetTime() + 0.2
    end
    return
  end
  if not (state.enabled and IsControlKeyDown()) then return end
  local enemyInfoFrame = getEnemyInfoWidget()
  local window = enemyInfoFrame and enemyInfoFrame.frame
  if window and window:IsVisible() and isMouseInsideEnemyInfo(window) then
    enemyInfoFrame:Hide()
    state.closingEnemyInfoClick = true
    state.suppressEnemyClickUntil = GetTime() + 0.2
    state.lastEnemyInfoAction = "closed with Ctrl+RightClick"
    if state.debug then report("Enemy Info: " .. state.lastEnemyInfoAction) end
  elseif state.debug then
    report("Enemy Info close: " .. (not window and "window not found"
      or not window:IsVisible() and "window hidden" or "click outside window"))
  end
end

local function wrapEnemyClick(originalOnClick)
  local wrapped = function(self, button, down)
    local mdt = getMDT()
    if mdt and shouldOpenEnemyInfo(button) then
      if state.closingEnemyInfoClick or GetTime() < state.suppressEnemyClickUntil then return end
      local db = mdt.GetDB and mdt:GetDB()
      if not (db and db.devMode) and mdt.visibleMapOnly then
        if openNativeEnemyInfo(self, originalOnClick) then return end
      end
      if not (db and db.devMode) and type(mdt.ShowEnemyInfoFrame) == "function" then
        mdt:ShowEnemyInfoFrame(self)
        return
      end
    end

    return originalOnClick(self, button, down)
  end
  state.originalEnemyClicks[wrapped] = originalOnClick
  return wrapped
end

local function installEnemyInfoHook()
  local mdt = getMDT()
  local mixin = _G.MDTDungeonEnemyMixin
  if not mdt or not mixin or type(mixin.OnClick) ~= "function" then return false end
  if mdt.visibleMapOnly then installMenuHook() end
  if not state.enemyInfoHooked then
    mixin.OnClick = wrapEnemyClick(mixin.OnClick)
    state.enemyInfoHooked = true
  end
  -- XML mixins are copied into frames. Also update buttons created before us.
  local blips = mdt.GetDungeonEnemyBlips and mdt:GetDungeonEnemyBlips()
  for _, blip in pairs(blips or {}) do
    if not state.hookedEnemyButtons[blip] and type(blip.OnClick) == "function" then
      if not state.originalEnemyClicks[blip.OnClick] then blip.OnClick = wrapEnemyClick(blip.OnClick) end
      state.hookedEnemyButtons[blip] = true
    end
  end
  return true
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
  if not db or not db.currentDungeonIdx or type(mdt.CountForces) ~= "function" then
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
                if blip and blip:IsShown() then
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
  -- Visible pin positions already include zoom and MDT's exclusion rules.
  if mdt.visibleMapOnly then return centersByPull end
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
  local mapScale = type(mdt.GetScale) == "function" and mdt:GetScale() or 1
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
                totalX = totalX + cloneData.x * mapScale
                totalY = totalY + cloneData.y * mapScale
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
  local mdt = getMDT()
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

  state.elapsed = state.elapsed + elapsed
  if state.elapsed < UPDATE_INTERVAL_SECONDS then
    return
  end
  state.elapsed = 0

  local mdt = getMDT()
  refreshVisibleMapData()
  local mainFrame = mdt and mdt.main_frame
  if not mainFrame or not mainFrame:IsShown() then
    hideAllLabels()
    return
  end
  installEnemyInfoHook()
  installSpellSearchUI()
  local mapActive = not mdt.IsMapSectionActive or mdt:IsMapSectionActive()
  if state.spellSearchUI then state.spellSearchUI.container:SetShown(mapActive) end
  if not mapActive then
    hideSpellSearchResults()
    hideAllLabels()
    state.spellSearchDirty = true
    return
  end
  refreshSpellSearchForDungeonChange()
  refreshOverlay()
end

local function onAddonLoaded(_, event, loadedAddonName, success)
  if event == "GLOBAL_MOUSE_DOWN" or event == "GLOBAL_MOUSE_UP" then
    handleEnemyInfoMouseEvent(event, loadedAddonName)
    return
  end
  if event == "SPELL_DATA_LOAD_RESULT" then
    if state.pendingSpells[loadedAddonName] then
      state.pendingSpells[loadedAddonName] = false
      if success then
        state.spellSearchIndexByDungeon = {}
        state.spellSearchDirty = true
      end
    end
    return
  end
  if loadedAddonName == addonName then
    state.enabled = true
    frame:SetScript("OnUpdate", onUpdate)
  end

  if loadedAddonName == addonName or loadedAddonName == "MythicDungeonTools" or loadedAddonName == "MythicDungeonTools_UI" then
    resolveMDT()
    installEnemyInfoHook()
    -- Other ADDON_LOADED handlers may still be initializing the MDT runtime.
    C_Timer.After(0, function()
      resolveMDT()
      installEnemyInfoHook()
    end)
  end
end

SLASH_MDTQOL1 = "/mdtqol"
SlashCmdList.MDTQOL = function(message)
  local command = normalizeText(message)
  if command == "debug" then
    state.debug = not state.debug
    report("Debug " .. (state.debug and "on" or "off") .. ".")
  elseif command == "refresh" then
    state.spellSearchIndexByDungeon = {}
    state.pendingSpells = {}
    state.spellSearchDirty = true
    resolveMDT()
    report("Search cache cleared; open MDT to refresh.")
  elseif command == "status" or command == "" then
    resolveMDT()
    local mdt = getMDT()
    refreshVisibleMapData()
    local version, build, _, interface = GetBuildInfo()
    local metadata = C_AddOns and C_AddOns.GetAddOnMetadata
    report(string.format("QoL %s; WoW %s (%s), interface %s; MDT %s",
      metadata and metadata(addonName, "Version") or "?", tostring(version), tostring(build), tostring(interface),
      metadata and metadata("MythicDungeonTools", "Version") or "?"))
    report("Connection: " .. state.connection)
    local index = mdt and getSpellSearchIndex(mdt)
    report(string.format("Window: %s; search: %s; Ctrl+RightClick: %s; dungeon: %s; spell/enemy entries: %d",
      mdt and mdt.main_frame and "created" or "not created", state.spellSearchUI and "created" or "not created",
      state.enemyInfoHooked and "hooked" or "waiting",
      tostring(getSpellSearchDungeonIdx(mdt)), index and #index or 0))
    local info = getEnemyInfoWidget()
    report("Enemy Info: " .. state.lastEnemyInfoAction .. "; window: "
      .. (info and (info.frame:IsVisible() and "visible" or "hidden") or "not found"))
  else
    report("/mdtqol status | debug | refresh")
  end
end

frame:RegisterEvent("SPELL_DATA_LOAD_RESULT")
frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
frame:RegisterEvent("GLOBAL_MOUSE_UP")
frame:SetScript("OnEvent", onAddonLoaded)

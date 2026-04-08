local addonName = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

local UPDATE_INTERVAL_SECONDS = 0.1
local FONT_SIZE = 16
local HOOK_RETRY_DELAY_SECONDS = 0.25
local HOOK_RETRY_MAX_ATTEMPTS = 40

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
  enemyInfoHooked = false,
}

local function applyPercentFont(fontString)
  for _, fontPath in ipairs(FONT_CANDIDATES) do
    if fontString:SetFont(fontPath, FONT_SIZE, "OUTLINE") then
      return
    end
  end
end

local function shouldOpenEnemyInfo(button)
  return IsControlKeyDown() and button == ENEMY_INFO_MOUSE_BUTTON
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
    entry.background:Hide()
  end
end

local function getPullPercentText(mdt, pullIdx)
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
    local background = anchorFrame:CreateTexture(nil, "OVERLAY", nil, -1)
    background:SetColorTexture(0, 0, 0, 0.55)

    local label = anchorFrame:CreateFontString(nil, "OVERLAY", nil)
    applyPercentFont(label)
    label:SetTextColor(1, 1, 1, 1)
    label:SetShadowColor(0, 0, 0, 1)
    label:SetShadowOffset(1, -1)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("MIDDLE")

    background:SetPoint("TOPLEFT", label, "TOPLEFT", -4, 4)
    background:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", 4, -4)

    entry = {
      label = label,
      background = background,
    }
    state.labelsByPull[pullIdx] = entry
  end

  if entry.label:GetParent() ~= anchorFrame then
    entry.label:SetParent(anchorFrame)
    entry.background:SetParent(anchorFrame)
  end

  entry.label:ClearAllPoints()
  entry.label:SetPoint("TOP", anchorFrame.fs or anchorFrame, "BOTTOM", 0, -1)
  return entry
end

local function shouldShowOverlay(mdt)
  if not IsControlKeyDown() then
    return false
  end
  if not mdt or not mdt.main_frame or not mdt.main_frame:IsShown() then
    return false
  end

  local mainFrame = mdt.main_frame
  local overMDT = MouseIsOver(mainFrame)
      or (mainFrame.sidePanel and MouseIsOver(mainFrame.sidePanel))
      or (mainFrame.topPanel and MouseIsOver(mainFrame.topPanel))
      or (mainFrame.bottomPanel and MouseIsOver(mainFrame.bottomPanel))

  return overMDT and mainFrame.mapPanelFrame and mainFrame.mapPanelFrame:IsShown()
end

local function refreshOverlay()
  local mdt = _G.MDT
  if not shouldShowOverlay(mdt) then
    hideAllLabels()
    return
  end

  local mapPanelFrame = mdt.main_frame.mapPanelFrame
  local seen = {}

  for _, child in ipairs({ mapPanelFrame:GetChildren() }) do
    local pullIdx = child.pullIdx
    if type(pullIdx) == "number" and child:IsShown() and child.fs and child.clickArea then
      local text = getPullPercentText(mdt, pullIdx)
      if text then
        local entry = ensureLabel(child, pullIdx)
        entry.label:SetText(text)
        entry.background:Show()
        entry.label:Show()
        seen[pullIdx] = true
      end
    end
  end

  for pullIdx, entry in pairs(state.labelsByPull) do
    if not seen[pullIdx] then
      entry.label:Hide()
      entry.background:Hide()
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

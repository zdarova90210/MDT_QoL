local _, addon = ...
local Compact = {}
addon.Compact = Compact

local HEADER_HEIGHT = 26
local GEOMETRY_KEYS = { "scale", "nonFullscreenScale", "maximized", "anchorFrom", "anchorTo", "xoffset", "yoffset" }
local unpack = unpack
local active, busy, controller
local finishResize

local function settings()
  if type(MDT_QoLDB) ~= "table" then MDT_QoLDB = {} end
  if type(MDT_QoLDB.compact) ~= "table" then MDT_QoLDB.compact = {} end
  return MDT_QoLDB.compact
end

local function copyGeometry(db)
  local result = {}
  for _, key in ipairs(GEOMETRY_KEYS) do result[key] = db[key] end
  return result
end

local function restoreGeometry(db, saved)
  for _, key in ipairs(GEOMETRY_KEYS) do db[key] = saved[key] end
end

local function captureRegion(region)
  local result = { parent = region:GetParent(), level = region:GetFrameLevel(), points = {} }
  for i = 1, region:GetNumPoints() do result.points[i] = { region:GetPoint(i) } end
  return result
end

local function restoreRegion(region, saved)
  region:ClearAllPoints()
  region:SetParent(saved.parent)
  region:SetFrameLevel(saved.level)
  for _, point in ipairs(saved.points) do region:SetPoint(unpack(point)) end
end

local function mapContext(c)
  local db = c.mdt:GetDB()
  local preset = c.mdt:GetCurrentPreset()
  return db.currentDungeonIdx, preset, preset and preset.value and preset.value.currentSublevel
end

local function captureView(c)
  local scroll, map = c.main.scrollFrame, c.main.mapPanelFrame
  local dungeon, preset, floor = mapContext(c)
  return { zoom = map:GetScale(), x = scroll:GetHorizontalScroll() / map:GetWidth(),
    y = scroll:GetVerticalScroll() / map:GetHeight(), dungeon = dungeon, preset = preset, floor = floor }
end

local function restoreView(c, view)
  local dungeon, preset, floor = mapContext(c)
  if dungeon ~= view.dungeon or preset ~= view.preset or floor ~= view.floor then return end
  local map, scroll = c.main.mapPanelFrame, c.main.scrollFrame
  c.restoringView = true
  map:SetScale(view.zoom)
  -- Same viewport limits as MDT's ZoomMap. Coordinates stay proportional when
  -- its native resize code changes the map's logical dimensions.
  scroll.maxX = map:GetWidth() * (view.zoom - 1) / view.zoom
  scroll.maxY = map:GetHeight() * (view.zoom - 1) / view.zoom
  scroll.zoomedIn = math.abs(view.zoom - 1) > 0.02
  scroll:SetHorizontalScroll(math.max(0, math.min(scroll.maxX, view.x * map:GetWidth())))
  scroll:SetVerticalScroll(math.max(0, math.min(scroll.maxY, view.y * map:GetHeight())))
  scroll.isFadeOutPanning = false
  scroll.wasPanningLastFrame = false
  c.restoringView = false
end

local function preserveView(c, callback)
  local view = captureView(c)
  c.pendingView = nil
  callback()
  restoreView(c, view)
  -- UpdateMap resets zoom again in a coroutine. A one-shot SetScale hook
  -- restores our viewport after that reset; real mouse input cancels it.
  c.pendingView = view
  C_Timer.After(2, function() if c.pendingView == view then c.pendingView = nil end end)
end

local function hideTracked(c, entry)
  c.hiding = true
  entry.region:Hide()
  c.hiding = false
end

local function track(c, region)
  if not region or c.hidden[region] then return end
  local entry = { region = region, shown = region:IsShown() }
  c.hidden[region] = entry
  region:HookScript("OnShow", function()
    if active and not c.hiding then entry.shown = true; hideTracked(c, entry) end
  end)
  region:HookScript("OnHide", function()
    if active and not c.hiding and not region:IsShown() then entry.shown = false end
  end)
  if active then hideTracked(c, entry) end
end

local function collectPanels(c)
  local f = c.main
  for _, key in ipairs({ "sidePanel", "navigationSidebar", "topPanel", "bottomPanel", "toolbar",
    "liveReturnButton", "setLivePresetButton", "blackoutFrame" }) do track(c, f[key]) end
  if f.toolbar then track(c, f.toolbar.toggleButton) end
  for _, key in ipairs({ "seasonSelectionGroup", "sublevelSelectionGroup" }) do
    local group = f[key]
    if group then track(c, group.frame) end
  end
  for _, child in ipairs({ f:GetChildren() }) do
    local name = child:GetName()
    if name and name:match("^MDTDungeonButton%d+$") then track(c, child) end
  end
  if c.search then track(c, c.search.container) end
end

local function bounds(c)
  local maxScale = math.min((UIParent:GetWidth() - 16) / c.baseWidth,
    (UIParent:GetHeight() - HEADER_HEIGHT - 16) / c.baseHeight)
  local minScale = math.min(420 / c.baseWidth, maxScale)
  c.main:SetResizeBounds(c.baseWidth * minScale, c.baseHeight * minScale,
    c.baseWidth * maxScale, c.baseHeight * maxScale)
  return minScale, maxScale
end

local function clampPosition(c)
  local f = c.main
  local x, top = f:GetLeft(), f:GetTop()
  if not x or not top then return end
  x = math.max(8, math.min(x, UIParent:GetWidth() - f:GetWidth() - 8))
  top = math.max(f:GetHeight() + 8, math.min(top, UIParent:GetHeight() - HEADER_HEIGHT - 8))
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, top)
end

local function saveCompact(c)
  if not active or c.maximized then return end
  settings().geometry = { scale = c.main:GetHeight() / c.baseHeight,
    x = c.main:GetLeft(), top = c.main:GetTop() }
end

local function setMaxLook(c, maximized)
  if maximized then c.main.maximizeButton:Maximize(true, true)
  else c.main.maximizeButton:Minimize(true, true) end
end

local function applyCompactGeometry(c, geometry, maximized)
  local minScale, maxScale = bounds(c)
  local scale = maximized and maxScale or math.max(minScale, math.min(maxScale, geometry.scale))
  local db = c.mdt:GetDB()
  db.nonFullscreenScale = scale
  -- Use the native minimize callback to resize tiles, pins, drawings and
  -- viewport limits together. Its temporary DB geometry is restored on exit.
  c.nativeMinimize(c.main.maximizeButton)
  c.main:ClearAllPoints()
  if maximized then
    c.main:SetPoint("TOP", UIParent, "TOP", 0, -HEADER_HEIGHT - 8)
  else
    c.main:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", geometry.x, geometry.top)
    clampPosition(c)
  end
  c.maximized = maximized
  c.main.resizer:SetShown(not maximized)
  setMaxLook(c, maximized)
end

local function restoreNormal(c)
  active = false
  c.pendingView = nil
  c.main:StopMovingOrSizing()
  c.main:SetScript("OnSizeChanged", c.sizeScript)
  c.main:SetResizeBounds(unpack(c.resizeBounds))
  restoreGeometry(c.mdt:GetDB(), c.normalDB)
  for region, saved in pairs(c.moved) do restoreRegion(region, saved) end
  for _, entry in pairs(c.hidden) do entry.region:SetShown(entry.shown) end
  c.header:Hide()
  if c.normalDB.maximized then c.nativeMaximize(c.main.maximizeButton)
  else c.nativeMinimize(c.main.maximizeButton) end
  -- The normal window may have a custom anchor unrelated to MDT's DB defaults.
  c.main:ClearAllPoints()
  for _, point in ipairs(c.normalPoints) do c.main:SetPoint(unpack(point)) end
  restoreGeometry(c.mdt:GetDB(), c.normalDB)
  setMaxLook(c, c.normalDB.maximized)
  c.button:ClearAllPoints()
  c.button:SetPoint("RIGHT", c.main.maximizeButton, "LEFT", -2, 0)
  c.button:SetFrameLevel(c.main.maximizeButton:GetFrameLevel() + 1)
end

local function runSafely(c, operation)
  if busy then return end
  busy = true
  local ok, message = pcall(operation)
  if not ok then
    settings().enabled = false
    if c.normalDB then pcall(restoreNormal, c) end
    active = false
    print("|cff33ff99MDT QoL:|r Compact mode could not be applied; restoring normal view.")
    geterrorhandler()(message)
  end
  busy = false
end

local function enter(c)
  local db = c.mdt:GetDB()
  c.normalDB = copyGeometry(db)
  c.normalPoints = captureRegion(c.main).points
  c.resizeBounds = { c.main:GetResizeBounds() }
  c.sizeScript = c.main:GetScript("OnSizeChanged")
  c.moved = {}
  for _, region in ipairs({ c.main.closeButton, c.main.maximizeButton, c.main.resizer }) do
    c.moved[region] = captureRegion(region)
  end
  collectPanels(c)
  for _, entry in pairs(c.hidden) do entry.shown = entry.region:IsShown() end
  local current = { scale = c.main:GetHeight() / c.baseHeight, x = c.main:GetLeft(), top = c.main:GetTop() }
  local geometry = settings().geometry
  if type(geometry) ~= "table" or type(geometry.scale) ~= "number"
    or type(geometry.x) ~= "number" or type(geometry.top) ~= "number" then geometry = current end
  active = true
  c.maximized = false
  local close, maximize, resizer = c.main.closeButton, c.main.maximizeButton, c.main.resizer
  close:ClearAllPoints(); close:SetParent(c.header)
  close:SetFrameLevel(c.header:GetFrameLevel() + 1)
  close:SetPoint("TOPRIGHT", c.header, "TOPRIGHT", -1, -1)
  maximize:ClearAllPoints(); maximize:SetParent(c.header)
  maximize:SetFrameLevel(c.header:GetFrameLevel() + 1)
  maximize:SetPoint("RIGHT", close, "LEFT", 0, 0)
  c.button:ClearAllPoints(); c.button:SetPoint("RIGHT", maximize, "LEFT", -2, 0)
  c.button:SetFrameLevel(c.header:GetFrameLevel() + 2)
  resizer:ClearAllPoints(); resizer:SetParent(c.main)
  resizer:SetPoint("BOTTOMRIGHT", c.main, "BOTTOMRIGHT", 0, 0)
  resizer:SetFrameLevel(c.main:GetFrameLevel() + 100)
  for _, entry in pairs(c.hidden) do hideTracked(c, entry) end
  if c.search then c.search.editBox:ClearFocus(); c.search.results:Hide() end
  c.header:Show()
  preserveView(c, function() applyCompactGeometry(c, geometry, false) end)
  settings().enabled = true
  saveCompact(c)
end

function Compact.Toggle()
  local c = controller
  if not c or not c.main:IsShown() then return end
  if not active and c.mdt.IsMapSectionActive and not c.mdt:IsMapSectionActive() then return end
  runSafely(c, function()
    if active then
      finishResize(c)
      saveCompact(c)
      preserveView(c, function() restoreNormal(c) end)
      settings().enabled = false
    else enter(c) end
  end)
end

function Compact.IsActive() return active == true end
function Compact.Status() return active and "on" or controller and "ready" or "waiting for MDT UI" end

finishResize = function(c)
  if not c.resizing then return end
  c.resizing = false
  preserveView(c, function() c.nativeResizeUp(c.main.resizer, "LeftButton") end)
  c.main:SetScript("OnSizeChanged", c.resizeScript)
  clampPosition(c)
  saveCompact(c)
end

local function install(mdt, search)
  local f = mdt and mdt.main_frame
  local maximum = f and f.maximizeButton
  if not (f and f.resizer and f.scrollFrame and f.mapPanelFrame and f.topPanel and f.sidePanel
    and f.closeButton and f.toolbar and f.seasonSelectionGroup and mdt.GetCurrentPreset
    and maximum and type(maximum.maximizedCallback) == "function"
    and type(maximum.minimizedCallback) == "function" and f.resizer:GetScript("OnMouseDown")
    and f.resizer:GetScript("OnMouseUp") and f.GetResizeBounds) then return end
  local db = mdt:GetDB()
  if not db or type(db.scale) ~= "number" or db.scale <= 0 then return end
  local c = { main = f, mdt = mdt, search = search, hidden = {},
    nativeMinimize = maximum.minimizedCallback, nativeMaximize = maximum.maximizedCallback,
    nativeResizeDown = f.resizer:GetScript("OnMouseDown"), nativeResizeUp = f.resizer:GetScript("OnMouseUp"),
    baseWidth = f:GetWidth() / db.scale, baseHeight = f:GetHeight() / db.scale }
  controller = c
  local header = CreateFrame("Frame", nil, f)
  c.header = header
  header:SetHeight(HEADER_HEIGHT)
  header:SetPoint("BOTTOMLEFT", f, "TOPLEFT")
  header:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT")
  header:SetFrameLevel(f:GetFrameLevel() + 100)
  local background = header:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(header); background:SetColorTexture(0.04, 0.04, 0.04, 0.95)
  header:EnableMouse(true); header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function()
    if not c.maximized then f:SetMovable(true); f:StartMoving() end
  end)
  header:SetScript("OnDragStop", function()
    f:StopMovingOrSizing(); f:SetMovable(false); clampPosition(c); saveCompact(c)
  end)
  header:Hide()
  local button = CreateFrame("Button", "MDTQoLCompactButton", f, "UIPanelButtonTemplate")
  c.button = button
  button:SetSize(24, 24)
  button:SetPoint("RIGHT", maximum, "LEFT", -2, 0)
  button:SetFrameLevel(maximum:GetFrameLevel() + 1)
  -- A small window icon; no font glyph or external image dependency.
  local icon = button:CreateTexture(nil, "OVERLAY")
  icon:SetSize(13, 10); icon:SetPoint("CENTER"); icon:SetColorTexture(0.95, 0.78, 0.25, 1)
  local inside = button:CreateTexture(nil, "OVERLAY", nil, 1)
  inside:SetSize(9, 6); inside:SetPoint("CENTER"); inside:SetColorTexture(0.12, 0.12, 0.12, 1)
  button:SetScript("OnClick", Compact.Toggle)
  button:SetScript("OnEnter", function()
    local ru = GetLocale() == "ruRU"
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText(active and (ru and "Вернуть панели MDT" or "Restore MDT panels")
      or (ru and "Компактный режим: только карта" or "Compact mode: map only"))
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  c.title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  c.title:SetPoint("LEFT", header, "LEFT", 8, 0)
  c.title:SetPoint("RIGHT", button, "LEFT", -8, 0)
  c.title:SetJustifyH("LEFT"); c.title:SetWordWrap(false)

  local function setCompactMaximized(value)
    runSafely(c, function()
      if c.resizing then finishResize(c) end
      if value then saveCompact(c) end
      preserveView(c, function() applyCompactGeometry(c, settings().geometry, value) end)
    end)
  end
  maximum:SetOnMaximizedCallback(function(self)
    if active then setCompactMaximized(true) else c.nativeMaximize(self) end
  end)
  maximum:SetOnMinimizedCallback(function(self)
    if active then setCompactMaximized(false) else c.nativeMinimize(self) end
  end)
  f.resizer:SetScript("OnMouseDown", function(self, buttonName)
    if not active then return c.nativeResizeDown(self, buttonName) end
    if buttonName ~= "LeftButton" or c.maximized then return end
    c.pendingView = nil
    c.resizeScript = f:GetScript("OnSizeChanged")
    c.resizing = true
    c.nativeResizeDown(self, buttonName)
  end)
  f.resizer:SetScript("OnMouseUp", function(self, buttonName)
    if not active then return c.nativeResizeUp(self, buttonName) end
    if buttonName == "LeftButton" then runSafely(c, function() finishResize(c) end) end
  end)
  f:HookScript("OnHide", function()
    if active then
      runSafely(c, function() finishResize(c); f:StopMovingOrSizing(); f:SetMovable(false); saveCompact(c) end)
    end
  end)
  hooksecurefunc(f.mapPanelFrame, "SetScale", function()
    local view = c.pendingView
    if not view or c.restoringView or c.viewQueued then return end
    c.viewQueued = true
    C_Timer.After(0, function()
      c.viewQueued = false
      if c.pendingView == view then c.pendingView = nil; restoreView(c, view) end
    end)
  end)
  for _, script in ipairs({ "OnMouseDown", "OnMouseWheel" }) do
    f.scrollFrame:HookScript(script, function() if not c.restoringView then c.pendingView = nil end end)
  end
  local events = CreateFrame("Frame")
  events:RegisterEvent("PLAYER_LOGOUT")
  events:SetScript("OnEvent", function()
    if active and c.normalDB then
      saveCompact(c)
      -- Let MDT persist its normal layout; QoL owns compact layout persistence.
      restoreGeometry(c.mdt:GetDB(), c.normalDB)
    end
  end)
  return c
end

function Compact.Update(mdt, search)
  local c = controller or install(mdt, search)
  if not c then return end
  c.search = search
  if not c.restoredSettings then
    c.restoredSettings = true
    if settings().enabled and (not mdt.IsMapSectionActive or mdt:IsMapSectionActive()) then Compact.Toggle() end
  end
  c.button:SetShown(active or not mdt.IsMapSectionActive or mdt:IsMapSectionActive())
  if active then
    local dungeon, preset, floor = mapContext(c)
    local title = preset and preset.text or "MDT"
    if c.titleText ~= title then c.title:SetText(title); c.titleText = title end
    if c.dungeon ~= dungeon or c.preset ~= preset or c.floor ~= floor then
      c.dungeon, c.preset, c.floor = dungeon, preset, floor
      collectPanels(c)
    end
  end
end

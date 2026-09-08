-- Run with Lua 5.1 from the addon directory: lua tests/compatibility.lua
-- Models the public MDT 6.2 surface, deliberately WITHOUT a global MDT.
local frames, messages, timers, requested = {}, {}, {}, {}
local methods = {}
function methods:RegisterEvent(event) self.events[event] = true end
function methods:SetScript(event, callback) self.scripts[event] = callback end
function methods:GetScript(event) return self.scripts[event] end
function methods:GetChildren() return unpack(self.children) end
function methods:GetParent() return self.parent end
function methods:SetParent(parent) self.parent = parent end
function methods:IsShown() return self.shown end
function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetShown(shown) self.shown = shown end
function methods:SetPoint(...) self.point = {...} end
function methods:GetPoint() return unpack(self.point or {}) end
function methods:SetFrameLevel(level) self.level = level end
function methods:GetFrameLevel() return self.level or 1 end
function methods:SetText(text)
  self.text = text
  if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end
end
function methods:GetText() return self.text end
function methods:SetFont() return true end
function methods:CreateTexture() return CreateFrame("Texture", nil, self) end
function methods:CreateFontString() return CreateFrame("FontString", nil, self) end
for _, name in ipairs({ "SetSize", "SetWidth", "SetHeight", "SetFrameStrata", "SetAllPoints", "SetColorTexture",
  "SetAutoFocus", "SetTextInsets", "ClearFocus", "SetJustifyH", "SetJustifyV", "RegisterForClicks", "SetWordWrap",
  "SetTextColor", "SetShadowColor", "SetShadowOffset", "ClearAllPoints", "SetTexture", "SetVertexColor",
  "SetTexCoord", "SetFontObject" }) do methods[name] = function() end end
function CreateFrame(kind, name, parent)
  local f = setmetatable({kind=kind, name=name, parent=parent, children={}, scripts={}, events={}, shown=true}, {__index=methods})
  frames[#frames+1] = f
  -- WoW GetChildren returns frames, not regions.
  if parent and kind ~= "Texture" and kind ~= "FontString" then parent.children[#parent.children+1] = f end
  if name then _G[name] = f end
  return f
end
function print(message) messages[#messages+1] = message end
local control, mouseDown, hovered, now = false, false, nil, 1
function IsControlKeyDown() return control end
function IsMouseButtonDown() return mouseDown end
function MouseIsOver(f) return hovered == f end
function GetMouseFoci() return hovered and {hovered} or {} end
function GetTime() return now end
local locale = "enUS"
function GetLocale() return locale end
local errors = {}
function geterrorhandler() return function(message) errors[#errors+1]=message end end
function GetBuildInfo() return "12.1.0", "69587", "", 120100 end
SlashCmdList = {}
C_Timer = {After = function(_, fn) timers[#timers+1] = fn end}
C_AddOns = {GetAddOnMetadata = function(name) return name == "MDT_QoL" and "0.5.0-test.3" or "6.2.15" end}
local spellNames = {[101]="Fire Bolt", [102]="Frost Blast", [104]="Shadow Burst"}
C_Spell = {
  GetSpellName = function(id) return spellNames[id] end,
  RequestLoadSpellData = function(id) requested[id] = true end,
}
local db = {currentDungeonIdx=1, currentPreset={[1]=1,[2]=1}, currentSection="maps", presets={
  [1]={{value={currentSublevel=1,pulls={{[1]={1}}}}}},
  [2]={{value={currentSublevel=1,pulls={}}}},
}}
MythicDungeonToolsAPI = {GetDB=function() return db end}
local source = assert(io.open("MDT_QoL.lua", "rb")):read("*a")
assert(loadstring(source, "@MDT_QoL.lua"))("MDT_QoL")
local controller = frames[1]
local function event(name, ...)
  assert(controller.events[name], "event must be registered: "..name)
  controller.scripts.OnEvent(controller, name, ...)
end
local function tick() now=now+0.2; controller.scripts.OnUpdate(controller, 0.2) end
event("ADDON_LOADED", "MDT_QoL")
for _=1,100 do tick() end -- no ten-second initialization deadline
assert(not _G.MDT, "must not restore or require a global MDT")
assert(#frames == 1, "must not force-load the MDT UI")

MDTFrame = CreateFrame("Frame")
MDTFrame.topPanel = CreateFrame("Frame", nil, MDTFrame)
MDTFrame.mapPanelFrame = CreateFrame("Frame", nil, MDTFrame)
MDTFrame.mapPanelTile1 = CreateFrame("Texture", nil, MDTFrame.mapPanelFrame)
MDTFrame.sidePanel = {newPullButtons={}}
local menuCalls, lastEnemy, infoCalls, menuOpen, infoWidget = 0, nil, 0, false, nil
local hookCalls = 0
function hooksecurefunc(target, name, callback)
  hookCalls=hookCalls+1
  local original=target[name]
  target[name]=function(...) local result=original(...); callback(...); return result end
end
Menu = {PopulateDescription=function(generator, owner, description) generator(owner,description) end}
MenuInputContext={MouseButton=1}
MenuUtil={GetElementText=function(element) return element.text end}
local menuRoots=setmetatable({}, {__mode="k"})
local menuLabel="Open Enemy Info"
local failHandler, restrictMenu, duplicateLabel = false, false, false
local function showInfo(enemyIdx)
  infoCalls=infoCalls+1
  lastEnemy=enemyIdx
  if not infoWidget then
    local f=CreateFrame("Frame",nil,MDTFrame)
    infoWidget={type="Frame",frame=f,enemyDropDown={},enemyDataContainer={},tabGroup={},model={},
      Hide=function(self) self.frame:Hide() end}
    f.obj=infoWidget
  end
  infoWidget.frame:Show()
end
local function createDescription(text, callback)
  local d={text=text, callback=callback, elements={}}
  function d:EnumerateElementDescriptions() return ipairs(self.elements) end
  function d:Pick(context, button)
    assert(context==MenuInputContext.MouseButton and button=="LeftButton")
    if not self.callback then return false end
    self.callback()
    menuOpen=false
    return true
  end
  function d:CreateButton(text, callback)
    local child=createDescription(text,callback)
    self.elements[#self.elements+1]=child
    return child
  end
  function d:CreateTitle(text) return self:CreateButton(text) end
  function d:CreateRadio(text) return self:CreateButton(text) end
  return d
end
function MenuUtil.CreateContextMenu(owner,generator)
  local root=createDescription()
  menuRoots[root]=true
  Menu.PopulateDescription(generator,owner,root)
  menuOpen=true
end
local function nativeOnClick(self, button)
  menuCalls=menuCalls+1
  if failHandler then error("test handler failure") end
  if button~="RightButton" or restrictMenu then return end
  MenuUtil.CreateContextMenu(MDTFrame,function(_,root)
    root:CreateTitle(self.data.name)
    root:CreateButton("Set Target Marker", function() error("wrong menu item selected") end)
    root:CreateButton(menuLabel,function() showInfo(self.enemyIdx) end)
    if duplicateLabel then root:CreateButton(menuLabel,function() error("ambiguous menu action") end) end
  end)
end
MDTDungeonEnemyMixin={OnClick=nativeOnClick}
local function pin(enemyIdx, spellId, name, floor)
  local p = CreateFrame("Button", nil, MDTFrame.mapPanelFrame)
  p.enemyIdx, p.cloneIdx = enemyIdx, 1
  p.clone = {x=100,y=-100,sublevel=floor or 1}
  p.data = {name=name,spells={[spellId]={}},clones={p.clone}}
  p.OnClick = nativeOnClick
  p:SetPoint("CENTER", MDTFrame.mapPanelTile1, "TOPLEFT", 200, -200)
  return p
end
local fire = pin(1,101,"Flame Keeper")
local frost = pin(2,102,"Frost Keeper")
local hidden = pin(3,104,"Hidden Keeper")
hidden:Hide()
local otherFloor = pin(4,104,"Other Floor",2)
event("ADDON_LOADED", "MythicDungeonTools_UI")
for _, fn in ipairs(timers) do fn() end
tick()
local edit
for _, f in ipairs(frames) do if f.kind == "EditBox" then edit = f end end
assert(edit, "search must appear after delayed UI loading without global MDT")
local function rows()
  local result={}
  for _, f in ipairs(frames) do if f.entry and f.shown then result[#result+1]=f end end
  return result
end
edit:SetText("fire")
assert(#rows()==1 and rows()[1].entry.spellId==101, "search spell name")
edit:SetText("KEEPER")
assert(#rows()==2, "enemy search excludes hidden pins and other floors")
edit:SetText("102")
assert(#rows()==1 and rows()[1].entry.enemyIdx==2, "search spell ID")
rows()[1].scripts.OnClick(rows()[1])
assert(menuCalls==1 and lastEnemy==2, "result opens existing native enemy menu")
assert(infoCalls==1 and not menuOpen, "search goes directly to Enemy Info")
db.devMode=true
rows()[1].scripts.OnClick(rows()[1])
assert(menuCalls==1, "must never run destructive dev-mode right click")
db.devMode=false

local staleRow=rows()[1]
db.presets[1][1].value.currentSublevel=2
staleRow.scripts.OnClick(staleRow)
assert(menuCalls==1, "reject stale search result after floor change")
tick()
edit:SetText("shadow")
assert(#rows()==1 and rows()[1].entry.enemyIdx==4, "replace search index on floor change")
fire:Hide(); frost:Hide(); otherFloor:Hide()
db.currentDungeonIdx=2
tick()
edit:SetText("fire")
assert(#rows()==0, "must not retain previous dungeon results")
local late=pin(1,103,"Late Keeper")
tick()
assert(requested[103], "request spell data that is not cached")
spellNames[103]="Fire Rain"
event("SPELL_DATA_LOAD_RESULT",103,true)
tick()
assert(#rows()==1 and rows()[1].entry.spellName=="Fire Rain", "refresh after asynchronous spell data load")
-- Reuse an existing pin for another enemy, as MDT's frame pool does.
late.data={name="Replacement",spells={[102]={}},clones={late.clone}}
tick()
edit:SetText("frost")
assert(#rows()==1 and rows()[1].entry.enemyName=="Replacement", "refresh pooled pin data")
db.currentSection="settings"
tick()
assert(not edit.parent:IsShown() and #rows()==0, "hide search in non-map sections")
db.currentSection="maps"
tick()
assert(edit.parent:IsShown() and #rows()==1, "restore search when returning to map")

-- Percentages come verbatim from the sidebar, with actual scaled pin positions.
db.presets[2][1].value.pulls={{[1]={1}}}
local pct=CreateFrame("FontString")
pct:SetText("23.45%")
MDTFrame.sidePanel.newPullButtons[1]={percentageFontString=pct}
control=true
tick()
local label
for _, f in ipairs(frames) do if f.kind=="FontString" and f~=pct and f.text=="23.45%" then label=f end end
assert(label and label:IsShown(), "render Ctrl percentages from MDT sidebar")
assert(label.parent.point[4]==200 and label.parent.point[5]==-200, "use scaled pin coordinates")
control=false
tick()
assert(not label:IsShown(), "hide percentage when Ctrl released")
SlashCmdList.MDTQOL("status")
assert(messages[#messages]:find("opened through native menu",1,true), "diagnose shortcut status")
SlashCmdList.MDTQOL("refresh")
tick()
assert(#rows()==1, "manual refresh rebuilds the index")

-- Native shortcut, closing inside the window, and preserving ordinary clicks.
control=true
local before=infoCalls
late:OnClick("RightButton")
assert(infoCalls==before+1 and infoWidget.frame:IsVisible() and not menuOpen)
hovered=infoWidget.frame
event("GLOBAL_MOUSE_UP", "RightButton") -- release of opening click cannot close it
assert(infoWidget.frame:IsShown())
-- Both mouse events may arrive without any intervening OnUpdate/pressed sample.
event("GLOBAL_MOUSE_DOWN", "RightButton")
assert(not infoWidget.frame:IsShown(), "Ctrl+right mouse down closes Enemy Info")
for _=1,10 do tick() end -- holding the closing mouse button must not defeat suppression
late:OnClick("RightButton")
assert(infoCalls==before+1, "closing click must not reopen the map pin underneath")
event("GLOBAL_MOUSE_UP", "RightButton")
late:OnClick("RightButton")
assert(infoCalls==before+1, "mouse-up delivered before pin OnClick must also suppress reopening")
tick(); tick()
control=false
late:OnClick("RightButton")
assert(menuOpen and infoCalls==before+1, "plain right click still opens the ordinary menu")
control=true
local function invoke() tick(); late:OnClick("RightButton") end
restrictMenu=true
invoke()
assert(infoCalls==before+1, "respect MDT's restricted environment")
restrictMenu=false
menuLabel="Changed by upstream"
invoke()
assert(menuOpen and infoCalls==before+1, "unknown label leaves menu open without choosing another action")
menuLabel="Open Enemy Info"
duplicateLabel=true
invoke()
assert(menuOpen and infoCalls==before+1, "ambiguous labels must not select an action")
duplicateLabel=false
failHandler=true
invoke()
assert(#errors==1, "report original MDT error")
failHandler=false
invoke()
assert(infoCalls==before+2, "recover after error without leaving an active menu request")

-- Nested controls own focus; unrelated popups and unmodified clicks stay alone.
local infoChild=CreateFrame("Frame", nil, infoWidget.frame)
local infoGrandchild=CreateFrame("Button", nil, infoChild)
hovered=infoGrandchild
control=false
event("GLOBAL_MOUSE_DOWN", "RightButton")
assert(infoWidget.frame:IsShown(), "plain right click must not close")
control=true
event("GLOBAL_MOUSE_DOWN", "LeftButton")
assert(infoWidget.frame:IsShown(), "Ctrl+left click must not close")
hovered=CreateFrame("Frame", nil, MDTFrame)
event("GLOBAL_MOUSE_DOWN", "RightButton")
assert(infoWidget.frame:IsShown(), "unrelated sibling must not close Enemy Info")
hovered=infoGrandchild
event("GLOBAL_MOUSE_DOWN", "RightButton")
event("GLOBAL_MOUSE_UP", "RightButton")
assert(not infoWidget.frame:IsShown(), "fast click over nested control closes without polling")
tick()
-- Native-menu openings also support closing, even without the QoL shortcut.
showInfo(1)
MDTFrame:Hide()
event("GLOBAL_MOUSE_DOWN", "RightButton")
assert(infoWidget.frame:IsShown(), "do not act on an invisible parent")
MDTFrame:Show()
hovered=infoWidget.frame
event("GLOBAL_MOUSE_DOWN", "RightButton")
event("GLOBAL_MOUSE_UP", "RightButton")
assert(not infoWidget.frame:IsShown(), "close a window opened through the ordinary menu")
tick()

-- Language tests: names are supplied by the client, not translated by QoL.
local translations={
  {"ruRU","Открыть информацию о враге","ОГНЕННЫЙ ВСПЛЕСК","огненный"},
  {"deDE","Gegnerinfo öffnen","ÜBERLADUNG","über"},
  {"frFR","Informations sur l'ennemi ouvert","ÉCLAIR","éclair"},
  {"itIT","Apri le informazioni sul nemico","FUOCO","fuoco"},
  {"esES","Abrir información del enemigo","EXPLOSIÓN","explosión"},
  {"esMX","Abrir información del enemigo","EXPLOSIÓN","explosión"},
  {"ptBR","Abrir informações do inimigo","EXPLOSÃO","explosão"},
  {"koKR","몹 정보 열기","화염구","화염"},
  {"zhCN","查看怪物信息","火球术","火球"},
  {"zhTW","開啟敵方資訊","火球術","火球"},
  {"enUS","Open Enemy Info","FIRE BOLT","fire"},
}
for _, sample in ipairs(translations) do
  locale,menuLabel=sample[1],sample[2]
  spellNames[102]=sample[3]
  SlashCmdList.MDTQOL("refresh")
  tick()
  edit:SetText(sample[4])
  assert(#rows()==1 and rows()[1].entry.spellName==sample[3], "localized spell search: "..locale)
  local count=infoCalls
  rows()[1].scripts.OnClick(rows()[1])
  assert(infoCalls==count+1 and not menuOpen, "localized native action: "..locale)
end

-- Also run the real MDT 6.2 menu generator and right-click implementation when
-- an installed reference is supplied. Only dependencies/UI rendering are mocked.
local reference=os.getenv("MDT_REFERENCE_DIR")
if reference then
  local file=assert(io.open(reference.."/Modules/DungeonEnemies.lua","rb"))
  local nativeSource=file:read("*a"):gsub("\r\n","\n"); file:close()
  local block=assert(nativeSource:match("(local iconColors =.-)\nlocal patrolPoints"))
  local privateMDT={main_frame=MDTFrame,
    GetCurrentPreset=function() return db.presets[db.currentDungeonIdx][db.currentPreset[db.currentDungeonIdx]] end,
    UpdateSelectedToolbarTool=function() end,
    CreateContextMenu=function(_,owner,generator) return MenuUtil.CreateContextMenu(owner,generator) end,
    ShowEnemyInfoFrame=function(_,blip) showInfo(blip.enemyIdx) end}
  local actualL=setmetatable({}, {__index=function(_,key) return key=="Open Enemy Info" and menuLabel or key end})
  local env=setmetatable({MDTDungeonEnemyMixin={},ICON_LIST={},
    CreateColor=function() return {} end,WrapTextInColor=function(text) return text end}, {__index=_G})
  env._G=env
  for i=1,8 do env.ICON_LIST[i]="icon"; env["RAID_TARGET_"..i]="marker" end
  local chunk=assert(loadstring("local MDT,db,L=...; local twipe=function(t) for k in pairs(t) do t[k]=nil end end;\n"..block.."\nreturn MDTDungeonEnemyMixin.OnClick"))
  setfenv(chunk,env)
  local actualClick=chunk(privateMDT,db,actualL)
  nativeOnClick=function(self,button,down) menuCalls=menuCalls+1; return actualClick(self,button,down) end
  local actualPin=pin(9,102,"Actual MDT")
  tick()
  for _,sample in ipairs(translations) do
    locale,menuLabel=sample[1],sample[2]
    local count=infoCalls
    actualPin:OnClick("RightButton")
    assert(infoCalls==count+1 and lastEnemy==9 and not menuOpen, "real MDT click implementation: "..locale)
  end
  io.write("PASS: actual installed MDT menu generator and right-click implementation in 11 locales\n")
end

-- Repeated use must not allocate more QoL frames or stack hooks/wrappers.
local frameCount, originalWrapped = #frames, late.OnClick
collectgarbage("collect")
local memoryBefore=collectgarbage("count")
for _=1,1000 do
  invoke()
  hovered=infoGrandchild
  event("GLOBAL_MOUSE_DOWN", "RightButton")
  event("GLOBAL_MOUSE_UP", "RightButton")
  assert(not infoWidget.frame:IsShown(), "close in every stress-test cycle")
  MDTFrame:Hide(); tick(); MDTFrame:Show(); tick()
end
collectgarbage("collect")
local memoryAfter=collectgarbage("count")
assert(#frames==frameCount, "no frame growth during repeated use")
assert(late.OnClick==originalWrapped and hookCalls==1, "no stacked hooks or click wrappers")
assert(next(menuRoots)==nil, "menu descriptions must be collectable")
assert(memoryAfter-memoryBefore<32, "retained memory must remain bounded")
io.write(string.format("PASS: 1000 open/close cycles, no new frames, one menu hook, retained Lua memory delta %.2f KiB\n",memoryAfter-memoryBefore))
-- Legacy MDT still supports direct Enemy Info and hooks copied into old pins.
infoCalls=0
MDT={main_frame=MDTFrame,dungeonEnemies={[2]={[1]=late.data}},GetDB=function() return db end,
  GetDungeonEnemyBlips=function() return {late} end,
  ShowEnemyInfoFrame=function() infoCalls=infoCalls+1 end}
MDTDungeonEnemyMixin={OnClick=function() end}
event("ADDON_LOADED","MythicDungeonTools")
control=true
late:OnClick("RightButton")
assert(infoCalls==1, "legacy existing pins retain Ctrl+right-click support")
io.write("PASS: delayed UI, searches in 11 locales, native shortcuts, fallbacks, restrictions, error recovery, dev-mode guard, stale results, async spells, pooled pins, sections, overlays, diagnostics, legacy hook\n")

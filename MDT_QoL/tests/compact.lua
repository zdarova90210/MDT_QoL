-- Lua 5.1; uses the installed MDT resize and maximize implementations read-only.
local frames, timers, now, hooks = {}, {}, 0, 0
local methods = {}
function methods:GetParent() return self.parent end
function methods:SetParent(parent) self.parent=parent end
function methods:GetName() return self.name end
function methods:GetChildren()
  local children={}
  for _,f in ipairs(frames) do if f.parent==self and f.kind~="Texture" and f.kind~="FontString" then children[#children+1]=f end end
  return unpack(children)
end
function methods:SetScript(event,fn) self.scripts[event]=fn end
function methods:GetScript(event) return self.scripts[event] end
function methods:HookScript(event,fn)
  hooks=hooks+1
  local old=self.scripts[event]
  self.scripts[event]=function(...) if old then old(...) end; fn(...) end
end
function methods:IsShown() return self.shown end
function methods:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function methods:Show()
  local changed=not self.shown; self.shown=true
  if changed and self:IsVisible() and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods:Hide()
  local changed=self.shown; self.shown=false
  if changed and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods:SetShown(value) if value then self:Show() else self:Hide() end end
function methods:GetFrameLevel() return self.level or 1 end
function methods:SetFrameLevel(level) self.level=level end
function methods:GetNumPoints() return #self.points end
function methods:GetPoint(i) return unpack(self.points[i or 1] or {}) end
function methods:ClearAllPoints() self.points={} end
function methods:SetPoint(...) self.points[#self.points+1]={...} end
function methods:SetAllPoints(f) self.allPoints=f or self.parent end
function methods:SetWidth(w) self:SetSize(w,self:GetHeight()) end
function methods:SetHeight(h) self:SetSize(self:GetWidth(),h) end
function methods:SetSize(w,h)
  local changed=self.width~=w or self.height~=h
  self.width,self.height=w,h
  if changed and self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self,w,h) end
end
function methods:GetWidth() return self.width or (self.allPoints and self.allPoints:GetWidth()) or 100 end
function methods:GetHeight() return self.height or (self.allPoints and self.allPoints:GetHeight()) or 100 end
function methods:GetLeft()
  local p=self.points[1]
  if not p then return self.parent and self.parent:GetLeft() or 0 end
  if p[1]=="TOPLEFT" then return p[4] or 0 end
  return (UIParent:GetWidth()-self:GetWidth())/2+(p[4] or 0)
end
function methods:GetTop()
  local p=self.points[1]
  if not p then return self.parent and self.parent:GetTop() or self:GetHeight() end
  if p[3]=="BOTTOMLEFT" then return p[5] end
  return UIParent:GetHeight()+(p[5] or 0)
end
function methods:GetScale() return self.scale or 1 end
function methods:SetScale(scale) self.scale=scale end
function methods:SetResizeBounds(...) self.bounds={...} end
function methods:GetResizeBounds() return unpack(self.bounds) end
function methods:SetHorizontalScroll(value) self.scrollX=value end
function methods:SetVerticalScroll(value) self.scrollY=value end
function methods:GetHorizontalScroll() return self.scrollX or 0 end
function methods:GetVerticalScroll() return self.scrollY or 0 end
function methods:StartSizing() self.sizing=true end
function methods:StartMoving() self.moving=true end
function methods:StopMovingOrSizing() self.sizing=false; self.moving=false end
function methods:SetText(text) self.text=text end
function methods:RegisterEvent(event) self.events[event]=true end
function methods:CreateTexture() return CreateFrame("Texture",nil,self) end
function methods:CreateFontString() return CreateFrame("FontString",nil,self) end
for _,name in ipairs({"EnableMouse","RegisterForDrag","SetMovable","SetJustifyH","SetWordWrap","SetColorTexture",
  "SetFrameStrata","SetDrawLayer","SetNormalTexture","SetPushedTexture","SetHighlightTexture","SetTexture","SetTexCoord",
  "SetMouseClickEnabled","ClearFocus"}) do methods[name]=function() end end
function methods:SetOnMaximizedCallback(fn) self.maximizedCallback=fn end
function methods:SetOnMinimizedCallback(fn) self.minimizedCallback=fn end
function methods:Maximize(_,skip)
  if not skip then self.maximizedCallback(self) end
  self.isMinimized=false
end
function methods:Minimize(_,skip)
  if not skip then self.minimizedCallback(self) end
  self.isMinimized=true
end
function CreateFrame(kind,name,parent)
  local f=setmetatable({kind=kind,name=name,parent=parent,scripts={},events={},points={},shown=true},{__index=methods})
  frames[#frames+1]=f
  if name then _G[name]=f end
  return f
end
function hooksecurefunc(target,key,fn)
  hooks=hooks+1
  local original=target[key]
  target[key]=function(...) local result=original(...); fn(...); return result end
end
C_Timer={After=function(delay,fn) timers[#timers+1]={time=now+delay,fn=fn} end}
local function advance(delta)
  now=now+delta
  local pending=timers; timers={}
  for _,t in ipairs(pending) do if t.time<=now then t.fn() else timers[#timers+1]=t end end
end
local errors={}
function geterrorhandler() return function(message) errors[#errors+1]=message end end
function GetLocale() return "ruRU" end
function GetCursorPosition() return 500,400 end
UIParent=CreateFrame("Frame"); UIParent:SetSize(1920,1080)
local db={scale=1,nonFullscreenScale=1,maximized=false,anchorTo="TOPLEFT",anchorFrom="BOTTOMLEFT",xoffset=200,yoffset=900,
  currentDungeonIdx=1,currentSection="maps",toolbarExpanded=true}
local preset={text="Test route",value={currentSublevel=1,pulls={}}}
local f=CreateFrame("Frame", "MDTFrame",UIParent); f:SetSize(840,555)
f:SetPoint("TOPLEFT",UIParent,"BOTTOMLEFT",200,900); f:SetResizeBounds(756,499.5,1600,1057)
for _,name in ipairs({"topPanel","bottomPanel","sidePanel","navigationSidebar","scrollFrame","mapPanelFrame","toolbar"}) do f[name]=CreateFrame("Frame",nil,f) end
f.scrollFrame:SetSize(840,555); f.mapPanelFrame:SetSize(840,555)
f.scrollFrame.cursorX,f.scrollFrame.cursorY=100,100
f.mapPanelFrame:SetScale(2.5)
f.scrollFrame:SetHorizontalScroll(140); f.scrollFrame:SetVerticalScroll(120)
f.toolbar.toggleButton=CreateFrame("Button",nil,f)
f.seasonSelectionGroup={frame=CreateFrame("Frame",nil,f)}
f.sublevelSelectionGroup={frame=CreateFrame("Frame",nil,f)}
f.sublevelSelectionGroup.frame:Hide()
local dungeonButton=CreateFrame("Button","MDTDungeonButton1",f)
for i=1,12 do f["mapPanelTile"..i]=f.mapPanelFrame:CreateTexture() end
for i=1,10 do for j=1,15 do f["largeMapPanelTile"..i..j]=f.mapPanelFrame:CreateTexture() end end
f.closeButton=CreateFrame("Button",nil,f)
f.closeButton:SetPoint("TOPRIGHT",f.sidePanel,"TOPRIGHT",-1,-4)
f.closeButton:SetScript("OnClick",function() f:Hide() end)
f.maximizeButton=CreateFrame("Frame",nil,f)
f.maximizeButton:SetPoint("RIGHT",f.closeButton,"LEFT",0,0)
local native={main_frame=f,GetDB=function() return db end,GetDefaultMapPanelSize=function() return 840,555 end,
  GetCurrentPreset=function() return preset end,IsMapSectionActive=function() return db.currentSection=="maps" end,
  GetNavigationSidebarWidth=function() return 40 end,GetFullScreenSizes=function() return 1500,1500*555/840,1500/840 end,
  DungeonEnemies_HideAllBlips=function() end,POI_HideAllPoints=function() end,HideAllPresetObjects=function() end,
  ReleaseHullTextures=function() end,UpdateEnemyInfoFrame=function() end,UpdateBottomText=function() end}
function native:ZoomMap()
  f.mapPanelFrame:SetScale(f.mapPanelFrame:GetScale())
end
function native:UpdateMap()
  C_Timer.After(0.01,function()
    f.mapPanelFrame:SetScale(1)
    f.scrollFrame:SetHorizontalScroll(0); f.scrollFrame:SetVerticalScroll(0)
    dungeonButton:Show(); f.toolbar:Show()
  end)
end
local reference=assert(os.getenv("MDT_REFERENCE_DIR"), "MDT_REFERENCE_DIR is required")
local function read(path) local file=assert(io.open(path,"rb")); local data=file:read("*a"); file:close(); return data:gsub("\r\n","\n") end
local mainSource=read(reference.."/Modules/MainFrame.lua")
local resize=assert(mainSource:match("  %-%-Resize Handle\n(.-)\nend\n"))
assert(loadstring("local MDT,db=...; local self=MDT; local sizey=555;\n"..resize))(native,db)
local scaling=assert(mainSource:match("(local oldScrollValues =.-)\nfunction MDT:GetFullScreenSizes"))
assert(loadstring("local MDT,db=...; local sizex,sizey=840,555;\n"..scaling))(native,db)
assert(loadstring(read(reference.."/Modules/Maximize.lua")))("MythicDungeonTools",native)
f.maximizeButton:SetOnMaximizedCallback(native.Maximize)
f.maximizeButton:SetOnMinimizedCallback(native.Minimize)
local search={container=CreateFrame("Frame",nil,f.topPanel),editBox=CreateFrame("Frame"),results=CreateFrame("Frame")}
local addon={}
assert(loadstring(read("MDT_QoL_Compact.lua"),"@MDT_QoL_Compact.lua"))("MDT_QoL",addon)
local compact=addon.Compact
compact.Update(native,search)
assert(compact.Status()=="ready")
local resizerParent=f.resizer:GetParent()
local normalSizeScript=f:GetScript("OnSizeChanged")
local function settle() advance(.1); advance(.1); advance(2.1) end
local function near(a,b) assert(math.abs(a-b)<0.001,tostring(a).." ~= "..tostring(b)) end
local function checkNormal()
  assert(not compact.IsActive())
  assert(f.sidePanel:IsShown() and f.topPanel:IsShown() and f.navigationSidebar:IsShown())
  assert(not f.sublevelSelectionGroup.frame:IsShown(), "previously hidden controls stay hidden")
  assert(f.resizer:GetParent()==resizerParent and f.closeButton:GetPoint(1)=="TOPRIGHT")
  assert(select(2,f.closeButton:GetPoint())==f.sidePanel)
  assert(f:GetScript("OnSizeChanged")==normalSizeScript)
  near(f:GetWidth(),840); near(f:GetLeft(),200); near(f:GetTop(),900)
  assert(db.nonFullscreenScale==1 and db.maximized==false)
end
compact.Toggle(); settle()
assert(compact.IsActive() and not f.sidePanel:IsShown() and not f.topPanel:IsShown())
assert(not dungeonButton:IsShown() and not f.toolbar:IsShown() and not search.container:IsShown())
assert(f.closeButton:IsVisible() and f.maximizeButton:IsVisible() and f.resizer:IsVisible())
assert(f.resizer:GetParent()==f)
near(f.mapPanelFrame:GetScale(),2.5); near(f.scrollFrame:GetHorizontalScroll(),140)
-- Native OnShow attempts must not bring panels back, nor stack hooks.
local initialHooks=hooks
for i=1,20 do f.sidePanel:Show(); f.toolbar:Show(); dungeonButton:Show() end
assert(not f.sidePanel:IsShown() and hooks==initialHooks)
local resizerDown=f.resizer:GetScript("OnMouseDown")
local resizerUp=f.resizer:GetScript("OnMouseUp")
resizerDown(f.resizer,"LeftButton"); f:SetHeight(350); resizerUp(f.resizer,"LeftButton"); settle()
near(f:GetWidth(),840*350/555)
near(f.mapPanelFrame:GetScale(),2.5); near(f.scrollFrame:GetHorizontalScroll(),140*350/555)
local compactWidth=f:GetWidth()
local header=f.closeButton:GetParent()
header:GetScript("OnDragStart")()
f:ClearAllPoints(); f:SetPoint("TOPLEFT",UIParent,"BOTTOMLEFT",1000,650)
header:GetScript("OnDragStop")()
near(MDT_QoLDB.compact.geometry.x,1000)
compact.Toggle(); settle(); checkNormal()
compact.Toggle(); settle(); near(f:GetWidth(),compactWidth); near(f:GetLeft(),1000)
f.maximizeButton:Maximize(); settle()
assert(compact.IsActive() and not f.resizer:IsShown() and not f.maximizeButton.isMinimized)
assert(f:GetWidth()<=UIParent:GetWidth() and not f.sidePanel:IsShown())
f.maximizeButton:Minimize(); settle(); near(f:GetWidth(),compactWidth); near(f:GetLeft(),1000)
f.closeButton:GetScript("OnClick")(); assert(not f:IsShown())
f:Show(); f.toolbar:Show(); compact.Update(native,search)
assert(compact.IsActive() and not f.toolbar:IsShown() and f.closeButton:IsVisible())
compact.Toggle(); settle(); checkNormal()
-- Enter from native fullscreen; exit restores native fullscreen + windowed layout.
f.maximizeButton:Maximize(); settle()
local fullscreenWidth=f:GetWidth()
compact.Toggle(); settle(); compact.Toggle(); settle()
assert(db.maximized and not f.resizer:IsShown() and f.blackoutFrame:IsShown())
near(f:GetWidth(),fullscreenWidth)
f.maximizeButton:Minimize(); settle(); checkNormal()
-- Player input cancels deferred viewport restoration.
compact.Toggle()
f.scrollFrame:GetScript("OnMouseDown")(f.scrollFrame,"LeftButton")
settle(); near(f.mapPanelFrame:GetScale(),1)
compact.Toggle(); settle()
-- A changed dungeon must never receive the old map's viewport.
f.mapPanelFrame:SetScale(3); compact.Toggle(); db.currentDungeonIdx=2
settle(); near(f.mapPanelFrame:GetScale(),1)
compact.Toggle(); settle(); db.currentDungeonIdx=1
-- Reload/logout keeps compact preferences but restores MDT's normal saved geometry.
compact.Toggle(); settle()
for _,frame in ipairs(frames) do if frame.events.PLAYER_LOGOUT then frame:GetScript("OnEvent")(frame,"PLAYER_LOGOUT") end end
assert(MDT_QoLDB.compact.enabled and db.nonFullscreenScale==1 and db.xoffset==200 and not db.maximized)
compact.Toggle(); settle(); checkNormal()
-- Closing during a resize must stop sizing and restore the temporary handler.
compact.Toggle(); settle()
resizerDown(f.resizer,"LeftButton"); f:SetHeight(370)
f:Hide(); settle(); assert(not f.sizing)
f:Show(); compact.Toggle(); settle(); checkNormal()
-- Fail safely if a native callback changes or fails: panels and controls return.
local originalEnemyUpdate=native.UpdateEnemyInfoFrame
native.UpdateEnemyInfoFrame=function() error("simulated MDT failure") end
compact.Toggle()
assert(not compact.IsActive() and f.sidePanel:IsShown() and f.closeButton:IsVisible())
assert(#errors==1 and errors[1]:find("simulated MDT failure",1,true))
errors={}; native.UpdateEnemyInfoFrame=originalEnemyUpdate
compact.Toggle(); settle(); compact.Toggle(); settle(); checkNormal()
local frameCount,hookCount=#frames,hooks
collectgarbage("collect"); local memory=collectgarbage("count")
for i=1,100 do compact.Toggle(); settle(); compact.Toggle(); settle() end
collectgarbage("collect")
assert(#frames==frameCount and hooks==hookCount, "switching must not allocate UI objects or stack hooks")
assert(collectgarbage("count")-memory<32,"retained memory must stay bounded")
checkNormal(); assert(#errors==0,table.concat(errors,"\n"))
io.write("PASS: actual MDT resize/maximize callbacks; compact panels and controls; viewport async reset/input cancellation; independent geometry; fullscreen; reopen; logout; 100 cycles without frame/hook growth\n")

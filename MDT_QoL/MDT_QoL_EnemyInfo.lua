local _, addon = ...

local Reader = {}
addon.EnemyInfoReader = Reader

local PANEL_PADDING = 10
local HEADER_HEIGHT = 34
local CARD_GAP = 10
local CARD_MIN_HEIGHT = 96
local TWO_COLUMN_WIDTH = 720
local SCROLLBAR_GUTTER = 22
local VARIANT_SIZE = 26
local VARIANT_GAP = 5

local requested, requestedAt, wasVisible, controller = false, nil, false, nil

local strings = {
  enUS = {
    title = "Abilities",
    loading = "Loading description...",
    unavailable = "No description is available for this spell.",
  },
  ruRU = {
    title = "Способности",
    loading = "Описание загружается...",
    unavailable = "Для этого заклинания нет доступного описания.",
  },
}

local statusOrder = { "interruptible", "magic", "poison", "disease", "curse", "bleed", "enrage" }
local statusAtlases = {
  interruptible = "icons_16x16_interrupt",
  magic = "icons_16x16_magic",
  poison = "icons_16x16_poison",
  disease = "icons_16x16_disease",
  curse = "icons_16x16_curse",
  bleed = "icons_16x16_bleed",
  enrage = "icons_16x16_enrage",
}

local function text()
  local locale = GetLocale and GetLocale() or "enUS"
  return strings[locale] or strings.enUS
end

local function safeSpellValue(method, spellId)
  if not C_Spell or type(C_Spell[method]) ~= "function" then return nil end
  local ok, value = pcall(C_Spell[method], spellId)
  return ok and value or nil
end

local function spellDescription(spellId)
  local description = safeSpellValue("GetSpellDescription", spellId)
  if description and description ~= "" then return description end
  if C_Spell and type(C_Spell.IsSpellDataCached) == "function"
    and not C_Spell.IsSpellDataCached(spellId) then
    return text().loading
  end
  return text().unavailable
end

local function childText(child, key)
  local region = child and child[key]
  return region and type(region.GetText) == "function" and region:GetText() or nil
end

local function childTexture(child)
  local region = child and child.icon
  return region and type(region.GetTexture) == "function" and region:GetTexture() or nil
end

local function statusMarkup(child)
  local result = {}
  for _, key in ipairs(statusOrder) do
    if child[key] then
      if type(CreateAtlasMarkup) == "function" then
        result[#result + 1] = CreateAtlasMarkup(statusAtlases[key], 14, 14)
      else
        result[#result + 1] = "•"
      end
    end
  end
  return table.concat(result, " ")
end

local function readEntries(widget)
  local children = widget and widget.spellScroll and widget.spellScroll.children
  if type(children) ~= "table" then return nil, nil end
  local entries, groupsByName, signature, abilityCount = {}, {}, {}, 0
  for _, child in ipairs(children) do
    local spellId = tonumber(child and child.spellId)
    if spellId then
      local name = childText(child, "title")
      if not name or name == "" then name = safeSpellValue("GetSpellName", spellId) end
      if not name or name == "" then name = string.format("Spell #%d", spellId) end
      local icon = childTexture(child) or safeSpellValue("GetSpellTexture", spellId)
      local flags = {}
      for _, key in ipairs(statusOrder) do flags[#flags + 1] = child[key] and "1" or "0" end
      local entry = {
        spellId = spellId,
        name = name,
        icon = icon,
        status = statusMarkup(child),
        description = spellDescription(spellId),
      }
      local group = groupsByName[name]
      if not group then
        group = {
          spellId = entry.spellId,
          name = entry.name,
          icon = entry.icon,
          status = entry.status,
          description = entry.description,
          variants = {},
        }
        groupsByName[name] = group
        entries[#entries + 1] = group
      end
      group.variants[#group.variants + 1] = entry
      abilityCount = abilityCount + 1
      signature[#signature + 1] = tostring(spellId) .. ":" .. name .. ":" .. table.concat(flags)
    end
  end
  return entries, table.concat(signature, ","), abilityCount
end

local function hideOwnedTooltip(owner)
  if not GameTooltip then return end
  if type(GameTooltip.IsOwned) ~= "function" or GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

local function hideReaderTooltip()
  if not GameTooltip or type(GameTooltip.GetOwner) ~= "function" then return end
  local owner = GameTooltip:GetOwner()
  if owner and (owner.mdtQolEnemyInfoCard or owner.mdtQolEnemyInfoVariant) then GameTooltip:Hide() end
end

local function showVariantTooltip(button)
  local entry = button and button.variant
  if not entry or not GameTooltip then return end
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  if type(GameTooltip.ClearLines) == "function" then GameTooltip:ClearLines() end
  GameTooltip:AddLine(entry.name, 1, 0.82, 0)
  GameTooltip:AddLine(string.format("#%d", entry.spellId), 0.55, 0.55, 0.55)
  if entry.status ~= "" then GameTooltip:AddLine(entry.status, 1, 1, 1, true) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(entry.description, 1, 1, 1, true)
  GameTooltip:Show()
end

local function createVariantButton(card)
  local button = CreateFrame("Button", nil, card)
  button.mdtQolEnemyInfoVariant = true
  button:SetSize(VARIANT_SIZE, VARIANT_SIZE)
  button:EnableMouse(true)

  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(button)
  background:SetColorTexture(0.03, 0.03, 0.03, 0.95)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
  icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
  button.icon = icon

  local number = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  number:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 1)
  number:SetJustifyH("RIGHT")
  button.number = number

  button:SetScript("OnEnter", showVariantTooltip)
  button:SetScript("OnLeave", function(self) hideOwnedTooltip(self) end)
  button:Hide()
  return button
end

local function createCard(c)
  local card = CreateFrame("Button", nil, c.content)
  card.mdtQolEnemyInfoCard = true
  card:EnableMouse(true)

  local background = card:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(card)
  background:SetColorTexture(0.08, 0.08, 0.08, 0.94)
  card.background = background

  local border = card:CreateTexture(nil, "BORDER")
  border:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
  border:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, 0)
  border:SetHeight(1)
  border:SetColorTexture(0.85, 0.68, 0.16, 0.7)

  local icon = card:CreateTexture(nil, "ARTWORK")
  icon:SetSize(36, 36)
  icon:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -10)
  card.icon = icon

  local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
  title:SetPoint("RIGHT", card, "RIGHT", -10, 0)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  card.title = title

  local metadata = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  metadata:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
  metadata:SetPoint("RIGHT", card, "RIGHT", -10, 0)
  metadata:SetJustifyH("LEFT")
  metadata:SetWordWrap(false)
  card.metadata = metadata

  local description = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  description:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -58)
  description:SetJustifyH("LEFT")
  description:SetJustifyV("TOP")
  description:SetWordWrap(true)
  card.description = description

  card:SetScript("OnEnter", function(self)
    if not self.spellId or not GameTooltip or #(self.variants or {}) > 1 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetSpellByID(self.spellId)
    GameTooltip:Show()
  end)
  card:SetScript("OnLeave", function(self) hideOwnedTooltip(self) end)
  card.variantButtons = {}
  card:Hide()
  return card
end

local function install(widget)
  local frame = widget and widget.frame
  local middle = widget and widget.midContainer and widget.midContainer.frame
  local right = widget and widget.rightContainer and widget.rightContainer.frame
  if not (frame and middle and right and widget.spellScroll) then return nil end
  if controller and controller.widget == widget then return controller end
  if controller and controller.panel then controller.panel:Hide() end

  local c = { widget = widget, cards = {}, dirty = true }
  controller = c
  local panel = CreateFrame("Frame", nil, frame)
  c.panel = panel
  panel.mdtQolEnemyInfoReader = true
  panel:SetPoint("TOPLEFT", middle, "TOPLEFT", 0, 0)
  panel:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
  panel:SetFrameLevel(math.max(middle:GetFrameLevel(), right:GetFrameLevel()) + 40)
  panel:EnableMouse(true)
  if panel.SetClipsChildren then panel:SetClipsChildren(true) end

  local background = panel:CreateTexture(nil, "BACKGROUND")
  background:SetAllPoints(panel)
  background:SetColorTexture(0.015, 0.015, 0.015, 0.98)

  local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  heading:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PADDING, -8)
  heading:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PANEL_PADDING, -8)
  heading:SetJustifyH("LEFT")
  c.heading = heading

  local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PADDING, -HEADER_HEIGHT)
  scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PANEL_PADDING - SCROLLBAR_GUTTER, PANEL_PADDING)
  c.scroll = scroll
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(1, 1)
  scroll:SetScrollChild(content)
  c.content = content

  panel:HookScript("OnSizeChanged", function() c.layoutDirty = true end)
  frame:HookScript("OnHide", function()
    if controller == c then Reader.Closed() end
  end)
  panel:Hide()
  return c
end

local function updateCard(card, entry)
  card.spellId = entry.spellId
  card.variants = entry.variants
  local variantCount = #(entry.variants or {})
  card.title:SetText(variantCount > 1 and string.format("%s ×%d", entry.name, variantCount) or entry.name)
  card.icon:SetTexture(entry.icon)
  local metadata = string.format("#%d", entry.spellId)
  if entry.status ~= "" then metadata = metadata .. "   " .. entry.status end
  card.metadata:SetText(metadata)
  card.description:SetText(entry.description)

  if variantCount > 1 then
    for index, variant in ipairs(entry.variants) do
      local button = card.variantButtons[index] or createVariantButton(card)
      card.variantButtons[index] = button
      button.variant = variant
      button.icon:SetTexture(variant.icon)
      button.number:SetText(tostring(index))
      button:Show()
    end
  end
  local firstHidden = variantCount > 1 and variantCount + 1 or 1
  for index = firstHidden, #card.variantButtons do
    card.variantButtons[index].variant = nil
    card.variantButtons[index]:Hide()
  end
end

local function layout(c, entries, resetScroll)
  local panelWidth = c.panel:GetWidth() or 0
  local scrollWidth = math.max(1, panelWidth - (PANEL_PADDING * 2) - SCROLLBAR_GUTTER)
  local columns = scrollWidth >= TWO_COLUMN_WIDTH and 2 or 1
  local cardWidth = math.floor((scrollWidth - ((columns - 1) * CARD_GAP)) / columns)
  c.content:SetWidth(scrollWidth)

  for index, entry in ipairs(entries) do
    local card = c.cards[index] or createCard(c)
    c.cards[index] = card
    card:SetWidth(cardWidth)
    card.description:SetWidth(math.max(1, cardWidth - 20))
    updateCard(card, entry)
    local descriptionHeight = card.description.GetStringHeight and card.description:GetStringHeight() or 28
    local variantCount = #(entry.variants or {})
    local variantRows, variantHeight = 0, 0
    if variantCount > 1 then
      local variantsPerRow = math.max(1, math.floor((cardWidth - 20 + VARIANT_GAP) / (VARIANT_SIZE + VARIANT_GAP)))
      variantRows = math.ceil(variantCount / variantsPerRow)
      variantHeight = 10 + variantRows * VARIANT_SIZE + (variantRows - 1) * VARIANT_GAP
      for variantIndex, button in ipairs(card.variantButtons) do
        if variantIndex <= variantCount then
          local row = math.floor((variantIndex - 1) / variantsPerRow)
          local column = (variantIndex - 1) % variantsPerRow
          button:ClearAllPoints()
          button:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT",
            10 + column * (VARIANT_SIZE + VARIANT_GAP),
            10 + (variantRows - row - 1) * (VARIANT_SIZE + VARIANT_GAP))
        end
      end
    end
    card.desiredHeight = math.max(CARD_MIN_HEIGHT,
      70 + math.ceil(descriptionHeight or 0) + variantHeight)
    card:Show()
  end
  for index = #entries + 1, #c.cards do
    c.cards[index].spellId = nil
    c.cards[index].variants = nil
    c.cards[index]:Hide()
  end

  local y = 0
  for rowStart = 1, #entries, columns do
    local rowHeight = 0
    for column = 0, columns - 1 do
      local card = c.cards[rowStart + column]
      if card and card:IsShown() then rowHeight = math.max(rowHeight, card.desiredHeight) end
    end
    for column = 0, columns - 1 do
      local card = c.cards[rowStart + column]
      if card and card:IsShown() then
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", c.content, "TOPLEFT", column * (cardWidth + CARD_GAP), -y)
        card:SetHeight(rowHeight)
      end
    end
    y = y + rowHeight + CARD_GAP
  end
  c.content:SetHeight(math.max(1, y > 0 and y - CARD_GAP or 1))
  c.lastWidth, c.layoutDirty = panelWidth, false
  if resetScroll and c.scroll.SetVerticalScroll then c.scroll:SetVerticalScroll(0) end
end

local function refresh(c)
  local entries, signature, abilityCount = readEntries(c.widget)
  if not entries then
    c.panel:Hide()
    return
  end
  local changed = signature ~= c.signature
  local dirty = c.dirty
  if changed or dirty then
    c.entries, c.signature, c.abilityCount, c.dirty = entries, signature, abilityCount, false
    c.heading:SetText(string.format("%s (%d)", text().title, abilityCount))
  end
  local width = c.panel:GetWidth() or 0
  if changed or dirty or c.layoutDirty or c.lastWidth ~= width then layout(c, c.entries, changed) end
  c.panel:Show()
end

function Reader.OpenedByShortcut(widget)
  requested, requestedAt = true, GetTime and GetTime() or 0
  if widget and widget.frame and widget.frame:IsVisible() then
    wasVisible = true
    local c = install(widget)
    if c then refresh(c) end
  end
end

function Reader.Closed()
  requested, requestedAt, wasVisible = false, nil, false
  hideReaderTooltip()
  if controller and controller.panel then
    controller.panel:Hide()
    controller.signature = nil
    controller.dirty = true
  end
end

function Reader.SpellDataUpdated(spellId)
  if not requested or not controller then return end
  if not spellId then controller.dirty = true; return end
  for _, entry in ipairs(controller.entries or {}) do
    for _, variant in ipairs(entry.variants or {}) do
      if variant.spellId == spellId then controller.dirty = true; return end
    end
  end
end

function Reader.Update(widget)
  local visible = widget and widget.frame and widget.frame:IsVisible()
  if not visible then
    local now = GetTime and GetTime() or 0
    if wasVisible or (requested and requestedAt and now - requestedAt > 1) then Reader.Closed() end
    return
  end
  wasVisible = true
  if not requested then
    if controller and controller.panel then controller.panel:Hide() end
    return
  end
  local c = install(widget)
  if c then refresh(c) end
end

function Reader.Status()
  if requested and controller and controller.panel:IsVisible() then return "reading" end
  return controller and "ready" or "waiting for Enemy Info"
end

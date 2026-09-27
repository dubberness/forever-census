local _, NS = ...
local Charts = {}
NS.Charts = Charts

local CLASS_TEXTURE = "Interface\\TargetingFrame\\UI-Classes-Circles"
local RACE_TEXTURE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Races"

Charts.classColor = {
    WARRIOR = {0.78, 0.61, 0.43}, PALADIN = {0.96, 0.55, 0.73}, HUNTER = {0.67, 0.83, 0.45},
    ROGUE = {1.00, 0.96, 0.41}, PRIEST = {0.90, 0.90, 0.90}, SHAMAN = {0.00, 0.44, 0.87},
    MAGE = {0.25, 0.78, 0.92}, WARLOCK = {0.53, 0.53, 0.93}, DRUID = {1.00, 0.49, 0.04},
}

-- Standard four-by-four grid on UI-Classes-Circles.
Charts.classCoords = {
    WARRIOR = {0, 0.25, 0, 0.25}, MAGE = {0.25, 0.49609375, 0, 0.25},
    ROGUE = {0.49609375, 0.7421875, 0, 0.25}, DRUID = {0.7421875, 0.98828125, 0, 0.25},
    HUNTER = {0, 0.25, 0.25, 0.5}, SHAMAN = {0.25, 0.49609375, 0.25, 0.5},
    PRIEST = {0.49609375, 0.7421875, 0.25, 0.5}, WARLOCK = {0.7421875, 0.98828125, 0.25, 0.5},
    PALADIN = {0, 0.25, 0.5, 0.75},
}

Charts.raceColor = {
    Human = {0.42, 0.60, 0.90}, Dwarf = {0.80, 0.55, 0.35}, Gnome = {0.75, 0.45, 0.80},
    NightElf = {0.50, 0.40, 0.85}, Orc = {0.45, 0.70, 0.35}, Scourge = {0.55, 0.70, 0.60},
    Tauren = {0.72, 0.50, 0.30}, Troll = {0.35, 0.72, 0.72},
}

-- Male portraits from the character-creation sheet; the female row sits 0.5 lower.
Charts.raceCoords = {
    Human = {0, 0.125, 0, 0.25}, Dwarf = {0.125, 0.25, 0, 0.25},
    Gnome = {0.25, 0.375, 0, 0.25}, NightElf = {0.375, 0.5, 0, 0.25},
    Tauren = {0, 0.125, 0.25, 0.5}, Scourge = {0.125, 0.25, 0.25, 0.5},
    Troll = {0.25, 0.375, 0.25, 0.5}, Orc = {0.375, 0.5, 0.25, 0.5},
}

Charts.factionColor = {Alliance = {0.28, 0.45, 0.88}, Horde = {0.78, 0.20, 0.18}, Unknown = {0.55, 0.55, 0.55}}

-- Localized name to file string. Populated at login; the English keys below keep the
-- charts readable if C_CreatureInfo is unavailable on this build.
Charts.classFile = {Warrior = "WARRIOR", Paladin = "PALADIN", Hunter = "HUNTER", Rogue = "ROGUE",
    Priest = "PRIEST", Shaman = "SHAMAN", Mage = "MAGE", Warlock = "WARLOCK", Druid = "DRUID"}
Charts.raceFile = {Human = "Human", Orc = "Orc", Dwarf = "Dwarf", ["Night Elf"] = "NightElf",
    Undead = "Scourge", Scourge = "Scourge", Tauren = "Tauren", Gnome = "Gnome", Troll = "Troll"}
Charts.classOrder = {"Druid", "Hunter", "Mage", "Paladin", "Priest", "Rogue", "Shaman", "Warlock", "Warrior"}
Charts.raceOrder = {"Human", "Dwarf", "Gnome", "Night Elf", "Orc", "Undead", "Tauren", "Troll"}

-- Alliance first, then Horde, so the race chart splits down the middle.
local RACE_IDS = {1, 3, 7, 4, 2, 5, 6, 8}
local CLASS_IDS = {1, 2, 3, 4, 5, 7, 8, 9, 11}

function Charts.LoadTaxonomy()
    if not C_CreatureInfo then return end
    local classNames, raceNames = {}, {}
    for _, id in ipairs(CLASS_IDS) do
        local info = C_CreatureInfo.GetClassInfo(id)
        if info and info.className then
            classNames[#classNames + 1] = info.className
            Charts.classFile[info.className] = info.classFile or Charts.classFile[info.className]
        end
    end
    for _, id in ipairs(RACE_IDS) do
        local info = C_CreatureInfo.GetRaceInfo(id)
        if info and info.raceName then
            raceNames[#raceNames + 1] = info.raceName
            Charts.raceFile[info.raceName] = info.clientFileString or Charts.raceFile[info.raceName]
        end
    end
    table.sort(classNames)
    if #classNames > 0 then Charts.classOrder = classNames end
    if #raceNames > 0 then Charts.raceOrder = raceNames end
end

function Charts.ClassStyle(className)
    local file = Charts.classFile[className]
    return Charts.classColor[file] or {0.62, 0.62, 0.66}, file and CLASS_TEXTURE or nil, Charts.classCoords[file]
end

function Charts.RaceStyle(raceName)
    local file = Charts.raceFile[raceName]
    return Charts.raceColor[file] or {0.62, 0.62, 0.66}, file and RACE_TEXTURE or nil, Charts.raceCoords[file]
end

function Charts.ClassHex(className)
    local color = Charts.ClassStyle(className)
    return string.format("ff%02x%02x%02x", color[1] * 255, color[2] * 255, color[3] * 255)
end

local function fill(texture, r, g, b, a)
    if texture.SetColorTexture then texture:SetColorTexture(r, g, b, a)
    else texture:SetTexture(r, g, b, a) end
end

local function text(parent, x, y, width, font, justify)
    local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    f:SetPoint("TOPLEFT", x, y)
    f:SetWidth(width)
    f:SetJustifyH(justify or "LEFT")
    return f
end

-- A titled, faintly outlined box. Every chart and list below lives in one of these.
function Charts.Panel(parent, x, y, width, height, title)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetSize(width, height)
    panel:SetPoint("TOPLEFT", x, y)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(panel)
    fill(bg, 0.04, 0.04, 0.06, 0.55)
    -- Two opposite anchors give each edge its length; only the thickness is set here.
    for _, edge in ipairs({{"TOPLEFT", "TOPRIGHT", true}, {"BOTTOMLEFT", "BOTTOMRIGHT", true},
        {"TOPLEFT", "BOTTOMLEFT", false}, {"TOPRIGHT", "BOTTOMRIGHT", false}}) do
        local line = panel:CreateTexture(nil, "BORDER")
        line:SetPoint(edge[1])
        line:SetPoint(edge[2])
        if edge[3] then line:SetHeight(1) else line:SetWidth(1) end
        fill(line, 1, 1, 1, 0.10)
    end
    panel.title = text(panel, 10, -8, width - 20, "GameFontNormal")
    -- Titles change with the chart breakdown; a long one is cut short, never wrapped
    -- down into the bars.
    panel.title:SetMaxLines(1)
    panel.title:SetText(title or "")
    panel.footer = text(panel, 10, -(height - 16), width - 20, "GameFontDisableSmall")
    panel.width, panel.height = width, height
    return panel
end

local function showTooltip(self)
    if not self.lines or #self.lines == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self.lines[1], 1, 0.82, 0)
    for i = 2, #self.lines do GameTooltip:AddLine(self.lines[i], 1, 1, 1) end
    GameTooltip:Show()
end

local function hideTooltip() GameTooltip:Hide() end

-- Columns are built once at the requested capacity and then shown or hidden, so a
-- refresh never creates frames while the window is open.
local function buildColumns(panel, capacity, iconRow, labelFont)
    local top, bottom = 30, panel.height - 18 - iconRow
    panel.plotTop, panel.plotBottom = top, bottom
    panel.plotHeight = bottom - top
    panel.barCeiling = math.max(4, panel.plotHeight - 26)
    local base = panel:CreateTexture(nil, "ARTWORK")
    base:SetPoint("TOPLEFT", 10, -bottom)
    base:SetSize(panel.width - 20, 1)
    fill(base, 1, 1, 1, 0.18)
    panel.columns = {}
    for i = 1, capacity do
        local column = CreateFrame("Button", nil, panel)
        column:SetHeight(panel.plotHeight + iconRow)
        local hover = column:CreateTexture(nil, "BACKGROUND")
        hover:SetAllPoints(column)
        fill(hover, 1, 1, 1, 0.07)
        hover:Hide()
        column.bar = column:CreateTexture(nil, "ARTWORK")
        column.bar:SetPoint("BOTTOM", column, "BOTTOM", 0, iconRow)
        column.value = column:CreateFontString(nil, "OVERLAY", labelFont or "GameFontHighlightSmall")
        column.value:SetPoint("BOTTOM", column.bar, "TOP", 0, 2)
        column.value:SetJustifyH("CENTER")
        column:SetScript("OnEnter", function(self) hover:Show(); showTooltip(self) end)
        column:SetScript("OnLeave", function() hover:Hide(); hideTooltip() end)
        panel.columns[i] = column
    end
    -- Widths and positions are recomputed per refresh, so a chart given six groups
    -- spreads them across the panel instead of leaving the slots of an unseen eighth.
    function panel:Layout(count)
        local slot = (self.width - 20) / math.max(1, count)
        for i, column in ipairs(self.columns) do
            column:ClearAllPoints()
            column:SetPoint("TOPLEFT", 10 + (i - 1) * slot + 1, -self.plotTop)
            column:SetWidth(math.max(4, slot - 2))
            column.bar:SetWidth(math.max(3, math.min(slot - 3, 34)))
        end
        self.slot = slot
    end
    panel:Layout(capacity)
end

-- A labelled bar chart with a portrait under each bar, as in the race and class panels.
--
-- Bars can be clicked: set panel.onSelect(key) to hear which, and panel.hint(key,
-- selected) to say in the tooltip what a click will do.
function Charts.BarChart(parent, x, y, width, height, title, capacity)
    local panel = Charts.Panel(parent, x, y, width, height, title)
    buildColumns(panel, capacity, 28)
    for _, column in ipairs(panel.columns) do
        column.icon = column:CreateTexture(nil, "ARTWORK")
        column.icon:SetSize(22, 22)
        column.icon:SetPoint("BOTTOM", column, "BOTTOM", 0, 2)
        column.name = column:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        column.name:SetPoint("BOTTOM", column, "BOTTOM", 0, 6)
        -- A standing gold wash behind the bar that is currently selected.
        column.mark = column:CreateTexture(nil, "BACKGROUND")
        column.mark:SetAllPoints(column)
        fill(column.mark, 1.00, 0.82, 0.00, 0.16)
        column.mark:Hide()
        column:SetScript("OnClick", function(self)
            if not (panel.onSelect and self.key) then return end
            panel.onSelect(self.key)
            -- The pointer is still over the bar, so redraw its tooltip for the new state.
            if self:IsShown() then showTooltip(self) end
        end)
        column:Hide()
    end
    -- entries: {key, count, percent}; style(key) returns colour, texture and tex coords.
    -- selected is the key to highlight, if any; scope names what the percentages are of.
    function panel:Update(entries, style, total, selected, scope)
        local peak, visible = 0, math.min(#entries, #self.columns)
        for _, entry in ipairs(entries) do peak = math.max(peak, entry.count) end
        self:Layout(math.max(1, visible))
        local accounted = 0
        for i, column in ipairs(self.columns) do
            local entry = i <= visible and entries[i] or nil
            if not entry then
                column.key = nil
                column:Hide()
            else
                accounted = accounted + entry.count
                local picked = selected ~= nil and entry.key == selected
                -- With something selected, everything else steps back a little.
                local faded = selected ~= nil and not picked
                local color, texture, coords = style(entry.key)
                -- Names come from the server or a sync partner; a stray | must not
                -- become a colour code.
                local label = (tostring(entry.key):gsub("|", "||"))
                column.key = entry.key
                column.mark:SetShown(picked)
                column.bar:SetHeight(math.max(2, peak > 0 and self.barCeiling * entry.count / peak or 2))
                fill(column.bar, color[1], color[2], color[3], entry.count == 0 and 0.25 or (faded and 0.45 or 0.95))
                column.value:SetText(string.format("%d\n|cffb0b0b0%.1f%%|r", entry.count, entry.percent))
                if texture then
                    column.icon:SetTexture(texture)
                    if coords then column.icon:SetTexCoord(unpack(coords)) end
                    column.icon:SetAlpha(entry.count == 0 and 0.35 or (faded and 0.55 or 1))
                    column.icon:Show()
                    column.name:SetText("")
                else
                    column.icon:Hide()
                    column.name:SetText(label)
                end
                column.lines = {label, string.format("%d characters", entry.count),
                    string.format("%.1f%% of %s", entry.percent, scope or "the current selection")}
                if self.hint then
                    column.lines[#column.lines + 1] = "|cff7fd97f" .. self.hint(entry.key, picked) .. "|r"
                end
                column:Show()
            end
        end
        -- Stating the total makes a gap visible: if the bars do not add up to the
        -- selection, a group is missing rather than quietly rounded away.
        if #entries == 0 then
            self.footer:SetText("No matching characters")
        else
            self.footer:SetText(string.format("%d of %d characters across %d groups%s",
                accounted, total, #entries,
                #entries > visible and string.format("  |  %d groups too many to draw", #entries - visible) or ""))
        end
    end
    return panel
end

-- One column per level, the shape of a realm's population at a glance.
function Charts.Histogram(parent, x, y, width, height, title)
    local Core = NS.Core
    local panel = Charts.Panel(parent, x, y, width, height, title)
    buildColumns(panel, Core.MAX_LEVEL, 16, "GameFontDisableSmall")
    for level, column in ipairs(panel.columns) do
        column.value:Hide()
        if level == 1 or level % 10 == 0 then
            local tick = column:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            tick:SetPoint("TOP", column, "BOTTOM", 0, 14)
            tick:SetText(level)
        end
    end
    function panel:Update(summary)
        local peak = math.max(1, summary.peakLevel)
        for level, column in ipairs(self.columns) do
            local count = summary.byLevel[level] or 0
            column.bar:SetHeight(math.max(1, self.barCeiling * count / peak))
            if level == Core.MAX_LEVEL then fill(column.bar, 0.65, 0.90, 1.00, 0.95)
            else fill(column.bar, 1.00, 0.82, 0.00, count > 0 and 0.90 or 0.18) end
            column.lines = {"Level " .. level, count .. " characters",
                string.format("%.1f%% of the current selection", summary.shown > 0 and count * 100 / summary.shown or 0)}
            column:Show()
        end
        self.footer:SetText(string.format("Peak %d at a single level  |  %d at level %d  |  average level %.1f",
            summary.peakLevel, summary.maxLevel, Core.MAX_LEVEL,
            summary.shown > 0 and summary.totalLevel / summary.shown or 0))
    end
    return panel
end

-- A scrolling two-column list (guilds, zones, passes). The wheel scrolls it; there is
-- no scrollbar because the row count is small and the panels are narrow.
--
-- Rows can be clicked the way chart bars can: an item with a `key` reports it to
-- panel.onSelect(key), panel.hint(key, selected) adds a line to its tooltip, and the
-- key passed to Update as `selected` is marked.
function Charts.List(parent, x, y, width, height, title, rowCount)
    local panel = Charts.Panel(parent, x, y, width, height, title)
    panel.offset, panel.items = 0, {}
    panel:EnableMouseWheel(true)
    panel.rows = {}
    for i = 1, rowCount do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(width - 20, 26)
        row:SetPoint("TOPLEFT", 10, -(28 + (i - 1) * 28))
        local hover = row:CreateTexture(nil, "BACKGROUND")
        hover:SetAllPoints(row)
        fill(hover, 1, 1, 1, 0.07)
        hover:Hide()
        row.mark = row:CreateTexture(nil, "BACKGROUND")
        row.mark:SetAllPoints(row)
        fill(row.mark, 1.00, 0.82, 0.00, 0.16)
        row.mark:Hide()
        row:SetScript("OnClick", function(self)
            if not (panel.onSelect and self.key) then return end
            panel.onSelect(self.key)
            if self:IsShown() then showTooltip(self) end
        end)
        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.left:SetPoint("TOPLEFT", 0, 0)
        row.left:SetWidth(width - 92)
        row.left:SetJustifyH("LEFT")
        row.left:SetMaxLines(1)
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("TOPLEFT", 0, -13)
        row.sub:SetWidth(width - 92)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetMaxLines(1)
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.right:SetPoint("TOPRIGHT", 0, -5)
        row.right:SetWidth(72)
        row.right:SetJustifyH("RIGHT")
        row:SetScript("OnEnter", function(self) hover:Show(); showTooltip(self) end)
        row:SetScript("OnLeave", function() hover:Hide(); hideTooltip() end)
        panel.rows[i] = row
    end
    local function draw()
        local maximum = math.max(0, #panel.items - rowCount)
        panel.offset = math.max(0, math.min(panel.offset, maximum))
        for i, row in ipairs(panel.rows) do
            local item = panel.items[i + panel.offset]
            if not item then
                row.key = nil
                row.mark:Hide()
                row:Hide()
            else
                row.left:SetText(item.left or "")
                row.sub:SetText(item.sub or "")
                row.right:SetText(item.right or "")
                local picked = item.key ~= nil and item.key == panel.selected
                row.key = item.key
                row.mark:SetShown(picked)
                row.lines = item.lines
                if item.key and item.lines and panel.hint then
                    -- A copy, so the hint never piles up on the item's own lines.
                    row.lines = {}
                    for n, line in ipairs(item.lines) do row.lines[n] = line end
                    row.lines[#row.lines + 1] = "|cff7fd97f" .. panel.hint(item.key, picked) .. "|r"
                end
                row:Show()
            end
        end
        panel.footer:SetText(#panel.items > rowCount
            and string.format("%d-%d of %d  |  scroll to see more", panel.offset + 1, math.min(#panel.items, panel.offset + rowCount), #panel.items)
            or (#panel.items == 0 and panel.emptyText or string.format("%d shown", #panel.items)))
    end
    panel:SetScript("OnMouseWheel", function(_, delta)
        panel.offset = panel.offset - delta * 3
        draw()
    end)
    function panel:Update(items, emptyText, selected)
        self.items, self.emptyText, self.selected = items, emptyText or "Nothing recorded yet", selected
        draw()
    end
    return panel
end

-- One column per day, oldest on the left: how quickly the census has grown.
-- entries: {count, tick (a label under the column, or nil), lines (its tooltip)}.
function Charts.Timeline(parent, x, y, width, height, title, capacity)
    local panel = Charts.Panel(parent, x, y, width, height, title)
    buildColumns(panel, capacity, 16, "GameFontDisableSmall")
    for _, column in ipairs(panel.columns) do
        column.tick = column:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        column.tick:SetPoint("TOP", column, "BOTTOM", 0, 14)
        column:Hide()
    end
    function panel:Update(entries, footer)
        local peak = 1
        for _, entry in ipairs(entries) do peak = math.max(peak, entry.count) end
        for i, column in ipairs(self.columns) do
            local entry = entries[i]
            if not entry then
                column:Hide()
            else
                column.bar:SetHeight(math.max(1, self.barCeiling * entry.count / peak))
                fill(column.bar, 0.39, 0.85, 0.77, entry.count > 0 and 0.90 or 0.18)
                column.value:SetText(entry.count > 0 and tostring(entry.count) or "")
                column.tick:SetText(entry.tick or "")
                column.lines = entry.lines
                column:Show()
            end
        end
        self.footer:SetText(footer or "")
    end
    return panel
end

-- A table with a header row, for putting census passes side by side. Its columns come
-- with each update, so it can show whichever classes the data holds. The wheel scrolls
-- it, as with Charts.List.
-- columns: {text, width, justify}; items: {cells = {...}, lines = tooltip}.
function Charts.Table(parent, x, y, width, height, title, rowCount, maxColumns)
    local panel = Charts.Panel(parent, x, y, width, height, title)
    panel.offset, panel.items = 0, {}
    panel:EnableMouseWheel(true)
    panel.headers, panel.rows = {}, {}
    for c = 1, maxColumns do
        local header = text(panel, 10, -30, 40, "GameFontNormalSmall")
        header:SetMaxLines(1)
        panel.headers[c] = header
    end
    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", 10, -45)
    rule:SetSize(width - 20, 1)
    fill(rule, 1, 1, 1, 0.12)
    panel.empty = text(panel, 10, -64, width - 20, "GameFontDisable", "CENTER")
    for i = 1, rowCount do
        local row = CreateFrame("Button", nil, panel)
        row:SetSize(width - 20, 24)
        row:SetPoint("TOPLEFT", 10, -(48 + (i - 1) * 26))
        local hover = row:CreateTexture(nil, "BACKGROUND")
        hover:SetAllPoints(row)
        fill(hover, 1, 1, 1, 0.07)
        hover:Hide()
        row.cells = {}
        for c = 1, maxColumns do
            local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            cell:SetMaxLines(1)
            row.cells[c] = cell
        end
        row:SetScript("OnEnter", function(self) hover:Show(); showTooltip(self) end)
        row:SetScript("OnLeave", function() hover:Hide(); hideTooltip() end)
        row:Hide()
        panel.rows[i] = row
    end
    local function place(fontString, left, y, span, justify)
        fontString:ClearAllPoints()
        fontString:SetPoint("TOPLEFT", left, y)
        fontString:SetWidth(math.max(4, span))
        fontString:SetJustifyH(justify or "LEFT")
    end
    local function draw()
        local maximum = math.max(0, #panel.items - rowCount)
        panel.offset = math.max(0, math.min(panel.offset, maximum))
        for i, row in ipairs(panel.rows) do
            local item = panel.items[i + panel.offset]
            if not item then row:Hide() else
                for c, cell in ipairs(row.cells) do cell:SetText(item.cells[c] or "") end
                row.lines = item.lines
                row:Show()
            end
        end
        panel.empty:SetText(#panel.items == 0 and panel.emptyText or "")
        panel.footer:SetText(#panel.items > rowCount
            and string.format("%d-%d of %d  |  scroll to see more", panel.offset + 1, math.min(#panel.items, panel.offset + rowCount), #panel.items)
            or (#panel.items == 0 and "" or (panel.note or string.format("%d shown", #panel.items))))
    end
    panel:SetScript("OnMouseWheel", function(_, delta)
        panel.offset = panel.offset - delta * 3
        draw()
    end)
    function panel:Update(columns, items, emptyText, note)
        local left = 0
        for c, header in ipairs(self.headers) do
            local column = columns[c]
            if column then
                place(header, 10 + left, -30, column.width - 6, column.justify)
                header:SetText(column.text)
                header:Show()
                for _, row in ipairs(self.rows) do
                    place(row.cells[c], left, -6, column.width - 6, column.justify)
                    row.cells[c]:Show()
                end
                left = left + column.width
            else
                header:SetText("")
                header:Hide()
                for _, row in ipairs(self.rows) do
                    row.cells[c]:SetText("")
                    row.cells[c]:Hide()
                end
            end
        end
        self.columnsWidth = left
        self.items, self.emptyText, self.note = items, emptyText or "Nothing recorded yet", note
        draw()
    end
    return panel
end

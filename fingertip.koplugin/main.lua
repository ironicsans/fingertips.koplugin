--[[
Fingertip

While you hold and drag to select text, your fingertip covers the words you
are selecting. Fingertip:

  * draws a copy of the selection a little above it (a 1:1 copy of the page,
    not magnified), with a sliver of lighter context around it, in one panel
    whose outline steps with the lines;
  * shows handles at both ends of the selection from the moment you start;
  * when you lift your finger, replaces KOReader's highlight popup with a
    compact action bar above the selection, built from that same popup's
    buttons, in the order you choose, a set at a time (More shows the next
    set and wraps around);
  * lets you drag either handle to adjust the selection: the bar steps aside
    and the lifted copy comes back while you drag.

How it hooks in:
  * Drawing: a ReaderView "view module", painted after the page and its
    highlights on every repaint.
  * State: thin wrappers around this reader's ReaderHighlight instance
    (onHold, onHoldPan, onHoldRelease, clear, onShowHighlightMenu). The
    originals still do all the selecting; Fingertip only draws, and shows
    its bar where KOReader would show its popup.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Actions = require("fingertip_actions")
local Arrange = require("fingertip_arrange")
local Bar = require("fingertip_bar")
local Panel = require("fingertip_panel")

local Screen = Device.screen

-- How far the copy is lifted, in line heights (measured top to top).
local LIFT = 2.25

-- What the lifted copy shows while you drag: just the word under your finger
-- (it moves along with you, like the iOS loupe), or the whole selection.
local PANEL_CHOICES = {
    { text = _("Around your finger"), value = "word" },
    { text = _("Whole selection"), value = "selection" },
}
local DEFAULT_PANEL = "word"
-- Width of the "Around your finger" copy, in letters, centred on the word
-- under the finger (a long word may not fit). A letter is taken as 0.4 of
-- the line height, about right for book fonts at normal line spacing.
local FOLLOW_LETTERS = 10
local LETTER_PER_LINE = 0.4

-- Outline thickness and corner radius, in KOReader's screen-scaled units
-- (Screen:scaleBySize), so they look about the same size on any screen.
local BORDER_CHOICES = {
    { text = _("Thin"), value = 2 },
    { text = _("Medium"), value = 3 },
    { text = _("Thick"), value = 5 },
    { text = _("Extra thick"), value = 7 },
}
local DEFAULT_BORDER = 3

local RADIUS_CHOICES = {
    { text = _("Square"), value = 0 },
    { text = _("Slight"), value = 5 },
    { text = _("Medium"), value = 9 },
    { text = _("Round"), value = 14 },
}
local DEFAULT_RADIUS = 9

local SHADOW_CHOICES = {
    { text = _("None"), value = "none" },
    { text = _("Hard"), value = "hard" },
    { text = _("Soft"), value = "soft" },
}
local DEFAULT_SHADOW = "none"

local Fingertip = WidgetContainer:extend{
    name = "fingertip",
    is_doc_only = true,
}

function Fingertip:init()
    self.enabled = G_reader_settings:nilOrTrue("fingertip_enabled")
    self.lift = LIFT
    self.panel_mode = G_reader_settings:readSetting("fingertip_panel_mode", DEFAULT_PANEL)
    self.finger_pos = nil -- page position of the finger (or dragged handle)
    self.finger_word = nil -- screen box of the last word found there
    self.border = G_reader_settings:readSetting("fingertip_border", DEFAULT_BORDER)
    self.radius = G_reader_settings:readSetting("fingertip_radius", DEFAULT_RADIUS)
    self.shadow = G_reader_settings:readSetting("fingertip_shadow", DEFAULT_SHADOW)
    -- nil: nothing shown; "drag": selecting (panel + handles);
    -- "bar": action bar shown (handles); "handle": dragging a handle (panel + handles)
    self.phase = nil
    self.layout = nil -- what to draw
    self.key = nil    -- fingerprint of the layout, to skip redundant refreshes
    self.bar = nil
    self.ui.menu:registerToMainMenu(self)
end

function Fingertip:onReaderReady()
    self.ui.view:registerViewModule("fingertip", self)
    self:wrapHighlight()
end

function Fingertip:wrapHighlight()
    local hl = self.ui.highlight
    if not hl or hl._fingertip_wrapped then return end
    hl._fingertip_wrapped = true
    local plugin = self

    -- Wrapping the instance (not the class) keeps this local to the open
    -- book, and the touch zones call hl:onHold() etc., so they reach us.
    local orig_onHold = hl.onHold
    hl.onHold = function(this, ...)
        local ret = orig_onHold(this, ...)
        plugin.finger_word = nil
        plugin.finger_pos = nil
        plugin.finger_key = nil
        plugin.panned = false
        if this.hold_pos and this.selected_text then
            plugin.phase = "drag"
            local p = this.hold_pos
            plugin.finger_pos = { x = p.x, y = p.y, page = p.page }
        end
        plugin:update()
        return ret
    end

    local orig_onHoldPan = hl.onHoldPan
    hl.onHoldPan = function(this, arg, ges, ...)
        local ret = orig_onHoldPan(this, arg, ges, ...)
        if this.holdpan_pos then plugin.panned = true end
        if ges and ges.pos then plugin:setFingerScreenPos(ges.pos.x, ges.pos.y) end
        plugin:update()
        return ret
    end

    local orig_onHoldRelease = hl.onHoldRelease
    hl.onHoldRelease = function(this, ...)
        -- Finger lifted: drop the panel before whatever comes next.
        if plugin.phase == "drag" then
            plugin.phase = nil
            plugin:update()
        end
        return orig_onHoldRelease(this, ...)
    end

    local orig_clear = hl.clear
    hl.clear = function(this, ...)
        local ret = orig_clear(this, ...)
        plugin:closeBar()
        plugin.phase = nil
        plugin:update()
        return ret
    end

    -- Where KOReader would open its popup for a new selection, show the bar.
    -- (With an index, it's the popup for an existing highlight: left alone.)
    local orig_onShowHighlightMenu = hl.onShowHighlightMenu
    hl.onShowHighlightMenu = function(this, index, ...)
        if index == nil and plugin.enabled and this.selected_text and this.hold_pos then
            local ok, shown = pcall(plugin.showBar, plugin)
            if ok and shown then return true end
            if not ok then
                logger.warn("Fingertip: could not show the action bar:", shown)
                plugin:closeBar()
                plugin.phase = nil
                plugin:update()
            end
        end
        return orig_onShowHighlightMenu(this, index, ...)
    end
end

-- Screen rectangles of the current selection, one per line, top to bottom.
function Fingertip:getLineBoxes()
    local hl = self.ui.highlight
    local sel = hl.selected_text
    if not (hl.hold_pos and sel and sel.sboxes and #sel.sboxes > 0) then
        return nil
    end
    local boxes = {}
    for i = 1, #sel.sboxes do
        -- sboxes are already screen boxes with crengine (EPUB...), and page
        -- boxes with PDF/DjVu; this converts the latter and passes the former.
        local r = self.ui.view:pageToScreenTransform(hl.hold_pos.page, sel.sboxes[i])
        if r and r.w > 0 and r.h > 0 then
            table.insert(boxes, Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h })
        end
    end
    if #boxes == 0 then return nil end

    -- A line can come back as several segments (inline styles, links...):
    -- merge segments that share a line into one box.
    table.sort(boxes, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    local lines = {}
    for i = 1, #boxes do
        local b = boxes[i]
        local last = lines[#lines]
        local b_mid = b.y + b.h / 2
        if last and b_mid > last.y and b_mid < last.y + last.h then
            lines[#lines] = last:combine(b)
        else
            table.insert(lines, b)
        end
    end
    return lines
end

function Fingertip:setFingerScreenPos(x, y)
    local p = self.ui.view:screenToPageTransform(Geom:new{ x = x, y = y, w = 0, h = 0 })
    if p then self.finger_pos = { x = p.x, y = p.y, page = p.page } end
end

-- Screen box of the word under the finger. Between words (or past the end
-- of a line) there's none: keep the last one, so the copy doesn't flicker.
function Fingertip:getFingerWordBox()
    local pos = self.finger_pos
    local key = pos and string.format("%s,%s,%s", pos.x, pos.y, tostring(pos.page))
    if pos and key ~= self.finger_key then
        self.finger_key = key
        local doc = self.ui.document
        local ok, word = pcall(doc.getWordFromPosition, doc, { x = pos.x, y = pos.y, page = pos.page }, true)
        -- With crengine, looking a word up changes the reader's selection
        -- (it clears it, or selects that word): put it back as it was.
        if self.ui.rolling then self:restoreSelection() end
        local box = ok and word and (word.sbox or word.pbox)
        if box then
            local r = self.ui.view:pageToScreenTransform(pos.page, box)
            if r and r.w > 0 and r.h > 0 then
                self.finger_word = Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h }
            end
        end
    end
    return self.finger_word
end

-- Redo the selection the way ReaderHighlight made it: from the hold point to
-- the last drag point, or just the held word if there was no drag yet.
function Fingertip:restoreSelection()
    local hl = self.ui.highlight
    local doc = self.ui.document
    if not hl.hold_pos then return end
    if self.panned and hl.holdpan_pos then
        pcall(doc.getTextFromPositions, doc, hl.hold_pos, hl.holdpan_pos)
    else
        pcall(doc.getWordFromPosition, doc, hl.hold_pos)
    end
end

-- Recompute what to show for the current phase and selection, and ask for a
-- refresh of the affected area only if something actually changed.
function Fingertip:update()
    local layout
    if self.enabled and self.phase then
        local lines = self:getLineBoxes()
        if lines then
            local with_panel = self.phase == "drag" or self.phase == "handle"
            local panel_lines
            if with_panel and self.panel_mode == "word" then
                local wb = self:getFingerWordBox() or lines[#lines]
                local w = math.floor(FOLLOW_LETTERS * LETTER_PER_LINE * wb.h + 0.5)
                local x = math.floor(wb.x + wb.w / 2 - w / 2 + 0.5)
                x = math.max(0, math.min(Screen:getWidth() - w, x))
                panel_lines = { Geom:new{ x = x, y = wb.y, w = w, h = wb.h } }
            end
            layout = Panel.computeLayout(lines, {
                lift = self.lift,
                border = self.border,
                radius = self.radius,
                shadow = self.shadow,
                with_panel = with_panel,
                with_handles = true,
                panel_lines = panel_lines,
                -- the fixed window already includes its context sideways
                panel_ctx_side = panel_lines and 0 or nil,
            })
        end
    end
    if layout and self.layout and layout.key == self.key then return end
    local old = self.layout
    self.layout, self.key = layout, layout and layout.key
    local dirty = layout and layout.region
    if old then dirty = dirty and dirty:combine(old.region) or old.region end
    if dirty then
        UIManager:setDirty(self.ui.highlight.dialog, "ui", dirty)
    end
end

-- Called by ReaderView after it has drawn the page and the highlights.
function Fingertip:paintTo(bb, x, y)
    if not self.layout then return end
    local ok, err = pcall(Panel.paint, bb, x, y, self.layout)
    if not ok then logger.warn("Fingertip: paint failed:", err) end
end

---------------------------------------------------------------------------
-- Action bar
---------------------------------------------------------------------------

function Fingertip:showBar()
    local hl = self.ui.highlight
    if not self:getLineBoxes() then return false end
    local actions = Actions.forBar(hl)
    if #actions == 0 then return false end
    self:closeBar()
    self.phase = "bar"
    self:update()
    local bar = Bar:new{
        plugin = self,
        hl = hl,
        actions = actions,
        rows = Actions.rows(),
        border = self.border,
        radius = self.radius,
    }
    self.bar = bar
    hl.highlight_dialog = bar -- so KOReader's own actions close it when done
    UIManager:show(bar, "ui", bar.bar_rect)
    return true
end

function Fingertip:closeBar()
    if self.bar then
        UIManager:close(self.bar) -- onBarClosed() does the rest
    end
end

function Fingertip:onBarClosed(bar)
    if self.bar ~= bar then return end
    self.bar = nil
    local hl = self.ui.highlight
    if hl.highlight_dialog == bar then hl.highlight_dialog = nil end
    if self.phase == "bar" or self.phase == "handle" then
        self.phase = nil
        self:update()
    end
end

-- Where the bar goes: above the selection, as far from it as the panel is;
-- below it if there's no room above; centred over it, kept on screen.
function Fingertip:barPosition(w, h)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin = Screen:scaleBySize(6)
    local lines = self:getLineBoxes()
    if not lines then
        return math.floor((sw - w) / 2), math.floor((sh - h) / 2)
    end
    local line_h = Panel.averageLineHeight(lines)
    local hg = Panel.handleGeometry(lines)
    local border = math.max(1, Screen:scaleBySize(self.border))
    local gap = math.floor(line_h * (self.lift - 1 - Panel.CONTEXT_V) + 0.5) - border
    gap = math.max(gap, 2 * hg.r + Screen:scaleBySize(4))
    local top = lines[1].y
    local bottom = lines[#lines].y + lines[#lines].h
    local left, right = math.huge, -math.huge
    for _, l in ipairs(lines) do
        left = math.min(left, l.x)
        right = math.max(right, l.x + l.w)
    end
    local y
    if top - gap - h >= 0 then
        y = top - gap - h
    elseif bottom + gap + h <= sh then
        y = bottom + gap
    elseif top > sh - bottom then
        y = 0
    else
        y = sh - h
    end
    local x = math.floor((left + right - w) / 2)
    x = math.max(margin, math.min(sw - margin - w, x))
    return x, math.floor(y)
end

---------------------------------------------------------------------------
-- Handles
---------------------------------------------------------------------------

-- The handle under pos, if any: { which = "start"|"stop", dx, dy }, where
-- (dx, dy) leads from pos to the selection edge that handle marks.
function Fingertip:handleAt(pos)
    local layout = self.layout
    if not (layout and layout.handles and pos) then return nil end
    local hg = layout.handles
    local lines = self:getLineBoxes()
    if not lines then return nil end
    local reach = math.max(Screen:scaleBySize(28), Panel.averageLineHeight(lines))
    local best, best_d
    for _, which in ipairs({ "start", "stop" }) do
        local hd = hg[which]
        local y0 = math.min(hd.top, hd.knob_y - hg.r)
        local y1 = math.max(hd.bottom, hd.knob_y + hg.r)
        local ddx = pos.x - hd.x
        local ddy = 0
        if pos.y < y0 then ddy = y0 - pos.y elseif pos.y > y1 then ddy = pos.y - y1 end
        local d = math.sqrt(ddx * ddx + ddy * ddy)
        if d <= reach and (not best_d or d < best_d) then
            best, best_d = which, d
        end
    end
    if not best then return nil end
    local hd = hg[best]
    local ex = best == "start" and hd.x + 1 or hd.x - 1
    local ey = math.floor((hd.top + hd.bottom) / 2)
    return { which = best, dx = ex - pos.x, dy = ey - pos.y }
end

-- Dragging one handle means the other end stays put: make that end the
-- point KOReader extends the selection from, as if the hold started there.
function Fingertip:beginHandleDrag(which)
    local hl = self.ui.highlight
    local lines = self:getLineBoxes()
    if not lines then return end
    local ax, ay
    if which == "stop" then
        local l = lines[1]
        ax, ay = l.x + 1, l.y + l.h / 2
    else
        local l = lines[#lines]
        ax, ay = l.x + l.w - 1, l.y + l.h / 2
    end
    local anchor = self.ui.view:screenToPageTransform(Geom:new{ x = math.floor(ax), y = math.floor(ay), w = 0, h = 0 })
    if anchor then hl.hold_pos = anchor end
    -- The copy follows the end being dragged.
    local l = which == "stop" and lines[#lines] or lines[1]
    local ex = which == "stop" and l.x + l.w - 1 or l.x + 1
    self.finger_word = nil
    self:setFingerScreenPos(math.floor(ex), math.floor(l.y + l.h / 2))
    -- ...and so does the selection's moving end, until the first move.
    local p = self.finger_pos
    if p then
        hl.holdpan_pos = Geom:new{ x = p.x, y = p.y, w = 0, h = 0 }
        hl.holdpan_pos.page = p.page
        self.panned = true
    end
    self.phase = "handle"
    self:update()
end

function Fingertip:moveHandle(pos)
    self.ui.highlight:onHoldPan(nil, { ges = "hold_pan", pos = pos })
end

function Fingertip:endHandleDrag()
    -- KOReader's long-hold timer is restarted by every selection change;
    -- stop it, as a normal release would.
    local hl = self.ui.highlight
    if hl._resetHoldTimer then pcall(hl._resetHoldTimer, hl, true) end
    self.phase = "bar"
    self:update()
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

-- A "Name: current value" menu entry opening a list of choices.
-- field: the property on self; setting: the G_reader_settings key.
function Fingertip:choiceMenu(title, choices, field, setting)
    local function same(a, b)
        if type(a) == "number" and type(b) == "number" then
            return math.abs(a - b) < 0.01
        end
        return a == b
    end
    local items = {}
    for i = 1, #choices do
        local choice = choices[i]
        items[i] = {
            text = choice.text,
            radio = true,
            checked_func = function() return same(self[field], choice.value) end,
            callback = function()
                self[field] = choice.value
                G_reader_settings:saveSetting(setting, choice.value)
            end,
        }
    end
    return {
        text_func = function()
            for i = 1, #choices do
                if same(self[field], choices[i].value) then
                    return title .. ": " .. choices[i].text
                end
            end
            return title
        end,
        enabled_func = function() return self.enabled end,
        sub_item_table = items,
    }
end

function Fingertip:showArrange()
    -- Opened from the menu, which stays open underneath: refresh the whole
    -- screen, or e-ink only redraws the menu row that was tapped.
    UIManager:show(Arrange:new{ hl = self.ui.highlight }, "flashui")
end

function Fingertip:addToMainMenu(menu_items)
    menu_items.fingertip = {
        text = _("Fingertip"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Fingertip on"),
                help_text = _("Off: text selection works as it does without Fingertip."),
                checked_func = function() return self.enabled end,
                callback = function()
                    self.enabled = not self.enabled
                    G_reader_settings:saveSetting("fingertip_enabled", self.enabled)
                    if not self.enabled then
                        self:closeBar()
                        self.phase = nil
                        self:update()
                    end
                end,
                separator = true,
            },
            {
                text = _("Action bar"),
                enabled_func = function() return self.enabled end,
                keep_menu_open = true,
                callback = function() self:showArrange() end,
                separator = true,
            },
            self:choiceMenu(_("Lifted copy"), PANEL_CHOICES, "panel_mode", "fingertip_panel_mode"),
            self:choiceMenu(_("Outline thickness"), BORDER_CHOICES, "border", "fingertip_border"),
            self:choiceMenu(_("Corner rounding"), RADIUS_CHOICES, "radius", "fingertip_radius"),
            self:choiceMenu(_("Drop shadow"), SHADOW_CHOICES, "shadow", "fingertip_shadow"),
        },
    }
end

return Fingertip

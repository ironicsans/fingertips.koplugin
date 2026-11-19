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

-- What the lifted copy shows while you drag: the line you start on (it
-- grows as you drag along it and goes away when you reach another line), or
-- the whole selection.
local PANEL_CHOICES = {
    { text = _("One line"), value = "line" },
    { text = _("Whole selection"), value = "selection" },
}
local DEFAULT_PANEL = "line"

-- Line lock, in line heights from the middle of the line being selected.
-- Once you've dragged down past a line, the end of the selection keeps a
-- steady distance above your finger, both ways: a line is added when your
-- finger is about half a line below it (LOCK_PULL), and taken off again
-- when your finger comes back up to about that spot (LOCK_PUSH). The small
-- gap between the two only stops a wobble from flickering a line on and off.
-- With the start handle it's the same, mirrored: the finger stays above.
local LOCK_PULL = 2.0
local LOCK_PUSH = 0.7
-- Right after a long-press your finger is on the line itself: going up then
-- takes moving half a line past its top edge.
local LOCK_UP_FROM_ON = 1.0
-- Room to wobble before a push, when you grab a handle close to its line.
local LOCK_MARGIN = 0.3

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
    if self.panel_mode ~= "selection" then self.panel_mode = "line" end
    self.finger = nil -- screen point of the finger (or the dragged handle)
    self.loupe_line_y = nil -- top of the line the drag started on
    self.loupe_hidden = false -- once the drag leaves that line, until the next one
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
    hl.onHold = function(this, arg, ges, ...)
        local ret = orig_onHold(this, arg, ges, ...)
        plugin:startLoupe(ges and ges.pos)
        if this.hold_pos and this.selected_text then
            plugin.phase = "drag"
        end
        plugin:update()
        return ret
    end

    local orig_onHoldPan = hl.onHoldPan
    hl.onHoldPan = function(this, arg, ges, ...)
        if not (plugin.enabled and ges and ges.pos and this.hold_pos) then
            return orig_onHoldPan(this, arg, ges, ...)
        end
        -- KOReader gets the line-locked point instead of the finger's own.
        local pos = plugin:lockedPoint(ges.pos)
        local locked = {}
        for k, v in pairs(ges) do locked[k] = v end
        locked.pos = pos
        local ret = orig_onHoldPan(this, arg, locked, ...)
        plugin:relock()
        -- The panel shows the line KOReader was given.
        plugin.finger = { x = pos.x, y = pos.y }
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
    local sboxes = sel.sboxes
    -- A long-pressed word comes with a single box, which for a word that
    -- wraps (Some-|where) covers both lines and the space between: ask
    -- crengine for that word's boxes line by line instead.
    if #sboxes == 1 and self.ui.rolling and type(sel.pos0) == "string" and type(sel.pos1) == "string" then
        local doc = self.ui.document
        local ok, per_line = pcall(doc.getScreenBoxesFromPositions, doc, sel.pos0, sel.pos1, true)
        if ok and per_line and #per_line > 0 then sboxes = per_line end
    end
    local boxes = {}
    for i = 1, #sboxes do
        -- sboxes are already screen boxes with crengine (EPUB...), and page
        -- boxes with PDF/DjVu; this converts the latter and passes the former.
        local r = self.ui.view:pageToScreenTransform(hl.hold_pos.page, sboxes[i])
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

-- A new gesture (a long-press, or grabbing a handle) brings the loupe back.
function Fingertip:startLoupe(pos, side)
    self.finger = pos and { x = pos.x, y = pos.y } or nil
    self.lock_side = side or "on"
    self.loupe_line_y = nil
    self.loupe_hidden = false
    self.lock = nil
    self.relock_y = nil
end

-- The selection's line under the finger, or the nearest one. Using the line
-- (not crengine's word box) keeps a word that wraps onto the next line from
-- stretching the loupe over both lines.
local function fingerLine(lines, finger)
    if not finger then return lines[#lines] end
    local best, best_d
    for _, l in ipairs(lines) do
        if finger.y >= l.y and finger.y < l.y + l.h then return l end
        local d = math.abs(finger.y - (l.y + l.h / 2))
        if not best_d or d < best_d then best, best_d = l, d end
    end
    return best
end

-- The "One line" panel: the selection on the line where the drag started,
-- growing as it grows. Nil once the drag has reached another line (like
-- iOS, it stays away until the next gesture).
function Fingertip:loupeLine(lines)
    if self.loupe_hidden then return nil end
    local line = fingerLine(lines, self.finger)
    if not self.loupe_line_y then
        self.loupe_line_y = line.y
    elseif math.abs(line.y - self.loupe_line_y) > line.h / 2 then
        self.loupe_hidden = true
        return nil
    end
    return line
end

-- Starts the line lock on a line, with the finger touching at touch_y.
function Fingertip:initLock(l, touch_y)
    local cy, h = l.y + l.h / 2, l.h
    local d0 = (touch_y - cy) / h
    local up, down
    if self.lock_side == "below" then
        up, down = math.min(LOCK_PUSH, d0 - LOCK_MARGIN), LOCK_PULL
    elseif self.lock_side == "above" then
        up, down = -LOCK_PULL, math.max(-LOCK_PUSH, d0 + LOCK_MARGIN)
    else
        up, down = -LOCK_UP_FROM_ON, LOCK_PULL
    end
    self.lock = { cy = cy, h = h, up = up, down = down }
end

-- Where to tell KOReader the finger is during a drag: the same left-right,
-- but on the middle of the line being selected until the finger has gone
-- far enough up or down to mean another line (see LOCK_PULL, LOCK_PUSH).
function Fingertip:lockedPoint(pos)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- KOReader's corners for selecting across pages: leave those alone.
    if (pos.y < sh / 8 or pos.y > sh * 7 / 8) and (pos.x < sw / 8 or pos.x > sw * 7 / 8) then
        self.lock = nil
        return pos
    end
    if not self.lock then
        local lines = self:getLineBoxes()
        if not lines then return pos end
        self:initLock(fingerLine(lines, self.finger or pos), pos.y)
    end
    local lk = self.lock
    local d = (pos.y - lk.cy) / lk.h
    local n = 0
    if d > lk.down then
        n = math.ceil(d - lk.down)
    elseif d < lk.up then
        n = -math.ceil(lk.up - d)
    end
    local y = lk.cy + n * lk.h
    if n ~= 0 then
        self.relock_y = y
        -- Pulled away from the text going down: from now on the finger is
        -- below the end it's moving (the start handle keeps it above).
        if n > 0 and self.lock_side == "on" then self.lock_side = "below" end
    end
    y = math.max(0, math.min(sh - 1, math.floor(y + 0.5)))
    return Geom:new{ x = pos.x, y = y, w = 0, h = 0 }
end

-- After moving to another line, lock onto that line's real position (line
-- heights are only an estimate: paragraph gaps, headings...).
function Fingertip:relock()
    local y = self.relock_y
    if not y then return end
    self.relock_y = nil
    local lines = self:getLineBoxes()
    if not lines then return end
    local l = fingerLine(lines, { x = 0, y = y })
    local up, down
    if self.lock_side == "below" then
        up, down = LOCK_PUSH, LOCK_PULL
    elseif self.lock_side == "above" then
        up, down = -LOCK_PULL, -LOCK_PUSH
    else
        up, down = -LOCK_UP_FROM_ON, LOCK_PULL
    end
    self.lock = { cy = l.y + l.h / 2, h = l.h, up = up, down = down }
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
            if with_panel and self.panel_mode == "line" then
                local l = self:loupeLine(lines)
                if l then panel_lines = { l } else with_panel = false end
            end
            layout = Panel.computeLayout(lines, {
                lift = self.lift,
                border = self.border,
                radius = self.radius,
                shadow = self.shadow,
                with_panel = with_panel,
                with_handles = true,
                panel_lines = panel_lines,
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
    return { which = best, dx = ex - pos.x, dy = ey - pos.y, touch_y = pos.y }
end

-- Dragging one handle means the other end stays put: make that end the
-- point KOReader extends the selection from, as if the hold started there.
function Fingertip:beginHandleDrag(which, touch_y)
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
    -- The one-line panel comes back, on the line of the end being dragged,
    -- and the finger stays on the handle's side of it.
    local l = which == "stop" and lines[#lines] or lines[1]
    local ex = which == "stop" and l.x + l.w - 1 or l.x + 1
    self:startLoupe({ x = math.floor(ex), y = math.floor(l.y + l.h / 2) },
        which == "stop" and "below" or "above")
    if touch_y then self:initLock(l, touch_y) end
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

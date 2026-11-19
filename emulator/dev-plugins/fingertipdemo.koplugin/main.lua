-- Dev-only driver for testing Fingertip in the desktop emulator.
-- With FT_DEMO=1, once a book is ready it plays a scripted scenario, saves a
-- screenshot after each step into $FT_DEMO_SHOTS, then quits.
-- FT_DEMO_SCENARIO: main (default), top, split, arrange, rows2, loupe, wrap, lock.
-- FT_DEMO_STYLE="border,radius,shadow" overrides the style settings.
-- Not meant to be installed on a device.

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Screen = Device.screen

local Demo = WidgetContainer:extend{
    name = "fingertipdemo",
    is_doc_only = true,
}

function Demo:init() end

local function pt(x, y)
    return Geom:new{ x = math.floor(x), y = math.floor(y), w = 0, h = 0 }
end

local function ges(name, x, y)
    return { ges = name, pos = pt(x, y) }
end

function Demo:onReaderReady()
    if os.getenv("FT_DEMO") ~= "1" then return end
    local dir = os.getenv("FT_DEMO_SHOTS") or "/tmp"
    local scenario = os.getenv("FT_DEMO_SCENARIO") or "main"
    local W, H = Screen:getWidth(), Screen:getHeight()
    local hl = self.ui.highlight
    local ft = self.ui.fingertip

    -- Start every run from the default bar arrangement.
    for _, k in ipairs({ "fingertip_bar_order", "fingertip_bar_hidden", "fingertip_bar_rows" }) do
        G_reader_settings:delSetting(k)
    end
    if scenario == "rows2" then G_reader_settings:saveSetting("fingertip_bar_rows", 2) end
    -- FT_DEMO_PANEL=line|selection: what the lifted copy shows (default: the setting)
    if os.getenv("FT_DEMO_PANEL") and ft then ft.panel_mode = os.getenv("FT_DEMO_PANEL") end
    local style = os.getenv("FT_DEMO_STYLE")
    if style and ft then
        local b, r, s = style:match("^([%d%.]+),([%d%.]+),(%a+)$")
        ft.border, ft.radius, ft.shadow = tonumber(b), tonumber(r), s
    end
    if ft then
        local items = {}
        ft:addToMainMenu(items)
        for _, item in ipairs(items.fingertip.sub_item_table) do
            local label = item.text_func and item.text_func() or item.text
            logger.info("FtDemo: menu", label)
        end
    end

    local function knob(which)
        local hd = ft.layout.handles[which]
        return pt(hd.knob_x, hd.knob_y)
    end
    local drag_from
    local function grab(which)
        drag_from = knob(which)
        ft.bar:onFtTouch(nil, { ges = "touch", pos = drag_from })
    end
    local function panBy(dx, dy)
        ft.bar:onFtPan(nil, { ges = "pan", start_pos = drag_from, pos = pt(drag_from.x + dx, drag_from.y + dy) })
    end
    local function releaseAt(dx, dy)
        ft.bar:onFtPanRelease(nil, { ges = "pan_release", pos = pt(drag_from.x + dx, drag_from.y + dy) })
    end

    local steps
    local hy = H * 0.42
    if scenario == "top" then
        local Event = require("ui/event")
        local ty = H * 0.03
        steps = {
            { "10-next-page",     function() self.ui:handleEvent(Event:new("GotoViewRel", 1)) end },
            { "11-hold-top-line", function() hl:onHold(nil, ges("hold", W * 0.20, ty)) end },
            { "12-drag-top-line", function() hl:onHoldPan(nil, ges("hold_pan", W * 0.70, ty)) end },
            { "13-released",      function() hl:onHoldRelease() end },
        }
    elseif scenario == "split" then
        steps = {
            { "20-hold-line-end",   function() hl:onHold(nil, ges("hold", W * 0.80, hy)) end },
            { "21-drag-next-start", function() hl:onHoldPan(nil, ges("hold_pan", W * 0.12, hy + H * 0.10)) end },
            { "22-released",        function() hl:onHoldRelease() end },
        }
    elseif scenario == "arrange" then
        local arr
        local function tapRow(id, on_box)
            for _, h in ipairs(arr.hit) do
                if h.id == id then
                    local x = on_box and h.box_x1 / 2 or W * 0.6
                    arr:onFtArrangeTap(nil, ges("tap", x, (h.y0 + h.y1) / 2))
                    return
                end
            end
            logger.warn("FtDemo: no row", id)
        end
        steps = {
            { "30-arrange-open", function()
                ft:showArrange()
                arr = UIManager._window_stack[#UIManager._window_stack].widget
            end },
            { "31-pick-dictionary", function() tapRow("06_dictionary") end },
            { "32-moved-up-4", function() for _ = 1, 4 do arr:move(-1) end end },
            { "33-untick-view-html", function() tapRow("09_view_html", true) end },
            { "34-two-rows", function() arr:setRows(2) end },
            { "35-closed-then-bar", function()
                arr:onFtArrangeClose()
                hl:onHold(nil, ges("hold", W * 0.30, hy))
                hl:onHoldPan(nil, ges("hold_pan", W * 0.75, hy))
                hl:onHoldRelease()
            end },
        }
    elseif scenario == "wrap" then
        steps = {
            { "50-hold-hyphenated", function() hl:onHold(nil, ges("hold", W * 0.93, hy)) end },
            { "51-hold-its-second-half", function()
                hl:onClose(); hl:onHold(nil, ges("hold", W * 0.06, hy + H * 0.04)) end },
        }
    elseif scenario == "probe" then
        -- Logs where the selection ends as the finger crosses words, and
        -- how long KOReader's own drag handling takes.
        steps = {
            { "75-hold", function() hl:onHold(nil, ges("hold", W * 0.30, hy)) end },
            { "76-sweep", function()
                local doc = self.ui.document
                local time = require("ui/time")
                for k = 0, 24 do
                    local x = math.floor(W * (0.50 + k * 0.018))
                    local t0 = time.now()
                    hl:onHoldPan(nil, ges("hold_pan", x, hy))
                    local t1 = time.now()
                    local sel = hl.selected_text
                    local last = sel and sel.sboxes and sel.sboxes[#sel.sboxes]
                    local w = doc:getWordFromPosition({ x = x, y = math.floor(hy) }, true)
                    local wb = w and w.sbox
                    logger.info(string.format("FtProbe x=%d sel_end=%s word=%s [%s..%s] tail=%q pan_ms=%.1f",
                        x, last and (last.x + last.w) or "-", w and w.word or "-",
                        wb and wb.x or "-", wb and (wb.x + wb.w) or "-",
                        sel and sel.text and sel.text:sub(-12) or "", time.to_ms(t1 - t0)))
                end
                -- Can crengine give boxes for part of a word?
                local sel = hl.selected_text
                local xp = sel.pos1
                for _ = 1, 3 do xp = doc:getPrevVisibleChar(xp) end
                local boxes = doc:getScreenBoxesFromPositions(sel.pos0, xp, true)
                local b = boxes[#boxes]
                logger.info("FtProbe partial: end", sel.pos1, "minus 3 chars", xp, "box end", b and (b.x + b.w))
                -- How long does a full page repaint take?
                local Blitbuffer = require("ffi/blitbuffer")
                local bb = Blitbuffer.new(W, H, Screen.bb:getType())
                local t0 = time.now()
                for _ = 1, 5 do self.ui.view:paintTo(bb, 0, 0) end
                logger.info(string.format("FtProbe page paint ms=%.1f", time.to_ms(time.now() - t0) / 5))
                doc:getTextFromPositions(hl.hold_pos, hl.holdpan_pos) -- redraw selection mark
                t0 = time.now()
                for _ = 1, 5 do self.ui.view:paintTo(bb, 0, 0) end
                logger.info(string.format("FtProbe page paint after selection change ms=%.1f", time.to_ms(time.now() - t0) / 5))
                bb:free()
            end },
        }
    elseif scenario == "relative" then
        -- Drag down five lines, then back up, a quarter line at a time.
        -- Logs how far the finger is below the bottom of the selection's
        -- last line, in line heights.
        local cy, lh
        local function pan(dy)
            hl:onHoldPan(nil, ges("hold_pan", W * 0.5, cy + dy * lh))
            local lines = ft:getLineBoxes()
            local last = lines[#lines]
            logger.info(string.format("FtRel finger=%+.2f lines=%d finger_below_end=%+.2f",
                dy, #lines, (cy + dy * lh - (last.y + last.h)) / lh))
        end
        steps = {
            { "80-hold", function()
                hl:onHold(nil, ges("hold", W * 0.30, hy))
                local l = ft:getLineBoxes()[1]
                cy, lh = l.y + l.h / 2, l.h
            end },
            { "81-down-and-up", function()
                for k = 1, 24 do pan(k * 0.25) end
                for k = 23, 0, -1 do pan(k * 0.25) end
            end },
        }
    elseif scenario == "lock" then
        -- Line lock: offsets are in line heights from the held line's middle.
        local cy, lh
        local function count() return #(ft:getLineBoxes() or {}) end
        local function pan(x, dy)
            hl:onHoldPan(nil, ges("hold_pan", x, cy + dy * lh))
            logger.info("FtDemo: finger dy", dy, "lines", count())
        end
        local function knobPan(which, dy)
            panBy(0, dy * lh)
            logger.info("FtDemo: handle", which, "dy", dy, "lines", count())
        end
        steps = {
            { "60-hold", function()
                hl:onHold(nil, ges("hold", W * 0.30, hy))
                local l = ft:getLineBoxes()[1]
                cy, lh = l.y + l.h / 2, l.h
            end },
            { "61-right-wobble-down", function() pan(W * 0.50, 0.45) end },
            { "62-right-wobble-up",   function() pan(W * 0.65, -0.45) end },
            { "63-down-1.8-still",    function() pan(W * 0.55, 1.8) end },
            { "64-down-2.3-next",     function() pan(W * 0.55, 2.3) end },
            { "65-down-3.3-next",     function() pan(W * 0.40, 3.3) end },
            { "66-up-to-3.1-stays",   function() pan(W * 0.40, 3.1) end },
            { "67-up-to-2.8-pushes",  function() pan(W * 0.40, 2.8) end },
            { "68-released",          function() hl:onHoldRelease() end },
            { "69-end-handle-up-0.2", function() grab("stop"); knobPan("stop", -0.2) end },
            { "70-end-handle-up-0.9", function() knobPan("stop", -0.9) end },
            { "71-end-released",      function() releaseAt(0, -0.9 * lh) end },
        }
    elseif scenario == "loupe" then
        local function pan(x, y) hl:onHoldPan(nil, ges("hold_pan", x, y)) end
        steps = {
            { "40-hold",           function() hl:onHold(nil, ges("hold", W * 0.30, hy)) end },
            { "41-pan-right",      function() pan(W * 0.45, hy) end },
            { "42-pan-a-little",   function() pan(W * 0.45 + 4, hy) end },
            { "43-pan-further",    function() pan(W * 0.65, hy) end },
            { "44-next-line",      function() pan(W * 0.40, hy + H * 0.10) end },
            { "45-back-up",        function() pan(W * 0.70, hy) end },
            { "46-released",       function() hl:onHoldRelease() end },
            { "47-grab-end",       function() grab("stop"); panBy(-W * 0.12, 0) end },
            { "48-end-released",   function() releaseAt(-W * 0.12, 0) end },
        }
    else -- main and rows2
        steps = {
            { "01-hold-word",      function() hl:onHold(nil, ges("hold", W * 0.30, hy)) end },
            { "02-drag-same-line", function() hl:onHoldPan(nil, ges("hold_pan", W * 0.75, hy)) end },
            { "03-drag-3-lines",   function() hl:onHoldPan(nil, ges("hold_pan", W * 0.60, hy + H * 0.14)) end },
            { "04-released-bar",   function() hl:onHoldRelease() end },
        }
        if scenario == "main" then
            local more = {
                { "05-more",           function() ft.bar:nextSet() end },
                { "06-more-again",     function() ft.bar:nextSet() end },
                { "07-more-wraps",     function() ft.bar:nextSet() end },
                { "08-drag-end-handle", function() grab("stop"); panBy(-W * 0.25, -H * 0.06) end },
                { "09-end-released",   function() releaseAt(-W * 0.25, -H * 0.06) end },
                { "10-drag-start-handle", function() grab("start"); panBy(-W * 0.2, -H * 0.07) end },
                { "11-start-released", function() releaseAt(-W * 0.2, -H * 0.07) end },
                { "12-tap-elsewhere",  function() ft.bar:onFtTap(nil, ges("tap", W * 0.5, H * 0.92)) end },
                { "13-hold-word-again", function() hl:onHold(nil, ges("hold", W * 0.55, H * 0.6)) end },
                { "14-release-word",   function() hl:onHoldRelease() end },
            }
            for _, s in ipairs(more) do table.insert(steps, s) end
        end
    end

    local i = 0
    local function nextStep()
        i = i + 1
        local step = steps[i]
        if not step then
            logger.info("FtDemo: done")
            UIManager:quit()
            return
        end
        logger.info("FtDemo: step", step[1])
        local ok, err = pcall(step[2])
        if not ok then logger.err("FtDemo: step failed", step[1], err) end
        UIManager:scheduleIn(1.0, function()
            local path = string.format("%s/%s.png", dir, step[1])
            Screen:shot(path)
            logger.info("FtDemo: saved", path, "phase", ft and ft.phase, "bar", ft and ft.bar and ft.bar.set_index)
            -- Grey Kobos (like the Clara BW) draw in 8-bit grey: repaint the
            -- reader into an 8-bit buffer too, so that path gets looked at.
            local Blitbuffer = require("ffi/blitbuffer")
            local bb8 = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
            local ok2, err2 = pcall(function()
                bb8:fill(Blitbuffer.COLOR_WHITE)
                self.ui.view:paintTo(bb8, 0, 0)
                bb8:writePNG(string.format("%s/%s-bb8.png", dir, step[1]))
            end)
            if not ok2 then logger.err("FtDemo: bb8 render failed", err2) end
            bb8:free()
            nextStep()
        end)
    end
    UIManager:scheduleIn(2.0, nextStep)
end

return Demo

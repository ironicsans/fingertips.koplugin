--[[
Fingertip: geometry and drawing of the lifted panel and the selection handles.

The panel is the page itself, shifted up by the lift and cut to a shape: the
selected lines plus a margin of context (a little of the text around them),
outlined as one staircase-shaped panel with rounded corners. Inside, the
selection keeps its shading and the context is drawn lighter.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local ffi = require("ffi")
local logger = require("logger")

local Screen = Device.screen

local Panel = {}

-- Context around the selection, in line heights.
Panel.CONTEXT_SIDE = 1.0   -- about three letters left and right
Panel.CONTEXT_V = 0.5      -- half a line above and below
-- How dark the context stays: 1 = as on the page, 0 = invisible.
local CONTEXT_INK = 0.33

local SHADOW_OFFSET = 3 -- screen-scaled units, down and right
-- How much each shadow darkens the page at its densest (0-1). The soft one
-- is blurred, which thins it out, so it starts stronger.
local SHADOW_STRENGTH = { hard = 0.41, soft = 0.56 }

local ARC_STEPS = 8 -- segments per rounded corner

local function sign(v)
    if v > 0 then return 1 elseif v < 0 then return -1 end
    return 0
end

-- Clockwise corners (screen coordinates, y down) of one group of rows.
-- rows[i] = { a = left, b = right }; ys[0] = top, ys[i] = bottom of row i.
local function groupCorners(rows, ys)
    local n = #rows
    local v = {}
    local function add(x, y) v[#v + 1] = { x = x, y = y } end
    add(rows[1].a, ys[0])
    add(rows[1].b, ys[0])
    for i = 1, n - 1 do -- right side, going down
        if rows[i].b ~= rows[i + 1].b then
            add(rows[i].b, ys[i])
            add(rows[i + 1].b, ys[i])
        end
    end
    add(rows[n].b, ys[n])
    add(rows[n].a, ys[n])
    for i = n - 1, 1, -1 do -- left side, going up
        if rows[i + 1].a ~= rows[i].a then
            add(rows[i + 1].a, ys[i])
            add(rows[i].a, ys[i])
        end
    end
    return v
end

-- Outline of a polygon with rounded corners, as a flat {x1, y1, x2, y2...}
-- list. With inset > 0, the outline is pulled inward by that much: corners
-- keep their arc centres, so convex radii shrink and concave ones grow,
-- which keeps the band between the two outlines exactly `inset` wide.
local function roundedPath(corners, radii, inset)
    local n = #corners
    local pts = {}
    for i = 1, n do
        local c = corners[i]
        local p = corners[(i - 2) % n + 1]
        local q = corners[i % n + 1]
        local d1x, d1y = sign(c.x - p.x), sign(c.y - p.y) -- incoming direction
        local d2x, d2y = sign(q.x - c.x), sign(q.y - c.y) -- outgoing direction
        local convex = (d1x * d2y - d1y * d2x) > 0
        -- sum of the inward normals of both edges (a diagonal, inward)
        local nx, ny = -d1y - d2y, d1x + d2x
        local vx, vy = c.x + inset * nx, c.y + inset * ny
        local r = radii[i]
        if inset > 0 then
            r = convex and math.max(0, r - inset) or (r + inset)
        end
        if r <= 0 then
            pts[#pts + 1] = vx
            pts[#pts + 1] = vy
        else
            local s = convex and 1 or -1 -- convex centres inside, concave outside
            local cx, cy = vx + s * r * nx, vy + s * r * ny
            local a1 = math.atan2(vy - d1y * r - cy, vx - d1x * r - cx)
            local a2 = math.atan2(vy + d2y * r - cy, vx + d2x * r - cx)
            local da = a2 - a1
            if da > math.pi then da = da - 2 * math.pi
            elseif da < -math.pi then da = da + 2 * math.pi end
            for k = 0, ARC_STEPS do
                local a = a1 + da * k / ARC_STEPS
                pts[#pts + 1] = cx + r * math.cos(a)
                pts[#pts + 1] = cy + r * math.sin(a)
            end
        end
    end
    return pts
end

-- Sets mask bytes to `value` (default 1) for pixels whose centre is inside
-- the closed path (even-odd rule). The mask covers the screen area
-- (ox, oy, w, h).
local function fillPath(mask, w, h, ox, oy, pts, value)
    value = value or 1
    local n = #pts / 2
    local min_y, max_y = math.huge, -math.huge
    for i = 2, #pts, 2 do
        if pts[i] < min_y then min_y = pts[i] end
        if pts[i] > max_y then max_y = pts[i] end
    end
    local row0 = math.max(0, math.floor(min_y - oy))
    local row1 = math.min(h - 1, math.ceil(max_y - oy))
    local xs = {}
    for row = row0, row1 do
        local y = oy + row + 0.5
        local cnt = 0
        for i = 0, n - 1 do
            local j = (i + 1) % n
            local y1, y2 = pts[2 * i + 2], pts[2 * j + 2]
            if (y1 <= y and y2 > y) or (y2 <= y and y1 > y) then
                local x1, x2 = pts[2 * i + 1], pts[2 * j + 1]
                cnt = cnt + 1
                xs[cnt] = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            end
        end
        for k = 2, cnt do -- insertion sort, cnt is small
            local v, m = xs[k], k - 1
            while m >= 1 and xs[m] > v do
                xs[m + 1] = xs[m]
                m = m - 1
            end
            xs[m + 1] = v
        end
        local base = row * w
        for k = 1, cnt - 1, 2 do
            local xa = math.max(0, math.ceil(xs[k] - ox - 0.5))
            local xb = math.min(w - 1, math.floor(xs[k + 1] - ox - 0.5))
            for x = xa, xb do
                mask[base + x] = value
            end
        end
    end
end

-- Box blur of a w x h byte mask, in place (outside the mask counts as 0).
-- Two passes give a soft, roughly Gaussian edge.
local function blurMask(mask, w, h, r)
    if r < 1 then return end
    local tmp = ffi.new("uint8_t[?]", w * h)
    local span = 2 * r + 1
    for _pass = 1, 2 do
        for row = 0, h - 1 do
            local base, sum = row * w, 0
            for x = 0, math.min(r, w - 1) do sum = sum + mask[base + x] end
            for x = 0, w - 1 do
                tmp[base + x] = math.floor(sum / span + 0.5)
                local add, sub = x + r + 1, x - r
                if add < w then sum = sum + mask[base + add] end
                if sub >= 0 then sum = sum - mask[base + sub] end
            end
        end
        for col = 0, w - 1 do
            local sum = 0
            for y = 0, math.min(r, h - 1) do sum = sum + tmp[y * w + col] end
            for y = 0, h - 1 do
                mask[y * w + col] = math.floor(sum / span + 0.5)
                local add, sub = y + r + 1, y - r
                if add < h then sum = sum + tmp[add * w + col] end
                if sub >= 0 then sum = sum - tmp[sub * w + col] end
            end
        end
    end
end

local function averageLineHeight(lines)
    local h = 0
    for i = 1, #lines do h = h + lines[i].h end
    return h / #lines
end
Panel.averageLineHeight = averageLineHeight

-- The two handles: a thin bar along the selection's edge plus a round knob,
-- above the start and below the end (as on phones).
function Panel.handleGeometry(lines)
    local first, last = lines[1], lines[#lines]
    local line_h = averageLineHeight(lines)
    local bar_w = math.max(2, Screen:scaleBySize(2))
    local r = math.max(3, math.floor(line_h * 0.2 + 0.5))
    local start = {
        x = first.x, top = first.y, bottom = first.y + first.h,
        knob_x = first.x, knob_y = first.y - r,
    }
    local stop = {
        x = last.x + last.w, top = last.y, bottom = last.y + last.h,
        knob_x = last.x + last.w, knob_y = last.y + last.h + r,
    }
    local function rect(hd)
        return Geom:new{
            x = hd.x - r - 1, y = math.min(hd.top, hd.knob_y - r) - 1,
            w = 2 * r + 2, h = math.max(hd.bottom, hd.knob_y + r) - math.min(hd.top, hd.knob_y - r) + 2,
        }
    end
    return {
        start = start, stop = stop, r = r, bar_w = bar_w,
        region = rect(start):combine(rect(stop)),
    }
end

-- Draws the handles into bb, with (dx, dy) added to their positions.
local function drawHandles(bb, hg, dx, dy)
    for _, hd in ipairs({ hg.start, hg.stop }) do
        local x = math.floor(hd.x + dx - hg.bar_w / 2 + 0.5)
        bb:paintRect(x, math.floor(hd.top + dy), hg.bar_w, math.floor(hd.bottom - hd.top), Blitbuffer.COLOR_BLACK)
        bb:paintCircle(math.floor(hd.knob_x + dx + 0.5), math.floor(hd.knob_y + dy + 0.5), hg.r, Blitbuffer.COLOR_BLACK)
    end
end

--[[
Works out what to draw. lines: screen boxes of the selected lines, top to
bottom. opts: lift (line heights), border and radius (screen-scaled units),
shadow ("none", "hard", "soft"), with_panel, with_handles, and panel_lines:
what the panel copies, when not the whole selection (e.g. just the word
under the finger). The selected lines stay dark in the copy either way.
Returns nil when there is nothing to draw.
]]
function Panel.computeLayout(lines, opts)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local layout = { parts = {} }
    local region

    if opts.with_handles then
        layout.handles = Panel.handleGeometry(lines)
        region = layout.handles.region
        local s, e = layout.handles.start, layout.handles.stop
        table.insert(layout.parts, string.format("h%d,%d,%d,%d,%d,%d", s.x, s.top, s.bottom, e.x, e.top, e.bottom))
    end

    if opts.with_panel then
        local panel = Panel.computePanel(opts.panel_lines or lines, opts, screen_w, screen_h, lines)
        if panel then
            layout.panel = panel
            region = region and region:combine(panel.region) or panel.region
            table.insert(layout.parts, panel.key)
        end
    end

    if not region then return nil end
    layout.region = region:intersect(Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h })
    layout.key = table.concat(layout.parts, ";")
    return layout
end

-- lines: what to copy; keep_lines: the selected lines (left dark).
function Panel.computePanel(lines, opts, screen_w, screen_h, keep_lines)
    keep_lines = keep_lines or lines
    local border = math.max(1, Screen:scaleBySize(opts.border))
    local radius = Screen:scaleBySize(opts.radius)
    local shadow_off, shadow_blur = 0, 0
    if opts.shadow ~= "none" then
        shadow_off = Screen:scaleBySize(SHADOW_OFFSET)
        if opts.shadow == "soft" then shadow_blur = math.max(1, math.floor(shadow_off / 2)) end
    end

    -- One lift for the whole selection, so the copies stay stacked like the
    -- real lines are.
    local line_h = averageLineHeight(lines)
    local lift = math.floor(line_h * opts.lift + 0.5)
    local ctx_side = opts.panel_ctx_side or math.floor(line_h * Panel.CONTEXT_SIDE + 0.5)
    local ctx_v = math.floor(line_h * Panel.CONTEXT_V + 0.5)

    -- Above the selection; or, at the top of the screen where there's no
    -- room, below it with the same gap.
    local first, last = lines[1], lines[#lines]
    local dy = -lift
    if first.y + dy - ctx_v - border < 0 then
        dy = (last.y + last.h - first.y) + (lift - line_h)
    end
    dy = math.floor(dy + 0.5)

    -- Each line is a row: the line plus context left and right, plus the
    -- outline. Rows on top of each other that overlap enough sideways share
    -- one outline; anything else gets an outline of its own.
    local min_overlap = 2 * math.max(radius, Screen:scaleBySize(9)) + 2 * border
    local groups, group = {}, nil
    for i = 1, #lines do
        local l = lines[i]
        local row = {
            a = math.max(0, l.x - ctx_side - border),
            b = math.min(screen_w, l.x + l.w + ctx_side + border),
            top = l.y + dy, bottom = l.y + l.h + dy,
        }
        if group then
            local prev = group[#group]
            local overlap = math.min(prev.b, row.b) - math.max(prev.a, row.a)
            local gap = row.top - prev.bottom
            if overlap < min_overlap or math.abs(gap) > line_h / 2 then
                group = nil
            end
        end
        if not group then
            group = {}
            table.insert(groups, group)
        end
        table.insert(group, row)
    end

    -- Top and bottom of each group: context above and below; but where two
    -- separate groups would overlap, they meet halfway between their lines.
    for g = 1, #groups do
        local rows = groups[g]
        rows.y_top = rows[1].top - ctx_v - border
        rows.y_bottom = rows[#rows].bottom + ctx_v + border
    end
    for g = 1, #groups - 1 do
        local lo, hi = groups[g][#groups[g]], groups[g + 1][1]
        if math.min(lo.b, hi.b) - math.max(lo.a, hi.a) > 0 then
            local mid = math.floor((lo.bottom + hi.top) / 2)
            groups[g].y_bottom = mid
            groups[g + 1].y_top = mid
        end
    end

    local shapes = {}
    local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
    for g = 1, #groups do
        local rows = groups[g]
        local n = #rows
        -- Line ends that almost line up would make tiny steps: line them up
        -- (widening, never cutting text off).
        for _pass = 1, 3 do
            for i = 1, n - 1 do
                local r1, r2 = rows[i], rows[i + 1]
                if r1.b ~= r2.b and math.abs(r1.b - r2.b) < min_overlap then
                    local m = math.max(r1.b, r2.b)
                    r1.b, r2.b = m, m
                end
                if r1.a ~= r2.a and math.abs(r1.a - r2.a) < min_overlap then
                    local m = math.min(r1.a, r2.a)
                    r1.a, r2.a = m, m
                end
            end
        end
        local ys = { [0] = math.max(0, rows.y_top) }
        for i = 1, n - 1 do
            ys[i] = math.floor((rows[i].bottom + rows[i + 1].top) / 2)
        end
        ys[n] = math.min(screen_h, rows.y_bottom)

        local corners = groupCorners(rows, ys)
        local radii = {}
        local nc = #corners
        for i = 1, nc do
            local c = corners[i]
            local p = corners[(i - 2) % nc + 1]
            local q = corners[i % nc + 1]
            local len_in = math.abs(c.x - p.x) + math.abs(c.y - p.y)
            local len_out = math.abs(q.x - c.x) + math.abs(q.y - c.y)
            radii[i] = math.min(radius, len_in / 2, len_out / 2)
            bx0, by0 = math.min(bx0, c.x), math.min(by0, c.y)
            bx1, by1 = math.max(bx1, c.x), math.max(by1, c.y)
        end
        local outer = roundedPath(corners, radii, 0)
        local shadow
        if shadow_off > 0 then
            shadow = {}
            for i = 1, #outer do shadow[i] = outer[i] + shadow_off end
        end
        table.insert(shapes, {
            outer = outer,
            inner = roundedPath(corners, radii, border),
            shadow = shadow,
            corners = corners,
        })
    end

    local reach = shadow_off + 2 * shadow_blur
    local back = math.max(0, 2 * shadow_blur - shadow_off)
    bx0, by0 = math.max(0, math.floor(bx0) - back), math.max(0, math.floor(by0) - back)
    bx1, by1 = math.min(screen_w, math.ceil(bx1) + reach), math.min(screen_h, math.ceil(by1) + reach)
    if bx1 <= bx0 or by1 <= by0 then return nil end

    local parts = { "p" .. dy }
    for i = 1, #shapes do
        for _, c in ipairs(shapes[i].corners) do
            parts[#parts + 1] = c.x .. "," .. c.y
        end
        parts[#parts + 1] = "|"
    end
    for i = 1, #keep_lines do
        local l = keep_lines[i]
        parts[#parts + 1] = string.format("%d,%d,%d,%d", l.x, l.y, l.w, l.h)
    end

    return {
        dy = dy,
        lines = keep_lines, -- the selected parts stay dark in the copy
        shapes = shapes,
        region = Geom:new{ x = bx0, y = by0, w = bx1 - bx0, h = by1 - by0 },
        shadow_blur = shadow_blur,
        shadow_mode = opts.shadow,
        key = table.concat(parts, ";"),
    }
end

-- Pixel layouts we edit directly: bytes per pixel, colour channels. Grey
-- e-ink Kobos draw in 8-bit grey, colour ones (and the desktop) in RGB32.
-- Anything else is handled in 8-bit grey.
local function pixelFormat(bbtype)
    if bbtype == Blitbuffer.TYPE_BB8 then return 1, 1 end
    if bbtype == Blitbuffer.TYPE_BBRGB32 then return 4, 3 end -- R, G, B, alpha
end

local function newBuffer(w, h, bbtype)
    local ok, bb = pcall(Blitbuffer.new, w, h, bbtype)
    if ok then return bb end
    logger.warn("Fingertip: could not allocate a", w, "x", h, "buffer")
end

local LIGHTEN = ffi.new("uint8_t[256]")
for v = 0, 255 do
    LIGHTEN[v] = 255 - math.floor((255 - v) * CONTEXT_INK + 0.5)
end

-- Draws the layout onto bb (the screen-sized page buffer at x, y), after the
-- page and its highlights are already there.
function Panel.paint(bb, x, y, layout)
    x, y = x or 0, y or 0
    local panel = layout.panel
    if not panel then
        if layout.handles then drawHandles(bb, layout.handles, x, y) end
        return
    end

    local t0 = os.clock()
    local reg = panel.region
    local w, h = reg.w, reg.h
    local bbtype = bb:getType()
    local bpp, nch = pixelFormat(bbtype)
    if not bpp then
        bbtype = Blitbuffer.TYPE_BB8
        bpp, nch = pixelFormat(bbtype)
    end
    local content = newBuffer(w, h, bbtype)
    local canvas = newBuffer(w, h, bbtype)
    if not (content and canvas) then
        if content then content:free() end
        if canvas then canvas:free() end
        if layout.handles then drawHandles(bb, layout.handles, x, y) end
        return
    end

    -- 1. The panel's contents: the page shifted by the lift, taken before
    --    anything else is drawn on top of it.
    content:fill(Blitbuffer.COLOR_WHITE)
    local sx0, sy0 = reg.x, reg.y - panel.dy -- where the contents come from
    local cx0, cy0 = math.max(0, sx0), math.max(0, sy0)
    local cx1 = math.min(bb:getWidth() - x, sx0 + w)
    local cy1 = math.min(bb:getHeight() - y, sy0 + h)
    if cx1 > cx0 and cy1 > cy0 then
        content:blitFrom(bb, cx0 - sx0, cy0 - sy0, x + cx0, y + cy0, cx1 - cx0, cy1 - cy0)
    end

    -- 2. Lighten the context: everything but the selected lines.
    local keep = ffi.new("uint8_t[?]", w * h)
    for _, l in ipairs(panel.lines) do
        local kx0 = math.max(0, math.floor(l.x - reg.x))
        local kx1 = math.min(w, math.ceil(l.x + l.w - reg.x))
        local ky0 = math.max(0, math.floor(l.y + panel.dy - reg.y))
        local ky1 = math.min(h, math.ceil(l.y + l.h + panel.dy - reg.y))
        for row = ky0, ky1 - 1 do
            local base = row * w
            for col = kx0, kx1 - 1 do keep[base + col] = 1 end
        end
    end
    do
        local px = ffi.cast("uint8_t*", content.data)
        local stride = tonumber(content.stride)
        for row = 0, h - 1 do
            local m, base = row * w, row * stride
            for col = 0, w - 1 do
                if keep[m + col] == 0 then
                    local o = base + col * bpp
                    for k = 0, nch - 1 do px[o + k] = LIGHTEN[px[o + k]] end
                end
            end
        end
    end

    -- 3. The handles, in the copy too.
    if layout.handles then
        drawHandles(content, layout.handles, -reg.x, panel.dy - reg.y)
    end

    -- 4. What's on the page where the panel goes (kept outside the outline),
    --    with the page's own handles on it.
    if layout.handles then drawHandles(bb, layout.handles, x, y) end
    canvas:blitFrom(bb, 0, 0, x + reg.x, y + reg.y, w, h)

    -- 5. Which pixels are outline and which are inside it.
    local outer = ffi.new("uint8_t[?]", w * h)
    local inner = ffi.new("uint8_t[?]", w * h)
    for _, shape in ipairs(panel.shapes) do
        fillPath(outer, w, h, reg.x, reg.y, shape.outer)
        fillPath(inner, w, h, reg.x, reg.y, shape.inner)
    end

    -- 6. Drop shadow: the outline shape moved down and right, darkening the
    --    page around the panel (the panel covers the rest of it).
    if panel.shapes[1] and panel.shapes[1].shadow then
        local smask = ffi.new("uint8_t[?]", w * h)
        for _, shape in ipairs(panel.shapes) do
            fillPath(smask, w, h, reg.x, reg.y, shape.shadow, 255)
        end
        blurMask(smask, w, h, panel.shadow_blur)
        local factor = {}
        local strength = SHADOW_STRENGTH[panel.shadow_mode] or 0.5
        for s = 0, 255 do factor[s] = 1 - strength * s / 255 end
        local bytes = ffi.cast("uint8_t*", canvas.data)
        local stride = tonumber(canvas.stride)
        for row = 0, h - 1 do
            local m, base = row * w, row * stride
            for col = 0, w - 1 do
                local s = smask[m + col]
                if s > 0 and outer[m + col] == 0 then
                    local f, o = factor[s], base + col * bpp
                    for k = 0, nch - 1 do
                        bytes[o + k] = math.floor(bytes[o + k] * f + 0.5)
                    end
                end
            end
        end
    end

    -- 7. Combine: inside -> contents, outline band -> black, else page.
    local cstride, tstride = tonumber(canvas.stride), tonumber(content.stride)
    if bpp == 4 then
        local cpx = ffi.cast("uint32_t*", canvas.data)
        local tpx = ffi.cast("uint32_t*", content.data)
        local black = 0xFF000000 -- opaque black: alpha 0xFF, RGB 0
        cstride, tstride = cstride / 4, tstride / 4
        for row = 0, h - 1 do
            local m, c, t = row * w, row * cstride, row * tstride
            for col = 0, w - 1 do
                if inner[m + col] == 1 then
                    cpx[c + col] = tpx[t + col]
                elseif outer[m + col] == 1 then
                    cpx[c + col] = black
                end
            end
        end
    else
        local cpx = ffi.cast("uint8_t*", canvas.data)
        local tpx = ffi.cast("uint8_t*", content.data)
        for row = 0, h - 1 do
            local m, c, t = row * w, row * cstride, row * tstride
            for col = 0, w - 1 do
                if inner[m + col] == 1 then
                    cpx[c + col] = tpx[t + col]
                elseif outer[m + col] == 1 then
                    cpx[c + col] = 0
                end
            end
        end
    end
    bb:blitFrom(canvas, x + reg.x, y + reg.y, 0, 0, w, h)
    content:free()
    canvas:free()
    logger.dbg(string.format("Fingertip: painted %d line(s) in %.1f ms", #panel.lines, (os.clock() - t0) * 1000))
end

return Panel

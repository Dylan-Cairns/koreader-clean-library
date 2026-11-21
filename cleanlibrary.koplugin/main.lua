--[[--
Clean Library

Uniform, rounded cover thumbnails for CoverBrowser's list views (the file
manager, History and Collections). Per row:

  * hides CoverBrowser's "book was opened" dogear;
  * replaces the thumbnail with a fixed 2:3 cell: one width for every book, a
    small gap from the row edges, rounded corners and a thin rounded border.
    Covers close to 2:3 are stretched to fill the cell; outliers are fitted
    (letterboxed) instead of being distorted;
  * replaces the dotted-square "no cover" placeholder with a generic cover.
    PDFs have no embedded cover, so KOReader renders page 1; when that page is
    mostly blank paper the row shows the generic cover instead of a washed-out
    scan;
  * replaces underscores with spaces in list titles (optionally; see
    REPLACE_UNDERSCORES below).

Cell geometry (uniform 2:3, radius 8) follows ZenOS 4.3.2 (GPL-3.0),
common/cover_utils.lua and modules/filebrowser/patches/browser_list_item_layout.lua;
the corner mask and the border painted on top of it follow ZenOS's
modules/global/patches/opds_browser.lua. See README "Credits".

CoverBrowser replaces FileChooser:updateItems and builds rows with its own
ListMenuItem class, which is local to its listmenu.lua module and only
reachable through a debug upvalue. That class is hooked once, lazily, from the
first list rebuild. Books, Collections and the file manager all rebuild through
Menu:switchItemTable, which BookList inherits, so the hook is installed there
rather than only from FileChooser (that was the "History opened before the file
browser keeps its old rows" bug).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FileChooser = require("ui/widget/filechooser")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local userpatch = require("userpatch")

local Screen = Device.screen

local RADIUS = Screen:scaleBySize(8)        -- corner radius, as ZenOS uses
local GAP = Screen:scaleBySize(6)           -- breathing room around the cell
local ASPECT = 2 / 3                        -- 2:3 cells
local STRETCH_LIMIT = 45                    -- % aspect divergence still stretched
local BORDER = Screen:scaleBySize(1)
local TEXT_PAGE_LIGHT = 0.85                -- PDF page this light is "just text"
local REPLACE_UNDERSCORES = true

local PLACEHOLDER_GLYPH = "\u{26F6}"        -- stock dotted-square placeholder

-- Assets ship inside the plugin, so there is nothing to copy into the
-- user's koreader directory. debug.getinfo gives us the plugin directory.
local PLUGIN_DIR
do
    local source = debug.getinfo(1, "S").source
    if type(source) == "string" then
        PLUGIN_DIR = source:match("^@(.*)[/\\][^/\\]+$")
    end
end
local PLACEHOLDER_FILE = PLUGIN_DIR and (PLUGIN_DIR .. "/icons/book_placeholder.svg") or nil

-- 1) Finding the row's thumbnail ---------------------------------------------

local function find_node(widget, predicate, chain)
    chain = chain or {}
    for i = 1, #widget do
        local child = widget[i]
        if type(child) == "table" then
            local child_chain = {}
            for j = 1, #chain do child_chain[j] = chain[j] end
            child_chain[#child_chain + 1] = child
            if predicate(child) then
                return child, child_chain
            end
            local found, found_chain = find_node(child, predicate, child_chain)
            if found then return found, found_chain end
        end
    end
end

local function has_cover_image(node)
    -- ImageWidget stores a Blitbuffer here: FFI cdata, not a Lua table.
    return node.image ~= nil and type(node.image) ~= "string" and type(node.image) ~= "boolean"
end

local function is_stock_placeholder(node)
    return type(node.text) == "string" and node.text:find(PLACEHOLDER_GLYPH, 1, true) ~= nil
end

-- ZenOS CoverUtils.calcDims(): portrait cell inside a box, keeping 2:3.
local function calc_dims(max_w, max_h)
    if max_h * ASPECT <= max_w then
        return math.floor(max_h * ASPECT), max_h
    end
    return max_w, math.floor(max_w / ASPECT)
end

local function build_frame(box_w, box_h, content)
    -- No border here: the thumbnail paints its own rounded mask and border
    -- (see round_corners). A frame border would be cut away by the mask.
    return FrameContainer:new{
        width = box_w + 2 * BORDER,
        height = box_h + 2 * BORDER,
        margin = 0,
        padding = 0,
        bordersize = 0,
        content,
    }
end

-- 2) Placeholder cover --------------------------------------------------------

-- A full-bleed generic cover that fills the cell and goes through the same
-- mask and border as real cover art, so it does not read as a picture inside
-- a picture. Falls back to the stock mdlight glyph if the asset is missing.
local function build_placeholder(box_w, box_h)
    if PLACEHOLDER_FILE and lfs.attributes(PLACEHOLDER_FILE, "mode") == "file" then
        local widget = ImageWidget:new{
            file = PLACEHOLDER_FILE,
            width = box_w,
            height = box_h,
            _cleanlibrary_round = true,
            _cleanlibrary_border = BORDER,
        }
        widget:getSize() -- render now: the row may be painted much later
        return widget
    end
    local icon_w = math.max(8, math.floor(box_w * 0.62))
    return FrameContainer:new{
        width = box_w,
        height = box_h,
        margin = 0,
        padding = 0,
        bordersize = BORDER,
        radius = RADIUS,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = box_w, h = box_h },
            IconWidget:new{
                icon = "book.opened",
                width = icon_w,
                height = icon_w,
            },
        },
    }
end

-- 3) PDFs whose page-1 thumbnail is just text ---------------------------------

local text_page_cache = {}

local function is_pdf(item)
    if not item.filepath then return false end
    return tostring(item.filepath):lower():match("%.pdf$") ~= nil
end

local function looks_like_text_page(item, bb)
    local key = tostring(item.filepath)
    if text_page_cache[key] ~= nil then return text_page_cache[key] end
    local ok, result = pcall(function()
        local w, h = bb:getWidth(), bb:getHeight()
        local bbtype = bb:getType()
        local grayscale = (bbtype == Blitbuffer.TYPE_BB8) or (bbtype == Blitbuffer.TYPE_BB8A)
        local step = math.max(2, math.floor(math.min(w, h) / 48))
        local light, total = 0, 0
        for y = 1, h - 1, step do
            for x = 1, w - 1, step do
                local pixel = bb:getPixel(x, y)
                local luma
                if grayscale then
                    luma = pixel.a
                else
                    luma = (pixel.r + pixel.g + pixel.b) / 3
                end
                if luma > 200 then light = light + 1 end
                total = total + 1
            end
        end
        return total > 0 and (light / total) >= TEXT_PAGE_LIGHT
    end)
    if not ok then result = false end
    text_page_cache[key] = result
    return result
end

-- 4) Rebuilding one row's thumbnail -----------------------------------------

local function tune_thumbnail(item)
    if item._cleanlibrary_tuned then return end

    local node, chain = find_node(item, has_cover_image)
    local kind = "cover"
    if not node then
        node, chain = find_node(item, is_stock_placeholder)
        kind = "placeholder"
    end
    if not node or not chain then return end

    -- The cell sits in a CenterContainer whose dimen is the row's thumbnail
    -- area; replacing its child gives the gap for free.
    local left = (kind == "cover") and chain[#chain - 2] or chain[#chain - 3]
    if type(left) ~= "table" or not left.dimen then return end

    local box_w, box_h = calc_dims(left.dimen.w, left.dimen.h - 2 * GAP)
    if box_w < 8 or box_h < 8 then return end

    -- A PDF "cover" that is only text becomes the placeholder cover.
    if kind == "cover" and is_pdf(item) and looks_like_text_page(item, node.image) then
        kind = "placeholder"
    end

    local content
    if kind == "cover" then
        content = ImageWidget:new{
            image = node.image,
            image_disposable = false,
            width = box_w,
            height = box_h,
            stretch_limit_percentage = STRETCH_LIMIT,
            _cleanlibrary_round = true,
            _cleanlibrary_border = BORDER,
        }
        -- Render now, like stock does: the source Blitbuffer may be reused by
        -- the next row if the render waits until paint time.
        content:getSize()
    else
        content = build_placeholder(box_w, box_h)
    end

    left[1] = build_frame(box_w, box_h, content)
    item._cleanlibrary_tuned = true
end

-- 5) Paint-time effects -------------------------------------------------------

local function round_corners(bb, dimen, border)
    local x, y = math.floor(dimen.x), math.floor(dimen.y)
    local w, h = math.floor(dimen.w), math.floor(dimen.h)
    local r = RADIUS
    if 2 * r > w then r = math.floor(w / 2) end
    if 2 * r > h then r = math.floor(h / 2) end
    if r < 2 then return end

    local function sample(px, py)
        if px < 0 or py < 0 or px >= bb:getWidth() or py >= bb:getHeight() then
            return Blitbuffer.COLOR_WHITE
        end
        return bb:getPixel(px, py)
    end
    -- Sample outside the cell so day/night and inverted themes both work.
    local color = sample(x - border - 3, y - border - 3)

    local sqrt = math.sqrt
    for row = 0, r - 1 do
        local dy = r - row - 0.5
        local cut = r - sqrt(r * r - dy * dy)
        local n = math.floor(cut + 0.5)
        if n > 0 then
            bb:paintRect(x, y + row, n, 1, color)
            bb:paintRect(x + w - n, y + row, n, 1, color)
            bb:paintRect(x, y + h - 1 - row, n, 1, color)
            bb:paintRect(x + w - n, y + h - 1 - row, n, 1, color)
        end
    end

    -- Border last, on top of the masked image, so the mask cannot eat the
    -- rounded arcs (ZenOS opds_browser draw order).
    if border > 0 then
        bb:paintBorder(x - border, y - border, w + 2 * border, h + 2 * border,
            border, Blitbuffer.COLOR_BLACK, RADIUS, true)
    end
end

local orig_image_paint_to = ImageWidget.paintTo
function ImageWidget:paintTo(bb, x, y)
    -- CoverBrowser's list dogear ("book was opened"); mosaic uses other names.
    if self.icon == "dogear.opaque" then return end
    orig_image_paint_to(self, bb, x, y)
    if self._cleanlibrary_round and self.dimen then
        round_corners(bb, self.dimen, self._cleanlibrary_border or 0)
    end
end

-- 6) Title cleanup ------------------------------------------------------------

local function clean_widget_text(widget)
    for i = 1, #widget do
        local child = widget[i]
        if type(child) == "table" then
            if type(child.text) == "string" and child.text:find("_", 1, true)
                and type(child.setText) == "function" then
                child:setText(child.text:gsub("_", " "))
            end
            clean_widget_text(child)
        end
    end
end

-- 7) Hooking CoverBrowser's row class ----------------------------------------

local list_item_patched = false

local function find_class(build, name)
    if type(build) ~= "function" then return nil end
    local ok, cls = pcall(userpatch.getUpValue, build, name)
    if ok and type(cls) == "table" then return cls end
end

local function patch_list_item(cls)
    if cls._cleanlibrary_patched then return end
    cls._cleanlibrary_patched = true

    local orig_update = cls.update
    function cls:update(...)
        if REPLACE_UNDERSCORES and type(self.text) == "string" then
            self.text = self.text:gsub("_", " ")
        end
        orig_update(self, ...)
        if REPLACE_UNDERSCORES then clean_widget_text(self) end
        self.do_hint_opened = false
        self._cleanlibrary_tuned = nil
        tune_thumbnail(self)
    end
    logger.info("CleanLibrary: list rows hooked")
end

-- Look for CoverBrowser's ListMenuItem in the class builder first, then in a
-- specific menu instance. The class is the same object everywhere (it is a
-- module-local in listmenu.lua), so patching it once covers every list view.
local function hook_list_item(...)
    if list_item_patched then return true end

    local candidates = { FileChooser._updateItemsBuildUI }
    for i = 1, select("#", ...) do
        local extra = select(i, ...)
        if type(extra) == "table" then
            candidates[#candidates + 1] = extra._updateItemsBuildUI
        else
            candidates[#candidates + 1] = extra
        end
    end

    for _, build in ipairs(candidates) do
        local cls = find_class(build, "ListMenuItem")
        if cls then
            patch_list_item(cls)
            list_item_patched = true
            return true
        end
    end
    return false
end

-- 8) Hook installation --------------------------------------------------------

local hooks_installed = false

local function install_hooks()
    if hooks_installed then return end
    hooks_installed = true

    -- Every list rebuild goes through Menu:switchItemTable, which BookList
    -- inherits. History and Collections build their rows there without ever
    -- touching FileChooser, which is why they used to keep stock rows when
    -- opened first.
    local orig_switch_item_table = Menu.switchItemTable
    function Menu.switchItemTable(self, ...)
        self._do_hint_opened = false
        hook_list_item(self)
        return orig_switch_item_table(self, ...)
    end

    -- The file manager builds its first page inside FileChooser:init, and
    -- rebuilds on every navigation in refreshPath.
    local orig_init = FileChooser.init
    function FileChooser:init(...)
        FileChooser._do_hint_opened = false
        hook_list_item(self)
        local result = orig_init(self, ...)
        self._do_hint_opened = false
        return result
    end

    local orig_refresh_path = FileChooser.refreshPath
    function FileChooser:refreshPath(...)
        FileChooser._do_hint_opened = false
        self._do_hint_opened = false
        hook_list_item(self)
        return orig_refresh_path(self, ...)
    end
end

-- 9) Plugin ------------------------------------------------------------------

local CleanLibrary = WidgetContainer:extend{
    name = "cleanlibrary",
}

function CleanLibrary:init()
    install_hooks()

    -- Plugins are loaded after the file manager has built its first page, so
    -- refresh it once every plugin (CoverBrowser included) has applied its
    -- display mode.
    UIManager:nextTick(function()
        local fc = self.ui and self.ui.file_chooser
        if not fc then return end
        if hook_list_item(fc) then
            fc:switchItemTable(nil, nil, fc.prev_itemnumber, { dummy = "" })
        else
            logger.warn("CleanLibrary: CoverBrowser list view not found; rows left unchanged")
        end
    end)
end

return CleanLibrary

local Cache = require("cache")
local CacheItem = require("cacheitem")
local CanvasContext = require("document/canvascontext")
local DocSettings = require("docsettings")
local Document = require("document/document")
local DrawContext = require("ffi/drawcontext")
local logger = require("logger")
local util = require("util")
local ffi = require("ffi")
local C = ffi.C
local pdf = nil

local PdfDocument = Document:new{
    _document = false,
    is_pdf = true,
    dc_null = DrawContext.new(),
    koptinterface = nil,
    provider = "mupdf",
    provider_name = "MuPDF",
}

function PdfDocument:init()
    if not pdf then pdf = require("ffi/mupdf") end
    -- mupdf.color has to stay false for kopt to work correctly
    -- and be accurate (including its job about showing highlight
    -- boxes). We will turn it on and off in PdfDocument:preRenderPage()
    -- and :postRenderPage() when mupdf is called without kopt involved.
    pdf.color = false
    self:updateColorRendering()
    self.koptinterface = require("document/koptinterface")
    self.koptinterface:setDefaultConfigurable(self.configurable)
    local ok
    ok, self._document = pcall(pdf.openDocument, self.file)
    if not ok then
        error(self._document)  -- will contain error message
    end
    self.is_reflowable = self._document:isDocumentReflowable()
    self.reflowable_font_size = self:convertKoptToReflowableFontSize()
    -- no-op on PDF
    self:layoutDocument()
    self.is_open = true
    self.info.has_pages = true
    self.info.configurable = true
    if self._document:needsPassword() then
        self.is_locked = true
    else
        self:_readMetadata()
    end
end

function PdfDocument:layoutDocument(font_size)
    if font_size then
        self.reflowable_font_size = font_size
    end
    self._document:layoutDocument(
        CanvasContext:getWidth(),
        CanvasContext:getHeight(),
        CanvasContext:scaleBySize(self.reflowable_font_size))
end

local default_font_size = 22
-- the koptreader config goes from 0.1 to 3.0, but we want a regular font size
function PdfDocument:convertKoptToReflowableFontSize(font_size)
    if font_size then
        return font_size * default_font_size
    end

    local size
    if DocSettings:hasSidecarFile(self.file) then
        local doc_settings = DocSettings:open(self.file)
        size = doc_settings:readSetting("kopt_font_size")
        doc_settings:close()
    end
    if size then
        return size * default_font_size
    elseif G_reader_settings:readSetting("kopt_font_size") then
        return G_reader_settings:readSetting("kopt_font_size") * default_font_size
    elseif DKOPTREADER_CONFIG_FONT_SIZE then
        return DKOPTREADER_CONFIG_FONT_SIZE * default_font_size
    else
        return default_font_size
    end
end

function PdfDocument:preRenderPage()
    pdf.color = self.render_color
end

function PdfDocument:postRenderPage()
    pdf.color = false
end

function PdfDocument:unlock(password)
    if not self._document:authenticatePassword(password) then
        return false
    end
    self.is_locked = false
    self:_readMetadata()
    return true
end

function PdfDocument:getPageTextBoxes(pageno)
    local page = self._document:openPage(pageno)
    local text = page:getPageText()
    page:close()
    return text
end

function PdfDocument:getWordFromPosition(spos)
    return self.koptinterface:getWordFromPosition(self, spos)
end

function PdfDocument:getTextFromPositions(spos0, spos1)
    return self.koptinterface:getTextFromPositions(self, spos0, spos1)
end

function PdfDocument:getPageBoxesFromPositions(pageno, ppos0, ppos1)
    return self.koptinterface:getPageBoxesFromPositions(self, pageno, ppos0, ppos1)
end

function PdfDocument:nativeToPageRectTransform(pageno, rect)
    return self.koptinterface:nativeToPageRectTransform(self, pageno, rect)
end

function PdfDocument:getOCRWord(pageno, wbox)
    return self.koptinterface:getOCRWord(self, pageno, wbox)
end

function PdfDocument:getOCRText(pageno, tboxes)
    return self.koptinterface:getOCRText(self, pageno, tboxes)
end

function PdfDocument:getPageBlock(pageno, x, y)
    return self.koptinterface:getPageBlock(self, pageno, x, y)
end

function PdfDocument:getUsedBBox(pageno)
    local hash = "pgubbox|"..self.file.."|"..self.reflowable_font_size.."|"..pageno
    local cached = Cache:check(hash)
    if cached then
        return cached.ubbox
    end
    local page = self._document:openPage(pageno)
    local used = {}
    used.x0, used.y0, used.x1, used.y1 = page:getUsedBBox()
    local pwidth, pheight = page:getSize(self.dc_null)
    -- clamp to page BBox
    if used.x0 < 0 then used.x0 = 0 end
    if used.x1 > pwidth then used.x1 = pwidth end
    if used.y0 < 0 then used.y0 = 0 end
    if used.y1 > pheight then used.y1 = pheight end
    --- @todo Give size for cacheitem?  02.12 2012 (houqp)
    Cache:insert(hash, CacheItem:new{
        ubbox = used,
    })
    page:close()
    return used
end

function PdfDocument:getPageLinks(pageno)
    local hash = "pglinks|"..self.file.."|"..self.reflowable_font_size.."|"..pageno
    local cached = Cache:check(hash)
    if cached then
        return cached.links
    end
    local page = self._document:openPage(pageno)
    local links = page:getPageLinks()
    Cache:insert(hash, CacheItem:new{
        links = links,
    })
    page:close()
    return links
end

function PdfDocument:saveHighlight(pageno, item)
    local suffix = util.getFileNameSuffix(self.file)
    if string.lower(suffix) ~= "pdf" then return end

    self.is_edited = true
    -- will also need mupdf_h.lua to be evaluated once
    -- but this is guaranteed at this point
    local n = #item.pboxes
    local quadpoints = ffi.new("float[?]", 8*n)
    for i=1, n do
        -- The order must be left bottom, right bottom, left top, right top.
        -- https://bugs.ghostscript.com/show_bug.cgi?id=695130
        quadpoints[8*i-8] = item.pboxes[i].x
        quadpoints[8*i-7] = item.pboxes[i].y + item.pboxes[i].h
        quadpoints[8*i-6] = item.pboxes[i].x + item.pboxes[i].w
        quadpoints[8*i-5] = item.pboxes[i].y + item.pboxes[i].h
        quadpoints[8*i-4] = item.pboxes[i].x
        quadpoints[8*i-3] = item.pboxes[i].y
        quadpoints[8*i-2] = item.pboxes[i].x + item.pboxes[i].w
        quadpoints[8*i-1] = item.pboxes[i].y
    end
    local page = self._document:openPage(pageno)
    local annot_type = C.PDF_ANNOT_HIGHLIGHT
    if item.drawer == "lighten" then
        annot_type = C.PDF_ANNOT_HIGHLIGHT
    elseif item.drawer == "underscore" then
        annot_type = C.PDF_ANNOT_UNDERLINE
    elseif item.drawer == "strikeout" then
        annot_type = C.PDF_ANNOT_STRIKEOUT
    end
    page:addMarkupAnnotation(quadpoints, n, annot_type)
    page:close()
end

function PdfDocument:writeDocument()
    logger.info("writing document to", self.file)
    self._document:writeDocument(self.file)
end

function PdfDocument:close()
    if self.is_edited then
        self:writeDocument()
    end
    Document.close(self)
end

function PdfDocument:getProps()
    local props = self._document:getMetadata()
    if props.title == "" then
        local startPos = util.lastIndexOf(self.file, "%/")
        if startPos > 0  then
            props.title = string.sub(self.file, startPos + 1, -5) --remove extension .pdf
        else
            props.title = string.sub(self.file, 0, -5)
        end
    end
    props.authors = props.author
    props.series = ""
    props.language = ""
    props.keywords = props.keywords
    props.description = props.subject
    return props
end

function PdfDocument:getLinkFromPosition(pageno, pos)
    return self.koptinterface:getLinkFromPosition(self, pageno, pos)
end

function PdfDocument:clipPagePNGFile(pos0, pos1, pboxes, drawer, filename)
    return self.koptinterface:clipPagePNGFile(self, pos0, pos1, pboxes, drawer, filename)
end

function PdfDocument:clipPagePNGString(pos0, pos1, pboxes, drawer)
    return self.koptinterface:clipPagePNGString(self, pos0, pos1, pboxes, drawer)
end

function PdfDocument:getPageBBox(pageno)
    return self.koptinterface:getPageBBox(self, pageno)
end

function PdfDocument:getPageDimensions(pageno, zoom, rotation)
    return self.koptinterface:getPageDimensions(self, pageno, zoom, rotation)
end

function PdfDocument:getCoverPageImage()
    return self.koptinterface:getCoverPageImage(self)
end

function PdfDocument:findText(pattern, origin, reverse, caseInsensitive, page)
    return self.koptinterface:findText(self, pattern, origin, reverse, caseInsensitive, page)
end

function PdfDocument:renderPage(pageno, rect, zoom, rotation, gamma, render_mode)
    return self.koptinterface:renderPage(self, pageno, rect, zoom, rotation, gamma, render_mode)
end

function PdfDocument:hintPage(pageno, zoom, rotation, gamma, render_mode)
    return self.koptinterface:hintPage(self, pageno, zoom, rotation, gamma, render_mode)
end

function PdfDocument:drawPage(target, x, y, rect, pageno, zoom, rotation, gamma, render_mode)
    return self.koptinterface:drawPage(self, target, x, y, rect, pageno, zoom, rotation, gamma, render_mode)
end

function PdfDocument:register(registry)
    --- Document types ---
    registry:addProvider("cbt", "application/vnd.comicbook+tar", self, 100)
    registry:addProvider("cbz", "application/vnd.comicbook+zip", self, 100)
    registry:addProvider("epub", "application/epub+zip", self, 50)
    registry:addProvider("fb2", "application/fb2", self, 80)
    registry:addProvider("htm", "text/html", self, 90)
    registry:addProvider("html", "text/html", self, 90)
    registry:addProvider("pdf", "application/pdf", self, 100)
    registry:addProvider("tar", "application/x-tar", self, 10)
    registry:addProvider("xhtml", "application/xhtml+xml", self, 100)
    registry:addProvider("xml", "application/xml", self, 10)
    registry:addProvider("xps", "application/oxps", self, 100)
    registry:addProvider("zip", "application/zip", self, 20)

    --- Picture types ---
    registry:addProvider("gif", "image/gif", self, 90)
    -- MS HD Photo == JPEG XR
    registry:addProvider("hdp", "image/vnd.ms-photo", self, 90)
    registry:addProvider("j2k", "image/jp2", self, 90)
    registry:addProvider("jp2", "image/jp2", self, 90)
    registry:addProvider("jpeg", "image/jpeg", self, 90)
    registry:addProvider("jpg", "image/jpeg", self, 90)
    -- JPEG XR
    registry:addProvider("jxr", "image/jxr", self, 90)
    registry:addProvider("pam", "image/x-portable-arbitrarymap", self, 90)
    registry:addProvider("pbm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("pgm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("png", "image/png", self, 90)
    registry:addProvider("pnm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("ppm", "image/x‑portable‑bitmap", self, 90)
    registry:addProvider("svg", "image/svg+xml", self, 90)
    registry:addProvider("tif", "image/tiff", self, 90)
    registry:addProvider("tiff", "image/tiff", self, 90)
    -- Windows Media Photo == JPEG XR
    registry:addProvider("wdp", "image/vnd.ms-photo", self, 90)
end

return PdfDocument

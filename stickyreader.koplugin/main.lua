local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Screensaver = require("ui/screensaver")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen
local json = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local POLL_SECONDS = 300   -- how often to check while the device is awake and online
local HISTORY_MAX = 100

local StickyReader = WidgetContainer:extend{
    name = "stickyreader",
    is_doc_only = false,
}

local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/stickyreader.lua")

-- Minimal HTTP/JSON client for the relay. Returns decoded body or nil, err.
local function request(method, path, body, timeouts)
    local base = settings:readSetting("server")
    if not base or base == "" then return nil, _("Set the relay server URL first.") end
    local chunks = {}
    local payload = body and json.encode(body) or nil
    local headers = { ["Content-Type"] = "application/json" }
    if payload then headers["Content-Length"] = tostring(#payload) end
    local token = settings:readSetting("token")
    if token then headers["Authorization"] = "Bearer " .. token end
    socketutil:set_timeout(timeouts and timeouts[1] or 10, timeouts and timeouts[2] or 30)
    local client = base:match("^https://") and https or http
    local code = socket.skip(1, client.request{
        url = base:gsub("/+$", "") .. path,
        method = method,
        headers = headers,
        source = payload and ltn12.source.string(payload) or nil,
        sink = ltn12.sink.table(chunks),
    })
    socketutil:reset_timeout()
    local ok, data = pcall(json.decode, table.concat(chunks))
    if code ~= 200 then
        return nil, (ok and type(data) == "table" and data.error) or (_("HTTP error: ") .. tostring(code))
    end
    return ok and data or {}
end

-- UTF-8 safe truncation to n characters.
local function shorten(text, n)
    text = text:gsub("%s+", " ")
    local out, count = {}, 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > n then return table.concat(out) .. "…" end
        out[#out + 1] = ch
    end
    return text
end

local function noteFontSize(len)
    if len <= 60 then return 54 elseif len <= 140 then return 44 elseif len <= 300 then return 34 end
    return 26
end

-- A framed "card": small label, the note in large type, and when it was received.
local function buildNoteCard(note, ts)
    local w = Screen:getWidth()
    local inner_w = math.floor(w * 0.72)
    local gray = Blitbuffer.COLOR_DARK_GRAY
    local function rule()
        return LineWidget:new{
            dimen = Geom:new{ w = math.floor(inner_w * 0.25), h = Size.line.thick },
            background = Blitbuffer.COLOR_BLACK,
        }
    end
    note = shorten(note, 600)
    local group = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = _("A NOTE FOR YOU"), face = Font:getFace("cfont", 18), bold = true, fgcolor = gray },
        VerticalSpan:new{ width = Screen:scaleBySize(14) },
        rule(),
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        TextBoxWidget:new{
            text = note,
            face = Font:getFace("cfont", noteFontSize(#note)),
            width = inner_w,
            alignment = "center",
            line_height = 0.2,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(24) },
        rule(),
        VerticalSpan:new{ width = Screen:scaleBySize(14) },
        TextWidget:new{
            text = os.date("%A %d %B · %H:%M", ts or os.time()),
            face = Font:getFace("cfont", 18),
            fgcolor = gray,
        },
    }
    local card = FrameContainer:new{
        bordersize = Size.border.thick,
        radius = Size.radius.window,
        padding = Screen:scaleBySize(36),
        background = Blitbuffer.COLOR_WHITE,
        group,
    }
    return FrameContainer:new{ -- thin outer frame for a double-border look
        bordersize = Size.border.thin,
        radius = Size.radius.window,
        padding = Screen:scaleBySize(6),
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        card,
    }
end

function StickyReader:init()
    self.ui.menu:registerToMainMenu(self)
    self:hookScreensaver()
    -- Periodic check while the device is awake and already online (never turns Wi-Fi on).
    self.pollTask = function()
        if settings:nilOrTrue("auto_sync") then self:sync{ quiet = true } end
        UIManager:scheduleIn(POLL_SECONDS, self.pollTask)
    end
    UIManager:scheduleIn(60, self.pollTask)
end

function StickyReader:onCloseWidget()
    if self.pollTask then UIManager:unschedule(self.pollTask) end
end

function StickyReader:isPaired() return settings:readSetting("token") ~= nil end

function StickyReader:withNetwork(fn)
    if NetworkMgr:isOnline() then
        fn()
    else
        NetworkMgr:runWhenOnline(fn)
    end
end

function StickyReader:toast(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

function StickyReader:addHistory(dir, text, ts)
    local history = settings:readSetting("history") or {}
    table.insert(history, 1, { dir = dir, text = text, ts = ts or os.time() })
    while #history > HISTORY_MAX do table.remove(history) end
    settings:saveSetting("history", history)
end

-- Fetch notes addressed to us. opts.quiet: no prompts, only if already online, small toast.
function StickyReader:sync(opts)
    opts = opts or {}
    if not self:isPaired() then return end
    local function run()
        local res, err = request("GET", "/messages?after=" .. (settings:readSetting("last_id") or 0),
            nil, opts.quiet and { 5, 10 } or nil)
        if not res then
            if not opts.quiet then self:toast(err) end
            return
        end
        local msgs = res.messages or {}
        if #msgs > 0 then
            for _i, m in ipairs(msgs) do self:addHistory("in", m.text, m.ts) end
            local last = msgs[#msgs]
            settings:saveSetting("last_id", last.id)
            settings:saveSetting("note", last.text)
            settings:saveSetting("note_ts", last.ts)
            settings:flush()
            if opts.quiet then
                Notification:notify(_("New note: ") .. shorten(last.text, 50))
            else
                self:toast(_("New note received:\n") .. last.text)
            end
        elseif not opts.quiet then
            self:toast(_("No new notes."))
        end
    end
    if opts.quiet then
        if NetworkMgr:isOnline() then run() end
    else
        self:withNetwork(run)
    end
end

function StickyReader:writeNote()
    local dialog
    dialog = InputDialog:new{
        title = _("Note for your partner"),
        input_type = "text",
        allow_newline = true,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Send"), is_enter_default = false, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                if util.trim(text) == "" then return end
                self:withNetwork(function()
                    local res, err = request("POST", "/messages", { text = text })
                    if res then
                        self:addHistory("out", text)
                        settings:flush()
                    end
                    self:toast(err or _("Note sent."))
                end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function StickyReader:pairCreate()
    self:withNetwork(function()
        local res, err = request("POST", "/pair/create", {})
        if not res then return self:toast(err) end
        settings:saveSetting("token", res.token)
        settings:saveSetting("last_id", 0)
        settings:flush()
        self:toast(_("Enter this code on the other device (valid 10 min):\n\n") .. res.code)
    end)
end

function StickyReader:pairJoin()
    local dialog
    dialog = InputDialog:new{
        title = _("Pairing code from the other device"),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Pair"), callback = function()
                local code = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                self:withNetwork(function()
                    local res, err = request("POST", "/pair/join", { code = code })
                    if not res then return self:toast(err) end
                    settings:saveSetting("token", res.token)
                    settings:saveSetting("last_id", 0)
                    settings:flush()
                    self:toast(_("Paired!"))
                end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Show a QR code (and the URL) that opens a send-a-note page on a phone.
function StickyReader:linkPhone()
    self:withNetwork(function()
        local res, err = request("POST", "/phone/link", {})
        if not res then return self:toast(err) end
        local url = settings:readSetting("server"):gsub("/+$", "") .. res.path
        local ok = pcall(function()
            local QRMessage = require("ui/widget/qrmessage")
            UIManager:show(QRMessage:new{
                text = url,
                width = Screen:getWidth(),
                height = Screen:getHeight(),
            })
        end)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Open this on your phone:\n\n") .. url })
        end
    end)
end

function StickyReader:unpair()
    if self:isPaired() then
        self:withNetwork(function() request("POST", "/unpair", {}) end)
    end
    for _i, k in ipairs{ "token", "last_id", "note", "note_ts" } do settings:delSetting(k) end
    settings:flush()
    self:toast(_("Unpaired."))
end

function StickyReader:setServer()
    local dialog
    dialog = InputDialog:new{
        title = _("Relay server URL (e.g. https://notes.example.com)"),
        input = settings:readSetting("server") or "https://",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Save"), callback = function()
                settings:saveSetting("server", util.trim(dialog:getInputText()))
                settings:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function StickyReader:historyItems()
    local items = {}
    for _i, h in ipairs(settings:readSetting("history") or {}) do
        local when = os.date("%d %b %H:%M", h.ts)
        items[#items + 1] = {
            text = (h.dir == "in" and _("In") or _("Out")) .. " · " .. when .. " · " .. shorten(h.text, 40),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = (h.dir == "in" and _("Received ") or _("Sent ")) .. os.date("%A %d %B, %H:%M", h.ts) .. "\n\n" .. h.text,
                })
            end,
        }
    end
    if #items == 0 then items[1] = { text = _("No notes yet"), enabled = false } else
        items[#items + 1] = {
            text = _("Clear history"),
            callback = function()
                settings:delSetting("history")
                settings:flush()
            end,
        }
    end
    return items
end

function StickyReader:addToMainMenu(menu_items)
    local function flag(key, default_on)
        return {
            checked_func = function()
                if default_on then return settings:nilOrTrue(key) end
                return settings:isTrue(key)
            end,
            callback = function()
                local on = default_on and settings:nilOrTrue(key) or settings:isTrue(key)
                settings:saveSetting(key, not on)
                settings:flush()
            end,
        }
    end
    local paired = function() return self:isPaired() end
    local show_note = flag("show_note", true)
    show_note.text = _("Show note on sleep screen")
    local auto_sync = flag("auto_sync", true)
    auto_sync.text = _("Fetch new notes automatically")
    local wifi_wake = flag("wifi_on_wake", false)
    wifi_wake.text = _("Turn on Wi-Fi briefly when waking up")
    menu_items.stickyreader = {
        text = _("Sticky Reader"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Write a note"), enabled_func = paired, callback = function() self:writeNote() end },
            { text = _("Check for new notes"), enabled_func = paired, callback = function() self:sync() end },
            { text = _("History"), enabled_func = paired, sub_item_table_func = function() return self:historyItems() end },
            { text = _("Link phone (QR code)"), enabled_func = paired, callback = function() self:linkPhone() end },
            { text = _("Settings"), sub_item_table = {
                show_note, auto_sync, wifi_wake,
                { text = _("Relay server URL"), keep_menu_open = true, callback = function() self:setServer() end },
            }},
            { text = _("Pairing"), sub_item_table = {
                { text = _("Create code"), callback = function() self:pairCreate() end },
                { text = _("Enter code"), callback = function() self:pairJoin() end },
                { text = _("Unpair"), enabled_func = paired, callback = function() self:unpair() end },
            }},
        },
    }
end

function StickyReader:onResume()
    -- Dismiss our note screen on wake, whatever the global "sleep screen delay" is.
    if Screensaver._stickyreader_note_shown then
        Screensaver._stickyreader_note_shown = false
        UIManager:scheduleIn(0.5, function() Screensaver:close_widget() end)
    end
    if self:isPaired() and settings:nilOrTrue("auto_sync") then
        UIManager:scheduleIn(3, function() self:syncOnWake() end)
    end
end

-- Fetch right after waking. Wi-Fi is only switched on if the user opted in, and switched back off after.
function StickyReader:syncOnWake()
    if NetworkMgr:isOnline() then
        self:sync{ quiet = true }
    elseif settings:isTrue("wifi_on_wake") and NetworkMgr.turnOnWifiAndWaitForConnection then
        NetworkMgr:turnOnWifiAndWaitForConnection(function()
            self:sync{ quiet = true }
            if NetworkMgr.turnOffWifi then NetworkMgr:turnOffWifi() end
        end)
    end
end

-- Draw the latest received note as the sleep screen instead of the normal one.
function StickyReader:hookScreensaver()
    if Screensaver._stickyreader_hooked then return end
    Screensaver._stickyreader_hooked = true
    local orig_show = Screensaver.show
    Screensaver.show = function(ss, ...)
        local note = settings:readSetting("note")
        if not note or settings:readSetting("show_note") == false then
            return orig_show(ss, ...)
        end
        local w, h = Screen:getWidth(), Screen:getHeight()
        -- Use KOReader's own ScreenSaverWidget so tap/key/wake dismissal and cleanup work.
        local ScreenSaverWidget = require("ui/widget/screensaverwidget")
        ss.screensaver_widget = ScreenSaverWidget:new{
            background = Blitbuffer.COLOR_WHITE,
            covers_fullscreen = true,
            widget = CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                buildNoteCard(note, settings:readSetting("note_ts")),
            },
        }
        ss.screensaver_widget.modal = true
        ss.screensaver_widget.dithered = true
        Screensaver._stickyreader_note_shown = true
        UIManager:show(ss.screensaver_widget, "full")
    end
end

return StickyReader

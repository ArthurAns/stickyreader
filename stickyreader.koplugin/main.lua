local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local Screensaver = require("ui/screensaver")
local UIManager = require("ui/uimanager")
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

local StickyReader = WidgetContainer:extend{
    name = "stickyreader",
    is_doc_only = false,
}

local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/stickyreader.lua")

-- Minimal HTTP/JSON client for the relay. Returns decoded body or nil, err.
local function request(method, path, body)
    local base = settings:readSetting("server")
    if not base or base == "" then return nil, _("Set the relay server URL first.") end
    local chunks = {}
    local payload = body and json.encode(body) or nil
    local headers = { ["Content-Type"] = "application/json" }
    if payload then headers["Content-Length"] = tostring(#payload) end
    local token = settings:readSetting("token")
    if token then headers["Authorization"] = "Bearer " .. token end
    socketutil:set_timeout(10, 30)
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

function StickyReader:init()
    self.ui.menu:registerToMainMenu(self)
    self:hookScreensaver()
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

-- Fetch notes addressed to us; keep the newest as the sleep-screen note.
function StickyReader:sync(silent)
    if not self:isPaired() then return end
    self:withNetwork(function()
        local res, err = request("GET", "/messages?after=" .. (settings:readSetting("last_id") or 0))
        if not res then
            if not silent then self:toast(err) end
            return
        end
        local msgs = res.messages or {}
        if #msgs > 0 then
            local last = msgs[#msgs]
            settings:saveSetting("last_id", last.id)
            settings:saveSetting("note", last.text)
            settings:saveSetting("note_ts", last.ts)
            settings:flush()
            if not silent then self:toast(_("New note received:\n") .. last.text) end
        elseif not silent then
            self:toast(_("No new notes."))
        end
    end)
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
                    local _res, err = request("POST", "/messages", { text = text })
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
        title = _("Relay server URL (e.g. http://192.168.1.10:8787)"),
        input = settings:readSetting("server") or "http://",
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

function StickyReader:addToMainMenu(menu_items)
    menu_items.stickyreader = {
        text = _("Sticky Reader"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Write a note"), enabled_func = function() return self:isPaired() end,
              callback = function() self:writeNote() end },
            { text = _("Link phone (QR code)"), enabled_func = function() return self:isPaired() end,
              callback = function() self:linkPhone() end },
            { text = _("Check for new notes"), enabled_func = function() return self:isPaired() end,
              callback = function() self:sync() end },
            { text = _("Show note on sleep screen"), checked_func = function()
                  return settings:readSetting("show_note") ~= false end,
              callback = function()
                  settings:saveSetting("show_note", settings:readSetting("show_note") == false)
                  settings:flush()
              end },
            { text = _("Sync when waking up"), checked_func = function()
                  return settings:isTrue("sync_on_resume") end,
              callback = function() settings:toggle("sync_on_resume"); settings:flush() end },
            { text = _("Relay server URL"), keep_menu_open = true, callback = function() self:setServer() end },
            { text = _("Pair: create code"), callback = function() self:pairCreate() end },
            { text = _("Pair: enter code"), callback = function() self:pairJoin() end },
            { text = _("Unpair"), enabled_func = function() return self:isPaired() end,
              callback = function() self:unpair() end },
        },
    }
end

function StickyReader:onResume()
    -- Dismiss our note screen on wake, whatever the global "sleep screen delay" is.
    if Screensaver._stickyreader_note_shown then
        Screensaver._stickyreader_note_shown = false
        UIManager:scheduleIn(0.5, function() Screensaver:close_widget() end)
    end
    if settings:isTrue("sync_on_resume") and NetworkMgr:isOnline() then
        UIManager:scheduleIn(3, function() self:sync(true) end)
    end
end

-- Draw the received note as a full-screen sleep screen instead of the normal one.
function StickyReader:hookScreensaver()
    if Screensaver._stickyreader_hooked then return end
    Screensaver._stickyreader_hooked = true
    local orig_show = Screensaver.show
    Screensaver.show = function(ss, ...)
        local note = settings:readSetting("note")
        if not note or settings:readSetting("show_note") == false then
            return orig_show(ss, ...)
        end
        local FrameContainer = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local Blitbuffer = require("ffi/blitbuffer")
        local Font = require("ui/font")
        local Geom = require("ui/geometry")
        local Size = require("ui/size")
        local w, h = Screen:getWidth(), Screen:getHeight()
        local text = TextBoxWidget:new{
            text = note,
            face = Font:getFace("cfont", 34),
            width = math.floor(w * 0.8),
            alignment = "center",
        }
        -- Use KOReader's own ScreenSaverWidget so tap/key/wake dismissal and cleanup work.
        local ScreenSaverWidget = require("ui/widget/screensaverwidget")
        ss.screensaver_widget = ScreenSaverWidget:new{
            background = Blitbuffer.COLOR_WHITE,
            covers_fullscreen = true,
            widget = CenterContainer:new{
                dimen = Geom:new{ w = w, h = h },
                FrameContainer:new{
                    bordersize = Size.border.thick, padding = Size.padding.large,
                    background = Blitbuffer.COLOR_WHITE, text,
                },
            },
        }
        ss.screensaver_widget.modal = true
        ss.screensaver_widget.dithered = true
        Screensaver._stickyreader_note_shown = true
        UIManager:show(ss.screensaver_widget, "full")
    end
end

return StickyReader

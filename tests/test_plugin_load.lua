-- Loads main.lua + icloudsync_io.lua against stubbed KOReader modules to catch
-- require / nil-index / wiring mistakes that only a real KOReader would hit.
local H = require("tests.harness")
local test, eq = H.test, H.eq

-- Stubs --------------------------------------------------------------------
local shown, closed, scheduled, broadcasts = {}, {}, {}, {}
local http_log, http_reply = {}, nil
local settings_store = {}
local json_replies = {}

local function widget(kind)
    return { new = function(_, o) o = o or {}; o.kind = kind; return o end }
end

local stubs = {
    ["ui/widget/confirmbox"] = widget("ConfirmBox"),
    ["ui/widget/infomessage"] = widget("InfoMessage"),
    ["ui/widget/inputdialog"] = {
        new = function(_, o)
            o.kind = "InputDialog"
            function o:getInputText() return o.test_input end
            function o:onShowKeyboard() end
            return o
        end,
    },
    ["ui/widget/notification"] = { notify = function(_, text) table.insert(shown, { kind = "Notification", text = text }) end },
    ["ui/uimanager"] = {
        show = function(_, w) table.insert(shown, w) end,
        close = function(_, w) table.insert(closed, w) end,
        scheduleIn = function(_, _s, fn) table.insert(scheduled, fn) end,
        forceRePaint = function() end,
        broadcastEvent = function(_, ev) table.insert(broadcasts, ev.name) end,
    },
    ["ui/widget/container/widgetcontainer"] = {
        extend = function(self, o)
            o.__index = o
            o.new = function(cls, inst) inst = setmetatable(inst or {}, cls); if inst.init then inst:init() end; return inst end
            return o
        end,
    },
    ["dispatcher"] = { registerAction = function(_, id, spec) _G.__dispatch = { id = id, spec = spec } end },
    ["logger"] = { err = function() end, warn = function() end, info = function() end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = {
        template = function(fmt, ...)
            local args = { ... }
            return (fmt:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
    },
    ["datastorage"] = { getSettingsDir = function() return "/tmp/settings" end },
    ["luasettings"] = {
        open = function()
            return {
                readSetting = function(_, k) return settings_store[k] end,
                saveSetting = function(_, k, v) settings_store[k] = v end,
                flush = function() end,
            }
        end,
    },
    ["socket.http"] = {
        request = function(req)
            table.insert(http_log, req)
            local code, body = http_reply(req)
            if type(code) == "string" then return nil, code end
            if body and req.sink then req.sink(body) end
            return 1, code, {}, "status"
        end,
    },
    ["ltn12"] = {
        sink = { table = function(t) return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end end },
        source = { file = function(fh) return function() return nil end end },
    },
    ["libs/libkoreader-lfs"] = {},
    ["socketutil"] = { set_timeout = function() end, reset_timeout = function() end },
    ["rapidjson"] = { decode = function(s) return json_replies[s] end },
    ["ui/network/manager"] = {
        runWhenOnline = function(_, fn) fn() end,
        isConnected = function() return true end,
    },
    ["apps/filemanager/filemanager"] = { instance = nil },
    ["ui/event"] = { new = function(_, name) return { name = name } end },
}
for name, mod in pairs(stubs) do package.preload[name] = function() return mod end end

_G.G_reader_settings = {
    data = {},
    readSetting = function(self, k, default) local v = self.data[k]; if v == nil then return default end return v end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    flush = function() end,
}

local ICloudSync = require("main")
local IO = require("icloudsync_io")

local registered
local function newPlugin(extra_ui)
    local ui = { menu = { registerToMainMenu = function(_, p) registered = p end } }
    for k, v in pairs(extra_ui or {}) do ui[k] = v end
    return ICloudSync:new{ ui = ui }
end

local function lastShown() return shown[#shown] end

-- Tests --------------------------------------------------------------------

test("plugin loads, registers menu and dispatcher action", function()
    local p = newPlugin()
    eq(registered == p, true)
    eq(_G.__dispatch.id, "icloudsync_sync")
    eq(p.settings.download_dir, "/mnt/us/Books")
    local items = {}
    p:addToMainMenu(items)
    eq(items.icloudsync.sorting_hint, "tools")
    for _, item in ipairs(items.icloudsync.sub_item_table) do
        if item.text_func then assert(type(item.text_func()) == "string") end
        if item.checked_func then assert(item.checked_func() == true) end
    end
    eq(p:lastSyncText(), "Last sync: never")
end)

test("sync without configuration asks for setup", function()
    local p = newPlugin()
    p:syncNow()
    eq(lastShown().kind, "InfoMessage")
    assert(lastShown().text:find("server address"), lastShown().text)
end)

test("editing server setting saves it", function()
    local p = newPlugin()
    p:editSetting("server", "t", "h")
    local dlg = lastShown()
    dlg.test_input = "  192.168.1.20:8765 "
    dlg.buttons[1][2].callback()
    eq(G_reader_settings.data.icloudsync.server, "192.168.1.20:8765")
end)

test("unreachable bridge -> failure message and last_sync.error", function()
    G_reader_settings.data.icloudsync = { server = "10.0.0.9:8765", token = "tok" }
    http_reply = function() return "connection refused" end
    local p = newPlugin()
    p:syncNow()
    local msg = lastShown()
    assert(msg.text:find("not reachable"), msg.text)
    assert(p.settings.last_sync.error:find("connection refused"))
    assert(p:lastSyncText():find("failed"))
    eq(http_log[#http_log].headers["X-Sync-Token"], "tok")
end)

test("bad token is reported as such", function()
    http_reply = function() return 401, "" end
    local p = newPlugin()
    p:syncNow()
    assert(lastShown().text:find("Bad token"), lastShown().text)
end)

test("auto sync is throttled, scheduled, and reports a failure once", function()
    http_reply = function() return "timeout" end
    G_reader_settings.data.icloudsync.auto_update_check = false
    local p = newPlugin()
    local before = #shown
    p:onNetworkConnected()
    eq(#scheduled, 1)
    scheduled[1]()
    eq(#shown, before + 1)
    eq(lastShown(), { kind = "Notification", text = "iCloud sync failed: Mac bridge not reachable (timeout)" })
    p:onNetworkConnected()
    eq(#scheduled, 1, "throttled within 5 minutes")
    p:runSync{ auto = true }
    eq(#shown, before + 1, "the same failure isn't repeated on every wake")
end)

test("open document and its sidecar are skipped", function()
    local p = newPlugin({ document = { file = "/mnt/us/Books/Fic/Dune.epub" } })
    local skip = p:openDocumentSkipper()
    eq(skip("Fic/Dune.epub"), true)
    eq(skip("Fic/Dune.sdr/metadata.epub.lua"), true)
    eq(skip("Fic/Dune 2.epub"), false)
    local outside = newPlugin({ document = { file = "/mnt/us/documents/Other.epub" } })
    eq(outside:openDocumentSkipper(), nil)
end)

test("urlEncodePath encodes per segment", function()
    eq(IO.urlEncodePath("Fic/Café Ü & Co.epub"), "Fic/Caf%C3%A9%20%C3%9C%20%26%20Co.epub")
end)

test("transport builds correct manifest / upload / delete requests", function()
    local t = IO.newTransport("http://192.168.1.20:8765/", "tok")
    json_replies["MANIFEST"] = { version = 1, files = {} }
    json_replies["PUTRESP"] = { path = "a b.epub", size = 3, mtime = 42 }
    http_reply = function(req)
        if req.url:find("/manifest$") then return 200, "MANIFEST" end
        if req.method == "PUT" then return 201, "PUTRESP" end
        if req.method == "DELETE" then return 204, "" end
    end
    eq(t.manifest(), { version = 1, files = {} })
    eq(http_log[#http_log].url, "http://192.168.1.20:8765/manifest")

    local src = os.tmpname()
    local f = io.open(src, "wb"); f:write("abc"); f:close()
    eq(t.upload("a b.epub", src, 3, 42), { path = "a b.epub", size = 3, mtime = 42 })
    os.remove(src)
    local put = http_log[#http_log]
    eq({ put.method, put.url, put.headers["Content-Length"], put.headers["X-Mtime"] },
       { "PUT", "http://192.168.1.20:8765/file/a%20b.epub", "3", "42" })

    eq(t.delete("x.epub", "run1"), true)
    eq(http_log[#http_log].headers["X-Run-Id"], "run1")
end)

test("transport download writes body to file", function()
    local t = IO.newTransport("h:1", "tok")
    http_reply = function() return 200, "BOOKDATA" end
    local dest = os.tmpname()
    eq(t.download("b.epub", dest), true)
    local f = io.open(dest, "rb"); local data = f:read("*a"); f:close(); os.remove(dest)
    eq(data, "BOOKDATA")
    http_reply = function() return 404, "" end
    local ok, err = t.download("b.epub", os.tmpname())
    eq({ ok, err }, { nil, "no longer in iCloud" })
    http_reply = function() return 409, "" end
    eq({ t.download("b.epub", os.tmpname()) }, { nil, "HTTP 409" })
end)

test("changed sync refreshes Bookshelf; up-to-date sync doesn't", function()
    local invalidated = 0
    package.loaded["lib/bookshelf_book_repository"] = { invalidateWalkCache = function() invalidated = invalidated + 1 end }
    G_reader_settings.data.icloudsync = { server = "h:1", token = "tok" }
    G_reader_settings.data.home_dir = "/mnt/us"
    json_replies["M1"] = { version = 1, files = { { path = "b.epub", size = 4, mtime = 7 } } }
    json_replies["M0"] = { version = 1, files = {} }
    local p = newPlugin()
    -- Fake the engine result instead of real file IO (lfs is stubbed).
    local Engine = require("icloudsync_engine")
    local real_run = Engine.run
    Engine.run = function() return { down = 1, up = 0, deleted_local = 0, deleted_remote = 0, failed = 0, changed = 1 } end
    broadcasts = {}
    p:runSync{ auto = false }
    eq(broadcasts, { "BookMetadataChanged" })
    eq(invalidated, 1)
    eq(lastShown().text, "1 downloaded")
    Engine.run = function() return { down = 0, up = 0, deleted_local = 0, deleted_remote = 0, failed = 0, changed = 0 } end
    broadcasts = {}
    p:runSync{ auto = false }
    eq(broadcasts, {})
    eq(lastShown().text, "Up to date")
    Engine.run = real_run
    package.loaded["lib/bookshelf_book_repository"] = nil
end)

test("old default folder is migrated to Books", function()
    G_reader_settings.data.icloudsync = { server = "h:1", token = "t", download_dir = "/mnt/us/documents/iCloud" }
    local p = newPlugin()
    eq(p.settings.download_dir, "/mnt/us/Books")
    eq(G_reader_settings.data.icloudsync.download_dir, "/mnt/us/Books", "persisted")
    G_reader_settings.data.icloudsync = { server = "h:1", token = "t", download_dir = "/mnt/us/Custom" }
    eq(newPlugin().settings.download_dir, "/mnt/us/Custom", "custom folder left alone")
end)

test("sync state is tied to its folder", function()
    local old = IO.newStore("/mnt/us/documents/iCloud")
    old.save({ ["Old Book.epub"] = { size = 5, rmtime = 1, lmtime = 1 } })
    eq(old.load()["Old Book.epub"].size, 5)
    local new = IO.newStore("/mnt/us/Books")
    eq(new.load(), {}, "new folder starts fresh, so nothing looks deleted")
    new.save({ ["x.epub"] = { size = 1, rmtime = 1, lmtime = 1 } })
    eq(IO.newStore("/mnt/us/Books").load()["x.epub"].size, 1)
end)

local function Engine_run_once(result)
    local Engine = require("icloudsync_engine")
    local real = Engine.run
    Engine.run = function() Engine.run = real; return result end
end

test("warns when sync folder is outside the home folder", function()
    G_reader_settings.data.icloudsync = { server = "h:1", token = "t" }
    local p = newPlugin()
    G_reader_settings.data.home_dir = "/mnt/us/documents"
    assert(p:homeFolderWarning():find("outside your home folder"))
    Engine_run_once({ down = 1, changed = 1 })
    p:runSync{ auto = false }
    assert(lastShown().text:find("outside your home folder"), "shown even when metadata warning is absent")
    G_reader_settings.data.home_dir = "/mnt/us/Books/"
    eq(p:homeFolderWarning(), nil)
    G_reader_settings.data.home_dir = "/mnt/us"
    eq(p:homeFolderWarning(), nil)
    G_reader_settings.data.home_dir = nil
    eq(p:homeFolderWarning(), nil)
end)

local function failedRun(n)
    local errors = {}
    for i = 1, n do errors[i] = "Fic/Book" .. i .. ".epub: no longer in iCloud" end
    return { down = 1, up = 0, deleted_local = 0, deleted_remote = 0, failed = n,
             changed = 1, errors = errors }
end

test("auto sync with failed files says why", function()
    G_reader_settings.data.icloudsync = { server = "h:1", token = "t" }
    local p = newPlugin()
    Engine_run_once(failedRun(2))
    p:runSync{ auto = true }
    eq(lastShown(), { kind = "Notification",
        text = "iCloud: 1 downloaded, 2 failed\nFic/Book1.epub: no longer in iCloud" })
end)

test("auto sync that held back deletions says so", function()
    local p = newPlugin()
    Engine_run_once({ down = 0, up = 0, deleted_local = 0, deleted_remote = 0, failed = 0,
                      changed = 0, guard_tripped = 12 })
    p:runSync{ auto = true }
    eq(lastShown(), { kind = "Notification",
        text = "iCloud: 12 deletions held back. Use Sync now to review them." })
    eq(p:lastSyncText():match("— (.*)$"), "Up to date, 12 deletions held back")
end)

test("manual sync lists failure reasons and keeps them for the menu", function()
    G_reader_settings.data.home_dir = "/mnt/us"
    local p = newPlugin()
    Engine_run_once(failedRun(7))
    p:runSync{ auto = false }
    local msg = lastShown()
    eq(msg.kind, "InfoMessage")
    eq(msg.timeout, nil, "stays up so it can be read")
    eq(msg.text, table.concat({
        "1 downloaded, 7 failed",
        "Fic/Book1.epub: no longer in iCloud",
        "Fic/Book2.epub: no longer in iCloud",
        "Fic/Book3.epub: no longer in iCloud",
        "…and 4 more (see koreader/crash.log)",
    }, "\n"))
    eq(#p.settings.last_sync.errors, 5, "at most 5 reasons stored")
    local details = p:lastSyncDetails()
    assert(details:find("Book5.epub") and details:find("and 2 more"), details)
end)

test("a crash while setting up a sync doesn't leave sync stuck", function()
    local p = newPlugin()
    local real = IO.newTransport
    IO.newTransport = function() error("setup exploded") end
    p:runSync{ auto = false }
    IO.newTransport = real
    assert(lastShown().text:find("setup exploded"), lastShown().text)
    Engine_run_once({ down = 1, changed = 1 })
    p:runSync{ auto = false }
    eq(lastShown().text, "1 downloaded", "the next sync runs")
end)

test("menu line shows a short failure reason, details show it all", function()
    local p = newPlugin()
    local long = "Mac bridge error: cannot read sync folder: Operation not permitted"
    p.settings.last_sync = { time = 0, error = long }
    local line = p:lastSyncText()
    assert(line:find("failed: Mac bridge error: cannot read sync folde…", 1, true), line)
    eq(p:lastSyncDetails(), long)
    p.settings.last_sync = { time = 0, error = "Ünïcödé ünïcödé ünïcödé ünïcödé ünï" }
    local cut = p:lastSyncText():match("failed: (.*)…$")
    assert(cut and not cut:find("[\192-\255]$"), "no half characters: " .. tostring(cut))
    p.settings.last_sync = { time = 0, failed = 2 }
    eq(p:lastSyncDetails(), "…and 2 more (see koreader/crash.log)", "v1.0 record without reasons")
end)

-- Updates ----------------------------------------------------------------------

local Update = require("icloudsync_update")

local function fakeUpdates(release)
    local real = Update.deviceContext
    Update.deviceContext = function(path, installed)
        return { installed = installed, fetchJSON = function()
            if type(release) == "string" then return nil, release end
            return release
        end }
    end
    return function() Update.deviceContext = real end
end

local NEWER = { tag_name = "v1.2.0", assets = {
    { name = "icloudsync.koplugin.zip", browser_download_url = "https://x/z.zip" } } }

test("menu has update items showing the installed version", function()
    local p = newPlugin()
    p.version = "1.1.0"
    local items = {}
    p:addToMainMenu(items)
    local texts = {}
    for _, item in ipairs(items.icloudsync.sub_item_table) do
        texts[#texts + 1] = item.text or item.text_func()
    end
    assert(table.concat(texts, "|"):find("Check for updates (installed: 1.1.0)|Check for updates automatically", 1, true))
end)

test("check for updates: newer release asks before installing", function()
    local restore = fakeUpdates(NEWER)
    local p = newPlugin()
    p.version = "1.1.0"
    local installed_url
    local real_install = Update.install
    Update.install = function(_ctx, url) installed_url = url; return true end
    local real_restart = package.loaded["ui/uimanager"].askForRestart
    local restart_text
    package.loaded["ui/uimanager"].askForRestart = function(_, text) restart_text = text end
    p:checkForUpdates()
    local box = lastShown()
    eq(box.kind, "ConfirmBox")
    eq(box.text, "iCloud Sync 1.2.0 is available (you have 1.1.0).\n\nInstall it now?")
    box.ok_callback()
    eq(installed_url, "https://x/z.zip")
    assert(restart_text:find("1.2.0 is installed"), restart_text)
    Update.install = real_install
    package.loaded["ui/uimanager"].askForRestart = real_restart
    restore()
end)

test("check for updates: up to date, unreachable, and failed install", function()
    local p = newPlugin()
    p.version = "1.2.0"
    local restore = fakeUpdates(NEWER)
    p:checkForUpdates()
    eq(lastShown().text, "iCloud Sync is up to date (1.2.0).")
    restore()
    restore = fakeUpdates("no release published yet")
    p:checkForUpdates()
    eq(lastShown().text, "Couldn't check for updates:\nno release published yet")
    restore()
    local real_install = Update.install
    Update.install = function() return nil, "Download failed: timeout" end
    restore = fakeUpdates(NEWER)
    p:installUpdate({ version = "1.3.0", url = "u" })
    eq(lastShown().text, "iCloud Sync wasn't updated:\nDownload failed: timeout")
    Update.install = function() error("disk on fire") end
    p:installUpdate({ version = "1.3.0", url = "u" })
    assert(lastShown().text:find("disk on fire"), "a crash is reported, not raised")
    Update.install = real_install
    restore()
end)

test("automatic update check runs once a day and only speaks up for news", function()
    G_reader_settings.data.icloudsync = { server = "h:1", token = "t", auto_on_wifi = false }
    local restore = fakeUpdates(NEWER)
    local p = newPlugin()
    p.version = "1.1.0"
    scheduled = {}
    p:onNetworkConnected()
    eq(#scheduled, 1)
    scheduled[1]()
    eq(lastShown(), { kind = "Notification",
        text = "iCloud Sync 1.2.0 is available: Tools → iCloud Sync → Check for updates." })
    p:onNetworkConnected()
    eq(#scheduled, 1, "not again the same day")
    p.settings.last_update_check = os.time() - 25 * 3600
    p.version = "1.2.0"
    local before = #shown
    p:onNetworkConnected()
    scheduled[2]()
    eq(#shown, before, "silent when up to date")
    p.settings.auto_update_check = false
    p.settings.last_update_check = 0
    p:onNetworkConnected()
    eq(#scheduled, 2, "off means off")
    restore()
end)

H.done()

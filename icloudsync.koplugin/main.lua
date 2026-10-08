--[[--
iCloud Sync for KOReader.

Two-way syncs /mnt/us/Books with "iCloud Drive/KOReader" on a Mac
running bridge/icloud_bridge.py on the same Wi-Fi. Books and their .sdr
sidecars (highlights, notes, progress) travel both ways; newest change wins.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local SyncEngine = require("icloudsync_engine")
local IO = require("icloudsync_io")
local Update = require("icloudsync_update")

local SETTINGS_KEY = "icloudsync"
local AUTO_THROTTLE = 5 * 60
local MAX_STORED_ERRORS = 5
local UPDATE_CHECK_EVERY = 24 * 60 * 60
local DEFAULTS = {
    server = "",
    token = "",
    download_dir = "/mnt/us/Books",
    auto_on_wifi = true,
    auto_on_resume = true,
    auto_update_check = true,
}

-- Module-level so the FileManager and Reader instances share them.
-- Folder used by v1.0.0 before it moved to Books; migrated on load.
local OLD_DEFAULT_DIR = "/mnt/us/documents/iCloud"

local running = false
local last_auto = 0

local ICloudSync = WidgetContainer:extend{
    name = "icloudsync",
    is_doc_only = false,
}

function ICloudSync:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    if self.settings.download_dir == OLD_DEFAULT_DIR then
        self.settings.download_dir = DEFAULTS.download_dir
        self:saveSettings()
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ICloudSync:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
    G_reader_settings:flush()
end

function ICloudSync:isConfigured()
    return self.settings.server ~= "" and self.settings.token ~= ""
end

function ICloudSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("icloudsync_sync", {
        category = "none",
        event = "ICloudSyncNow",
        title = _("iCloud Sync: sync now"),
        general = true,
    })
end

-- Events ---------------------------------------------------------------------

function ICloudSync:onICloudSyncNow()
    self:syncNow()
    return true
end

function ICloudSync:onNetworkConnected()
    if self.settings.auto_on_wifi then self:autoSync() end
    self:autoUpdateCheck()
end

function ICloudSync:onResume()
    if not self.settings.auto_on_resume then return end
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and NetworkMgr and NetworkMgr:isConnected() then
        self:autoSync()
    end
end

function ICloudSync:autoSync()
    if not self:isConfigured() or running then return end
    if os.time() - last_auto < AUTO_THROTTLE then return end
    last_auto = os.time()
    -- Let the connection (and the UI after wake) settle first.
    UIManager:scheduleIn(2, function() self:runSync{ auto = true } end)
end

function ICloudSync:syncNow(force_deletions)
    if not self:isConfigured() then
        UIManager:show(InfoMessage:new{ text = _("Set the server address and token first:\nTools → iCloud Sync.") })
        return
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        self:runSync{ auto = false, force_deletions = force_deletions }
    end)
end

-- Sync -----------------------------------------------------------------------

-- Relative path of the open document inside the sync folder, if any.
function ICloudSync:openDocumentSkipper()
    local file = self.ui and self.ui.document and self.ui.document.file
    local root = self.settings.download_dir
    if not file or file:sub(1, #root + 1) ~= root .. "/" then return nil end
    local rel = file:sub(#root + 2)
    local sdr = (rel:match("^(.*)%.[^/%.]+$") or rel) .. ".sdr/"
    return function(p)
        return p == rel or p:sub(1, #sdr) == sdr
    end
end

function ICloudSync:runSync(opts)
    if running then return end
    running = true

    local progress
    if not opts.auto then
        progress = InfoMessage:new{ text = _("Syncing with iCloud…") }
        UIManager:show(progress)
        UIManager:forceRePaint()
    end

    local function onProgress(done, total)
        -- Repaint every few files so a big first sync visibly moves.
        if not progress or (done % 5 ~= 0 and done ~= total) then return end
        UIManager:close(progress)
        progress = InfoMessage:new{ text = T(_("Syncing with iCloud… %1/%2"), done, total) }
        UIManager:show(progress)
        UIManager:forceRePaint()
    end

    -- Build the context inside the pcall too: if anything here throws,
    -- `running` must still be reset or every later sync silently no-ops.
    local ok, summary = pcall(function()
        return SyncEngine.run{
            transport = IO.newTransport(self.settings.server, self.settings.token),
            fs = IO.fs,
            store = IO.newStore(self.settings.download_dir),
            onProgress = onProgress,
            root = self.settings.download_dir,
            run_id = os.date("%Y-%m-%d_%H%M%S"),
            isSkipped = self:openDocumentSkipper(),
            force_deletions = opts.force_deletions,
        }
    end)
    running = false
    if progress then UIManager:close(progress) end

    if not ok then
        logger.err("icloudsync: sync crashed:", summary)
        summary = { error = tostring(summary), changed = 0 }
    end
    for _i, e in ipairs(summary.errors or {}) do
        logger.warn("icloudsync:", e)
    end

    local prev_error = self.settings.last_sync and self.settings.last_sync.error
    local errors = {}
    for i = 1, math.min(MAX_STORED_ERRORS, #(summary.errors or {})) do
        errors[i] = summary.errors[i]
    end
    self.settings.last_sync = {
        time = os.time(),
        down = summary.down, up = summary.up,
        deleted_local = summary.deleted_local, deleted_remote = summary.deleted_remote,
        failed = summary.failed, bad_names = summary.bad_names, pending = summary.pending,
        guard_tripped = summary.guard_tripped, error = summary.error, errors = errors,
    }
    self:saveSettings()

    if (summary.changed or 0) > 0 then self:refreshLibraryViews() end
    self:report(summary, opts, prev_error)
end

function ICloudSync:refreshLibraryViews()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    if fm and fm.file_chooser then
        pcall(fm.file_chooser.refreshPath, fm.file_chooser)
    end
    -- Bookshelf plugin: its dir-mtime poll only watches one level below home,
    -- so books landing deeper can be missed. Drop its walk cache (only if it's
    -- loaded) and send the standard event it rebuilds on, which also flags a
    -- full refresh for when it's next shown.
    local repo = package.loaded["lib/bookshelf_book_repository"]
    if type(repo) == "table" and repo.invalidateWalkCache then
        pcall(repo.invalidateWalkCache)
    end
    local Event = require("ui/event")
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
end

local function summaryText(s)
    local parts = {}
    if (s.down or 0) > 0 then table.insert(parts, T(_("%1 downloaded"), s.down)) end
    if (s.up or 0) > 0 then table.insert(parts, T(_("%1 uploaded"), s.up)) end
    local deleted = (s.deleted_local or 0) + (s.deleted_remote or 0)
    if deleted > 0 then table.insert(parts, T(_("%1 deleted"), deleted)) end
    if (s.failed or 0) > 0 then table.insert(parts, T(_("%1 failed"), s.failed)) end
    if #parts == 0 then return _("Up to date") end
    return table.concat(parts, ", ")
end

-- "path: reason" lines for failed files, plus a pointer to the log for the rest.
local function failureLines(errors, failed, max)
    local lines = {}
    for i = 1, math.min(max, #errors) do lines[i] = errors[i] end
    local more = (failed or 0) - #lines
    if more > 0 then
        table.insert(lines, T(_("…and %1 more (see koreader/crash.log)"), more))
    end
    return lines
end

-- Cut to at most n bytes without splitting a UTF-8 character.
local function shorten(s, n)
    if #s <= n then return s end
    local cut = n
    while cut > 0 and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    return s:sub(1, cut) .. "…"
end

function ICloudSync:metadataWarning()
    if G_reader_settings:readSetting("document_metadata_folder", "doc") ~= "doc" then
        return _("Highlights and progress aren't synced: set Settings → Document → Book metadata location to 'book folder'.")
    end
end

-- Bookshelf (and KOReader's home view) only list books under the home folder.
function ICloudSync:homeFolderWarning()
    local home = G_reader_settings:readSetting("home_dir")
    if type(home) ~= "string" or home == "" or home == "/" then return end
    home = home:gsub("/+$", "")
    local dir = self.settings.download_dir
    if dir ~= home and dir:sub(1, #home + 1) ~= home .. "/" then
        return T(_("Synced books are in %1, which is outside your home folder (%2), so Bookshelf won't show them. Set your home folder to %1 (or a folder that contains it)."), dir, home)
    end
end

function ICloudSync:report(s, opts, prev_error)
    if opts.auto then
        -- Stay quiet on wake unless something happened, and say a failure
        -- only once: a sleeping Mac would otherwise nag on every wake.
        local lines = {}
        if s.error then
            if s.error ~= prev_error then
                table.insert(lines, T(_("iCloud sync failed: %1"), s.error))
            end
        else
            if (s.changed or 0) > 0 or (s.failed or 0) > 0 then
                table.insert(lines, T(_("iCloud: %1"), summaryText(s)))
            end
            if (s.failed or 0) > 0 and s.errors and s.errors[1] then
                table.insert(lines, s.errors[1])
            end
            if (s.guard_tripped or 0) > 0 then
                table.insert(lines, T(_("iCloud: %1 deletions held back. Use Sync now to review them."), s.guard_tripped))
            end
        end
        if #lines > 0 then
            local Notification = require("ui/widget/notification")
            Notification:notify(table.concat(lines, "\n"))
        end
        return
    end

    if s.error then
        UIManager:show(InfoMessage:new{ text = T(_("iCloud sync failed:\n%1"), s.error) })
        return
    end

    local lines = { summaryText(s) }
    if (s.failed or 0) > 0 then
        for _i, line in ipairs(failureLines(s.errors or {}, s.failed, 3)) do
            table.insert(lines, line)
        end
    end
    if (s.bad_names or 0) > 0 then
        table.insert(lines, T(_("%1 files skipped: names not allowed on Kindle storage."), s.bad_names))
    end
    if (s.pending or 0) > 0 then
        table.insert(lines, T(_("%1 files still downloading to the Mac from iCloud."), s.pending))
    end
    local meta_warn, home_warn = self:metadataWarning(), self:homeFolderWarning()
    if meta_warn then table.insert(lines, meta_warn) end
    if home_warn then table.insert(lines, home_warn) end

    if (s.guard_tripped or 0) > 0 then
        UIManager:show(ConfirmBox:new{
            text = table.concat(lines, "\n") .. "\n\n" ..
                T(_("%1 files would be deleted. That's more than half your synced files, so they were kept.\n\nApply these deletions?"), s.guard_tripped),
            ok_text = _("Delete"),
            ok_callback = function() self:syncNow(true) end,
        })
        return
    end
    -- Failure reasons stay up until dismissed so they can be read.
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = (s.failed or 0) == 0 and 4 or nil,
    })
end

-- Updates --------------------------------------------------------------------

function ICloudSync:installedVersion()
    return self.version or "0" -- PluginLoader copies _meta.lua's fields onto the plugin
end

function ICloudSync:updateContext()
    return Update.deviceContext(self.path, self:installedVersion())
end

function ICloudSync:checkForUpdates()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local ok, info, err = pcall(Update.check, self:updateContext())
        if not ok then info, err = nil, info end
        self.settings.last_update_check = os.time()
        self:saveSettings()
        if not info then
            UIManager:show(InfoMessage:new{ text = T(_("Couldn't check for updates:\n%1"), tostring(err)) })
        elseif not info.newer then
            UIManager:show(InfoMessage:new{
                text = T(_("iCloud Sync is up to date (%1)."), self:installedVersion()), timeout = 3 })
        else
            self:offerUpdate(info)
        end
    end)
end

-- At most once a day when Wi-Fi connects; only speaks up when there's something new.
function ICloudSync:autoUpdateCheck()
    if not self.settings.auto_update_check then return end
    if os.time() - (self.settings.last_update_check or 0) < UPDATE_CHECK_EVERY then return end
    self.settings.last_update_check = os.time()
    self:saveSettings()
    -- After the auto-sync scheduled at 2 s, which runs to completion first.
    UIManager:scheduleIn(5, function()
        local ok, info = pcall(Update.check, self:updateContext())
        if ok and info and info.newer then
            local Notification = require("ui/widget/notification")
            Notification:notify(T(_("iCloud Sync %1 is available: Tools → iCloud Sync → Check for updates."), info.version))
        end
    end)
end

function ICloudSync:offerUpdate(info)
    UIManager:show(ConfirmBox:new{
        text = T(_("iCloud Sync %1 is available (you have %2).\n\nInstall it now?"), info.version, self:installedVersion()),
        ok_text = _("Install"),
        ok_callback = function() self:installUpdate(info) end,
    })
end

function ICloudSync:installUpdate(info)
    local progress = InfoMessage:new{ text = T(_("Installing iCloud Sync %1…"), info.version) }
    UIManager:show(progress)
    UIManager:forceRePaint()
    local ok, done, err = pcall(Update.install, self:updateContext(), info.url)
    UIManager:close(progress)
    if not ok then done, err = nil, done end
    if not done then
        logger.err("icloudsync: update failed:", err)
        UIManager:show(InfoMessage:new{ text = T(_("iCloud Sync wasn't updated:\n%1"), tostring(err)) })
        return
    end
    UIManager:askForRestart(T(_("iCloud Sync %1 is installed. Restart KOReader to use it.\n\nIf the release notes mention the Mac bridge, update it too:\ncd ~/koreader-icloud-sync && git pull && ./bridge/install.sh"), info.version))
end

-- Menu -----------------------------------------------------------------------

function ICloudSync:editSetting(key, title, hint, touchmenu_instance)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = self.settings[key],
        input_hint = hint,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local v = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                    self.settings[key] = v
                    self:saveSettings()
                    UIManager:close(dlg)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function ICloudSync:testConnection()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local transport = IO.newTransport(self.settings.server, self.settings.token)
        local ok, err = transport.health()
        if ok then
            local m
            m, err = transport.manifest()
            if m then
                UIManager:show(InfoMessage:new{
                    text = T(_("Connected. %1 files in iCloud."), #(m.files or {})), timeout = 3 })
                return
            end
        end
        UIManager:show(InfoMessage:new{ text = T(_("Connection failed:\n%1"), err) })
    end)
end

function ICloudSync:lastSyncText()
    local ls = self.settings.last_sync
    if not ls then return _("Last sync: never") end
    local when = os.date("%Y-%m-%d %H:%M", ls.time)
    if ls.error then return T(_("Last sync: %1 — failed: %2"), when, shorten(ls.error, 40)) end
    local text = summaryText(ls)
    if (ls.guard_tripped or 0) > 0 then
        text = text .. T(_(", %1 deletions held back"), ls.guard_tripped)
    end
    return T(_("Last sync: %1 — %2"), when, text)
end

-- Full details behind the "Last sync" menu line.
function ICloudSync:lastSyncDetails()
    local ls = self.settings.last_sync
    if not ls then return end
    if ls.error then return ls.error end
    if (ls.failed or 0) > 0 then
        return table.concat(failureLines(ls.errors or {}, ls.failed, MAX_STORED_ERRORS), "\n")
    end
end

function ICloudSync:addToMainMenu(menu_items)
    menu_items.icloudsync = {
        text = _("iCloud Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function() self:syncNow() end,
            },
            {
                text_func = function() return self:lastSyncText() end,
                keep_menu_open = true,
                callback = function()
                    local details = self:lastSyncDetails()
                    if details then UIManager:show(InfoMessage:new{ text = details }) end
                end,
                separator = true,
            },
            {
                text = _("Auto-sync when Wi-Fi connects"),
                checked_func = function() return self.settings.auto_on_wifi end,
                callback = function()
                    self.settings.auto_on_wifi = not self.settings.auto_on_wifi
                    self:saveSettings()
                end,
            },
            {
                text = _("Auto-sync on wake"),
                checked_func = function() return self.settings.auto_on_resume end,
                callback = function()
                    self.settings.auto_on_resume = not self.settings.auto_on_resume
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text_func = function()
                    local s = self.settings.server
                    return T(_("Server address: %1"), s ~= "" and s or _("not set"))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editSetting("server", _("Mac bridge address"), "192.168.1.20:8765", touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return self.settings.token ~= "" and _("Token: set") or _("Token: not set")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editSetting("token", _("Bridge token"), _("Printed by install.sh on the Mac"), touchmenu_instance)
                end,
            },
            {
                text = _("Test connection"),
                keep_menu_open = true,
                enabled_func = function() return self:isConfigured() end,
                callback = function() self:testConnection() end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Check for updates (installed: %1)"), self:installedVersion())
                end,
                keep_menu_open = true,
                callback = function() self:checkForUpdates() end,
            },
            {
                text = _("Check for updates automatically"),
                checked_func = function() return self.settings.auto_update_check end,
                callback = function()
                    self.settings.auto_update_check = not self.settings.auto_update_check
                    self:saveSettings()
                end,
            },
        },
    }
end

return ICloudSync

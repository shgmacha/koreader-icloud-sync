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

local SETTINGS_KEY = "icloudsync"
local AUTO_THROTTLE = 5 * 60
local DEFAULTS = {
    server = "",
    token = "",
    download_dir = "/mnt/us/Books",
    auto_on_wifi = true,
    auto_on_resume = true,
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

    local ok, summary = pcall(SyncEngine.run, {
        transport = IO.newTransport(self.settings.server, self.settings.token),
        fs = IO.fs,
        store = IO.newStore(self.settings.download_dir),
        onProgress = onProgress,
        root = self.settings.download_dir,
        run_id = os.date("%Y-%m-%d_%H%M%S"),
        isSkipped = self:openDocumentSkipper(),
        force_deletions = opts.force_deletions,
    })
    if not ok then
        logger.err("icloudsync: sync crashed:", summary)
        summary = { error = tostring(summary), changed = 0 }
    end
    for _i, e in ipairs(summary.errors or {}) do
        logger.warn("icloudsync:", e)
    end

    running = false
    if progress then UIManager:close(progress) end

    self.settings.last_sync = {
        time = os.time(),
        down = summary.down, up = summary.up,
        deleted_local = summary.deleted_local, deleted_remote = summary.deleted_remote,
        failed = summary.failed, bad_names = summary.bad_names,
        guard_tripped = summary.guard_tripped, error = summary.error,
    }
    self:saveSettings()

    if (summary.changed or 0) > 0 then self:refreshLibraryViews() end
    self:report(summary, opts)
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

function ICloudSync:report(s, opts)
    if opts.auto then
        -- Stay quiet on wake unless something actually arrived or left.
        if not s.error and (s.changed or 0) > 0 then
            local Notification = require("ui/widget/notification")
            Notification:notify(T(_("iCloud: %1"), summaryText(s)))
        end
        return
    end

    if s.error then
        UIManager:show(InfoMessage:new{ text = T(_("iCloud sync failed:\n%1"), s.error) })
        return
    end

    local lines = { summaryText(s) }
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
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n"), timeout = 4 })
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
    if ls.error then return T(_("Last sync: %1 — failed"), when) end
    return T(_("Last sync: %1 — %2"), when, summaryText(ls))
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
                    local ls = self.settings.last_sync
                    if ls and ls.error then
                        UIManager:show(InfoMessage:new{ text = ls.error })
                    end
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
            },
        },
    }
end

return ICloudSync

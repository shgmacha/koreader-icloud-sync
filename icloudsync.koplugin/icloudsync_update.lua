--[[--
In-app updates from the project's GitHub releases.

Pure helpers plus check/install flows over injected adapters, so this runs
under plain LuaJIT in tests; Update.deviceContext() builds the real adapters.

An install never touches the running plugin until the new copy is fully on
disk: it unpacks into "<plugin>.new", checks every file's size, then swaps
folders (and swaps back if that fails). A half-copied plugin won't load at
all, and then it can't fix itself.
--]]

local Update = {}

Update.REPO = "shgmacha/koreader-icloud-sync"
Update.ASSET = "icloudsync.koplugin.zip"
Update.DIRNAME = "icloudsync.koplugin"
Update.REQUIRED = { "_meta.lua", "main.lua" }
Update.LATEST_URL = "https://api.github.com/repos/" .. Update.REPO .. "/releases/latest"

--- "v1.2.3" / "1.2" -> { 1, 2, 3 } / { 1, 2 }; nil if it doesn't start with a number.
function Update.parseVersion(s)
    local core = type(s) == "string" and s:match("^[vV]?(%d[%d%.]*)")
    if not core then return nil end
    local parts = {}
    for n in core:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end

--- True when version a is newer than version b. Missing parts count as 0.
function Update.isNewer(a, b)
    local va, vb = Update.parseVersion(a), Update.parseVersion(b)
    if not va or not vb then return false end
    for i = 1, math.max(#va, #vb) do
        local x, y = va[i] or 0, vb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

function Update.pickAsset(release)
    for _, asset in ipairs(type(release) == "table" and release.assets or {}) do
        if asset.name == Update.ASSET and type(asset.browser_download_url) == "string" then
            return asset.browser_download_url
        end
    end
end

--- entries = { {path, mode, size}, ... } from the zip. Returns the files to
-- extract as { {path, rel, size}, ... }, or nil, reason.
function Update.planExtract(entries)
    local prefix = Update.DIRNAME .. "/"
    local files, have = {}, {}
    for _, e in ipairs(entries) do
        if e.path:sub(1, #prefix) ~= prefix or ("/" .. e.path .. "/"):find("/%.%./") then
            return nil, "unexpected file " .. e.path
        end
        local rel = e.path:sub(#prefix + 1):gsub("/$", "")
        if e.mode == "file" and rel ~= "" then
            files[#files + 1] = { path = e.path, rel = rel, size = e.size }
            have[rel] = true
        end
    end
    for _, name in ipairs(Update.REQUIRED) do
        if not have[name] then return nil, "missing " .. name end
    end
    return files
end

--- ctx: { installed = "1.1.0", fetchJSON = function(url) -> table | nil, err }
-- Returns { version, url, newer } or nil, reason.
function Update.check(ctx)
    local release, err = ctx.fetchJSON(Update.LATEST_URL)
    if not release then return nil, err or "no answer from GitHub" end
    if not Update.parseVersion(release.tag_name) then return nil, "no release found" end
    local url = Update.pickAsset(release)
    if not url then return nil, "the latest release has no " .. Update.ASSET end
    return {
        version = (release.tag_name:gsub("^[vV]", "")),
        url = url,
        newer = Update.isNewer(release.tag_name, ctx.installed),
    }
end

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

--- ctx: {
--   plugin_dir, zip_path,
--   download    = function(url, dest) -> true | nil, err
--   openArchive = function(path) -> reader | nil, err
--                 reader: entries() -> list, extract(path, dest) -> bool, close()
--   fs = { mkdirp(dir), rename(a, b) -> true | nil, err, remove(file),
--          removeTree(dir), size(file) -> number | nil }
-- }
-- Returns true, or nil and a reason (with nothing changed).
function Update.install(ctx, url)
    local fs, zip = ctx.fs, ctx.zip_path
    fs.mkdirp(dirname(zip))
    local ok, err = ctx.download(url, zip)
    if not ok then
        fs.remove(zip)
        return nil, "Download failed: " .. tostring(err)
    end

    local reader = ctx.openArchive(zip)
    if not reader then
        fs.remove(zip)
        return nil, "The update file is damaged (can't open it)."
    end
    local files, plan_err = Update.planExtract(reader.entries())
    if not files then
        reader.close()
        fs.remove(zip)
        return nil, "The update file is damaged (" .. plan_err .. ")."
    end

    local new_dir, old_dir = ctx.plugin_dir .. ".new", ctx.plugin_dir .. ".old"
    fs.removeTree(new_dir) -- leftovers from an interrupted attempt
    for _, f in ipairs(files) do
        local dest = new_dir .. "/" .. f.rel
        fs.mkdirp(dirname(dest))
        if not reader.extract(f.path, dest) or fs.size(dest) ~= f.size then
            reader.close()
            fs.remove(zip)
            fs.removeTree(new_dir)
            return nil, "Install failed: couldn't unpack " .. f.rel .. "."
        end
    end
    reader.close()
    fs.remove(zip)

    fs.removeTree(old_dir)
    ok, err = fs.rename(ctx.plugin_dir, old_dir)
    if not ok then
        fs.removeTree(new_dir)
        return nil, "Install failed: " .. tostring(err)
    end
    ok, err = fs.rename(new_dir, ctx.plugin_dir)
    if not ok then
        fs.rename(old_dir, ctx.plugin_dir)
        fs.removeTree(new_dir)
        return nil, "Install failed: " .. tostring(err)
    end
    fs.removeTree(old_dir)
    return true
end

--- Real adapters for KOReader on the device.
function Update.deviceContext(plugin_dir, installed)
    local DataStorage = require("datastorage")
    local Archiver = require("ffi/archiver")
    local ffiutil = require("ffi/util")
    local http = require("socket.http")
    local lfs = require("libs/libkoreader-lfs")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local IO = require("icloudsync_io")
    local json_decode = IO.json_decode

    local function fetchJSON(url)
        local chunks = {}
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                headers = { ["Accept"] = "application/vnd.github+json", ["User-Agent"] = socketutil.USER_AGENT },
                sink = socketutil.table_sink(chunks),
            })
        end)
        socketutil:reset_timeout()
        if not ok or type(code) ~= "number" then return nil, tostring(code) end
        if code == 404 then return nil, "no release published yet" end
        if code ~= 200 then return nil, "GitHub answered " .. tostring(code) end
        local decoded, obj = pcall(json_decode, table.concat(chunks))
        if not decoded or type(obj) ~= "table" then return nil, "unreadable answer from GitHub" end
        return obj
    end

    local function download(url, dest)
        local fh, err = io.open(dest, "wb")
        if not fh then return nil, err end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok, code = pcall(function()
            return socket.skip(1, http.request{
                url = url,
                redirect = true, -- GitHub serves release assets from another host
                headers = { ["User-Agent"] = socketutil.USER_AGENT },
                sink = socketutil.file_sink(fh),
            })
        end)
        socketutil:reset_timeout()
        pcall(fh.close, fh) -- file_sink closes on EOF; harmless otherwise
        if not ok or type(code) ~= "number" then return nil, tostring(code) end
        if code ~= 200 then return nil, "HTTP " .. code end
        return true
    end

    local function openArchive(path)
        local r = Archiver.Reader:new()
        if not r:open(path) then return nil end
        local list = {}
        for entry in r:iterate() do
            list[#list + 1] = { path = entry.path, mode = entry.mode, size = entry.size }
        end
        return {
            entries = function() return list end,
            extract = function(p, dest) return r:extractToPath(p, dest) end,
            close = function() r:close() end,
        }
    end

    return {
        installed = installed,
        plugin_dir = plugin_dir,
        zip_path = DataStorage:getDataDir() .. "/cache/icloudsync-update.zip",
        fetchJSON = fetchJSON,
        download = download,
        openArchive = openArchive,
        fs = {
            mkdirp = IO.fs.mkdirp,
            rename = os.rename,
            remove = os.remove,
            removeTree = function(dir)
                if lfs.attributes(dir, "mode") == "directory" then
                    ffiutil.purgeDir(dir)
                end
            end,
            size = function(file) return lfs.attributes(file, "size") end,
        },
    }
end

return Update

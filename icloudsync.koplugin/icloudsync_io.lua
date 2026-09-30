--[[--
Real-device adapters for icloudsync_engine: HTTP transport (luasocket) to the
Mac bridge, filesystem (lfs), and the sync-state store (LuaSettings).
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local ltn12 = require("ltn12")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socketutil = require("socketutil")

local IO = {}

-- JSON: rapidjson is bundled with current KOReader; fall back to json.
local json_decode
do
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and rapidjson then
        json_decode = rapidjson.decode
    else
        json_decode = require("json").decode
    end
end

local function urlEncodeSegment(s)
    return (s:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function urlEncodePath(path)
    local out = {}
    for seg in (path .. "/"):gmatch("(.-)/") do
        out[#out + 1] = urlEncodeSegment(seg)
    end
    return table.concat(out, "/")
end
IO.urlEncodePath = urlEncodePath

local function describe(code, body)
    if code == 401 then return "Bad token" end
    if type(code) ~= "number" then
        return "Mac bridge not reachable (" .. tostring(code) .. ")"
    end
    local msg
    if body and body ~= "" then
        local ok, obj = pcall(json_decode, body)
        msg = ok and type(obj) == "table" and obj.error
    end
    return "HTTP " .. code .. (msg and (": " .. msg) or "")
end

--- Transport talking to icloud_bridge.py. server = "192.168.1.20:8765".
function IO.newTransport(server, token, timeouts)
    timeouts = timeouts or {}
    local base = "http://" .. server:gsub("^https?://", ""):gsub("/+$", "")
    local T = {}

    -- Returns code, response body (when no custom sink).
    local function request(method, path, opts, block_t, total_t)
        local chunks = {}
        local headers = { ["X-Sync-Token"] = token }
        for k, v in pairs(opts.headers or {}) do headers[k] = v end
        socketutil:set_timeout(block_t, total_t)
        local ok, _, code = pcall(http.request, {
            url = base .. path,
            method = method,
            headers = headers,
            source = opts.source,
            sink = opts.sink or ltn12.sink.table(chunks),
        })
        socketutil:reset_timeout()
        if not ok then
            return tostring(_), ""
        end
        return code, table.concat(chunks)
    end

    local SMALL_B, SMALL_T = timeouts.block or 5, timeouts.total or 15
    local FILE_B = socketutil.FILE_BLOCK_TIMEOUT or 15
    local FILE_T = socketutil.FILE_TOTAL_TIMEOUT or 300

    function T.health()
        local code = request("GET", "/health", {}, SMALL_B, SMALL_T)
        if code == 200 then return true end
        return nil, describe(code)
    end

    function T.manifest()
        local code, body = request("GET", "/manifest", {}, SMALL_B, SMALL_T)
        if code ~= 200 then return nil, describe(code, body) end
        local ok, obj = pcall(json_decode, body)
        if not ok or type(obj) ~= "table" then return nil, "Invalid manifest" end
        return obj
    end

    function T.download(path, dest)
        local fh, err = io.open(dest, "wb")
        if not fh then return nil, err end
        local write_err
        local sink = function(chunk)
            if chunk and not write_err then
                local ok, e = fh:write(chunk)
                if not ok then write_err = e end
            end
            return 1
        end
        local code = request("GET", "/file/" .. urlEncodePath(path), { sink = sink }, FILE_B, FILE_T)
        fh:close()
        if write_err then return nil, write_err end
        if code ~= 200 then return nil, describe(code) end
        return true
    end

    function T.upload(path, src, size, mtime)
        local fh, err = io.open(src, "rb")
        if not fh then return nil, err end
        local code, body = request("PUT", "/file/" .. urlEncodePath(path), {
            headers = { ["Content-Length"] = tostring(size), ["X-Mtime"] = tostring(mtime) },
            source = ltn12.source.file(fh),
        }, FILE_B, FILE_T)
        pcall(fh.close, fh) -- source.file closes on EOF; harmless otherwise
        if code ~= 201 then return nil, describe(code, body) end
        local ok, info = pcall(json_decode, body)
        if not ok or type(info) ~= "table" then return nil, "Invalid upload response" end
        return info
    end

    function T.delete(path, run_id)
        local code, body = request("DELETE", "/file/" .. urlEncodePath(path),
            { headers = { ["X-Run-Id"] = run_id } }, SMALL_B, SMALL_T)
        if code ~= 204 then return nil, describe(code, body) end
        return true
    end

    return T
end

--- Filesystem adapter over lfs.
IO.fs = {}

function IO.fs.scan(dir)
    local out = {}
    local function walk(abs, rel)
        local ok, iter, state = pcall(lfs.dir, abs)
        if not ok then return end
        for name in iter, state do
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
                local child_abs = abs .. "/" .. name
                local child_rel = rel == "" and name or (rel .. "/" .. name)
                local attr = lfs.attributes(child_abs)
                if attr and attr.mode == "directory" then
                    walk(child_abs, child_rel)
                elseif attr and attr.mode == "file" then
                    out[child_rel] = { size = attr.size, mtime = attr.modification }
                end
            end
        end
    end
    walk(dir, "")
    return out
end

function IO.fs.stat(file)
    local attr = lfs.attributes(file)
    if attr and attr.mode == "file" then
        return { size = attr.size, mtime = attr.modification }
    end
end

function IO.fs.mkdirp(dir)
    if dir == "" or lfs.attributes(dir, "mode") == "directory" then return end
    local path = dir:sub(1, 1) == "/" and "" or "."
    for seg in dir:gmatch("[^/]+") do
        path = path .. "/" .. seg
        if lfs.attributes(path, "mode") ~= "directory" then
            lfs.mkdir(path)
        end
    end
end

function IO.fs.rename(from, to)
    return os.rename(from, to)
end

function IO.fs.remove(file)
    if lfs.attributes(file, "mode") ~= "file" then return true end
    return os.remove(file)
end

function IO.fs.touch(file, mtime)
    local ok, err = pcall(lfs.touch, file, mtime, mtime)
    if not ok then logger.warn("icloudsync: touch failed", file, err) end
end

function IO.fs.pruneEmptyDirs(dir, stop_at)
    while dir ~= stop_at and dir:sub(1, #stop_at + 1) == stop_at .. "/" do
        if not lfs.rmdir(dir) then break end -- fails when not empty
        dir = dir:match("^(.*)/[^/]*$")
    end
end

--- Per-file sync state, stored in KOReader's settings dir.
-- State belongs to one local folder: after switching folders, old records
-- would make every file look "deleted on the Kindle", so a different root
-- starts fresh (a first sync only adds, never deletes).
function IO.newStore(root)
    local path = DataStorage:getSettingsDir() .. "/icloudsync_state.lua"
    local settings = LuaSettings:open(path)
    return {
        load = function()
            if settings:readSetting("root") ~= root then return {} end
            return settings:readSetting("files") or {}
        end,
        save = function(files)
            settings:saveSetting("root", root)
            settings:saveSetting("files", files)
            settings:flush()
        end,
        reset = function()
            settings:saveSetting("files", {})
            settings:flush()
        end,
    }
end

return IO

local H = require("tests.harness")
local Update = require("icloudsync_update")
local test, eq = H.test, H.eq

local PLUGIN = "/mnt/us/koreader/plugins/icloudsync.koplugin"
local ZIP = "/mnt/us/koreader/cache/icloudsync-update.zip"

-- In-memory filesystem: files[path] = size. Folders are implied by paths.
local function world(zip_entries, opts)
    opts = opts or {}
    local W = { files = {}, calls = {} }
    W.files[PLUGIN .. "/main.lua"] = 100
    W.files[PLUGIN .. "/_meta.lua"] = 10

    local function under(dir)
        local out = {}
        for p in pairs(W.files) do
            if p:sub(1, #dir + 1) == dir .. "/" then out[#out + 1] = p end
        end
        return out
    end
    W.under = under

    W.ctx = {
        installed = "1.1.0",
        plugin_dir = PLUGIN,
        zip_path = ZIP,
        fetchJSON = function() return W.release, W.fetch_err end,
        download = function(url, dest)
            table.insert(W.calls, "download " .. url)
            if opts.download_fails then return nil, "timeout" end
            W.files[dest] = 1
            return true
        end,
        openArchive = function()
            if opts.unreadable then return nil end
            return {
                entries = function() return zip_entries end,
                extract = function(path, dest)
                    for _, e in ipairs(zip_entries) do
                        if e.path == path then
                            W.files[dest] = (opts.short == path) and e.size - 1 or e.size
                            return true
                        end
                    end
                end,
                close = function() W.closed = true end,
            }
        end,
        fs = {
            mkdirp = function() end,
            rename = function(a, b)
                table.insert(W.calls, "rename " .. a:match("[^/]*$") .. " -> " .. b:match("[^/]*$"))
                if opts.fail_rename == b then
                    opts.fail_rename = nil -- refuse once, so the rollback can succeed
                    return nil, "rename refused"
                end
                local moved = under(a)
                if #moved == 0 then return nil, "no such folder" end
                for _, p in ipairs(moved) do
                    W.files[b .. p:sub(#a + 1)], W.files[p] = W.files[p], nil
                end
                return true
            end,
            remove = function(f) W.files[f] = nil end,
            removeTree = function(dir) for _, p in ipairs(under(dir)) do W.files[p] = nil end end,
            size = function(f) return W.files[f] end,
        },
    }
    return W
end

local GOOD_ZIP = {
    { path = "icloudsync.koplugin/", mode = "directory", size = 0 },
    { path = "icloudsync.koplugin/_meta.lua", mode = "file", size = 11 },
    { path = "icloudsync.koplugin/main.lua", mode = "file", size = 222 },
    { path = "icloudsync.koplugin/icloudsync_plan.lua", mode = "file", size = 333 },
}

local function release(tag, with_asset)
    return {
        tag_name = tag,
        assets = with_asset == false and {} or {
            { name = "notes.txt", browser_download_url = "https://x/notes.txt" },
            { name = "icloudsync.koplugin.zip", browser_download_url = "https://x/icloudsync.koplugin.zip" },
        },
    }
end

-- Pure helpers ---------------------------------------------------------------

test("versions compare numerically, with or without a v prefix", function()
    eq(Update.parseVersion("v1.10.2"), { 1, 10, 2 })
    eq(Update.parseVersion("nightly"), nil)
    eq(Update.isNewer("v1.1.0", "1.0.0"), true)
    eq(Update.isNewer("1.10.0", "1.9.9"), true, "not string order")
    eq(Update.isNewer("v1.1", "1.1.0"), false, "missing parts count as 0")
    eq(Update.isNewer("1.0.0", "1.1.0"), false)
    eq(Update.isNewer("garbage", "1.0.0"), false)
end)

test("planExtract keeps only files inside the plugin folder", function()
    local files = Update.planExtract(GOOD_ZIP)
    eq(#files, 3)
    eq(files[3], { path = "icloudsync.koplugin/icloudsync_plan.lua", rel = "icloudsync_plan.lua", size = 333 })
end)

test("planExtract rejects stray, escaping, or incomplete archives", function()
    local stray = { { path = "README.md", mode = "file", size = 1 } }
    eq({ Update.planExtract(stray) }, { nil, "unexpected file README.md" })
    local escape = { { path = "icloudsync.koplugin/../evil.lua", mode = "file", size = 1 } }
    eq({ Update.planExtract(escape) }, { nil, "unexpected file icloudsync.koplugin/../evil.lua" })
    local no_main = { { path = "icloudsync.koplugin/_meta.lua", mode = "file", size = 1 } }
    eq({ Update.planExtract(no_main) }, { nil, "missing main.lua" })
end)

-- Check ------------------------------------------------------------------------

test("check finds a newer release and its zip", function()
    local W = world(GOOD_ZIP)
    W.release = release("v1.2.0")
    eq(Update.check(W.ctx), { version = "1.2.0", url = "https://x/icloudsync.koplugin.zip", newer = true })
    W.release = release("v1.1.0")
    eq(Update.check(W.ctx).newer, false)
end)

test("check explains what went wrong", function()
    local W = world(GOOD_ZIP)
    W.fetch_err = "no release published yet"
    eq({ Update.check(W.ctx) }, { nil, "no release published yet" })
    W.fetch_err, W.release = nil, release("v2.0.0", false)
    eq({ Update.check(W.ctx) }, { nil, "the latest release has no icloudsync.koplugin.zip" })
end)

-- Install ----------------------------------------------------------------------

test("install swaps in the new plugin folder", function()
    local W = world(GOOD_ZIP)
    W.files[PLUGIN .. ".new/stale.lua"] = 5 -- leftover from an interrupted attempt
    eq(Update.install(W.ctx, "https://x/z.zip"), true)
    eq(W.files[PLUGIN .. "/icloudsync_plan.lua"], 333)
    eq(W.files[PLUGIN .. "/main.lua"], 222)
    eq(#W.under(PLUGIN .. ".new") + #W.under(PLUGIN .. ".old"), 0, "no leftovers")
    eq(W.files[PLUGIN .. "/stale.lua"], nil)
    eq(W.files[ZIP], nil, "zip removed")
    eq(W.closed, true)
end)

test("a short extraction leaves the installed plugin untouched", function()
    local W = world(GOOD_ZIP, { short = "icloudsync.koplugin/icloudsync_plan.lua" })
    eq({ Update.install(W.ctx, "u") }, { nil, "Install failed: couldn't unpack icloudsync_plan.lua." })
    eq(W.files[PLUGIN .. "/main.lua"], 100, "old plugin still in place")
    eq(#W.under(PLUGIN .. ".new"), 0)
    eq(W.files[ZIP], nil)
end)

test("a failed swap puts the old plugin back", function()
    local W = world(GOOD_ZIP, { fail_rename = PLUGIN })
    eq({ Update.install(W.ctx, "u") }, { nil, "Install failed: rename refused" })
    eq(W.files[PLUGIN .. "/main.lua"], 100)
    eq(#W.under(PLUGIN .. ".new") + #W.under(PLUGIN .. ".old"), 0)
end)

test("download and archive problems change nothing", function()
    local W = world(GOOD_ZIP, { download_fails = true })
    eq({ Update.install(W.ctx, "u") }, { nil, "Download failed: timeout" })
    W = world(GOOD_ZIP, { unreadable = true })
    eq({ Update.install(W.ctx, "u") }, { nil, "The update file is damaged (can't open it)." })
    eq(W.files[ZIP], nil)
    W = world({ { path = "icloudsync.koplugin/main.lua", mode = "file", size = 1 } })
    eq({ Update.install(W.ctx, "u") }, { nil, "The update file is damaged (missing _meta.lua)." })
    eq(W.files[PLUGIN .. "/main.lua"], 100)
end)

H.done()

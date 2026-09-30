local H = require("tests.harness")
local SyncEngine = require("icloudsync_engine")
local test, eq = H.test, H.eq

local ROOT = "/kindle/iCloud"

-- In-memory "Mac" (bridge) and "Kindle" (filesystem). Files are {data, mtime}.
local function world(opts)
    opts = opts or {}
    local W = { mac = {}, kindle = {}, trash = {}, saved = {}, clock = 1000, calls = {} }

    W.transport = {
        manifest = function()
            if W.offline then return nil, "Mac bridge not reachable" end
            local files = {}
            for p, f in pairs(W.mac) do
                files[#files + 1] = { path = p, size = #f.data, mtime = f.mtime }
            end
            return { version = 1, files = files, pending = W.pending or {} }
        end,
        download = function(p, dest)
            table.insert(W.calls, "GET " .. p)
            if W.fail_download and W.fail_download[p] then return nil, "boom" end
            local f = W.mac[p]
            local data = W.truncate and f.data:sub(2) or f.data
            W.kindle[dest] = { data = data, mtime = W.clock }
            return true
        end,
        upload = function(p, src, size, mtime)
            table.insert(W.calls, "PUT " .. p)
            if W.fail_upload and W.fail_upload[p] then return nil, "HTTP 500" end
            W.mac[p] = { data = W.kindle[src].data, mtime = mtime }
            return { path = p, size = size, mtime = mtime }
        end,
        delete = function(p, run_id)
            table.insert(W.calls, "DELETE " .. p)
            W.trash[run_id .. "/" .. p] = W.mac[p]
            W.mac[p] = nil
            return true
        end,
    }

    W.fs = {
        scan = function(dir)
            local out = {}
            for file, f in pairs(W.kindle) do
                local rel = file:sub(#dir + 2)
                if file:sub(1, #dir + 1) == dir .. "/" then
                    out[rel] = { size = #f.data, mtime = f.mtime }
                end
            end
            return out
        end,
        stat = function(file)
            local f = W.kindle[file]
            return f and { size = #f.data, mtime = f.mtime }
        end,
        mkdirp = function() end,
        rename = function(a, b)
            W.kindle[b], W.kindle[a] = W.kindle[a], nil
            return true
        end,
        remove = function(file)
            if not W.kindle[file] then return nil, "no such file" end
            W.kindle[file] = nil
            return true
        end,
        -- FAT32 rounds mtimes to 2s; model that to prove we never compare across devices.
        touch = function(file, mtime) W.kindle[file].mtime = mtime - (mtime % 2) end,
        pruneEmptyDirs = function() end,
    }

    W.state = opts.state or {}
    W.store = {
        load = function()
            local copy = {}
            for k, v in pairs(W.state) do copy[k] = v end
            return copy
        end,
        save = function(files)
            W.state = files
            W.saved[#W.saved + 1] = true
        end,
    }

    function W.run(extra)
        W.calls = {}
        local ctx = { transport = W.transport, fs = W.fs, store = W.store, root = ROOT, run_id = "run" }
        for k, v in pairs(extra or {}) do ctx[k] = v end
        return SyncEngine.run(ctx)
    end

    function W.kput(rel, data, mtime) W.kindle[ROOT .. "/" .. rel] = { data = data, mtime = mtime } end
    function W.kget(rel) return W.kindle[ROOT .. "/" .. rel] end

    return W
end

test("first sync merges both sides", function()
    local W = world()
    W.mac["Fic/Dune.epub"] = { data = "dune", mtime = 101 }
    W.mac["Same.pdf"] = { data = "same", mtime = 50 }
    W.kput("Mine.epub", "mine", 200)
    W.kput("Mine.sdr/metadata.epub.lua", "hl", 201)
    W.kput("Same.pdf", "SAME", 60)       -- same size: adopt, no transfer
    W.kput("stray.jpg", "x", 1)          -- not syncable: ignored
    local s = W.run()
    eq(s.error, nil)
    eq({ s.down, s.up, s.adopted, s.failed }, { 1, 2, 1, 0 })
    eq(W.kget("Fic/Dune.epub").data, "dune")
    eq(W.kget("Fic/Dune.epub.part"), nil, "temp file renamed away")
    eq(W.mac["Mine.sdr/metadata.epub.lua"].data, "hl")
    eq(W.mac["stray.jpg"], nil)
    eq(W.state["Fic/Dune.epub"], { size = 4, rmtime = 101, lmtime = 100 }, "lmtime is FAT-rounded local stat")
end)

test("second run is a no-op", function()
    local W = world()
    W.mac["a.epub"] = { data = "aaa", mtime = 101 }
    W.kput("b.epub", "bb", 300)
    W.run()
    local s = W.run()
    eq(W.calls, {})
    eq(s.changed, 0)
end)

test("edits flow both ways", function()
    local W = world()
    W.mac["a.epub"] = { data = "v1", mtime = 100 }
    W.kput("b.sdr/metadata.epub.lua", "h1", 100)
    W.run()
    W.mac["a.epub"] = { data = "v2!", mtime = 500 }
    W.kput("b.sdr/metadata.epub.lua", "h2 more", 600)
    local s = W.run()
    eq({ s.down, s.up }, { 1, 1 })
    eq(W.kget("a.epub").data, "v2!")
    eq(W.mac["b.sdr/metadata.epub.lua"].data, "h2 more")
end)

test("conflict: newest wins", function()
    local W = world()
    W.mac["a.epub"] = { data = "base", mtime = 100 }
    W.run()
    W.mac["a.epub"] = { data = "mac edit", mtime = 900 }
    W.kput("a.epub", "kindle edit!", 800)
    W.run()
    eq(W.kget("a.epub").data, "mac edit")
end)

test("deletions propagate both ways; iCloud side goes to trash", function()
    local W = world()
    W.mac["x.epub"] = { data = "x", mtime = 100 }
    W.mac["y.epub"] = { data = "y", mtime = 100 }
    W.run()
    W.mac["x.epub"] = nil                         -- deleted in iCloud
    W.kindle[ROOT .. "/y.epub"] = nil             -- deleted on Kindle
    local s = W.run()
    eq({ s.deleted_local, s.deleted_remote }, { 1, 1 })
    eq(W.kget("x.epub"), nil)
    eq(W.mac["y.epub"], nil)
    eq(W.trash["run/y.epub"].data, "y")
    eq(W.state, {})
end)

test("failed transfer leaves state untouched and retries next run", function()
    local W = world()
    W.mac["a.epub"] = { data = "aaaa", mtime = 100 }
    W.kput("b.epub", "bb", 100)
    W.fail_download = { ["a.epub"] = true }
    W.fail_upload = { ["b.epub"] = true }
    local s = W.run()
    eq(s.failed, 2)
    eq(W.state["a.epub"], nil)
    eq(W.state["b.epub"], nil)
    eq(W.kget("a.epub.part"), nil, "no partial file left")
    W.fail_download, W.fail_upload = nil, nil
    s = W.run()
    eq({ s.down, s.up, s.failed }, { 1, 1, 0 })
end)

test("truncated download is rejected", function()
    local W = world()
    W.mac["a.epub"] = { data = "complete", mtime = 100 }
    W.truncate = true
    local s = W.run()
    eq(s.failed, 1)
    eq(W.kget("a.epub"), nil)
    eq(W.kget("a.epub.part"), nil)
end)

test("unreachable bridge changes nothing", function()
    local W = world()
    W.kput("a.epub", "a", 1)
    W.offline = true
    local s = W.run()
    eq(s.error, "Mac bridge not reachable")
    eq(W.calls, {})
    eq(#W.saved, 0)
end)

test("mass deletion is held back unless forced", function()
    local W = world()
    for i = 1, 12 do W.mac["b" .. i .. ".epub"] = { data = "x", mtime = 100 } end
    W.run()
    W.mac = {} -- iCloud folder looks empty (e.g. renamed)
    local s = W.run()
    eq(s.guard_tripped, 12)
    eq(s.deleted_local, 0)
    eq(W.kget("b1.epub").data, "x")
    -- Unchanged local files with state but no remote... re-running still guards.
    s = W.run({ force_deletions = true })
    eq(s.deleted_local, 12)
end)

test("open book and its sidecar are skipped", function()
    local W = world()
    W.mac["open.epub"] = { data = "new!", mtime = 100 }
    W.mac["open.sdr/metadata.epub.lua"] = { data = "m", mtime = 100 }
    W.mac["other.epub"] = { data = "o", mtime = 100 }
    local s = W.run({ isSkipped = function(p) return p:sub(1, 5) == "open." end })
    eq(W.calls, { "GET other.epub" })
    eq(s.down, 1)
end)

test("pending (evicted) iCloud file is not deleted locally", function()
    local W = world()
    W.mac["big.pdf"] = { data = "big", mtime = 100 }
    W.run()
    W.mac["big.pdf"] = nil
    W.pending = { "big.pdf" }
    local s = W.run()
    eq(s.deleted_local, 0)
    eq(s.pending, 1)
    eq(W.kget("big.pdf").data, "big")
end)

test("bad manifest version aborts", function()
    local W = world()
    W.transport.manifest = function() return { version = 2, files = {} } end
    eq(W.run().error, "unsupported bridge version")
end)

H.done()

--[[--
Executes one iCloud Sync run. All I/O goes through injected adapters so this
runs under plain LuaJIT in tests and under KOReader on the device.

ctx = {
  transport = {
    manifest = function() -> manifest | nil, err
    download = function(path, dest_file) -> true | nil, err
    upload   = function(path, src_file, size, mtime) -> {size, mtime} | nil, err
    delete   = function(path, run_id) -> true | nil, err
  },
  fs = {
    scan   = function(dir) -> { [relpath] = {size, mtime} }
    stat   = function(file) -> {size, mtime} | nil
    mkdirp = function(dir)
    rename = function(from, to) -> true | nil, err
    remove = function(file) -> true | nil, err
    touch  = function(file, mtime)
    pruneEmptyDirs = function(dir, stop_at)
  },
  store = { load = function() -> files, save = function(files) },
  root = "/mnt/us/Books",              -- local sync folder
  run_id = "2026-09-30_101500",
  isSkipped = function(path) -> bool   -- optional (open document)
  force_deletions = bool               -- optional (bypass mass-deletion guard)
  onProgress = function(done, total, path) -- optional
}
--]]

local SyncPlan = require("icloudsync_plan")

local SyncEngine = {}

local SAVE_EVERY = 10

local function dirname(path)
    return path:match("^(.*)/[^/]*$") or ""
end

local function join(root, rel)
    return root .. "/" .. rel
end

local function toMap(list)
    local map = {}
    for _, f in ipairs(list or {}) do
        if type(f) == "table" and type(f.path) == "string" then
            map[f.path] = { size = tonumber(f.size), mtime = tonumber(f.mtime) }
        end
    end
    return map
end

local function toSet(list)
    local set = {}
    for _, p in ipairs(list or {}) do set[p] = true end
    return set
end

local function emptySummary()
    return {
        down = 0, up = 0, deleted_local = 0, deleted_remote = 0, adopted = 0,
        failed = 0, bad_names = 0, pending = 0, guard_tripped = 0,
        errors = {}, error = nil,
    }
end

function SyncEngine.run(ctx)
    local summary = emptySummary()
    local T, fs = ctx.transport, ctx.fs

    local manifest, err = T.manifest()
    if not manifest then
        summary.error = err or "could not fetch manifest"
        return summary
    end
    if manifest.version ~= 1 or type(manifest.files) ~= "table" then
        summary.error = "unsupported bridge version"
        return summary
    end

    fs.mkdirp(ctx.root)
    local remote = toMap(manifest.files)
    local locals = {}
    for p, info in pairs(fs.scan(ctx.root)) do
        if SyncPlan.isSyncable(p) then locals[p] = info end
    end
    local state = ctx.store.load() or {}

    local skip = {}
    if ctx.isSkipped then
        for _, tbl in ipairs({ remote, locals }) do
            for p in pairs(tbl) do
                if ctx.isSkipped(p) then skip[p] = true end
            end
        end
    end

    local plan = SyncPlan.reconcile(remote, locals, state, {
        pending = toSet(manifest.pending), skip = skip,
    })
    summary.bad_names = #plan.bad_names
    summary.pending = #(manifest.pending or {})

    if not ctx.force_deletions then
        local tracked = 0
        for _ in pairs(state) do tracked = tracked + 1 end
        summary.guard_tripped = SyncPlan.applyGuard(plan, tracked)
    end

    -- Cheap bookkeeping first: no transfers needed.
    for _, p in ipairs(plan.adopt) do
        state[p] = { size = remote[p].size, rmtime = remote[p].mtime, lmtime = locals[p].mtime }
        summary.adopted = summary.adopted + 1
    end
    for _, p in ipairs(plan.drop_state) do
        state[p] = nil
    end

    local total = SyncPlan.changeCount(plan)
    local done = 0
    local function step(p, ok, e)
        done = done + 1
        if not ok then
            summary.failed = summary.failed + 1
            table.insert(summary.errors, p .. ": " .. tostring(e))
        end
        if done % SAVE_EVERY == 0 then ctx.store.save(state) end
        if ctx.onProgress then ctx.onProgress(done, total, p) end
    end

    for _, p in ipairs(plan.download) do
        local r = remote[p]
        local dest = join(ctx.root, p)
        local tmp = dest .. ".part"
        fs.mkdirp(dirname(dest))
        local ok, e = T.download(p, tmp)
        if ok then
            local st = fs.stat(tmp)
            if not st or st.size ~= r.size then
                ok, e = nil, "size mismatch"
            else
                ok, e = fs.rename(tmp, dest)
            end
        end
        if ok then
            fs.touch(dest, r.mtime)
            local st = fs.stat(dest)
            state[p] = { size = r.size, rmtime = r.mtime, lmtime = st and st.mtime or r.mtime }
            summary.down = summary.down + 1
        else
            fs.remove(tmp)
        end
        step(p, ok, e)
    end

    for _, p in ipairs(plan.upload) do
        local l = locals[p]
        local info, e = T.upload(p, join(ctx.root, p), l.size, l.mtime)
        if info then
            state[p] = { size = l.size, rmtime = tonumber(info.mtime) or l.mtime, lmtime = l.mtime }
            summary.up = summary.up + 1
        end
        step(p, info ~= nil, e)
    end

    for _, p in ipairs(plan.delete_remote) do
        local ok, e = T.delete(p, ctx.run_id)
        if ok then
            state[p] = nil
            summary.deleted_remote = summary.deleted_remote + 1
        end
        step(p, ok, e)
    end

    for _, p in ipairs(plan.delete_local) do
        local file = join(ctx.root, p)
        local ok, e = fs.remove(file)
        if ok then
            fs.pruneEmptyDirs(dirname(file), ctx.root)
            state[p] = nil
            summary.deleted_local = summary.deleted_local + 1
        end
        step(p, ok, e)
    end

    ctx.store.save(state)
    summary.changed = summary.down + summary.up + summary.deleted_local + summary.deleted_remote
    return summary
end

return SyncEngine

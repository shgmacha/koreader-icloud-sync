--[[--
Pure two-way reconciliation for iCloud Sync. No KOReader dependencies, so it
can be unit-tested with plain LuaJIT.

Inputs are maps keyed by relative POSIX path:
  remote[path] = { size, mtime }            -- from the bridge manifest
  locals[path] = { size, mtime }            -- from scanning the Kindle folder
  state[path]  = { size, rmtime, lmtime }   -- what both sides looked like at the last sync
--]]

local SyncPlan = {}

SyncPlan.ALLOWED_EXTS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, fb2 = true,
    cbz = true, cbr = true, djvu = true, txt = true, rtf = true, docx = true,
    html = true, md = true,
}

-- Mass-deletion guard thresholds.
SyncPlan.GUARD_MIN = 10
SyncPlan.GUARD_RATIO = 0.5

local FAT_ILLEGAL = '[:%*%?"<>|\\]'

--- Shared sync rule (mirrors is_syncable in bridge/icloud_bridge.py).
function SyncPlan.isSyncable(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
        return false
    end
    local segs = {}
    for seg in (path .. "/"):gmatch("(.-)/") do
        if seg == "" or seg == "." or seg == ".." or seg:sub(1, 1) == "." then
            return false
        end
        if seg:find(FAT_ILLEGAL) then
            return false
        end
        segs[#segs + 1] = seg
    end
    local name = segs[#segs]
    if name:match("%.part$") or name:match("%.old$") then
        return false
    end
    for i = 1, #segs - 1 do
        if segs[i]:match("%.sdr$") then
            return true
        end
    end
    local ext = name:match("%.([^%.]+)$")
    return ext ~= nil and SyncPlan.ALLOWED_EXTS[ext:lower()] == true
end

local function remoteChanged(r, s)
    return r.size ~= s.size or r.mtime ~= s.rmtime
end

local function localChanged(l, s)
    return l.size ~= s.size or l.mtime ~= s.lmtime
end

-- Ties favour iCloud.
local function newestWins(r, l)
    if r.mtime >= l.mtime then return "download" end
    return "upload"
end

--- Decide the action for one path. Returns one of:
-- "download", "upload", "delete_local", "delete_remote", "adopt", "drop_state", nil (nothing)
function SyncPlan.decide(r, l, s)
    if not s then
        if r and l then
            if r.size == l.size then return "adopt" end
            return newestWins(r, l)
        elseif r then
            return "download"
        elseif l then
            return "upload"
        end
        return nil
    end
    if r and l then
        local rc, lc = remoteChanged(r, s), localChanged(l, s)
        if rc and lc then return newestWins(r, l) end
        if rc then return "download" end
        if lc then return "upload" end
        return nil
    elseif l then
        -- deleted in iCloud; an edit on the Kindle beats the delete
        if localChanged(l, s) then return "upload" end
        return "delete_local"
    elseif r then
        -- deleted on the Kindle; an edit in iCloud beats the delete
        if remoteChanged(r, s) then return "download" end
        return "delete_remote"
    end
    return "drop_state"
end

local function newPlan()
    return {
        download = {}, upload = {}, delete_local = {}, delete_remote = {},
        adopt = {}, drop_state = {}, skipped = {}, bad_names = {},
    }
end

--- Build the plan. opts.pending / opts.skip are sets of paths to leave alone.
function SyncPlan.reconcile(remote, locals, state, opts)
    opts = opts or {}
    local pending, skip = opts.pending or {}, opts.skip or {}
    local plan = newPlan()

    local paths, seen = {}, {}
    for _, tbl in ipairs({ remote, locals, state }) do
        for p in pairs(tbl) do
            if not seen[p] then
                seen[p] = true
                paths[#paths + 1] = p
            end
        end
    end
    table.sort(paths)

    for _, p in ipairs(paths) do
        if not SyncPlan.isSyncable(p) then
            table.insert(plan.bad_names, p)
        elseif pending[p] or skip[p] then
            table.insert(plan.skipped, p)
        else
            local action = SyncPlan.decide(remote[p], locals[p], state[p])
            if action then
                table.insert(plan[action], p)
            end
        end
    end
    return plan
end

--- Count of actions that transfer or delete something.
function SyncPlan.changeCount(plan)
    return #plan.download + #plan.upload + #plan.delete_local + #plan.delete_remote
end

--- Drop deletions if they look like an accident (folder vanished, card wiped).
-- Returns the number of deletions held back (0 when the guard didn't trip).
function SyncPlan.applyGuard(plan, tracked_count)
    local dl, dr = #plan.delete_local, #plan.delete_remote
    local limit = SyncPlan.GUARD_RATIO * tracked_count
    if dl + dr > SyncPlan.GUARD_MIN and (dl > limit or dr > limit) then
        plan.delete_local, plan.delete_remote = {}, {}
        return dl + dr
    end
    return 0
end

return SyncPlan

local H = require("tests.harness")
local SyncPlan = require("icloudsync_plan")
local test, eq = H.test, H.eq

-- Keep in sync with bridge/test_icloud_bridge.py SYNCABLE_CASES.
local SYNCABLE_CASES = {
    { "Dune.epub", true },
    { "Fiction/Dune.EPUB", true },
    { "Fiction/Dune.sdr/metadata.epub.lua", true },
    { "Fiction/Dune.sdr/cover.jpg", true },
    { "Fiction/Dune.sdr/metadata.epub.lua.old", false },
    { "Dune.epub.part", false },
    { "notes.jpg", false },
    { "noext", false },
    { ".hidden.epub", false },
    { ".koreader-trash/x/Dune.epub", false },
    { "a/../Dune.epub", false },
    { "./Dune.epub", false },
    { "/abs/Dune.epub", false },
    { "a//Dune.epub", false },
    { "", false },
    { "What? A book.epub", false },
    { "Café – Ünïcode.pdf", true },
    { "Smith Jr./Dune.epub", false },
    { "Trailing /Dune.epub", false },
    { "Tab\there.epub", false },
    { "Good Girl #1\u{F022} A Guide.epub", true },
    { "Smith Jr\u{F029}/Dune.epub", true },
}

test("isSyncable matches the shared case table", function()
    for _, c in ipairs(SYNCABLE_CASES) do
        eq(SyncPlan.isSyncable(c[1]), c[2], "isSyncable(" .. c[1] .. ")")
    end
end)

local function F(size, mtime) return { size = size, mtime = mtime } end
local function S(size, rmtime, lmtime) return { size = size, rmtime = rmtime, lmtime = lmtime } end

-- Every row of the spec's reconcile table.
local DECIDE_CASES = {
    -- name,                               R,           L,           S,               want
    { "new in iCloud",                     F(10, 100),  nil,         nil,             "download" },
    { "new on Kindle",                     nil,         F(10, 100),  nil,             "upload" },
    { "both, same size, no state",         F(10, 100),  F(10, 999),  nil,             "adopt" },
    { "both, diff size, iCloud newer",     F(10, 200),  F(11, 100),  nil,             "download" },
    { "both, diff size, Kindle newer",     F(10, 100),  F(11, 200),  nil,             "upload" },
    { "unchanged",                         F(10, 100),  F(10, 101),  S(10, 100, 101), nil },
    { "iCloud changed (mtime)",            F(10, 150),  F(10, 101),  S(10, 100, 101), "download" },
    { "iCloud changed (size)",             F(12, 100),  F(10, 101),  S(10, 100, 101), "download" },
    { "Kindle changed",                    F(10, 100),  F(10, 150),  S(10, 100, 101), "upload" },
    { "both changed, iCloud newer",        F(20, 300),  F(30, 200),  S(10, 100, 101), "download" },
    { "both changed, Kindle newer",        F(20, 200),  F(30, 300),  S(10, 100, 101), "upload" },
    { "both changed, tie -> iCloud",       F(20, 300),  F(30, 300),  S(10, 100, 101), "download" },
    { "deleted in iCloud",                 nil,         F(10, 101),  S(10, 100, 101), "delete_local" },
    { "deleted in iCloud, Kindle edited",  nil,         F(10, 200),  S(10, 100, 101), "upload" },
    { "deleted on Kindle",                 F(10, 100),  nil,         S(10, 100, 101), "delete_remote" },
    { "deleted on Kindle, iCloud edited",  F(10, 200),  nil,         S(10, 100, 101), "download" },
    { "deleted on both",                   nil,         nil,         S(10, 100, 101), "drop_state" },
}

test("decide covers every reconcile-table row", function()
    for _, c in ipairs(DECIDE_CASES) do
        eq(SyncPlan.decide(c[2], c[3], c[4]), c[5], c[1])
    end
end)

test("reconcile buckets paths, sorted", function()
    local remote = { ["b.epub"] = F(1, 1), ["a.epub"] = F(1, 1), ["gone.epub"] = F(1, 1) }
    local locals = { ["mine.pdf"] = F(2, 2), ["gone.epub"] = nil }
    local state  = { ["gone.epub"] = S(1, 1, 5) }
    local plan = SyncPlan.reconcile(remote, locals, state)
    eq(plan.download, { "a.epub", "b.epub" })
    eq(plan.upload, { "mine.pdf" })
    eq(plan.delete_remote, { "gone.epub" })
    eq(SyncPlan.changeCount(plan), 4)
end)

test("pending and skip paths are left alone", function()
    local remote = { ["big.pdf"] = F(1, 1) }
    local locals = { ["open.epub"] = F(1, 9), ["open.sdr/metadata.epub.lua"] = F(3, 9) }
    local state  = { ["big.pdf"] = S(1, 1, 1), ["open.epub"] = S(1, 1, 1) } -- big.pdf "missing" locally
    local plan = SyncPlan.reconcile(remote, locals, state, {
        pending = { ["big.pdf"] = true },
        skip = { ["open.epub"] = true, ["open.sdr/metadata.epub.lua"] = true },
    })
    eq(SyncPlan.changeCount(plan), 0)
    eq(plan.skipped, { "big.pdf", "open.epub", "open.sdr/metadata.epub.lua" })
end)

test("pending path is not deleted locally even though absent from files", function()
    local plan = SyncPlan.reconcile({}, { ["big.pdf"] = F(1, 1) }, { ["big.pdf"] = S(1, 1, 1) },
        { pending = { ["big.pdf"] = true } })
    eq(plan.delete_local, {})
end)

test("unsafe remote paths are reported, never acted on", function()
    local remote = { ["../escape.epub"] = F(1, 1), ["/etc/x.epub"] = F(1, 1), ["ok.epub"] = F(1, 1) }
    local plan = SyncPlan.reconcile(remote, {}, {})
    eq(plan.download, { "ok.epub" })
    eq(plan.bad_names, { "../escape.epub", "/etc/x.epub" })
end)

test("a record that only fails the stricter rule is dropped, not reported", function()
    -- v1.0 synced "Smith Jr./Dune.epub"; the Kindle's copy really sits at "Smith Jr/".
    local state = { ["Smith Jr./Dune.epub"] = S(4, 100, 100) }
    local remote = { ["Smith Jr\u{F029}/Dune.epub"] = F(4, 100) }
    local plan = SyncPlan.reconcile(remote, {}, state)
    eq(plan.drop_state, { "Smith Jr./Dune.epub" })
    eq(plan.bad_names, {})
    eq(plan.download, { "Smith Jr\u{F029}/Dune.epub" })
    eq(#plan.delete_local + #plan.delete_remote, 0, "nothing deleted")
end)

test("second pass after applying plan is a no-op", function()
    -- Simulate a completed first sync: both sides now equal, state recorded.
    local remote = { ["a.epub"] = F(5, 100), ["b.sdr/metadata.epub.lua"] = F(7, 200) }
    local locals = { ["a.epub"] = F(5, 100), ["b.sdr/metadata.epub.lua"] = F(7, 200) }
    local state = {
        ["a.epub"] = S(5, 100, 100),
        ["b.sdr/metadata.epub.lua"] = S(7, 200, 200),
    }
    local plan = SyncPlan.reconcile(remote, locals, state)
    eq(SyncPlan.changeCount(plan) + #plan.adopt + #plan.drop_state, 0)
end)

local function nDeletes(n_local, n_remote)
    local plan = { delete_local = {}, delete_remote = {} }
    for i = 1, n_local do plan.delete_local[i] = "l" .. i end
    for i = 1, n_remote do plan.delete_remote[i] = "r" .. i end
    return plan
end

test("guard trips on >10 deletions that are >50% of tracked", function()
    local plan = nDeletes(11, 0)
    eq(SyncPlan.applyGuard(plan, 20), 11)
    eq(plan.delete_local, {})
    plan = nDeletes(0, 30)
    eq(SyncPlan.applyGuard(plan, 40), 30, "remote side")
    eq(plan.delete_remote, {})
end)

test("guard does not trip for small or proportionate deletions", function()
    local plan = nDeletes(10, 0)
    eq(SyncPlan.applyGuard(plan, 10), 0, "exactly 10 is allowed")
    eq(#plan.delete_local, 10)
    plan = nDeletes(11, 0)
    eq(SyncPlan.applyGuard(plan, 100), 0, "11 of 100 is fine")
    plan = nDeletes(6, 6)
    eq(SyncPlan.applyGuard(plan, 20), 0, "neither side over 50%")
end)

H.done()

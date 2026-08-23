-- main_offline_pull_spec.lua
-- "Auto sync only when already online" (auto_sync_online_only). With it on,
-- background (auto sync) pulls on book open / device wake never force Wi-Fi
-- up: on devices where KOReader drives the radio (Kobo, Kindle, …)
-- NetworkMgr:beforeWifiAction is modal and blocks the UI thread — with
-- "Action when Wi-Fi is off: turn on" it shows an uncancellable "Scanning for
-- networks…" dialog for ~30 s when no known AP is in range. So when offline a
-- background pull skips silently, remembers that it skipped, and
-- onNetworkConnected reruns it once the device is back online. Interactive
-- pulls (menu taps), and every pull with the setting off (the default), keep
-- going through NetworkMgr:willRerunWhenOnline.

require("spec_helper")
local stubs = require("spec.koreader_stubs")

local UIManagerStub = stubs.UIManager
local NetworkMgrStub = stubs.NetworkMgr
local ReadestSync = require("main")

-- Bare plugin instance (skips init()); fakes the pull methods so tests observe
-- what onNetworkConnected triggers.
local function makePlugin(opts)
    local plugin = setmetatable({
        settings = {
            auto_sync = opts.auto_sync,
            auto_sync_online_only = opts.online_only ~= false,  -- default on in these specs
            access_token = opts.access_token,
            localsend_enabled = false,
        },
        ui = { document = opts.document },
        pull_calls = {},
    }, { __index = ReadestSync })
    for _, method in ipairs({ "pullBookConfig", "pullBookNotes", "pullBookStats" }) do
        plugin[method] = function(self, interactive)
            table.insert(self.pull_calls, { method = method, interactive = interactive })
        end
    end
    return plugin
end

describe("ReadestSync:willRerunPullWhenOnline", function()
    before_each(function()
        stubs.reset()
    end)

    it("lets a background pull proceed when online, without touching NetworkMgr", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        NetworkMgrStub._online = true

        assert.is_false(plugin:willRerunPullWhenOnline(false, function() end))
        assert.are.equal(0, NetworkMgrStub._willRerunWhenOnline_calls)
        assert.is_nil(plugin.pull_pending_offline)
    end)

    it("skips a background pull when offline and never asks NetworkMgr to bring Wi-Fi up", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        NetworkMgrStub._online = false

        assert.is_true(plugin:willRerunPullWhenOnline(false, function() end))
        -- This is the whole point: no beforeWifiAction, so no blocking modal.
        assert.are.equal(0, NetworkMgrStub._willRerunWhenOnline_calls)
        assert.is_true(plugin.pull_pending_offline)
    end)

    it("routes an interactive pull through NetworkMgr:willRerunWhenOnline", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        NetworkMgrStub._online = false

        assert.is_false(plugin:willRerunPullWhenOnline(true, function() end))
        assert.are.equal(1, NetworkMgrStub._willRerunWhenOnline_calls)
        assert.is_nil(plugin.pull_pending_offline)
    end)

    it("keeps the default behaviour when the setting is off (background pull goes through NetworkMgr)", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {}, online_only = false })
        NetworkMgrStub._online = false

        assert.is_false(plugin:willRerunPullWhenOnline(false, function() end))
        assert.are.equal(1, NetworkMgrStub._willRerunWhenOnline_calls)
        assert.is_nil(plugin.pull_pending_offline)
    end)

    it("treats a missing setting (pre-upgrade settings table) as off", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        plugin.settings.auto_sync_online_only = nil
        NetworkMgrStub._online = false

        assert.is_false(plugin:willRerunPullWhenOnline(false, function() end))
        assert.are.equal(1, NetworkMgrStub._willRerunWhenOnline_calls)
    end)
end)

describe("ReadestSync background pulls while offline", function()
    before_each(function()
        stubs.reset()
    end)

    -- Real pull methods (not the fakes): each must bail before ensureClient
    -- when offline, and reach it when online.
    for _, method in ipairs({ "pullBookConfig", "pullBookNotes", "pullBookStats" }) do
        it(method .. "(false) bails before ensureClient when offline", function()
            local plugin = setmetatable({
                settings = { auto_sync = true, auto_sync_online_only = true, access_token = "tok" },
                ui = { document = {} },
                ensure_client_calls = 0,
            }, { __index = ReadestSync })
            plugin.getBookIdentifiers = function() return "book-hash", "meta-hash" end
            plugin.ensureClient = function(self)
                self.ensure_client_calls = self.ensure_client_calls + 1
                return nil  -- stop here; the sync modules are out of scope
            end

            NetworkMgrStub._online = false
            plugin[method](plugin, false)
            assert.are.equal(0, plugin.ensure_client_calls)
            assert.are.equal(0, NetworkMgrStub._willRerunWhenOnline_calls)
            assert.is_true(plugin.pull_pending_offline)

            NetworkMgrStub._online = true
            plugin[method](plugin, false)
            assert.are.equal(1, plugin.ensure_client_calls)
        end)
    end
end)

describe("ReadestSync:onNetworkConnected", function()
    before_each(function()
        stubs.reset()
    end)

    it("reruns the skipped pull once the device is back online", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        plugin.pull_pending_offline = true

        plugin:onNetworkConnected()

        assert.are.equal(1, #UIManagerStub._scheduled)
        -- Deferred, like the open pull: let the event settle first.
        assert.is_true(UIManagerStub._scheduled[1].delay > 0)
        assert.is_nil(plugin.pull_pending_offline)

        UIManagerStub._scheduled[1].fn()
        assert.are.equal(3, #plugin.pull_calls)
        local pulled = {}
        for _, call in ipairs(plugin.pull_calls) do
            pulled[call.method] = true
            assert.is_false(call.interactive)
        end
        assert.is_true(pulled.pullBookConfig)
        assert.is_true(pulled.pullBookNotes)
        assert.is_true(pulled.pullBookStats)
    end)

    it("does nothing when no pull was skipped", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        plugin:onNetworkConnected()
        assert.are.equal(0, #UIManagerStub._scheduled)
    end)

    it("does nothing without an open document (FileManager context)", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = nil })
        plugin.pull_pending_offline = true
        plugin:onNetworkConnected()
        assert.are.equal(0, #UIManagerStub._scheduled)
    end)

    it("does nothing when auto sync is off or signed out", function()
        for _, opts in ipairs({
            { auto_sync = false, access_token = "tok", document = {} },
            { auto_sync = true, access_token = nil, document = {} },
        }) do
            local plugin = makePlugin(opts)
            plugin.pull_pending_offline = true
            plugin:onNetworkConnected()
            assert.are.equal(0, #UIManagerStub._scheduled)
        end
    end)

    it("coalesces repeated NetworkConnected events into one pull", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        plugin.pull_pending_offline = true
        plugin:onNetworkConnected()
        plugin:onNetworkConnected()
        assert.are.equal(1, #UIManagerStub._scheduled)
    end)

    it("drops the pending pull and the flag when the widget closes", function()
        local plugin = makePlugin({ auto_sync = true, access_token = "tok", document = {} })
        plugin.pull_pending_offline = true
        plugin:onNetworkConnected()
        assert.are.equal(1, #UIManagerStub._scheduled)

        plugin.pull_pending_offline = true  -- as if another pull skipped meanwhile
        plugin:onCloseWidget()
        assert.are.equal(0, #UIManagerStub._scheduled)
        assert.is_nil(plugin.pull_pending_offline)
    end)
end)

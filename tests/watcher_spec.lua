---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")
local project_mock = require("tests.helpers.project_mock")

describe("haunt.watcher", function()
	local watcher

	before_each(function()
		helpers.reset_modules()
		watcher = require("haunt.watcher")
	end)

	after_each(function()
		watcher.stop()
		project_mock.restore()
	end)

	describe("start", function()
		it("returns false when not in a git repo", function()
			-- Force `git rev-parse --absolute-git-dir` to fail by running it from /tmp.
			local original_cwd = vim.fn.getcwd()
			local tmp = vim.fn.tempname()
			vim.fn.mkdir(tmp, "p")
			vim.cmd("cd " .. tmp)

			local started = watcher.start()

			vim.cmd("cd " .. original_cwd)
			vim.fn.delete(tmp, "rf")

			assert.is_false(started)
		end)

		it("does not throw when called repeatedly", function()
			local ok, err = pcall(function()
				watcher.start()
				watcher.start()
				watcher.start()
			end)
			assert.is_true(ok, "watcher.start raised: " .. tostring(err))
		end)
	end)

	describe("stop", function()
		it("is safe to call without prior start", function()
			local ok, err = pcall(watcher.stop)
			assert.is_true(ok, "watcher.stop raised: " .. tostring(err))
		end)

		it("is idempotent", function()
			watcher.start()
			local ok, err = pcall(function()
				watcher.stop()
				watcher.stop()
			end)
			assert.is_true(ok, "double stop raised: " .. tostring(err))
		end)
	end)

	describe("_check_and_reload", function()
		it("is a no-op when no storage path has been stamped", function()
			-- Fresh store has no stamped path, so even if branches differ
			-- the watcher must not fire reload.
			local store = require("haunt.store")
			store._reset_for_testing()
			assert.is_nil(store.get_loaded_storage_path())

			local api = require("haunt.api")
			local original_reload = api.reload
			local reload_called = false
			api.reload = function()
				reload_called = true
				return true
			end

			local ok, err = pcall(watcher._check_and_reload)

			api.reload = original_reload

			assert.is_true(ok, "_check_and_reload raised: " .. tostring(err))
			assert.is_false(reload_called)
		end)

		it("does not reload when current storage path matches the stamped path", function()
			project_mock.set({ root = "/proj", branch = "main", project_id = "p-id" })

			-- Force the store to stamp itself by calling load(). Reset first to
			-- make sure load() actually runs (otherwise it short-circuits on _loaded).
			local store = require("haunt.store")
			store._reset_for_testing()
			package.loaded["haunt.store"] = nil
			store = require("haunt.store")
			store.load()

			local stamped = store.get_loaded_storage_path()
			assert.is_string(stamped)

			local api = require("haunt.api")
			local original_reload = api.reload
			local reload_called = false
			api.reload = function()
				reload_called = true
				return true
			end

			-- Same project_mock still in effect → same storage path → no reload.
			local ok, err = pcall(watcher._check_and_reload)

			api.reload = original_reload

			assert.is_true(ok, "_check_and_reload raised: " .. tostring(err))
			assert.is_false(reload_called)
		end)

		-- The watcher decides whether to reload by comparing the freshly
		-- resolved storage path against the store's stamp. Both sides now
		-- include the active collection, so the comparison keeps working: same
		-- collection on a new branch still resolves to a different path.
		it("resolves a different path on a new branch while a non-default collection is active", function()
			local data_dir = helpers.create_temp_data_dir()
			local persistence = require("haunt.persistence")
			persistence.set_data_dir(data_dir)

			project_mock.set({ root = "/proj", branch = "main", project_id = "p-id" })

			local collections = require("haunt.collections")
			collections.invalidate()
			collections.create("review")
			collections.set_active("review")

			local store = require("haunt.store")
			store._reset_for_testing()
			package.loaded["haunt.store"] = nil
			store = require("haunt.store")
			store.load()

			local stamped = store.get_loaded_storage_path()
			assert.is_string(stamped)

			-- The stamp reflects the active collection, not the default one.
			assert.are.equal(persistence.get_storage_path({ collection = "review" }), stamped)
			assert.are_not.equal(persistence.get_storage_path({ collection = "default" }), stamped)

			-- Same collection, different branch → the watcher sees a mismatch.
			project_mock.set({ root = "/proj", branch = "feature", project_id = "p-id" })
			assert.are_not.equal(stamped, persistence.get_storage_path())

			persistence.set_data_dir(nil)
			helpers.cleanup_temp_dir(data_dir)
		end)
	end)
end)

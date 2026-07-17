---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.api collections", function()
	local api
	local collections
	local persistence
	local hooks
	local data_dir
	local bufnr, test_file
	local original_confirm, original_input

	before_each(function()
		helpers.reset_modules()
		data_dir = helpers.create_temp_data_dir()

		local haunt = require("haunt")
		haunt.setup({ data_dir = data_dir })

		api = require("haunt.api")
		collections = require("haunt.collections")
		persistence = require("haunt.persistence")
		hooks = require("haunt.hooks")

		persistence.set_data_dir(data_dir)
		collections.invalidate()
		api._reset_for_testing()

		-- Auto-confirm destructive prompts by default; tests that care override.
		original_confirm = vim.fn.confirm
		vim.fn.confirm = function()
			return 1
		end

		original_input = vim.fn.input

		bufnr, test_file = helpers.create_test_buffer()
	end)

	after_each(function()
		vim.fn.confirm = original_confirm
		vim.fn.input = original_input
		helpers.cleanup_buffer(bufnr, test_file)
		helpers.cleanup_temp_dir(data_dir)
	end)

	---@param line number
	---@param note string
	local function annotate_at(line, note)
		vim.api.nvim_win_set_cursor(0, { line, 0 })
		api.annotate(note)
	end

	describe("create_collection", function()
		it("creates and switches by default", function()
			assert.is_true(api.create_collection("review"))
			assert.are.equal("review", collections.get_active())
		end)

		it("does not switch when switch = false", function()
			assert.is_true(api.create_collection("review", { switch = false }))
			assert.are.equal("default", collections.get_active())
			assert.is_true(collections.exists("review"))
		end)

		it("rejects a duplicate", function()
			api.create_collection("review", { switch = false })
			assert.is_false(api.create_collection("review", { switch = false }))
		end)

		it("rejects the reserved default name", function()
			assert.is_false(api.create_collection("default", { switch = false }))
		end)

		it("rejects an invalid name", function()
			assert.is_false(api.create_collection("a|b", { switch = false }))
			assert.is_false(collections.exists("a|b"))
		end)

		it("prompts when no name is given", function()
			vim.fn.input = function()
				return "prompted"
			end
			assert.is_true(api.create_collection())
			assert.is_true(collections.exists("prompted"))
		end)

		it("treats an empty prompt as a cancel", function()
			vim.fn.input = function()
				return ""
			end
			assert.is_false(api.create_collection())
			assert.are.same({ "default" }, collections.list())
		end)
	end)

	describe("switch_collection", function()
		it("isolates bookmarks between collections", function()
			annotate_at(1, "default-note")
			assert.are.equal(1, #api.get_bookmarks())

			api.create_collection("review")
			assert.are.equal(0, #api.get_bookmarks())

			annotate_at(2, "review-note")
			assert.are.equal(1, #api.get_bookmarks())

			api.switch_collection("default")
			assert.are.equal(1, #api.get_bookmarks())
			assert.are.equal("default-note", api.get_bookmarks()[1].note)

			api.switch_collection("review")
			assert.are.equal("review-note", api.get_bookmarks()[1].note)
		end)

		it("persists bookmarks of the collection being left", function()
			annotate_at(1, "default-note")
			api.create_collection("review")
			api.switch_collection("default")

			assert.are.equal(1, #api.get_bookmarks())
			assert.are.equal("default-note", api.get_bookmarks()[1].note)
		end)

		it("rejects an unknown collection", function()
			assert.is_false(api.switch_collection("nope"))
			assert.are.equal("default", collections.get_active())
		end)

		it("rejects an invalid name", function()
			assert.is_false(api.switch_collection(""))
		end)

		it("is a no-op when already active", function()
			local emitted = 0
			hooks.on_collection_change(function()
				emitted = emitted + 1
			end)

			assert.is_true(api.switch_collection("default"))
			assert.are.equal(0, emitted)

			hooks._reset_for_testing()
		end)

		it("emits on_collection_change with both names", function()
			api.create_collection("review", { switch = false })

			local ctx
			hooks.on_collection_change(function(c)
				ctx = c
			end)

			api.switch_collection("review")

			assert.is_not_nil(ctx)
			assert.are.equal("review", ctx.new_collection)
			assert.are.equal("default", ctx.old_collection)

			hooks._reset_for_testing()
		end)

		-- A failed registry write must not leave memory showing a collection
		-- that disk does not consider active.
		it("does not reload when the registry write fails", function()
			api.create_collection("review", { switch = false })
			annotate_at(1, "default-note")

			local original = vim.fn.writefile
			vim.fn.writefile = function()
				return -1
			end

			local ok = api.switch_collection("review")

			vim.fn.writefile = original

			assert.is_false(ok)
			assert.are.equal("default", collections.get_active())
			assert.are.equal(1, #api.get_bookmarks())
		end)
	end)

	describe("delete_collection", function()
		it("refuses to delete the default collection", function()
			assert.is_false(api.delete_collection("default"))
			assert.is_true(collections.exists("default"))
		end)

		it("refuses even when default is not active", function()
			api.create_collection("review")
			assert.is_false(api.delete_collection("default"))
			assert.is_true(collections.exists("default"))
		end)

		it("deletes a non-active collection", function()
			api.create_collection("review", { switch = false })
			assert.is_true(api.delete_collection("review"))
			assert.is_false(collections.exists("review"))
			assert.are.equal("default", collections.get_active())
		end)

		it("falls back to default when deleting the active collection", function()
			annotate_at(1, "default-note")
			api.create_collection("review")
			annotate_at(2, "review-note")

			assert.is_true(api.delete_collection("review"))

			assert.are.equal("default", collections.get_active())
			assert.are.equal(1, #api.get_bookmarks())
			assert.are.equal("default-note", api.get_bookmarks()[1].note)
		end)

		it("unlinks the collection's storage file", function()
			api.create_collection("review")
			annotate_at(1, "review-note")

			local review_path = persistence.get_storage_path()
			assert.are.equal(1, vim.fn.filereadable(review_path))

			api.delete_collection("review")

			assert.are.equal(0, vim.fn.filereadable(review_path))
		end)

		it("does not resurrect bookmarks after recreating the name", function()
			api.create_collection("review")
			annotate_at(1, "review-note")
			api.delete_collection("review")

			api.create_collection("review")
			assert.are.equal(0, #api.get_bookmarks())
		end)

		it("rejects an unknown collection", function()
			assert.is_false(api.delete_collection("nope"))
		end)

		-- The branch fan-out enumerates refs/heads, which yields nothing when git
		-- is unavailable and never contains a detached HEAD. The store still
		-- wrote a file keyed by whatever branch resolved to (nil included), so it
		-- must still be unlinked — otherwise recreating the name resurrects the
		-- bookmarks the user was told were deleted.
		it("unlinks the file when the branch is unresolvable", function()
			local project_mock = require("tests.helpers.project_mock")
			project_mock.set({ root = nil, branch = nil, project_id = "no-git-project" })
			collections.invalidate()

			api.create_collection("review")
			annotate_at(1, "review-note")

			local review_path = persistence.get_storage_path()
			assert.are.equal(1, vim.fn.filereadable(review_path))

			assert.is_true(api.delete_collection("review"))
			assert.are.equal(0, vim.fn.filereadable(review_path))

			project_mock.restore()
		end)

		it("unlinks the file for a detached HEAD", function()
			local project_mock = require("tests.helpers.project_mock")
			local project = require("haunt.project")

			-- Detached HEAD reports a short commit hash, and `refs/heads` never
			-- lists it. Mock the ref listing rather than relying on whatever
			-- branches the ambient repo happens to have.
			project_mock.set({ root = "/tmp/detached", branch = "a1b2c3d", project_id = "detached-project" })
			local original_run_git = project.run_git
			project.run_git = function()
				return { "main", "develop" }
			end
			collections.invalidate()

			api.create_collection("review")
			annotate_at(1, "review-note")

			local review_path = persistence.get_storage_path()
			assert.are.equal(1, vim.fn.filereadable(review_path))

			local ok = api.delete_collection("review")

			project.run_git = original_run_git
			project_mock.restore()

			assert.is_true(ok)
			assert.are.equal(0, vim.fn.filereadable(review_path))
		end)

		it("respects a declined confirmation", function()
			api.create_collection("review", { switch = false })
			vim.fn.confirm = function()
				return 2
			end

			assert.is_false(api.delete_collection("review"))
			assert.is_true(collections.exists("review"))
		end)

		it("emits on_collection_change when the active collection is deleted", function()
			api.create_collection("review")

			local ctx
			hooks.on_collection_change(function(c)
				ctx = c
			end)

			api.delete_collection("review")

			assert.is_not_nil(ctx)
			assert.are.equal("default", ctx.new_collection)
			assert.are.equal("review", ctx.old_collection)

			hooks._reset_for_testing()
		end)

		it("prompts when no name is given", function()
			api.create_collection("review", { switch = false })
			vim.fn.input = function()
				return "review"
			end

			assert.is_true(api.delete_collection())
			assert.is_false(collections.exists("review"))
		end)

		it("treats an empty prompt as a cancel", function()
			vim.fn.input = function()
				return ""
			end
			assert.is_false(api.delete_collection())
		end)
	end)

	describe("import_collection", function()
		local json_buf

		--- Put JSON in a buffer and make it current, as `:HauntCollectionImport % `
		--- would see it.
		---@param entries table
		local function json_buffer(entries)
			json_buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(json_buf, 0, -1, false, vim.split(vim.json.encode(entries), "\n"))
			vim.api.nvim_set_current_buf(json_buf)
		end

		after_each(function()
			if json_buf and vim.api.nvim_buf_is_valid(json_buf) then
				vim.api.nvim_buf_delete(json_buf, { force = true })
			end
			json_buf = nil
		end)

		it("creates a collection from the current buffer and switches to it", function()
			json_buffer({
				{ file = "/tmp/a.lua", line = 3, summary = "first finding" },
				{ file = "/tmp/b.lua", line = 9, summary = "second finding" },
			})

			assert.is_true(api.import_collection("review"))

			assert.are.equal("review", collections.get_active())
			assert.are.equal(2, #api.get_bookmarks())
		end)

		it("annotates bookmarks with the summary", function()
			json_buffer({ { file = "/tmp/a.lua", line = 3, summary = "the summary" } })
			api.import_collection("review")

			assert.are.equal("the summary", api.get_bookmarks()[1].note)
		end)

		it("persists the imported bookmarks", function()
			json_buffer({ { file = "/tmp/a.lua", line = 3, summary = "x" } })
			api.import_collection("review")

			assert.are.equal(1, vim.fn.filereadable(persistence.get_storage_path()))

			-- Round-trip: they survive a switch away and back.
			api.switch_collection("default")
			api.switch_collection("review")
			assert.are.equal(1, #api.get_bookmarks())
		end)

		it("imports from a file path", function()
			local path = vim.fn.tempname() .. ".json"
			vim.fn.writefile({ vim.json.encode({ { file = "/tmp/a.lua", line = 1, summary = "from file" } }) }, path)

			assert.is_true(api.import_collection("review", path))
			assert.are.equal("from file", api.get_bookmarks()[1].note)

			vim.fn.delete(path)
		end)

		-- The user asked for refuse-not-merge, so an import can never quietly
		-- rewrite bookmarks that already exist.
		it("refuses when the collection already exists", function()
			api.create_collection("review", { switch = false })
			json_buffer({ { file = "/tmp/a.lua", line = 1, summary = "x" } })

			assert.is_false(api.import_collection("review"))
		end)

		it("leaves an existing collection's bookmarks untouched when refusing", function()
			local bufnr, test_file = helpers.create_test_buffer()
			api.create_collection("review")
			annotate_at(1, "hand-made")

			json_buffer({ { file = "/tmp/a.lua", line = 1, summary = "imported" } })
			assert.is_false(api.import_collection("review"))

			api.switch_collection("review")
			assert.are.equal(1, #api.get_bookmarks())
			assert.are.equal("hand-made", api.get_bookmarks()[1].note)

			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("rejects an invalid collection name", function()
			json_buffer({ { file = "/tmp/a.lua", line = 1, summary = "x" } })
			assert.is_false(api.import_collection("a|b"))
			assert.is_false(collections.exists("a|b"))
		end)

		it("rejects the reserved default name", function()
			json_buffer({ { file = "/tmp/a.lua", line = 1, summary = "x" } })
			assert.is_false(api.import_collection("default"))
		end)

		-- Don't leave an empty collection behind for an import that found nothing.
		it("does not create a collection from undecodable JSON", function()
			json_buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(json_buf, 0, -1, false, { "{ not json" })
			vim.api.nvim_set_current_buf(json_buf)

			assert.is_false(api.import_collection("review"))
			assert.is_false(collections.exists("review"))
		end)

		it("does not create a collection from an empty array", function()
			json_buffer({})
			assert.is_false(api.import_collection("review"))
			assert.is_false(collections.exists("review"))
		end)

		it("does not create a collection when every entry is malformed", function()
			json_buffer({ { line = 1 }, { file = "" } })
			assert.is_false(api.import_collection("review"))
			assert.is_false(collections.exists("review"))
		end)

		it("does not create a collection from a missing file", function()
			assert.is_false(api.import_collection("review", "/nope/missing.json"))
			assert.is_false(collections.exists("review"))
		end)

		it("imports the good entries and skips the bad", function()
			json_buffer({
				{ file = "/tmp/a.lua", line = 1, summary = "good" },
				{ line = 2, summary = "no file" },
			})

			assert.is_true(api.import_collection("review"))
			assert.are.equal(1, #api.get_bookmarks())
		end)

		-- Imported bookmarks arrive with no extmarks; a buffer already open must
		-- get its signs and annotations drawn now, not on next load.
		it("renders visuals in an already-open buffer", function()
			local bufnr, test_file = helpers.create_test_buffer()

			json_buffer({ { file = test_file, line = 1, summary = "visible now" } })
			api.import_collection("review")

			-- Back to the annotated file: the import drew into it while it was open.
			vim.api.nvim_set_current_buf(bufnr)
			local ns = require("haunt.display").get_namespace()
			local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
			assert.is_true(#marks > 0, "imported bookmark left no extmarks in the open buffer")

			helpers.cleanup_buffer(bufnr, test_file)
		end)
	end)

	describe("store persistence safety", function()
		local store

		before_each(function()
			store = require("haunt.store")
		end)

		--- Get a store module that has genuinely never loaded. `_reset_for_testing`
		--- deliberately sets `_loaded = true` to prevent auto-loading, so it
		--- cannot express this state; only a fresh require can.
		---@return table store
		local function fresh_unloaded_store()
			package.loaded["haunt.store"] = nil
			return require("haunt.store")
		end

		-- Regression: an unloaded store is empty because it has not read disk,
		-- not because the user has no bookmarks. Saving it wrote an empty list,
		-- and an empty save deletes the storage file — so switching collections
		-- from a session that had not loaded yet (opening the picker straight
		-- from a dashboard) destroyed the bookmarks it was about to leave.
		it("does not let an unloaded store wipe a collection's bookmarks", function()
			api.create_collection("review")
			annotate_at(1, "keep me")

			local review_path = persistence.get_storage_path()
			assert.are.equal(1, vim.fn.filereadable(review_path))

			local pristine = fresh_unloaded_store()
			assert.is_nil(pristine.get_loaded_storage_path())

			assert.is_true(pristine.save())

			assert.are.equal(1, vim.fn.filereadable(review_path))
		end)

		-- The counterpart to the guard above: `load()` leaves the store unloaded
		-- when the file is corrupt (or still v1), but bookmarks made after that
		-- failure must still reach disk — writing valid v2 repairs the file.
		-- Guarding on `_loaded` alone would silently drop them.
		it("persists bookmarks added after a failed load", function()
			local path = persistence.get_storage_path()
			vim.fn.writefile({ "{ not valid json" }, path)

			local pristine = require("haunt.store")
			package.loaded["haunt.store"] = nil
			pristine = require("haunt.store")

			-- add_bookmark -> ensure_loaded -> load() fails, store stays unloaded
			pristine.add_bookmark(persistence.create_bookmark("/tmp/repaired.lua", 1, "survives"))
			assert.is_nil(pristine.get_loaded_storage_path())

			assert.is_true(pristine.save())

			local written = table.concat(vim.fn.readfile(path), "")
			local ok, data = pcall(vim.json.decode, written)
			assert.is_true(ok, "storage file should have been repaired to valid JSON")
			assert.are.equal(1, #data.bookmarks)
			assert.are.equal("survives", data.bookmarks[1].note)
		end)

		it("still deletes the file when a loaded store is emptied", function()
			annotate_at(1, "note")
			local path = persistence.get_storage_path()
			assert.are.equal(1, vim.fn.filereadable(path))

			-- Clearing everything is a legitimate empty save: the file should go.
			store.clear_all_bookmarks()
			store.save()

			assert.are.equal(0, vim.fn.filereadable(path))
		end)
	end)

	describe("change_data_dir", function()
		-- The registry lives inside the data dir, so its cache must not survive
		-- a dir swap.
		it("resolves the new dir's collections", function()
			api.create_collection("in-first-dir", { switch = false })
			assert.is_true(collections.exists("in-first-dir"))

			local other_dir = helpers.create_temp_data_dir()
			api.change_data_dir(other_dir)

			assert.is_false(collections.exists("in-first-dir"))
			assert.are.equal("default", collections.get_active())

			api.change_data_dir(data_dir)
			assert.is_true(collections.exists("in-first-dir"))

			helpers.cleanup_temp_dir(other_dir)
		end)
	end)
end)

---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt user commands", function()
	local haunt
	local api

	before_each(function()
		helpers.reset_modules()
		haunt = require("haunt")
		haunt.setup()
		api = require("haunt.api")
		api._reset_for_testing()
	end)

	describe("command registration", function()
		local expected_commands = {
			"HauntToggle",
			"HauntAnnotate",
			"HauntList",
			"HauntClear",
			"HauntClearAll",
			"HauntNext",
			"HauntPrev",
			"HauntQf",
			"HauntQfAll",
			"HauntMigrate",
			"HauntReload",
			"HauntCollections",
			"HauntCollectionNew",
			"HauntCollectionDelete",
			"HauntCollectionImport",
		}

		for _, cmd in ipairs(expected_commands) do
			it("registers " .. cmd, function()
				local exists = vim.fn.exists(":" .. cmd) == 2
				assert.is_true(exists)
			end)
		end
	end)

	describe("HauntAnnotate", function()
		local bufnr, test_file
		local original_input

		before_each(function()
			bufnr, test_file = helpers.create_test_buffer()
			original_input = vim.fn.input
		end)

		after_each(function()
			vim.fn.input = original_input
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("creates annotated bookmark", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.fn.input = function()
				return "Command annotation"
			end

			vim.cmd("HauntAnnotate")

			local bookmarks = api.get_bookmarks()
			assert.are.equal(1, #bookmarks)
			assert.are.equal("Command annotation", bookmarks[1].note)
		end)
	end)

	describe("HauntDelete", function()
		local bufnr, test_file
		local original_input

		before_each(function()
			bufnr, test_file = helpers.create_test_buffer()
			original_input = vim.fn.input
			vim.fn.input = function()
				return "Test"
			end
		end)

		after_each(function()
			vim.fn.input = original_input
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("removes bookmark at cursor", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")

			local before = api.get_bookmarks()
			assert.are.equal(1, #before)

			vim.cmd("HauntDelete")

			local after = api.get_bookmarks()
			assert.are.equal(0, #after)
		end)
	end)

	describe("HauntNext / HauntPrev", function()
		local bufnr, test_file
		local original_input

		before_each(function()
			bufnr, test_file = helpers.create_test_buffer({ "Line 1", "Line 2", "Line 3", "Line 4", "Line 5" })
			original_input = vim.fn.input
			vim.fn.input = function()
				return "Test"
			end

			-- Create bookmarks at lines 1, 3, 5
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			vim.cmd("HauntAnnotate")
			vim.api.nvim_win_set_cursor(0, { 5, 0 })
			vim.cmd("HauntAnnotate")
		end)

		after_each(function()
			vim.fn.input = original_input
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("HauntNext jumps to next bookmark", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntNext")
			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)

		it("HauntPrev jumps to previous bookmark", function()
			vim.api.nvim_win_set_cursor(0, { 5, 0 })
			vim.cmd("HauntPrev")
			local pos = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(3, pos[1])
		end)
	end)

	describe("HauntClear", function()
		local bufnr1, test_file1, bufnr2, test_file2
		local original_input

		before_each(function()
			original_input = vim.fn.input
			vim.fn.input = function()
				return "Test"
			end

			bufnr1, test_file1 = helpers.create_test_buffer({ "File1 Line 1", "File1 Line 2" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			vim.cmd("HauntAnnotate")

			bufnr2, test_file2 = helpers.create_test_buffer({ "File2 Line 1" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
		end)

		after_each(function()
			vim.fn.input = original_input
			helpers.cleanup_buffer(bufnr1, test_file1)
			helpers.cleanup_buffer(bufnr2, test_file2)
		end)

		it("clears only current file bookmarks", function()
			local before = api.get_bookmarks()
			assert.are.equal(3, #before)

			vim.api.nvim_set_current_buf(bufnr1)
			vim.cmd("HauntClear")

			local after = api.get_bookmarks()
			assert.are.equal(1, #after)
		end)
	end)

	describe("HauntClearAll", function()
		local bufnr, test_file
		local original_input, original_confirm

		before_each(function()
			original_input = vim.fn.input
			original_confirm = vim.fn.confirm

			vim.fn.input = function()
				return "Test"
			end

			bufnr, test_file = helpers.create_test_buffer()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			vim.cmd("HauntAnnotate")
		end)

		after_each(function()
			vim.fn.input = original_input
			vim.fn.confirm = original_confirm
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("clears all bookmarks when confirmed", function()
			vim.fn.confirm = function()
				return 1
			end

			local before = api.get_bookmarks()
			assert.are.equal(2, #before)

			vim.cmd("HauntClearAll")

			local after = api.get_bookmarks()
			assert.are.equal(0, #after)
		end)
	end)

	describe("HauntList", function()
		local bufnr, test_file
		local original_input
		local original_ui_select
		local ui_select_calls

		before_each(function()
			bufnr, test_file = helpers.create_test_buffer()
			original_input = vim.fn.input
			vim.fn.input = function()
				return "Test"
			end

			-- No picker plugin is installed in the test env, so picker.show()
			-- falls through to the vim.ui.select fallback. Neovim's default
			-- implementation calls vim.fn.inputlist, which blocks on stdin and
			-- hangs the headless run — stub it out and record the call instead.
			ui_select_calls = {}
			original_ui_select = vim.ui.select
			vim.ui.select = function(items, opts, on_choice)
				table.insert(ui_select_calls, { items = items, opts = opts, on_choice = on_choice })
			end

			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
		end)

		after_each(function()
			vim.fn.input = original_input
			vim.ui.select = original_ui_select
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("calls picker.show without throwing", function()
			local picker = require("haunt.picker")
			local ok = pcall(picker.show)
			assert.is_true(ok)
		end)

		it("HauntList reaches the picker", function()
			vim.cmd("HauntList")

			assert.are.equal(1, #ui_select_calls)
		end)
	end)

	describe("HauntCollectionDelete completion", function()
		local data_dir
		local collections

		before_each(function()
			data_dir = helpers.create_temp_data_dir()
			require("haunt.persistence").set_data_dir(data_dir)
			collections = require("haunt.collections")
			collections.invalidate()
		end)

		after_each(function()
			require("haunt.persistence").set_data_dir(nil)
			helpers.cleanup_temp_dir(data_dir)
		end)

		-- A Lua `complete` has customlist semantics: Neovim does not filter the
		-- returned list against what was typed, so the command must do it.
		it("filters on what has been typed", function()
			collections.create("review")
			collections.create("refactor")
			collections.create("perf")

			local matches = vim.fn.getcompletion("HauntCollectionDelete re", "cmdline")
			table.sort(matches)
			assert.are.same({ "refactor", "review" }, matches)
		end)

		it("omits the default collection, which cannot be deleted", function()
			collections.create("review")

			local matches = vim.fn.getcompletion("HauntCollectionDelete ", "cmdline")
			assert.is_false(vim.tbl_contains(matches, "default"))
			assert.is_true(vim.tbl_contains(matches, "review"))
		end)
	end)

	describe("HauntCollectionImport", function()
		local data_dir
		local collections
		local json_buf

		before_each(function()
			data_dir = helpers.create_temp_data_dir()
			require("haunt.persistence").set_data_dir(data_dir)
			collections = require("haunt.collections")
			collections.invalidate()

			json_buf = vim.api.nvim_create_buf(false, true)
			local json = vim.json.encode({
				{ file = "/tmp/a.lua", line = 3, summary = "a finding" },
			})
			vim.api.nvim_buf_set_lines(json_buf, 0, -1, false, vim.split(json, "\n"))
			vim.api.nvim_set_current_buf(json_buf)
		end)

		after_each(function()
			if json_buf and vim.api.nvim_buf_is_valid(json_buf) then
				vim.api.nvim_buf_delete(json_buf, { force = true })
			end
			require("haunt.persistence").set_data_dir(nil)
			helpers.cleanup_temp_dir(data_dir)
		end)

		it("imports from the current buffer via %", function()
			vim.cmd("HauntCollectionImport review %")

			assert.is_true(collections.exists("review"))
			assert.are.equal("review", collections.get_active())
			assert.are.equal("a finding", require("haunt.api").get_bookmarks()[1].note)
		end)

		it("defaults to the current buffer when no source is given", function()
			vim.cmd("HauntCollectionImport review")
			assert.is_true(collections.exists("review"))
		end)

		it("imports from a file path", function()
			local path = vim.fn.tempname() .. ".json"
			vim.fn.writefile({ vim.json.encode({ { file = "/tmp/b.lua", line = 1, summary = "from file" } }) }, path)

			vim.cmd("HauntCollectionImport review " .. path)

			assert.are.equal("from file", require("haunt.api").get_bookmarks()[1].note)
			vim.fn.delete(path)
		end)

		it("does not throw without arguments", function()
			local ok = pcall(vim.cmd, "HauntCollectionImport")
			-- nargs="+" makes Neovim itself reject the empty form
			assert.is_false(ok)
		end)
	end)

	describe("HauntQf", function()
		local bufnr1, test_file1, bufnr2, test_file2
		local original_input

		before_each(function()
			original_input = vim.fn.input
			vim.fn.input = function()
				return "Test annotation"
			end

			bufnr1, test_file1 = helpers.create_test_buffer({ "File1 Line 1", "File1 Line 2" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")

			bufnr2, test_file2 = helpers.create_test_buffer({ "File2 Line 1" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
		end)

		after_each(function()
			vim.fn.input = original_input
			vim.cmd("cclose")
			helpers.cleanup_buffer(bufnr1, test_file1)
			helpers.cleanup_buffer(bufnr2, test_file2)
		end)

		it("populates quickfix with current buffer bookmarks only", function()
			vim.api.nvim_set_current_buf(bufnr2)

			vim.cmd("HauntQf")

			local qf_list = vim.fn.getqflist()
			assert.are.equal(1, #qf_list)
			assert.are.equal(bufnr2, qf_list[1].bufnr)
		end)

		it("toggles quickfix window open", function()
			vim.cmd("cclose")
			assert.is_false(helpers.is_quickfix_open())

			vim.cmd("HauntQf")

			assert.is_true(helpers.is_quickfix_open())
		end)
	end)

	describe("HauntMigrate", function()
		local project_mock = require("tests.helpers.project_mock")
		local original_notify
		local notify_calls

		before_each(function()
			notify_calls = {}
			original_notify = vim.notify
			vim.notify = function(msg, level)
				table.insert(notify_calls, { msg = msg, level = level })
			end

			-- Inject "not in a git repo" project info.
			project_mock.set({ root = nil, branch = nil, project_id = vim.fn.getcwd() })
		end)

		after_each(function()
			vim.notify = original_notify
			project_mock.restore()
		end)

		it("is registered as a user command", function()
			assert.are.equal(2, vim.fn.exists(":HauntMigrate"))
		end)

		it("does not crash when invoked outside a git repo", function()
			local ok, err = pcall(vim.cmd, "HauntMigrate")
			assert.is_true(ok, "HauntMigrate raised an error: " .. tostring(err))
		end)

		it("emits a warning notify when invoked outside a git repo", function()
			pcall(vim.cmd, "HauntMigrate")

			local saw_warn = false
			for _, call in ipairs(notify_calls) do
				if call.level == vim.log.levels.WARN and type(call.msg) == "string" and call.msg:match("not in a git repo") then
					saw_warn = true
					break
				end
			end
			assert.is_true(saw_warn, "expected a WARN notify mentioning 'not in a git repo'")
		end)
	end)

	describe("HauntReload", function()
		it("invokes api.reload()", function()
			local original_reload = api.reload
			local call_count = 0
			api.reload = function()
				call_count = call_count + 1
				return true
			end

			local ok, err = pcall(vim.cmd, "HauntReload")

			api.reload = original_reload

			assert.is_true(ok, "HauntReload raised an error: " .. tostring(err))
			assert.are.equal(1, call_count)
		end)
	end)

	describe("HauntQfAll", function()
		local bufnr1, test_file1, bufnr2, test_file2
		local original_input

		before_each(function()
			original_input = vim.fn.input
			vim.fn.input = function()
				return "Test annotation"
			end

			bufnr1, test_file1 = helpers.create_test_buffer({ "File1 Line 1", "File1 Line 2" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")

			bufnr2, test_file2 = helpers.create_test_buffer({ "File2 Line 1" })
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("HauntAnnotate")
		end)

		after_each(function()
			vim.fn.input = original_input
			vim.cmd("cclose")
			helpers.cleanup_buffer(bufnr1, test_file1)
			helpers.cleanup_buffer(bufnr2, test_file2)
		end)

		it("populates quickfix with all bookmarks", function()
			vim.cmd("HauntQfAll")

			local qf_list = vim.fn.getqflist()
			assert.are.equal(2, #qf_list)
		end)

		it("toggles quickfix window open", function()
			vim.cmd("cclose")
			assert.is_false(helpers.is_quickfix_open())

			vim.cmd("HauntQfAll")

			assert.is_true(helpers.is_quickfix_open())
		end)
	end)
end)

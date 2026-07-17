---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.picker.fallback", function()
	local fallback
	local api
	local haunt

	-- Mock vim functions
	local original_notify
	local original_ui_select
	local notifications
	local ui_select_calls

	before_each(function()
		helpers.reset_modules()
		notifications = {}
		ui_select_calls = {}

		-- Mock vim.notify to capture notifications
		original_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end

		-- Mock vim.ui.select to capture calls
		original_ui_select = vim.ui.select
		vim.ui.select = function(items, opts, on_choice)
			table.insert(ui_select_calls, { items = items, opts = opts, on_choice = on_choice })
		end

		-- Initialize modules
		haunt = require("haunt")
		haunt.setup()
		api = require("haunt.api")
		api._reset_for_testing()
		fallback = require("haunt.picker.fallback")
	end)

	after_each(function()
		vim.notify = original_notify
		vim.ui.select = original_ui_select
	end)

	describe("show()", function()
		local bufnr, test_file

		before_each(function()
			bufnr, test_file = helpers.create_test_buffer()
		end)

		after_each(function()
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("returns true (always available)", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test")

			local result = fallback.show()
			assert.is_true(result)
		end)

		it("notifies when no bookmarks exist", function()
			fallback.show()

			assert.are.equal(1, #notifications)
			assert.is_truthy(notifications[1].msg:match("No bookmarks found"))
			assert.are.equal(vim.log.levels.INFO, notifications[1].level)
		end)

		it("calls vim.ui.select when bookmarks exist", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test bookmark")

			fallback.show()

			assert.are.equal(1, #ui_select_calls)
			assert.are.equal(1, #ui_select_calls[1].items)
		end)

		it("passes correct prompt to vim.ui.select", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test")

			fallback.show()

			assert.are.equal("Hauntings", ui_select_calls[1].opts.prompt)
		end)

		it("provides format_item function", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test note")

			fallback.show()

			local format_item = ui_select_calls[1].opts.format_item
			assert.is_not_nil(format_item)

			local item = ui_select_calls[1].items[1]
			local formatted = format_item(item)
			assert.is_truthy(formatted:match("Test note"))
		end)

		it("handles multiple bookmarks", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("First")
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			api.annotate("Second")
			vim.api.nvim_win_set_cursor(0, { 3, 0 })
			api.annotate("Third")

			fallback.show()

			assert.are.equal(1, #ui_select_calls)
			assert.are.equal(3, #ui_select_calls[1].items)
		end)

		it("jumps to bookmark when item is selected", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test")

			fallback.show()

			-- Simulate user selecting the first item
			local on_choice = ui_select_calls[1].on_choice
			local item = ui_select_calls[1].items[1]

			-- Move cursor away first
			vim.api.nvim_win_set_cursor(0, { 3, 0 })

			on_choice(item)

			local cursor = vim.api.nvim_win_get_cursor(0)
			assert.are.equal(1, cursor[1])
		end)

		it("handles nil choice gracefully", function()
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("Test")

			fallback.show()

			-- Simulate user cancelling
			local on_choice = ui_select_calls[1].on_choice
			local ok = pcall(on_choice, nil)
			assert.is_true(ok)
		end)
	end)

	describe("show_collections()", function()
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

		it("returns true (always available)", function()
			assert.is_true(fallback.show_collections())
		end)

		it("lists the default collection even with no registry", function()
			fallback.show_collections()

			assert.are.equal(1, #ui_select_calls)
			local items = ui_select_calls[1].items
			assert.are.equal(1, #items)
			assert.are.equal("default", items[1].name)
		end)

		it("marks the active collection", function()
			collections.create("review")
			collections.set_active("review")

			fallback.show_collections()

			local items = ui_select_calls[1].items
			local by_name = {}
			for _, item in ipairs(items) do
				by_name[item.name] = item
			end

			assert.is_true(by_name["review"].active)
			assert.is_false(by_name["default"].active)
			assert.is_truthy(by_name["review"].label:match("●"))
		end)

		it("switches to the chosen collection", function()
			collections.create("review")
			assert.are.equal("default", collections.get_active())

			fallback.show_collections()

			local call = ui_select_calls[1]
			local chosen
			for _, item in ipairs(call.items) do
				if item.name == "review" then
					chosen = item
				end
			end

			call.on_choice(chosen)

			assert.are.equal("review", collections.get_active())
		end)

		it("handles nil choice gracefully", function()
			fallback.show_collections()

			local ok = pcall(ui_select_calls[1].on_choice, nil)
			assert.is_true(ok)
			assert.are.equal("default", collections.get_active())
		end)
	end)
end)

---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.picker.telescope", function()
	local telescope_picker
	local api
	local haunt

	-- Mock vim functions
	local original_notify
	local notifications

	before_each(function()
		helpers.reset_modules()
		package.loaded["telescope"] = nil
		notifications = {}

		-- Mock vim.notify to capture notifications
		original_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end

		-- Initialize modules
		haunt = require("haunt")
		haunt.setup()
		api = require("haunt.api")
		api._reset_for_testing()
		telescope_picker = require("haunt.picker.telescope")
	end)

	after_each(function()
		vim.notify = original_notify
		package.loaded["telescope"] = nil
	end)

	describe("is_available()", function()
		it("returns false when Telescope is not installed", function()
			assert.is_false(telescope_picker.is_available())
		end)

		-- Note: Testing with real Telescope would require installing it
		-- These tests focus on the unavailable case
	end)

	describe("show()", function()
		local bufnr, test_file

		before_each(function()
			bufnr, test_file = helpers.create_test_buffer()
		end)

		after_each(function()
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("returns false when Telescope is not available", function()
			local result = telescope_picker.show()
			assert.is_false(result)
		end)

		it("does not notify when Telescope is not available", function()
			-- The show() function just returns false, doesn't notify
			-- Notification is handled by the parent picker module
			telescope_picker.show()
			assert.are.equal(0, #notifications)
		end)
	end)

	describe("set_picker_module()", function()
		it("accepts a module reference without error", function()
			local ok = pcall(telescope_picker.set_picker_module, { show = function() end })
			assert.is_true(ok)
		end)
	end)

	describe("show_collections()", function()
		local data_dir
		local collections
		local mock
		local original_confirm, original_input

		--- Stand up just enough of Telescope's module graph to drive
		--- show_collections: pickers.new(...):find(), finders.new_table,
		--- config.values.generic_sorter, actions.select_default:replace, and
		--- actions.state. Captures the picker config, the mapped keys, and any
		--- finder handed to current_picker:refresh().
		local function install_mock_telescope()
			local m = {
				picker_config = nil,
				found = false,
				mapped = {},
				refreshed_with = nil,
				closed = false,
				selected = nil,
			}

			m.current_picker = {
				refresh = function(_, finder)
					m.refreshed_with = finder
				end,
			}

			package.loaded["telescope"] = {}
			package.loaded["telescope.pickers"] = {
				new = function(_, config)
					m.picker_config = config
					return {
						find = function()
							m.found = true
							-- Telescope calls attach_mappings with the prompt bufnr
							-- and a mapper; run it so the spec can drive the actions.
							if config.attach_mappings then
								config.attach_mappings(1, function(mode, key, fn)
									m.mapped[key] = { mode = mode, fn = fn }
								end)
							end
						end,
					}
				end,
			}
			package.loaded["telescope.finders"] = {
				new_table = function(opts)
					return { _results = opts.results, _entry_maker = opts.entry_maker }
				end,
			}
			package.loaded["telescope.config"] = {
				values = {
					generic_sorter = function()
						return "sorter"
					end,
					grep_previewer = function()
						return "previewer"
					end,
				},
			}
			package.loaded["telescope.actions"] = {
				close = function()
					m.closed = true
				end,
				select_default = {
					replace = function(_, fn)
						m.select_default = fn
					end,
				},
			}
			package.loaded["telescope.actions.state"] = {
				get_selected_entry = function()
					return m.selected
				end,
				get_current_picker = function()
					return m.current_picker
				end,
			}
			package.loaded["telescope.previewers"] = {
				new_buffer_previewer = function(cfg)
					m.previewer = cfg
					return cfg
				end,
			}

			return m
		end

		before_each(function()
			data_dir = helpers.create_temp_data_dir()
			require("haunt.persistence").set_data_dir(data_dir)
			collections = require("haunt.collections")
			collections.invalidate()

			original_confirm = vim.fn.confirm
			vim.fn.confirm = function()
				return 1
			end
			original_input = vim.fn.input

			mock = install_mock_telescope()
			telescope_picker = require("haunt.picker.telescope")
		end)

		after_each(function()
			vim.fn.confirm = original_confirm
			vim.fn.input = original_input
			for _, name in ipairs({
				"telescope",
				"telescope.pickers",
				"telescope.finders",
				"telescope.config",
				"telescope.actions",
				"telescope.actions.state",
				"telescope.previewers",
			}) do
				package.loaded[name] = nil
			end
			require("haunt.persistence").set_data_dir(nil)
			helpers.cleanup_temp_dir(data_dir)
		end)

		--- Resolve a collection into the entry shape Telescope hands to actions.
		---@param name string
		---@return table
		local function entry_for(name)
			for _, item in ipairs(mock.picker_config.finder._results) do
				if item.name == name then
					return { value = item }
				end
			end
			error("no such collection in finder results: " .. name)
		end

		it("returns false when Telescope is not available", function()
			package.loaded["telescope.pickers"] = nil
			assert.is_false(telescope_picker.show_collections())
		end)

		it("opens a picker titled Collections", function()
			assert.is_true(telescope_picker.show_collections())
			assert.is_true(mock.found)
			assert.are.equal("Collections", mock.picker_config.prompt_title)
		end)

		it("lists the default collection with no registry", function()
			telescope_picker.show_collections()
			local results = mock.picker_config.finder._results
			assert.are.equal(1, #results)
			assert.are.equal("default", results[1].name)
		end)

		it("builds entries with the name as ordinal", function()
			collections.create("review")
			telescope_picker.show_collections()

			local maker = mock.picker_config.finder._entry_maker
			local entry = maker(mock.picker_config.finder._results[2])
			assert.are.equal("review", entry.ordinal)
			assert.is_truthy(entry.display:match("review$"))
		end)

		it("switches on select and closes the picker", function()
			collections.create("review")
			telescope_picker.show_collections()

			mock.selected = entry_for("review")
			mock.select_default()

			assert.is_true(mock.closed)
			assert.are.equal("review", collections.get_active())
		end)

		it("handles select with no entry", function()
			telescope_picker.show_collections()
			mock.selected = nil
			assert.is_true(pcall(mock.select_default))
		end)

		-- The bookmark picker's grep previewer expects a file, which collection
		-- entries have none of; preview their bookmarks instead.
		it("previews the collection's bookmarks", function()
			local bufnr, test_file = helpers.create_test_buffer()

			api.create_collection("review")
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			api.annotate("review note")
			api.switch_collection("default")

			telescope_picker.show_collections()
			assert.is_not_nil(mock.previewer, "no previewer was configured")

			local preview_buf = vim.api.nvim_create_buf(false, true)
			mock.previewer.define_preview({ state = { bufnr = preview_buf } }, entry_for("review"))

			local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
			assert.are.equal(1, #lines)
			assert.is_truthy(lines[1]:match("review note"))

			vim.api.nvim_buf_delete(preview_buf, { force = true })
			helpers.cleanup_buffer(bufnr, test_file)
		end)

		it("previews an empty collection", function()
			collections.create("empty-one")
			telescope_picker.show_collections()

			local preview_buf = vim.api.nvim_create_buf(false, true)
			mock.previewer.define_preview({ state = { bufnr = preview_buf } }, entry_for("empty-one"))

			local lines = vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false)
			assert.is_truthy(lines[1]:match("No bookmarks"))

			vim.api.nvim_buf_delete(preview_buf, { force = true })
		end)

		it("maps the configured create and delete keys", function()
			telescope_picker.show_collections()
			assert.is_not_nil(mock.mapped["n"])
			assert.is_not_nil(mock.mapped["d"])
		end)

		it("deletes a collection and refreshes with a rebuilt finder", function()
			collections.create("review")
			telescope_picker.show_collections()

			mock.selected = entry_for("review")
			mock.mapped["d"].fn(1)

			assert.is_false(collections.exists("review"))
			assert.is_not_nil(mock.refreshed_with, "picker was not refreshed after delete")
			-- The rebuilt finder must reflect the deletion, not the stale list.
			assert.are.equal(1, #mock.refreshed_with._results)
			assert.are.equal("default", mock.refreshed_with._results[1].name)
		end)

		-- The guard lives in the api; the backend just declines to refresh.
		it("does not delete the default collection", function()
			telescope_picker.show_collections()

			mock.selected = entry_for("default")
			mock.mapped["d"].fn(1)

			assert.is_true(collections.exists("default"))
			assert.is_nil(mock.refreshed_with)
		end)

		it("handles delete with no entry", function()
			telescope_picker.show_collections()
			mock.selected = nil
			assert.is_true(pcall(mock.mapped["d"].fn, 1))
		end)

		it("creates a collection via the mapped key", function()
			vim.fn.input = function()
				return "fresh"
			end

			telescope_picker.show_collections()
			mock.mapped["n"].fn(1)

			assert.is_true(collections.exists("fresh"))
		end)
	end)
end)

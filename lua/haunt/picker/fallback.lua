---@toc_entry Picker Fallback
---@tag haunt-picker-fallback
---@text
--- # Picker Fallback ~
---
--- Fallback picker implementation using vim.ui.select.
--- Used when neither Snacks.nvim nor Telescope.nvim is available.
---
--- This picker provides basic functionality:
---   - `<CR>`: Jump to the selected bookmark
---
--- Note: Delete and edit annotation actions are not available in the fallback picker.
--- The collections picker is likewise selection-only here; use
--- `:HauntCollectionNew` and `:HauntCollectionDelete` instead.

---@type PickerModule
---@diagnostic disable-next-line: missing-fields
local M = {}

local utils = require("haunt.picker.utils")

--- Check if the fallback picker is available
--- Always returns true since vim.ui.select is built into Neovim
---@return boolean available Always true
function M.is_available()
	return true
end

--- Set the parent picker module reference
--- No-op for fallback since it doesn't support delete/edit actions that need reopening
---@param _ PickerRouter The parent picker module (unused)
function M.set_picker_module(_)
	-- No-op: fallback doesn't support actions that need reopening
end

--- Show the fallback picker using vim.ui.select
---@param _opts? table Options (unused, for interface compliance)
---@return boolean success Always returns true
function M.show(_opts)
	local api = utils.get_api()

	local bookmarks = api.get_bookmarks()
	if #bookmarks == 0 then
		vim.notify("haunt.nvim: No bookmarks found", vim.log.levels.INFO)
		return true
	end

	vim.ui.select(utils.build_picker_items(bookmarks), {
		prompt = "Hauntings",
		format_item = function(item)
			return item.text
		end,
	}, function(choice)
		if not choice then
			return
		end
		utils.jump_to_bookmark(choice)
	end)

	return true
end

--- Show the collections picker using vim.ui.select
--- Selection only: create and delete are available via the user commands.
---@param _opts? table Options (unused, for interface compliance)
---@return boolean success Always returns true
function M.show_collections(_opts)
	local api = utils.get_api()
	local collections = require("haunt.collections")

	local items = utils.build_collection_items(collections.list(), collections.get_active())

	vim.ui.select(items, {
		prompt = "Collections",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			return
		end
		api.switch_collection(choice.name)
	end)

	return true
end

return M

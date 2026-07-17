---@toc_entry Picker fzf-lua
---@tag haunt-picker-fzf
---@text
--- # Picker fzf-lua ~
---
--- fzf-lua picker implementation for haunt.nvim.
--- Requires fzf-lua (https://github.com/ibhagwan/fzf-lua) to be installed.
---
--- Picker actions: ~
---   - `<CR>`: Jump to the selected bookmark
---   - `d` (normal mode): Delete the selected bookmark
---   - `a` (normal mode): Edit the bookmark's annotation
---
--- The keybindings can be customized via |HauntConfig|.picker_keys.

---@type PickerModule
---@diagnostic disable-next-line: missing-fields
local M = {}

local utils = require("haunt.picker.utils")

---@private
---@type PickerRouter|nil
local picker_module = nil

--- Set the parent picker module reference for reopening after edit
---@param module PickerRouter The parent picker module
function M.set_picker_module(module)
	picker_module = module
end

--- Check if fzf-lua is available
---@return boolean available True if fzf-lua is installed
function M.is_available()
	local ok, _ = pcall(require, "fzf-lua")
	return ok
end

---@private
---@param item PickerItem The selected bookmark item
---@param reopen_fn fun() Function to reopen the picker after deletion
local function handle_delete(item, reopen_fn)
	local api = utils.get_api()

	if not item then
		return
	end

	local success = api.delete_by_id(item.id)

	if not success then
		vim.notify("haunt.nvim: Failed to delete bookmark", vim.log.levels.WARN)
		return
	end

	local remaining = api.get_bookmarks()
	if #remaining == 0 then
		vim.notify("haunt.nvim: No bookmarks remaining", vim.log.levels.INFO)
		return
	end

	reopen_fn()
end

---@private
---@param item PickerItem The selected bookmark item
local function handle_edit_annotation(item)
	utils.handle_edit_annotation({
		item = item,
		close_picker = function()
			-- fzf-lua closes automatically when an action is triggered
		end,
		reopen_picker = function()
			if picker_module then
				picker_module.show()
			end
		end,
	})
end

--- Show the fzf-lua picker
---@param opts? table Options to pass to fzf-lua (see fzf-lua documentation)
---@return boolean success True if picker was shown
function M.show(opts)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		return false
	end

	local api = utils.get_api()
	local haunt = utils.get_haunt()

	local bookmarks = api.get_bookmarks()
	if #bookmarks == 0 then
		vim.notify("haunt.nvim: No bookmarks found", vim.log.levels.INFO)
		return true
	end

	local cfg = haunt.get_config()
	local picker_keys = cfg.picker_keys

	local items = utils.build_picker_items(bookmarks)

	-- Build display list and lookup table
	local display_list = {}
	local lookup = {}

	for _, item in ipairs(items) do
		local label = string.format("%s:%d:%d", item.file, item.line, item.pos[2] or 0)
		if item.note and item.note ~= "" then
			label = label .. " " .. item.note
		end
		table.insert(display_list, label)
		lookup[label] = item
	end

	-- Build actions table with configurable keybindings
	local actions = {}

	-- Default action: jump to bookmark
	actions["default"] = function(selected)
		if not selected or #selected == 0 then
			return
		end
		local entry = selected[1]
		local item = lookup[entry]
		if item then
			utils.jump_to_bookmark(item)
		end
	end

	-- Delete action
	if picker_keys.delete then
		local key = picker_keys.delete.key or "d"
		actions[key] = function(selected)
			if not selected or #selected == 0 then
				return
			end
			local entry = selected[1]
			local item = lookup[entry]
			if item then
				handle_delete(item, function()
					M.show(opts)
				end)
			end
		end
	end

	-- Edit annotation action
	if picker_keys.edit_annotation then
		local key = picker_keys.edit_annotation.key or "a"
		actions[key] = function(selected)
			if not selected or #selected == 0 then
				return
			end
			local entry = selected[1]
			local item = lookup[entry]
			if item then
				handle_edit_annotation(item)
			end
		end
	end

	local fzf_opts = {
		prompt = "Hauntings> ",
		previewer = "builtin",
		actions = actions,
	}
	fzf_opts = vim.tbl_deep_extend("force", fzf_opts, opts or {})

	fzf.fzf_exec(display_list, fzf_opts)
	return true
end

--- Show the fzf-lua collections picker
---@param opts? table Options to pass to fzf-lua
---@return boolean success True if picker was shown
function M.show_collections(opts)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		return false
	end

	local api = utils.get_api()
	local haunt = utils.get_haunt()
	local collections = require("haunt.collections")

	local cfg = haunt.get_config()
	local picker_keys = cfg.picker_keys or {}

	local items = utils.build_collection_items(collections.list(), collections.get_active())

	-- Build display list and lookup table. Labels are unique because
	-- collection names are unique within a project.
	local display_list = {}
	local lookup = {}

	for _, item in ipairs(items) do
		table.insert(display_list, item.label)
		lookup[item.label] = item
	end

	local actions = {}

	-- Default action: switch to the selected collection
	actions["default"] = function(selected)
		if not selected or #selected == 0 then
			return
		end
		local item = lookup[selected[1]]
		if item then
			api.switch_collection(item.name)
		end
	end

	if picker_keys.new_collection then
		local key = picker_keys.new_collection.key or "n"
		actions[key] = function()
			utils.handle_new_collection({
				close_picker = function() end,
				reopen_picker = function()
					M.show_collections(opts)
				end,
			})
		end
	end

	if picker_keys.delete_collection then
		local key = picker_keys.delete_collection.key or "d"
		actions[key] = function(selected)
			if not selected or #selected == 0 then
				return
			end
			local item = lookup[selected[1]]
			if not item then
				return
			end
			-- The api notifies and returns false for the default collection.
			if api.delete_collection(item.name) then
				M.show_collections(opts)
			end
		end
	end

	local fzf_opts = {
		prompt = "Collections> ",
		actions = actions,
	}
	fzf_opts = vim.tbl_deep_extend("force", fzf_opts, opts or {})

	fzf.fzf_exec(display_list, fzf_opts)
	return true
end

return M

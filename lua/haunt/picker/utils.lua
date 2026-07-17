---@toc_entry Picker Utilities
---@tag haunt-picker-utils
---@text
--- # Picker Utilities ~
---
--- Shared utilities for all picker implementations.
--- This module provides common functions used by Snacks, Telescope, and fallback pickers.

---@class PickerUtils
---@field ensure_modules fun()
---@field get_api fun(): ApiModule
---@field get_haunt fun(): HauntModule
---@field with_buffer_context fun(bufnr: number, line: number, callback: function): any
---@field build_picker_items fun(bookmarks: Bookmark[]): PickerItem[]
---@field jump_to_bookmark fun(item: PickerItem)
---@field handle_edit_annotation fun(ctx: EditAnnotationContext)

---@type PickerUtils
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
---@type ApiModule|nil
local api = nil
---@private
---@type HauntModule|nil
local haunt = nil

---@private
function M.ensure_modules()
	if not api then
		api = require("haunt.api")
	end
	if not haunt then
		haunt = require("haunt")
	end
end

--- Get the API module
---@return ApiModule
function M.get_api()
	M.ensure_modules()
	---@cast api -nil
	return api
end

--- Get the haunt module
---@return HauntModule
function M.get_haunt()
	M.ensure_modules()
	---@cast haunt -nil
	return haunt
end

--- Execute a callback with buffer context temporarily switched
--- Switches to the target buffer, sets cursor position, executes callback, then safely restores
--- Uses pcall and validation to prevent errors when restoring picker buffer state
---@param bufnr number Target buffer number
---@param line number Line number to set cursor to
---@param callback function Function to execute in the target buffer context
---@return any The return value of the callback
function M.with_buffer_context(bufnr, line, callback)
	-- Save current buffer and window
	local current_bufnr = vim.api.nvim_get_current_buf()
	local current_win = vim.api.nvim_get_current_win()
	local cursor_saved = vim.api.nvim_win_get_cursor(current_win)

	-- Ensure target buffer is loaded
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		vim.fn.bufload(bufnr)
	end

	-- Switch to target buffer
	vim.api.nvim_set_current_buf(bufnr)

	-- Move cursor to the bookmark line (with validation)
	-- Clamp line to valid range to avoid "Cursor position outside buffer" error
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local safe_line = math.min(math.max(1, line), line_count)
	pcall(vim.api.nvim_win_set_cursor, current_win, { safe_line, 0 })

	-- Execute the callback
	local result = callback()

	-- Safely restore original buffer with validation
	-- The picker buffer might not be in a valid state to restore, so use pcall
	if vim.api.nvim_buf_is_valid(current_bufnr) and vim.api.nvim_buf_is_loaded(current_bufnr) then
		-- Attempt to restore buffer - use pcall to handle any state errors
		pcall(vim.api.nvim_set_current_buf, current_bufnr)

		-- Only restore cursor if we successfully switched back to the original buffer
		if vim.api.nvim_get_current_buf() == current_bufnr then
			pcall(vim.api.nvim_win_set_cursor, current_win, cursor_saved)
		end
	end

	return result
end

--- Build picker items from bookmarks
---@param bookmarks Bookmark[]
---@return PickerItem[]
function M.build_picker_items(bookmarks)
	local items = {}
	for i, bm in ipairs(bookmarks) do
		local relpath = vim.fn.fnamemodify(bm.file, ":.")
		local filename = vim.fn.fnamemodify(bm.file, ":t")
		local text = relpath .. ":" .. bm.line
		if bm.note and bm.note ~= "" then
			text = text .. " " .. bm.note
		end
		table.insert(items, {
			idx = i,
			score = i,
			file = bm.file,
			relpath = relpath,
			filename = filename,
			pos = { bm.line, 0 },
			text = text,
			note = bm.note,
			id = bm.id,
			line = bm.line,
		})
	end
	return items
end

--- Jump to a bookmark item (shared logic for all pickers)
---@param item PickerItem The selected bookmark item
function M.jump_to_bookmark(item)
	if not item then
		return
	end

	-- Open file
	local bufnr = vim.fn.bufnr(item.file)
	if bufnr == -1 then
		-- File not loaded, open it
		vim.cmd("edit " .. vim.fn.fnameescape(item.file))
	else
		-- File already loaded, switch to it
		vim.cmd("buffer " .. bufnr)
	end

	-- Go to line and center
	vim.api.nvim_win_set_cursor(0, { item.line, 0 })
	vim.cmd("normal! zz")
end

--- Handle editing a bookmark annotation (shared across picker implementations)
---@param ctx EditAnnotationContext
function M.handle_edit_annotation(ctx)
	local api_module = M.get_api()
	local item = ctx.item

	if not item then
		return
	end

	local default_text = item.note or ""

	-- Close picker temporarily to show input prompt clearly
	ctx.close_picker()

	local annotation = vim.fn.input({
		prompt = "Annotation: ",
		default = default_text,
	})

	-- If user cancelled (ESC) with no existing annotation, reopen picker
	if annotation == "" and default_text == "" then
		ctx.reopen_picker()
		return
	end

	-- Open the file in a buffer if not already open
	local bufnr = vim.fn.bufnr(item.file)
	if bufnr == -1 then
		bufnr = vim.fn.bufadd(item.file)
		vim.fn.bufload(bufnr)
	end

	-- Execute annotate in the buffer context
	M.with_buffer_context(bufnr, item.line, function()
		api_module.annotate(annotation)
	end)

	-- Reopen the picker with updated data
	ctx.reopen_picker()
end

--- Build display items for the collections picker (shared across implementations)
---@param names string[] Collection names
---@param active string The active collection name
---@return CollectionItem[] items
function M.build_collection_items(names, active)
	local items = {}

	for idx, name in ipairs(names) do
		local is_active = name == active
		table.insert(items, {
			idx = idx,
			score = idx,
			name = name,
			active = is_active,
			text = name,
			label = (is_active and "● " or "  ") .. name,
		})
	end

	return items
end

--- Read a collection's bookmarks without switching to it.
---
--- The active collection is read from the store so its lines reflect where the
--- bookmarks currently sit (extmarks move with edits, and those positions only
--- reach disk on the next save). Every other collection is read straight from
--- its storage file.
---@param name string Collection name
---@param active boolean Whether this is the active collection
---@return Bookmark[]|nil bookmarks nil when the collection's file could not be read
function M.read_collection_bookmarks(name, active)
	if active then
		return M.get_api().get_bookmarks()
	end

	local persistence = require("haunt.persistence")
	local path = persistence.get_storage_path({ collection = name })

	-- An empty collection has no file at all (an empty save deletes it), which
	-- is a legitimately empty collection rather than a read failure.
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end

	return persistence.load_bookmarks(path)
end

--- Build the preview lines for a collection: the bookmarks it holds.
---@param name string Collection name
---@param active boolean Whether this is the active collection
---@return string[] lines
function M.build_collection_preview(name, active)
	local bookmarks = M.read_collection_bookmarks(name, active)

	if not bookmarks then
		return { "Could not read this collection's bookmarks." }
	end

	if #bookmarks == 0 then
		return { "No bookmarks in this collection." }
	end

	local sorted = vim.deepcopy(bookmarks)
	table.sort(sorted, function(a, b)
		if a.file == b.file then
			return a.line < b.line
		end
		return a.file < b.file
	end)

	local lines = {}
	for _, bm in ipairs(sorted) do
		local line = vim.fn.fnamemodify(bm.file, ":.") .. ":" .. bm.line
		if bm.note and bm.note ~= "" then
			line = line .. "  " .. bm.note
		end
		table.insert(lines, line)
	end

	return lines
end

--- Handle creating a new collection (shared across picker implementations)
---@param ctx NewCollectionContext
function M.handle_new_collection(ctx)
	local api_module = M.get_api()

	-- Close picker temporarily to show input prompt clearly
	ctx.close_picker()

	local name = vim.fn.input({ prompt = "Collection: " })
	if name == "" then
		ctx.reopen_picker()
		return
	end

	-- create_collection switches to the new collection, so there's nothing to
	-- reopen onto that the user still wants; but reopening shows the new state.
	api_module.create_collection(name)
	ctx.reopen_picker()
end

return M

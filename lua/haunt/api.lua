---@toc_entry API Functions
---@tag haunt-api
---@text
--- # API Functions ~
---
--- All API functions are available through `require('haunt.api')`.
---
--- These functions provide the core functionality for managing bookmarks:
--- creating, navigating, annotating, and deleting bookmarks.

---@class ApiModule
---@field toggle_annotation fun(): boolean
---@field toggle_all_lines fun(): boolean
---@field are_annotations_visible fun(): boolean
---@field delete fun(): boolean
---@field get_bookmarks fun(): Bookmark[]
---@field has_bookmarks fun(): boolean
---@field load fun(): boolean
---@field restore_buffer_bookmarks fun(bufnr: number): boolean
---@field save fun(): boolean
---@field annotate fun(text?: string): boolean
---@field clear fun(): boolean
---@field clear_all fun(): boolean
---@field next fun(): boolean
---@field prev fun(): boolean
---@field delete_by_id fun(bookmark_id: string): boolean
---@field to_quickfix fun(opts?: QuickfixOpts): boolean
---@field yank_locations fun(opts?: SidekickOpts): boolean
---@field cleanup_buffer_tracking fun(bufnr: number)
---@field change_data_dir fun(new_dir: string|nil): boolean
---@field switch_collection fun(name: string): boolean
---@field create_collection fun(name?: string, opts?: CreateCollectionOpts): boolean
---@field delete_collection fun(name?: string): boolean
---@field reload fun(reason?: ReloadReason): boolean
---@field refresh_above_annotations fun()
---@field _reset_for_testing fun()

---@private
---@type ApiModule
---@diagnostic disable-next-line: missing-fields
local M = {}

local utils = require("haunt.utils")

---@private
---@type boolean
local _annotations_visible = true

---@private
---@type boolean
local _absolute_notified = false

---@private
---@type StoreModule|nil
local store = nil
---@private
---@type DisplayModule|nil
local display = nil
---@private
---@type PersistenceModule|nil
local persistence = nil
---@private
---@type NavigationModule|nil
local navigation = nil
---@private
---@type RestorationModule|nil
local restoration = nil
---@private
---@type SidekickModule|nil
local sidekick = nil
---@private
---@type HooksModule|nil
local hooks = nil

---@private
local function ensure_modules()
	if not store then
		store = require("haunt.store")
	end
	if not display then
		display = require("haunt.display")
	end
	if not persistence then
		persistence = require("haunt.persistence")
	end
	if not navigation then
		navigation = require("haunt.navigation")
	end
	if not restoration then
		restoration = require("haunt.restoration")
	end
	if not sidekick then
		sidekick = require("haunt.sidekick")
	end
	if not hooks then
		hooks = require("haunt.hooks")
	end
end

--- Clean up all visual elements for a bookmark
--- Removes extmarks, signs, and annotations from the buffer
---@param bufnr number Buffer number
---@param bookmark Bookmark The bookmark whose visuals should be cleaned up
local function cleanup_bookmark_visuals(bufnr, bookmark)
	ensure_modules()
	---@cast display -nil

	-- Delete annotation extmark if it exists
	if bookmark.annotation_extmark_id then
		display.hide_annotation(bufnr, bookmark.annotation_extmark_id)
	end

	if bookmark.extmark_id then
		-- Delete the extmark
		display.delete_bookmark_mark(bufnr, bookmark.extmark_id)

		-- Unplace the sign
		display.unplace_sign(bufnr, bookmark.extmark_id)
	end
end

--- Re-create visual elements for a bookmark whose previous visuals were torn down.
--- Used by delete-path rollback when save fails: the bookmark is being put back
--- into the store, and the user's screen needs the sign/extmark/annotation back.
---@param bufnr number Buffer number
---@param bookmark Bookmark The bookmark to re-render. Its extmark/annotation IDs are reassigned.
local function recreate_bookmark_visuals(bufnr, bookmark)
	ensure_modules()
	---@cast display -nil

	local new_extmark_id = display.set_bookmark_mark(bufnr, bookmark)
	if not new_extmark_id then
		bookmark.extmark_id = nil
		bookmark.annotation_extmark_id = nil
		return
	end
	bookmark.extmark_id = new_extmark_id
	display.place_sign(bufnr, bookmark.line, new_extmark_id)

	if bookmark.note and _annotations_visible then
		bookmark.annotation_extmark_id = display.show_annotation(bufnr, bookmark.line, bookmark.note)
	else
		bookmark.annotation_extmark_id = nil
	end
end

--- Create a bookmark with visual elements and persist it
--- This is a helper function to avoid code duplication between toggle_annotation() and annotate()
---@param bufnr number Buffer number
---@param filepath string Normalized absolute file path
---@param line number 1-based line number
---@param note string|nil Optional annotation text
---@return boolean success True if bookmark was created and persisted successfully
local function create_and_persist_bookmark(bufnr, filepath, line, note)
	ensure_modules()
	---@cast store -nil
	---@cast display -nil
	---@cast persistence -nil
	---@cast hooks -nil

	-- Create bookmark with unique ID
	local new_bookmark, err = persistence.create_bookmark(filepath, line, note)
	if not new_bookmark then
		vim.notify("haunt.nvim: Failed to create bookmark: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return false
	end

	local project_root = require("haunt.project").get_info().root
	if project_root and not utils.is_within_project(filepath, project_root) then
		new_bookmark.absolute = true
		if not _absolute_notified then
			_absolute_notified = true
			vim.notify(
				"haunt.nvim: bookmark is outside project root; stored as absolute path (will not sync across machines)",
				vim.log.levels.INFO
			)
		end
	end

	-- Set extmark for line tracking
	local extmark_id = display.set_bookmark_mark(bufnr, new_bookmark)
	if not extmark_id then
		vim.notify("haunt.nvim: Failed to create extmark", vim.log.levels.ERROR)
		return false
	end

	-- Store extmark_id in bookmark
	new_bookmark.extmark_id = extmark_id

	-- Show annotation as virtual text if note exists
	if note then
		local annotation_extmark_id = display.show_annotation(bufnr, line, note)
		new_bookmark.annotation_extmark_id = annotation_extmark_id
	end

	-- Place sign (using extmark_id as sign_id)
	display.place_sign(bufnr, line, extmark_id)

	-- Add to store
	store.add_bookmark(new_bookmark)

	-- Save to persistence
	local save_ok = store.save()
	if not save_ok then
		-- Rollback: remove from store and clean up all visual elements
		store.remove_bookmark(new_bookmark)

		if new_bookmark.annotation_extmark_id then
			display.hide_annotation(bufnr, new_bookmark.annotation_extmark_id)
		end
		display.delete_bookmark_mark(bufnr, extmark_id)
		display.unplace_sign(bufnr, extmark_id)
		vim.notify("haunt.nvim: Failed to save bookmarks", vim.log.levels.ERROR)
		return false
	end

	hooks.emit_create({
		bookmark = new_bookmark,
		bufnr = bufnr,
		file = filepath,
		line = line,
	})

	return true
end

--- Update an existing bookmark's annotation
---@param bufnr number Buffer number
---@param line number 1-based line number
---@param bookmark Bookmark The bookmark to update
---@param new_note string The new annotation text
---@return boolean success True if bookmark was updated and persisted successfully
local function update_bookmark_annotation(bufnr, line, bookmark, new_note)
	ensure_modules()
	---@cast store -nil
	---@cast display -nil
	---@cast hooks -nil

	local old_note = bookmark.note
	local old_annotation_extmark_id = bookmark.annotation_extmark_id

	-- Hide old annotation if it exists
	if old_annotation_extmark_id then
		display.hide_annotation(bufnr, old_annotation_extmark_id)
	end

	-- Show new annotation and update bookmark
	local new_extmark_id = display.show_annotation(bufnr, line, new_note)
	bookmark.note = new_note
	bookmark.annotation_extmark_id = new_extmark_id

	-- Save to persistence
	local save_ok = store.save()
	if not save_ok then
		-- Rollback
		bookmark.note = old_note
		bookmark.annotation_extmark_id = old_annotation_extmark_id
		if new_extmark_id then
			display.hide_annotation(bufnr, new_extmark_id)
		end

		if old_annotation_extmark_id then
			bookmark.annotation_extmark_id = display.show_annotation(bufnr, line, old_note or "")
		end

		vim.notify("haunt.nvim: Failed to save bookmarks after annotation update", vim.log.levels.ERROR)
		return false
	end

	hooks.emit_update({
		bookmark = bookmark,
		bufnr = bufnr,
		file = bookmark.file,
		line = line,
		old_note = old_note,
		new_note = new_note,
	})

	return true
end

--- Toggle annotation visibility at the current cursor position.
---
--- If a bookmark exists at the current line and has an annotation,
--- this will show/hide the annotation virtual text. If no annotation
--- exists, does nothing.
---
---@return boolean success True if toggled successfully
---
---@usage >lua
---   require('haunt.api').toggle_annotation()
--- <
function M.toggle_annotation()
	ensure_modules()
	---@cast store -nil
	---@cast display -nil
	---@cast hooks -nil

	require("haunt")._ensure_initialized()

	local bufnr = vim.api.nvim_get_current_buf()

	local valid, error_msg = utils.validate_buffer_for_bookmarks(bufnr)
	if not valid then
		vim.notify("haunt.nvim: " .. error_msg, vim.log.levels.WARN)
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1] -- 1-based line number
	local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

	-- Check if a bookmark exists at this line
	local existing_bookmark, _ = store.get_bookmark_at_line(filepath, line)
	if not existing_bookmark then
		vim.notify("haunt.nvim: No bookmark on this line", vim.log.levels.INFO)
		return false
	end

	-- if no note exists do nothing, keep sign col
	if not existing_bookmark.note then
		return true
	end

	-- toggle visibility
	local visible
	if existing_bookmark.annotation_extmark_id then
		display.hide_annotation(bufnr, existing_bookmark.annotation_extmark_id)
		existing_bookmark.annotation_extmark_id = nil
		visible = false
	else
		local extmark_id = display.show_annotation(bufnr, line, existing_bookmark.note)
		existing_bookmark.annotation_extmark_id = extmark_id
		visible = true
	end

	hooks.emit_toggle({
		bookmark = existing_bookmark,
		bufnr = bufnr,
		file = filepath,
		line = line,
		visible = visible,
	})

	return true
end

--- Toggle visibility of ALL annotations across ALL bookmarks.
---
--- This is useful for temporarily hiding all annotations to reduce
--- visual noise, then showing them again.
---
---@return boolean visible The new visibility state (true = visible, false = hidden)
---
---@usage >lua
---   local visible = require('haunt.api').toggle_all_lines()
---   print(visible and "Annotations shown" or "Annotations hidden")
--- <
function M.toggle_all_lines()
	ensure_modules()
	---@cast store -nil
	---@cast display -nil
	---@cast hooks -nil

	_annotations_visible = not _annotations_visible

	local bookmarks = store.get_all_raw()
	local toggled_count = 0
	for _, bookmark in ipairs(bookmarks) do
		if not bookmark.note then
			goto continue
		end

		local bufnr = vim.fn.bufnr(bookmark.file)
		if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
			goto continue
		end

		-- get line from extmark, persistence can become ood
		local current_line = nil
		if bookmark.extmark_id then
			current_line = display.get_extmark_line(bufnr, bookmark.extmark_id)
		end
		if not current_line then -- fallback
			current_line = bookmark.line
		end

		-- if line is gone, move on
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		if current_line < 1 or current_line > line_count then
			goto continue
		end

		-- actual toggling logic
		if _annotations_visible then
			-- Only update annotation if it doesn't exist or is at wrong position
			local needs_update = true
			if bookmark.annotation_extmark_id then
				local annotation_line = display.get_extmark_line(bufnr, bookmark.annotation_extmark_id)
				-- If annotation is already at the correct position, no update needed
				if annotation_line == current_line then
					needs_update = false
				else
					-- Position changed, hide old annotation
					display.hide_annotation(bufnr, bookmark.annotation_extmark_id)
				end
			end

			if needs_update then
				local ok, extmark_id = pcall(display.show_annotation, bufnr, current_line, bookmark.note)
				if ok then
					bookmark.annotation_extmark_id = extmark_id
				end
			end
		else
			if bookmark.annotation_extmark_id then
				display.hide_annotation(bufnr, bookmark.annotation_extmark_id)
				bookmark.annotation_extmark_id = nil
			end
		end

		toggled_count = toggled_count + 1

		::continue::
	end

	hooks.emit_toggle_all({
		visible = _annotations_visible,
		count = toggled_count,
	})

	return _annotations_visible
end

--- Check if annotations are globally visible.
---
---@return boolean visible True if annotations should be displayed
function M.are_annotations_visible()
	return _annotations_visible
end

--- Delete the bookmark at the current cursor position.
---
--- Removes the bookmark from persistence and cleans up all visual elements
--- (sign, extmarks, annotations).
---
---@return boolean success True if bookmark was deleted
---
---@usage >lua
---   require('haunt.api').delete()
--- <
function M.delete()
	ensure_modules()
	---@cast store -nil
	---@cast hooks -nil

	require("haunt")._ensure_initialized()

	local bufnr = vim.api.nvim_get_current_buf()

	local valid, error_msg = utils.validate_buffer_for_bookmarks(bufnr)
	if not valid then
		vim.notify("haunt.nvim: " .. error_msg, vim.log.levels.WARN)
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1] -- 1-based line number
	local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

	-- Check if a bookmark exists at this line
	local existing_bookmark, _ = store.get_bookmark_at_line(filepath, line)
	if not existing_bookmark then
		vim.notify("haunt.nvim: No bookmark on this line", vim.log.levels.INFO)
		return false
	end

	cleanup_bookmark_visuals(bufnr, existing_bookmark)
	store.remove_bookmark(existing_bookmark)

	-- Save to persistence
	local save_ok = store.save()
	if not save_ok then
		-- Rollback: re-add to store and re-render visuals so the user's view
		-- still matches what's on disk. Mirrors create_and_persist_bookmark.
		store.add_bookmark(existing_bookmark)
		recreate_bookmark_visuals(bufnr, existing_bookmark)
		vim.notify("haunt.nvim: Failed to save bookmarks after removal", vim.log.levels.ERROR)
		return false
	end

	hooks.emit_delete({
		bookmark = existing_bookmark,
		bufnr = bufnr,
		file = filepath,
		line = line,
	})

	vim.notify("haunt.nvim: Bookmark deleted", vim.log.levels.INFO)
	return true
end

--- Add or edit an annotation for a bookmark.
---
--- If a bookmark exists at the current line, updates its annotation.
--- If no bookmark exists, creates a new bookmark with the annotation.
--- Empty input cancels the operation.
---
---@param text? string Optional annotation text. If provided, skips the input prompt.
---@return boolean success True if annotation was created/updated
---
---@usage >lua
---   -- Prompt user for annotation
---   require('haunt.api').annotate()
---
---   -- Set annotation programmatically
---   require('haunt.api').annotate("TODO: Fix this bug")
--- <
function M.annotate(text)
	ensure_modules()
	---@cast store -nil

	-- Ensure display layer is initialized
	require("haunt")._ensure_initialized()

	-- Get current buffer and cursor position
	local bufnr = vim.api.nvim_get_current_buf()

	-- Validate buffer can have bookmarks
	local valid, error_msg = utils.validate_buffer_for_bookmarks(bufnr)
	if not valid then
		vim.notify("haunt.nvim: " .. error_msg, vim.log.levels.WARN)
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(0)
	local line = cursor[1] -- 1-based line number

	local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

	local existing_bookmark, _ = store.get_bookmark_at_line(filepath, line)

	-- use param if programmatic call, otherwise prompt user
	local annotation = text
	if not annotation then
		local default_text = existing_bookmark and existing_bookmark.note or ""
		annotation = vim.fn.input({
			prompt = " Annotation: ",
			default = default_text,
		})
	end

	-- no input is a cancel
	if annotation == "" then
		return false
	end

	if existing_bookmark then
		local success = update_bookmark_annotation(bufnr, line, existing_bookmark, annotation)
		if success then
			vim.notify("haunt.nvim: Annotation updated", vim.log.levels.INFO)
		end
		return success
	end

	local success = create_and_persist_bookmark(bufnr, filepath, line, annotation)
	if success then
		vim.notify("haunt.nvim: Annotation created", vim.log.levels.INFO)
	end
	return success
end

--- Clear all bookmarks in the current file.
---
---@return boolean success True if cleared successfully
---
---@usage >lua
---   require('haunt.api').clear()
--- <
function M.clear()
	ensure_modules()
	---@cast store -nil
	---@cast hooks -nil

	local current_file = utils.normalize_filepath(vim.fn.expand("%"))

	if current_file == "" then
		vim.notify("haunt.nvim: No file in current buffer", vim.log.levels.WARN)
		return false
	end

	-- Get bookmarks before clearing for visual cleanup
	local bookmarks = store.get_all_raw()
	local file_bookmarks = {}
	for _, bookmark in ipairs(bookmarks) do
		if bookmark.file == current_file then
			table.insert(file_bookmarks, bookmark)
		end
	end

	-- early return for no bookmarks
	if #file_bookmarks == 0 then
		vim.notify("haunt.nvim: No bookmarks to clear in current file", vim.log.levels.INFO)
		return true
	end

	local bufnr = vim.api.nvim_get_current_buf()

	for _, bookmark in ipairs(file_bookmarks) do
		cleanup_bookmark_visuals(bufnr, bookmark)
	end

	-- Clear from store
	store.clear_file_bookmarks(current_file)

	local save_ok = store.save()

	if save_ok then
		for _, bookmark in ipairs(file_bookmarks) do
			hooks.emit_delete({
				bookmark = bookmark,
				bufnr = bufnr,
				file = bookmark.file,
				line = bookmark.line,
			})
		end
		local count = #file_bookmarks
		hooks.emit_clear({
			bufnr = bufnr,
			file = current_file,
			bookmarks = file_bookmarks,
			count = count,
		})
		vim.notify(string.format("haunt.nvim: Cleared %d bookmark(s) from current file", count), vim.log.levels.INFO)
		return true
	else
		vim.notify("haunt.nvim: Failed to save after clearing bookmarks", vim.log.levels.ERROR)
		return false
	end
end

--- Clear all bookmarks in the project/branch.
---
--- Shows a confirmation prompt before clearing.
---
---@return boolean success True if cleared successfully
---
---@usage >lua
---   require('haunt.api').clear_all()
--- <
function M.clear_all()
	ensure_modules()
	---@cast store -nil
	---@cast hooks -nil

	if not store.has_bookmarks() then
		vim.notify("haunt.nvim: No bookmarks to clear", vim.log.levels.INFO)
		return true
	end

	local choice = vim.fn.confirm("Clear all bookmarks in the CWD?", "&Yes\n&No", 2)

	-- no = 2, cancelled = 0
	if choice ~= 1 then
		vim.notify("haunt.nvim: Clear all cancelled", vim.log.levels.INFO)
		return false
	end

	-- Group bookmarks by file to find corresponding buffers
	local bookmarks = store.get_all_raw()
	--- @type table<string, Bookmark[]>
	local grouped_bookmarks = {}
	for _, bookmark in ipairs(bookmarks) do
		if not grouped_bookmarks[bookmark.file] then
			grouped_bookmarks[bookmark.file] = {}
		end
		table.insert(grouped_bookmarks[bookmark.file], bookmark)
	end

	-- iterate over file -> bookmarks map
	for file_path, file_bookmarks in pairs(grouped_bookmarks) do
		local bufnr = vim.fn.bufnr(file_path)
		if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
			goto continue
		end

		for _, bookmark in ipairs(file_bookmarks) do
			cleanup_bookmark_visuals(bufnr, bookmark)
		end

		::continue::
	end

	-- Get count before clearing
	local count = #bookmarks

	-- Clear all from store
	store.clear_all_bookmarks()

	-- Save empty bookmark list to persistence
	local save_ok = store.save()

	if save_ok then
		for file_path, file_bookmarks in pairs(grouped_bookmarks) do
			local bufnr = vim.fn.bufnr(file_path)
			for _, bookmark in ipairs(file_bookmarks) do
				hooks.emit_delete({
					bookmark = bookmark,
					bufnr = bufnr ~= -1 and bufnr or nil,
					file = bookmark.file,
					line = bookmark.line,
				})
			end
		end
		hooks.emit_clear_all({
			count = count,
			bookmarks = bookmarks,
		})
		vim.notify(string.format("haunt.nvim: Cleared all %d bookmark(s)", count), vim.log.levels.INFO)
		return true
	else
		vim.notify("haunt.nvim: Failed to save after clearing all bookmarks", vim.log.levels.ERROR)
		return false
	end
end

--- Delete a bookmark by its unique ID.
---
--- This is useful for programmatic deletion without needing to navigate
--- to the bookmark (e.g., from the picker).
---
---@param bookmark_id string The unique ID of the bookmark to delete
---@return boolean success True if the bookmark was deleted
---
---@usage >lua
---   local bookmarks = require('haunt.api').get_bookmarks()
---   if #bookmarks > 0 then
---     require('haunt.api').delete_by_id(bookmarks[1].id)
---   end
--- <
function M.delete_by_id(bookmark_id)
	ensure_modules()
	---@cast store -nil
	---@cast hooks -nil

	local bookmark, _ = store.find_by_id(bookmark_id)
	if not bookmark then
		vim.notify("haunt.nvim: Bookmark not found", vim.log.levels.WARN)
		return false
	end

	local bufnr, err = utils.ensure_buffer_for_file(bookmark.file)
	if not bufnr then
		vim.notify("haunt.nvim: " .. (err or "unknown error"), vim.log.levels.ERROR)
		return false
	end

	cleanup_bookmark_visuals(bufnr, bookmark)
	store.remove_bookmark(bookmark)

	local save_ok = store.save()
	if not save_ok then
		store.add_bookmark(bookmark)
		recreate_bookmark_visuals(bufnr, bookmark)
		vim.notify("haunt.nvim: Failed to save bookmarks after deletion", vim.log.levels.ERROR)
		return false
	end

	hooks.emit_delete({
		bookmark = bookmark,
		bufnr = bufnr,
		file = bookmark.file,
		line = bookmark.line,
	})

	return true
end

--- Populate the quickfix list with haunt bookmarks.
---
---@param opts? QuickfixOpts Options for filtering and formatting
---@return boolean success True if the quickfix list was updated
function M.to_quickfix(opts)
	ensure_modules()
	---@cast store -nil

	local items = store.get_quickfix_items(opts)
	if #items == 0 then
		vim.notify("haunt.nvim: No bookmarks to add to quickfix", vim.log.levels.INFO)
		return false
	end

	local title = (opts and opts.current_buffer) and "Haunt (buffer)" or "Haunt"

	vim.fn.setqflist({}, " ", {
		title = title,
		items = items,
	})

	utils.toggle_quickfix()

	return true
end

--- Yank bookmark locations to the system clipboard.
---
--- Copies all bookmarks formatted for sidekick.nvim to the unnamedplus register.
--- Useful for users who want to share bookmark locations without sidekick.nvim.
---
---@param opts? SidekickOpts Options for filtering and formatting
---@return boolean success True if yank was successful
---
---@usage >lua
---   require('haunt.api').yank_locations()
---
---   -- Yank only current buffer bookmarks
---   require('haunt.api').yank_locations({ current_buffer = true })
--- <
function M.yank_locations(opts)
	ensure_modules()
	---@cast sidekick -nil
	opts = opts or {}

	local locations = sidekick.get_locations(opts)

	if locations == "" then
		vim.notify("No bookmarks to yank", vim.log.levels.WARN)
		return false
	end

	vim.fn.setreg("+", locations)

	local count = select(2, locations:gsub("\n", "\n")) + 1
	vim.notify(string.format("Yanked %d bookmark location(s) to clipboard", count), vim.log.levels.INFO)

	return true
end

--- Get all bookmarks as a deep copy.
---
--- Returns all bookmarks currently in memory. The returned table is a
--- deep copy, so modifications won't affect the internal state.
---
---@return Bookmark[] bookmarks Array of all bookmarks
---
---@usage >lua
---   local bookmarks = require('haunt.api').get_bookmarks()
---   for _, bookmark in ipairs(bookmarks) do
---     print(string.format("%s:%d - %s",
---       bookmark.file, bookmark.line, bookmark.note or ""))
---   end
--- <
function M.get_bookmarks()
	ensure_modules()
	---@cast store -nil
	return store.get_bookmarks()
end

--- Check if any bookmarks exist.
---
--- Returns true if there are any bookmarks in memory (after loading from disk).
--- This is more reliable than checking package.loaded state.
---
---@return boolean has_bookmarks True if bookmarks exist, false otherwise
---
---@usage >lua
---   if require('haunt.api').has_bookmarks() then
---     print("Bookmarks found!")
---   end
--- <
function M.has_bookmarks()
	ensure_modules()
	---@cast store -nil
	return store.has_bookmarks()
end

--- Load bookmarks from persistent storage. (Disk)
---
--- This is called automatically when needed. You typically don't need
--- to call this manually unless you want to reload bookmarks from disk.
---
---@return boolean success True if load succeeded
function M.load()
	ensure_modules()
	---@cast store -nil
	return store.load()
end

--- Save bookmarks to persistent storage.
---
--- Bookmarks are auto-saved on text changes (debounced) and Neovim exit,
--- but you can call this manually to force a save.
---
---@return boolean success True if save succeeded
---
---@usage >lua
---   require('haunt.api').save()
--- <
function M.save()
	ensure_modules()
	---@cast store -nil
	return store.save()
end

--- Jump to the next bookmark in the current buffer.
---
--- Wraps around to the first bookmark if at the end.
---
---@return boolean success True if jumped to a bookmark
---
---@usage >lua
---   require('haunt.api').next()
--- <
function M.next()
	ensure_modules()
	---@cast navigation -nil
	return navigation.next()
end

--- Jump to the previous bookmark in the current buffer.
---
--- Wraps around to the last bookmark if at the beginning.
---
---@return boolean success True if jumped to a bookmark
---
---@usage >lua
---   require('haunt.api').prev()
--- <
function M.prev()
	ensure_modules()
	---@cast navigation -nil
	return navigation.prev()
end

--- Restore bookmark visuals for a specific buffer.
---
--- This is called automatically when buffers are opened. You typically
--- don't need to call this manually.
---
---@param bufnr number Buffer number to restore bookmarks for
---@return boolean success True if restoration succeeded or was skipped
function M.restore_buffer_bookmarks(bufnr)
	ensure_modules()
	---@cast restoration -nil
	return restoration.restore_buffer_bookmarks(bufnr, _annotations_visible)
end

--- Clean up restoration tracking for a deleted buffer
--- This prevents memory leaks in the restored_buffers table
---@param bufnr number Buffer number that was deleted
function M.cleanup_buffer_tracking(bufnr)
	ensure_modules()
	---@cast restoration -nil
	restoration.cleanup_buffer_tracking(bufnr)
end

--- Refresh in-memory state from on-disk storage.
---
--- Clears extmarks and signs from all loaded buffers, resets restoration
--- tracking, reloads the store from disk, then restores visuals on all
--- loaded buffers. The on-disk state is treated as the source of truth —
--- this does NOT call store.save() first.
---
--- Used after the storage file has been changed externally (data dir
--- swap, migration, etc.).
---
---@param reason? ReloadReason Why the reload is happening; defaults to "manual" (`:HauntReload`)
---@return boolean success Always true once invoked
function M.reload(reason)
	ensure_modules()
	---@cast store -nil
	---@cast display -nil
	---@cast restoration -nil
	---@cast hooks -nil

	-- Clear visuals from all loaded buffers
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_is_valid(bufnr) then
			display.clear_buffer_marks(bufnr)
			display.clear_buffer_signs(bufnr)
		end
	end

	-- Reset restoration tracking so buffers can be re-restored
	restoration.reset_tracking()

	-- Reset store and reload from new location
	store.reload()

	-- Restore visuals for all loaded buffers
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_is_valid(bufnr) then
			restoration.restore_buffer_bookmarks(bufnr, _annotations_visible)
		end
	end

	-- Re-target the branch watcher: the gitdir may have changed (cross-project
	-- :cd, worktree switch). Within the same repo this is a cheap no-op since
	-- start() short-circuits when already watching the right HEAD path.
	require("haunt.watcher").restart()

	local bookmarks = store.get_all_raw()
	hooks.emit_reload({
		reason = reason or "manual",
		bookmarks = bookmarks,
		count = #bookmarks,
	})

	return true
end

--- Change the data directory and reload all bookmarks.
---
--- Saves current bookmarks to the old data_dir, clears all visual elements,
--- then loads bookmarks from the new location and restores visuals.
--- This is useful for autocommands that need to switch bookmark contexts.
---
---@param new_dir string|nil The new data directory path, or nil to reset to default
---@return boolean success True if the change was successful
---
---@usage >lua
---   -- Switch to a project-specific bookmark directory
---   require('haunt.api').change_data_dir('/path/to/project/.bookmarks/')
---
---   -- Reset to default data directory
---   require('haunt.api').change_data_dir(nil)
--- <
function M.change_data_dir(new_dir)
	ensure_modules()
	---@cast store -nil
	---@cast persistence -nil
	---@cast hooks -nil

	local old_dir = persistence.ensure_data_dir()

	store.save()
	persistence.set_data_dir(new_dir)
	-- The collections registry lives inside the data dir, so its cache is stale
	-- the moment the dir changes; reloading before this would resolve the old
	-- dir's active collection.
	require("haunt.collections").invalidate()
	local ok = M.reload("data_dir_change")

	hooks.emit_data_dir_change({
		new_dir = new_dir,
		old_dir = old_dir,
	})

	return ok
end

--- Prompt for a collection name when one wasn't supplied programmatically.
--- An empty response is a cancel, mirroring `annotate`.
---@param name string|nil
---@param prompt string
---@return string|nil name nil when the user cancelled
local function resolve_collection_name(name, prompt)
	if name ~= nil then
		return name
	end

	local input = vim.fn.input({ prompt = prompt })
	if input == "" then
		return nil
	end
	return input
end

--- Unlink a collection's storage file across every local branch.
---
--- The registry is per-project but storage files are per-branch, so deleting a
--- collection has to remove the file each branch wrote. Filenames are opaque
--- hashes and can't be enumerated from disk, but git can enumerate the branches
--- that produced them. Best-effort: if git is unavailable or per-branch
--- bookmarks are off, fall back to the single resolved path.
---@param collection string
local function delete_collection_files(collection)
	local persistence_mod = require("haunt.persistence")
	local project = require("haunt.project")
	local config = require("haunt.config").get()
	local info = project.get_info()

	if not config.per_branch_bookmarks then
		vim.fn.delete(persistence_mod._storage_path_for(info.project_id, nil, collection, false))
		return
	end

	local branches = project.run_git("git for-each-ref --format=%(refname:short) refs/heads") or {}

	local seen = {}
	---@param branch string|nil nil is a real key (the default-branch key), not a no-op
	local function unlink(branch)
		local key = branch or "\0default"
		if seen[key] then
			return
		end
		seen[key] = true
		-- An empty collection legitimately has no file, so a failed delete
		-- ("not found") is success, not an error worth reporting.
		vim.fn.delete(persistence_mod._storage_path_for(info.project_id, branch, collection, true))
	end

	for _, branch in ipairs(branches) do
		if branch ~= "" then
			unlink(branch)
		end
	end

	-- `refs/heads` never contains a detached HEAD, and when git is unavailable
	-- it yields nothing at all — but the store still wrote a file keyed by
	-- whatever `info.branch` resolved to (nil included). Cover it explicitly, or
	-- the file survives and resurrects when the name is recreated.
	unlink(info.branch)
end

--- Switch the active collection.
---
--- Saves the current collection's bookmarks, then loads the target collection
--- and restores its visuals. The choice persists across sessions until changed.
---
---@param name string The collection to switch to (must already exist)
---@return boolean success True if the switch was successful
---
---@usage >lua
---   require('haunt.api').switch_collection('review')
--- <
function M.switch_collection(name)
	ensure_modules()
	---@cast store -nil
	---@cast hooks -nil

	local collections = require("haunt.collections")

	local valid, err = collections.validate_name(name)
	if not valid then
		vim.notify("haunt.nvim: " .. err, vim.log.levels.WARN)
		return false
	end

	if not collections.exists(valid) then
		vim.notify("haunt.nvim: no such collection: " .. valid, vim.log.levels.WARN)
		return false
	end

	local old_collection = collections.get_active()
	if valid == old_collection then
		return true
	end

	-- Save to the OLD stamped path before the key source changes.
	store.save()

	-- Unlike set_data_dir, this performs I/O and can fail. Reloading after a
	-- failed persist would leave memory showing a collection that disk doesn't
	-- consider active.
	local ok, set_err = collections.set_active(valid)
	if not ok then
		vim.notify("haunt.nvim: " .. set_err, vim.log.levels.ERROR)
		return false
	end

	local reloaded = M.reload("collection_change")

	hooks.emit_collection_change({
		new_collection = valid,
		old_collection = old_collection,
	})

	return reloaded
end

--- Options for `create_collection`.
---@class CreateCollectionOpts
---@field switch? boolean Switch to the new collection after creating it (default: true)

--- Create a bookmark collection.
---
--- Prompts for a name when called without one. Switches to the new collection
--- unless `opts.switch` is false.
---
---@param name? string The collection name; prompts when omitted
---@param opts? CreateCollectionOpts
---@return boolean success True if the collection was created
---
---@usage >lua
---   require('haunt.api').create_collection('review')
---   require('haunt.api').create_collection('review', { switch = false })
--- <
function M.create_collection(name, opts)
	ensure_modules()

	local collections = require("haunt.collections")
	opts = opts or {}

	local requested = resolve_collection_name(name, " Collection: ")
	if requested == nil then
		return false
	end

	local valid, err = collections.validate_name(requested)
	if not valid then
		vim.notify("haunt.nvim: " .. err, vim.log.levels.WARN)
		return false
	end

	local ok, create_err = collections.create(valid)
	if not ok then
		vim.notify("haunt.nvim: " .. create_err, vim.log.levels.WARN)
		return false
	end

	vim.notify("haunt.nvim: created collection: " .. valid, vim.log.levels.INFO)

	if opts.switch == false then
		return true
	end

	return M.switch_collection(valid)
end

--- Delete a bookmark collection and its bookmarks.
---
--- Prompts for a name when called without one, and asks for confirmation. The
--- default collection cannot be deleted. Deleting the active collection falls
--- back to the default collection.
---
---@param name? string The collection to delete; prompts when omitted
---@return boolean success True if the collection was deleted
---
---@usage >lua
---   require('haunt.api').delete_collection('review')
--- <
function M.delete_collection(name)
	ensure_modules()
	---@cast hooks -nil

	local collections = require("haunt.collections")

	local requested = resolve_collection_name(name, " Delete collection: ")
	if requested == nil then
		return false
	end

	local valid, err = collections.validate_name(requested)
	if not valid then
		vim.notify("haunt.nvim: " .. err, vim.log.levels.WARN)
		return false
	end

	if valid == collections.DEFAULT then
		vim.notify("haunt.nvim: cannot delete the default collection", vim.log.levels.WARN)
		return false
	end

	if not collections.exists(valid) then
		vim.notify("haunt.nvim: no such collection: " .. valid, vim.log.levels.WARN)
		return false
	end

	local choice = vim.fn.confirm("Delete collection '" .. valid .. "' and its bookmarks?", "&Yes\n&No", 2)

	-- no = 2, cancelled = 0
	if choice ~= 1 then
		vim.notify("haunt.nvim: Delete cancelled", vim.log.levels.INFO)
		return false
	end

	local was_active = collections.get_active() == valid

	-- Drop the registry entry before unlinking the bookmarks. `collections.delete`
	-- does I/O and can fail; doing it first means a failed write leaves the
	-- collection fully intact rather than listed-but-emptied. Nothing between
	-- here and the unlink can trigger a save (it is all synchronous), and
	-- deliberately no store.save() anywhere in this function — the in-memory
	-- bookmarks belong to the collection being deleted, so saving would recreate
	-- the very file we are about to remove.
	local ok, delete_err = collections.delete(valid)
	if not ok then
		vim.notify("haunt.nvim: " .. delete_err, vim.log.levels.ERROR)
		return false
	end

	delete_collection_files(valid)

	if was_active then
		M.reload("collection_change")
		hooks.emit_collection_change({
			new_collection = collections.DEFAULT,
			old_collection = valid,
		})
	end

	vim.notify("haunt.nvim: deleted collection: " .. valid, vim.log.levels.INFO)
	return true
end

--- Reset internal state for testing purposes only
--- WARNING: This will clear ALL bookmarks from memory without persisting
--- Only use in test environments
---@private
--- Re-render all visible "above" annotations so they adapt to the current
--- window width. Called on resize events.
function M.refresh_above_annotations()
	ensure_modules()
	---@cast store -nil
	---@cast display -nil

	if not _annotations_visible then
		return
	end

	local cfg = require("haunt.config").get()
	if (cfg.virt_text_pos or "eol") ~= "above" then
		return
	end

	local bookmarks = store.get_all_raw()
	for _, bookmark in ipairs(bookmarks) do
		if not bookmark.note or not bookmark.annotation_extmark_id then
			goto continue
		end

		local bufnr = vim.fn.bufnr(bookmark.file)
		if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
			goto continue
		end

		local current_line = nil
		if bookmark.extmark_id then
			current_line = display.get_extmark_line(bufnr, bookmark.extmark_id)
		end
		if not current_line then
			current_line = bookmark.line
		end

		local line_count = vim.api.nvim_buf_line_count(bufnr)
		if current_line < 1 or current_line > line_count then
			goto continue
		end

		display.hide_annotation(bufnr, bookmark.annotation_extmark_id)
		local ok, extmark_id = pcall(display.show_annotation, bufnr, current_line, bookmark.note)
		if ok then
			bookmark.annotation_extmark_id = extmark_id
		else
			bookmark.annotation_extmark_id = nil
		end

		::continue::
	end
end

function M._reset_for_testing()
	ensure_modules()
	---@cast store -nil
	store._reset_for_testing()
	_annotations_visible = true
	_absolute_notified = false
end

return M

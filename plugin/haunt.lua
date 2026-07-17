---@toc_entry Commands
---@tag haunt-commands
---@text
--- # Commands ~
---
--- haunt.nvim provides the following user commands:
---
--- `:HauntToggle` - Toggle bookmark annotation visibility
--- `:HauntAnnotate [text]` - Add or edit annotation for bookmark at cursor
--- `:HauntDelete` - Delete bookmark at current line
--- `:HauntNext` - Jump to next bookmark
--- `:HauntPrev` - Jump to previous bookmark
--- `:HauntList` - Open interactive picker to browse all bookmarks
--- `:HauntClear` - Clear all bookmarks in current buffer
--- `:HauntClearAll` - Clear all bookmarks across all files
--- `:HauntQf` - Send buffer annotations to the quickfix list
--- `:HauntQfAll` - Send all annotations to the quickfix list
--- `:HauntCollections` - Open picker to switch the active bookmark collection
--- `:HauntCollectionNew [name]` - Create a bookmark collection and switch to it
--- `:HauntCollectionDelete [name]` - Delete a bookmark collection and its bookmarks
--- `:HauntCollectionImport {name} [file|%]` - Create a collection from a JSON file or buffer
--- `:HauntChangeDataDir [path]` - Change bookmark data directory (for project-specific bookmarks)
--- `:HauntMigrate` - Migrate bookmarks from v1 to v2 storage (project-relative paths)
--- `:HauntReload` - Reload bookmarks from disk (e.g. after switching branches externally)
---

-- haunt.nvim plugin loader
-- This file is automatically sourced by Neovim when the plugin is installed

-- Prevent loading twice
if vim.g.loaded_haunt == 1 then
	return
end
vim.g.loaded_haunt = 1

---@class HauntCommandInfo
---@field fn string
---@field desc string
---@field has_args? boolean
---@field args? table
---@field complete? fun(): string[]

---@type table<string, HauntCommandInfo>
local commands = {
	HauntToggle = { fn = "toggle_annotation", desc = "Toggle bookmark annotation visibility" },
	HauntAnnotate = { fn = "annotate", desc = "Add/edit annotation", has_args = true },
	HauntClear = { fn = "clear", desc = "Clear bookmarks in current file" },
	HauntClearAll = { fn = "clear_all", desc = "Clear all bookmarks" },
	HauntNext = { fn = "next", desc = "Jump to next bookmark" },
	HauntPrev = { fn = "prev", desc = "Jump to previous bookmark" },
	HauntDelete = { fn = "delete", desc = "Delete bookmark at current line" },
	HauntQf = { fn = "to_quickfix", desc = "Send Buffer Annotations to Quickfix List", args = { current_buffer = true } },
	HauntQfAll = { fn = "to_quickfix", desc = "Send All Annotations to Quickfix List" },
	HauntChangeDataDir = { fn = "change_data_dir", desc = "Change bookmark data directory", has_args = true },
	HauntReload = { fn = "reload", desc = "Reload bookmarks from disk" },
	HauntCollectionNew = { fn = "create_collection", desc = "Create a bookmark collection", has_args = true },
	HauntCollectionDelete = {
		fn = "delete_collection",
		desc = "Delete a bookmark collection",
		has_args = true,
		-- A Lua `complete` has customlist semantics: Neovim does not filter the
		-- returned list against what was typed, so do it here. The default
		-- collection is omitted because the command refuses to delete it.
		complete = function(arg_lead)
			local collections = require("haunt.collections")
			return vim.tbl_filter(function(name)
				return name ~= collections.DEFAULT and vim.startswith(name, arg_lead)
			end, collections.list())
		end,
	},
}

for name, info in pairs(commands) do
	vim.api.nvim_create_user_command(name, function(opts)
		if info.has_args and opts.args ~= "" then
			require("haunt.api")[info.fn](opts.args)
		elseif info.args then
			require("haunt.api")[info.fn](info.args)
		else
			require("haunt.api")[info.fn]()
		end
	end, { desc = info.desc, nargs = info.has_args and "?" or 0, complete = info.complete })
end

-- Special case for HauntList (uses picker)
vim.api.nvim_create_user_command("HauntList", function()
	require("haunt.picker").show()
end, { desc = "List all bookmarks" })

-- Special case for HauntCollections (uses picker)
vim.api.nvim_create_user_command("HauntCollections", function()
	require("haunt.picker").show_collections()
end, { desc = "Switch the active bookmark collection" })

-- Special case for HauntCollectionImport: takes a name plus an optional source,
-- so it can't use the single-argument command loop above.
vim.api.nvim_create_user_command("HauntCollectionImport", function(opts)
	local name, source = opts.fargs[1], opts.fargs[2]
	if not name then
		vim.notify("haunt.nvim: usage: :HauntCollectionImport <name> [file|%]", vim.log.levels.WARN)
		return
	end
	require("haunt.api").import_collection(name, source)
end, {
	desc = "Create a bookmark collection from a JSON file or buffer",
	nargs = "+",
	-- Complete file paths for the source argument only; the name is freeform.
	complete = function(arg_lead, cmd_line)
		if #vim.split(vim.trim(cmd_line), "%s+") < 2 then
			return {}
		end
		return vim.fn.getcompletion(arg_lead, "file")
	end,
})

-- Special case for HauntMigrate (one-shot v1->v2 storage migration)
vim.api.nvim_create_user_command("HauntMigrate", function()
	require("haunt.migration").migrate_current_project()
end, { desc = "Migrate bookmarks from v1 to v2 storage (project-relative paths)" })

-- Deferred restoration setup. Dashboard plugins seemingly block this
vim.api.nvim_create_autocmd("UIEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			require("haunt")._setup_restoration_autocmd()
		end)
	end,
})

---@toc_entry Import
---@tag haunt-import
---@tag Import
---@text
--- # Import ~
---
--- Build a bookmark collection from a JSON array, so findings produced by
--- another tool — a code review, a linter, a script — land as annotated
--- bookmarks you can navigate.
---
--- The JSON is an array of objects: ~
--- >json
---   [
---     {
---       "file": "src/services/lookup.cs",
---       "line": 45,
---       "summary": "Bucket key never matches, so a genuine hit is dropped.",
---       "failure_scenario": "Caller sends Ips: [\"::ffff:1.2.3.4\"] ..."
---     }
---   ]
--- <
---
--- - `file` (required): absolute, or relative to the project root.
--- - `line` (required): 1-based.
--- - `summary` (optional): becomes the bookmark's annotation. `note` is
---   accepted as an alias.
--- - `failure_scenario` (optional): longer detail. Appended to the annotation
---   only when |HauntConfig|.virt_text_pos is `"above"`, whose bordered box
---   wraps multi-line text — at any other position it would bury the line in
---   virtual text. `detail` is accepted as an alias.
---
--- Unknown keys are ignored, so richer tool output imports as-is.
---
--- See |haunt.import_collection()| and `:HauntCollectionImport`.

---@class ImportEntry
---@field file string Absolute path, or relative to the project root
---@field line number 1-based line number
---@field summary? string Becomes the annotation (alias: `note`)
---@field failure_scenario? string Extra detail (alias: `detail`)

--- What an import did, for reporting.
---@class ImportStats
---@field imported number Bookmarks created
---@field skipped number Entries rejected as malformed
---@field duplicates number Entries dropped as a repeat of an earlier file:line
---@field detail boolean Whether `failure_scenario` was folded into annotations

---@class ImportOptions
---@field detail? boolean|"auto" Include `failure_scenario` in the annotation. "auto" (default) includes it only when virt_text_pos is "above"

---@class ImportModule
---@field read_source fun(source?: string): string|nil, string|nil
---@field build_bookmarks fun(json_str: string, opts?: ImportOptions): Bookmark[]|nil, ImportStats|string

---@private
---@type ImportModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Read the JSON text to import.
---@param source? string `"%"` or nil for the current buffer, otherwise a file path
---@return string|nil text
---@return string|nil err
function M.read_source(source)
	if source == nil or source == "" or source == "%" then
		local bufnr = vim.api.nvim_get_current_buf()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return nil, "current buffer is not valid"
		end
		return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	end

	local path = vim.fn.expand(source)
	if vim.fn.filereadable(path) ~= 1 then
		return nil, "cannot read file: " .. path
	end

	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil, "failed to read file: " .. path
	end

	return table.concat(lines, "\n")
end

--- Whether to fold `failure_scenario` into the annotation.
---
--- Only the "above" position renders a wrapped, multi-line box; everywhere else
--- the annotation is a single run of virtual text on the line, where a
--- paragraph of detail is noise.
---@param detail boolean|"auto"|nil
---@return boolean
local function include_detail(detail)
	if type(detail) == "boolean" then
		return detail
	end
	return (require("haunt.config").get().virt_text_pos or "eol") == "above"
end

--- Resolve an entry's file to an absolute path. Bookmarks are absolute in
--- memory; `persistence._build_serializable` re-relativizes them on save.
---@param file string
---@return string
local function resolve_file(file)
	if vim.startswith(file, "/") then
		return vim.fs.normalize(file)
	end

	local root = require("haunt.project").get_info().root or vim.fn.getcwd()
	return require("haunt.utils").to_absolute(file, root)
end

--- Build the annotation for an entry.
---@param entry ImportEntry
---@param with_detail boolean
---@return string|nil note
local function build_note(entry, with_detail)
	local summary = entry.summary or entry.note
	if type(summary) ~= "string" or summary == "" then
		summary = nil
	end

	local detail = entry.failure_scenario or entry.detail
	if type(detail) ~= "string" or detail == "" or not with_detail then
		return summary
	end

	if not summary then
		return detail
	end

	-- A blank line between them: build_box_lines splits on newlines, so the
	-- summary stays a readable first paragraph.
	return summary .. "\n\n" .. detail
end

--- Turn JSON text into bookmarks.
---
--- Malformed entries are skipped rather than aborting the import — one bad
--- record in a generated report should not cost you the other findings — and
--- are counted so the caller can say so.
---@param json_str string
---@param opts? ImportOptions
---@return Bookmark[]|nil bookmarks nil when the JSON itself could not be used
---@return ImportStats|string stats_or_err
function M.build_bookmarks(json_str, opts)
	opts = opts or {}

	if type(json_str) ~= "string" or vim.trim(json_str) == "" then
		return nil, "no JSON to import (source is empty)"
	end

	local ok, decoded = pcall(vim.json.decode, json_str)
	if not ok then
		return nil, "JSON decode failed: " .. tostring(decoded)
	end

	if type(decoded) ~= "table" then
		return nil, "expected a JSON array of entries"
	end

	-- vim.json decodes both [] and {} to a table; only an array has [1] (or is
	-- empty, which is a valid but pointless import).
	if next(decoded) ~= nil and decoded[1] == nil then
		return nil, "expected a JSON array of entries, got an object"
	end

	local with_detail = include_detail(opts.detail)
	local persistence = require("haunt.persistence")

	local bookmarks = {}
	local seen = {}
	local stats = { imported = 0, skipped = 0, duplicates = 0, detail = with_detail }

	for _, entry in ipairs(decoded) do
		local valid = type(entry) == "table"
			and type(entry.file) == "string"
			and entry.file ~= ""
			and type(entry.line) == "number"
			and entry.line >= 1

		if not valid then
			stats.skipped = stats.skipped + 1
		else
			local file = resolve_file(entry.file)
			local line = math.floor(entry.line)
			local key = file .. ":" .. line

			if seen[key] then
				stats.duplicates = stats.duplicates + 1
			else
				-- create_bookmark notifies on bad input; the checks above mean it
				-- only ever sees valid input here.
				local bookmark = persistence.create_bookmark(file, line, build_note(entry, with_detail))
				if bookmark then
					seen[key] = true
					table.insert(bookmarks, bookmark)
					stats.imported = stats.imported + 1
				else
					stats.skipped = stats.skipped + 1
				end
			end
		end
	end

	return bookmarks, stats
end

return M

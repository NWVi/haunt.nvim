---@toc_entry Collections
---@tag haunt-collections
---@tag Collections
---@text
--- # Collections ~
---
--- Collections are named bookmark lists. Each project starts with a single
--- `default` collection — the bookmarks haunt has always kept — and you can
--- create more to organize bookmarks by topic: a refactor, a bug hunt, a
--- review pass.
---
--- Only one collection is active at a time. The active collection persists
--- across sessions until you change it, and every haunt feature (annotations,
--- navigation, quickfix, per-branch scoping) operates on whichever collection
--- is active.
---
--- Collections are scoped per project: switching to a collection in one
--- project has no effect on any other. The active collection persists across
--- branch switches, since a branch is which code you are on and a collection
--- is which lens you are using.
---
--- The `default` collection is reserved: it always exists and cannot be
--- deleted.
---
--- Commands: ~
---   - `:HauntCollections` - Pick the active collection
---   - `:HauntCollectionNew [name]` - Create a collection and switch to it
---   - `:HauntCollectionDelete [name]` - Delete a collection and its bookmarks
---
--- See |haunt.switch_collection()|, |haunt.create_collection()|, and
--- |haunt.delete_collection()| for the programmatic API.

--- Registry file contents. Written to `<data_dir>/collections.json`, and only
--- ever written once the user creates, deletes, or switches a collection — a
--- user who never touches collections never grows the file.
---@class CollectionRegistry
---@field version number Registry schema version
---@field projects table<string, CollectionRegistryEntry> Keyed by project_id

---@class CollectionRegistryEntry
---@field collections string[] Known collection names for this project
---@field active string The active collection name

---@class CollectionsModule
---@field DEFAULT string
---@field list fun(): string[]
---@field get_active fun(): string
---@field set_active fun(name: string): boolean, string|nil
---@field create fun(name: string): boolean, string|nil
---@field delete fun(name: string): boolean, string|nil
---@field exists fun(name: string): boolean
---@field validate_name fun(name: any): string|nil, string|nil
---@field invalidate fun()
---@field _reset_for_testing fun()

---@private
---@type CollectionsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

-- NOTE: every require in this module is deliberately in-function. Requiring
-- haunt.persistence at load time would cycle: persistence.get_storage_path
-- calls collections.get_active, which needs persistence.get_data_dir.

local REGISTRY_VERSION = 1
local REGISTRY_FILE = "collections.json"
local MAX_NAME_LENGTH = 64

M.DEFAULT = "default"

--- Cached registry, along with the data_dir it was read from. `get_active()` is
--- called on every storage-path resolution, so this keeps that a table lookup
--- rather than a file read. Invalidated on write and when the data_dir changes.
---@private
---@type CollectionRegistry|nil
local _cache = nil
---@private
---@type string|nil
local _cache_dir = nil

--- Path of a registry file that failed to parse, if the last read hit one.
--- Overwriting it would silently discard every project's collections, so the
--- first write preserves it first (mirrors how `haunt.migration` backs up v1).
---@private
---@type string|nil
local _unreadable_path = nil

---@private
---@return string path
local function registry_path()
	return require("haunt.persistence").get_data_dir() .. REGISTRY_FILE
end

--- Read and validate the registry.
---
--- Every failure mode degrades to an empty registry rather than propagating:
--- a missing file is the normal state for a user who has never made a
--- collection, and a corrupt or hand-edited file must not wedge the plugin.
---
--- `force` bypasses the cache. Writers must pass it: unlike the per-project
--- bookmark files, the registry is a single file shared by every project and
--- every running instance, and a write serializes the whole thing. Merging into
--- a stale cache would drop entries another instance (or another project) added
--- since this one last read.
---@private
---@param force? boolean Re-read from disk even when cached
---@return CollectionRegistry
local function read_registry(force)
	local dir = require("haunt.persistence").get_data_dir()
	if not force and _cache and _cache_dir == dir then
		return _cache
	end

	local empty = { version = REGISTRY_VERSION, projects = {} }
	local path = dir .. REGISTRY_FILE

	if vim.fn.filereadable(path) ~= 1 then
		_cache, _cache_dir = empty, dir
		return empty
	end

	local read_ok, lines = pcall(vim.fn.readfile, path)
	if not read_ok then
		_cache, _cache_dir = empty, dir
		return empty
	end

	local decode_ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decode_ok or type(data) ~= "table" or data.version ~= REGISTRY_VERSION or type(data.projects) ~= "table" then
		_unreadable_path = path
		_cache, _cache_dir = empty, dir
		return empty
	end

	_unreadable_path = nil

	_cache, _cache_dir = data, dir
	return data
end

---@private
---@param registry CollectionRegistry
---@return boolean success
---@return string|nil err
local function write_registry(registry)
	local persistence = require("haunt.persistence")
	persistence.ensure_data_dir()

	local encode_ok, json_str = pcall(vim.json.encode, registry)
	if not encode_ok then
		return false, "failed to encode collections registry: " .. tostring(json_str)
	end

	-- A registry we couldn't parse degraded to empty on read; overwriting it now
	-- would destroy the collections of every project it described. Keep a copy.
	if _unreadable_path then
		local backup = _unreadable_path .. ".bak"
		vim.fn.rename(_unreadable_path, backup)
		vim.notify(
			"haunt.nvim: collections registry was unreadable and has been reset. Previous file saved to " .. backup,
			vim.log.levels.WARN
		)
		_unreadable_path = nil
	end

	-- vim.fn.writefile returns -1 on I/O failure rather than throwing, so check
	-- both the pcall result and the return value (mirrors save_bookmarks).
	local path = registry_path()
	local write_ok, write_ret = pcall(vim.fn.writefile, { json_str }, path)
	if not write_ok or write_ret == -1 then
		return false, "failed to write collections registry: " .. path
	end

	_cache, _cache_dir = registry, persistence.get_data_dir()
	return true
end

---@private
---@return string project_id
local function project_id()
	return require("haunt.project").get_info().project_id
end

--- Read this project's entry, normalized so callers never handle a malformed
--- one: the default collection is always present and `active` always names a
--- known collection.
---
--- `force` bypasses the cache; mutators must pass it so they extend the entry
--- another instance may have grown since this one last read, rather than
--- replacing it wholesale.
---@private
---@param force? boolean Re-read from disk even when cached
---@return CollectionRegistryEntry
local function get_entry(force)
	local registry = read_registry(force)
	local entry = registry.projects[project_id()]

	if type(entry) ~= "table" or type(entry.collections) ~= "table" then
		return { collections = { M.DEFAULT }, active = M.DEFAULT }
	end

	-- Validate names coming off disk, not just names coming from the user. This
	-- is the only path that feeds a storage key from a file a human could have
	-- edited, and a name containing "|" or "^" would forge a different
	-- collection's key — the very thing the sigil exists to prevent.
	local names, seen = {}, {}
	for _, name in ipairs(entry.collections) do
		local valid = M.validate_name(name)
		if valid and not seen[valid] then
			seen[valid] = true
			table.insert(names, valid)
		end
	end
	if not seen[M.DEFAULT] then
		table.insert(names, M.DEFAULT)
	end

	-- An active collection that no longer exists (hand-edited file, or a
	-- half-written delete) must not strand the user on a phantom collection.
	local active = entry.active
	if type(active) ~= "string" or not vim.tbl_contains(names, active) then
		active = M.DEFAULT
	end

	return { collections = names, active = active }
end

---@private
---@param entry CollectionRegistryEntry
---@return boolean success
---@return string|nil err
local function save_entry(entry)
	-- Merge against disk, not the cache: another instance may have added a
	-- project (or a collection) since this one last read, and a write
	-- serializes the whole registry.
	local registry = vim.deepcopy(read_registry(true))
	registry.version = REGISTRY_VERSION
	registry.projects = registry.projects or {}
	registry.projects[project_id()] = entry
	return write_registry(registry)
end

--- Validate and normalize a collection name.
---
--- A blocklist rather than an allowlist, so non-ASCII names work. `|` and `^`
--- are rejected because they are the storage key's separator and collection
--- sigil. `/` needs no ban: names are hashed, never used as filenames.
---@param name any The candidate name
---@return string|nil name The trimmed name, or nil when invalid
---@return string|nil err Why it was rejected
function M.validate_name(name)
	if type(name) ~= "string" then
		return nil, "collection name must be a string"
	end

	local trimmed = vim.trim(name)
	if trimmed == "" then
		return nil, "collection name cannot be empty"
	end
	if #trimmed > MAX_NAME_LENGTH then
		return nil, string.format("collection name cannot exceed %d characters", MAX_NAME_LENGTH)
	end
	if trimmed:find("[|^]") then
		return nil, "collection name cannot contain '|' or '^'"
	end
	if trimmed:find("%c") then
		return nil, "collection name cannot contain control characters"
	end

	return trimmed
end

--- List the known collections for the current project.
--- The default collection is always first; the rest are sorted.
---@return string[] names
function M.list()
	local entry = get_entry()

	local rest = {}
	for _, name in ipairs(entry.collections) do
		if name ~= M.DEFAULT then
			table.insert(rest, name)
		end
	end
	table.sort(rest)

	local names = { M.DEFAULT }
	vim.list_extend(names, rest)
	return names
end

--- Get the active collection for the current project.
--- Always returns a usable name, falling back to the default collection.
---@return string name
function M.get_active()
	return get_entry().active
end

--- Whether a collection exists for the current project.
---@param name string
---@return boolean
function M.exists(name)
	return vim.tbl_contains(M.list(), name)
end

--- Set the active collection. Writes the registry only; swapping the loaded
--- bookmarks is `haunt.api`'s job (see |haunt.switch_collection()|).
---@param name string
---@return boolean success
---@return string|nil err
function M.set_active(name)
	local valid, err = M.validate_name(name)
	if not valid then
		return false, err
	end
	if not M.exists(valid) then
		return false, "no such collection: " .. valid
	end

	local entry = get_entry(true)
	entry.active = valid
	return save_entry(entry)
end

--- Create a collection. Writes the registry immediately: an empty collection
--- has no storage file (an empty save deletes it), so the registry is the only
--- record that it exists.
---@param name string
---@return boolean success
---@return string|nil err
function M.create(name)
	local valid, err = M.validate_name(name)
	if not valid then
		return false, err
	end
	if M.exists(valid) then
		return false, "collection already exists: " .. valid
	end

	local entry = get_entry(true)
	table.insert(entry.collections, valid)
	return save_entry(entry)
end

--- Remove a collection from the registry. Deleting its bookmarks and choosing
--- a new active collection are `haunt.api`'s job (see |haunt.delete_collection()|).
---@param name string
---@return boolean success
---@return string|nil err
function M.delete(name)
	local valid, err = M.validate_name(name)
	if not valid then
		return false, err
	end
	if valid == M.DEFAULT then
		return false, "cannot delete the default collection"
	end
	if not M.exists(valid) then
		return false, "no such collection: " .. valid
	end

	local entry = get_entry(true)
	local remaining = {}
	for _, existing in ipairs(entry.collections) do
		if existing ~= valid then
			table.insert(remaining, existing)
		end
	end
	entry.collections = remaining
	if entry.active == valid then
		entry.active = M.DEFAULT
	end

	return save_entry(entry)
end

--- Drop the cached registry. Must be called when the data directory changes,
--- since the registry lives inside it.
function M.invalidate()
	_cache, _cache_dir = nil, nil
	_unreadable_path = nil
end

--- Reset internal state for testing purposes only
---@private
function M._reset_for_testing()
	M.invalidate()
end

return M

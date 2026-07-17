---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.collections", function()
	local collections
	local persistence
	local data_dir

	before_each(function()
		helpers.reset_modules()
		data_dir = helpers.create_temp_data_dir()

		local haunt = require("haunt")
		haunt.setup({ data_dir = data_dir })

		collections = require("haunt.collections")
		persistence = require("haunt.persistence")
		persistence.set_data_dir(data_dir)
		collections.invalidate()
	end)

	after_each(function()
		helpers.cleanup_temp_dir(data_dir)
	end)

	describe("validate_name", function()
		it("accepts a simple name", function()
			local name, err = collections.validate_name("review")
			assert.are.equal("review", name)
			assert.is_nil(err)
		end)

		it("trims surrounding whitespace", function()
			assert.are.equal("review", collections.validate_name("  review  "))
		end)

		it("accepts non-ASCII names", function()
			assert.are.equal("réview", collections.validate_name("réview"))
		end)

		it("rejects a non-string", function()
			local name, err = collections.validate_name(42)
			assert.is_nil(name)
			assert.is_not_nil(err)
		end)

		it("rejects an empty name", function()
			local name, err = collections.validate_name("")
			assert.is_nil(name)
			assert.is_not_nil(err)
		end)

		it("rejects a whitespace-only name", function()
			local name, err = collections.validate_name("   ")
			assert.is_nil(name)
			assert.is_not_nil(err)
		end)

		-- "|" is the key separator and "^" is the collection sigil; allowing
		-- either would let a name forge a different collection's storage key.
		it("rejects a name containing the key separator", function()
			assert.is_nil(collections.validate_name("a|b"))
		end)

		it("rejects a name containing the collection sigil", function()
			assert.is_nil(collections.validate_name("a^b"))
		end)

		it("rejects control characters", function()
			assert.is_nil(collections.validate_name("a\nb"))
		end)

		it("rejects a name over 64 characters", function()
			assert.is_nil(collections.validate_name(string.rep("a", 65)))
		end)

		it("accepts a name of exactly 64 characters", function()
			local name = string.rep("a", 64)
			assert.are.equal(name, collections.validate_name(name))
		end)
	end)

	describe("defaults with no registry file", function()
		it("lists only the default collection", function()
			assert.are.same({ "default" }, collections.list())
		end)

		it("reports the default collection as active", function()
			assert.are.equal("default", collections.get_active())
		end)

		it("does not create a registry file just by reading", function()
			collections.list()
			collections.get_active()
			assert.is_nil(helpers.read_registry_file(data_dir))
		end)

		it("reports that the default collection exists", function()
			assert.is_true(collections.exists("default"))
		end)

		it("reports that an unknown collection does not exist", function()
			assert.is_false(collections.exists("nope"))
		end)
	end)

	describe("create", function()
		it("adds the collection to the list", function()
			assert.is_true(collections.create("review"))
			assert.are.same({ "default", "review" }, collections.list())
		end)

		it("writes the registry immediately", function()
			collections.create("review")
			local registry = helpers.read_registry_file(data_dir)
			assert.is_not_nil(registry)
			assert.are.equal(1, registry.version)
		end)

		it("does not switch the active collection", function()
			collections.create("review")
			assert.are.equal("default", collections.get_active())
		end)

		it("rejects a duplicate", function()
			collections.create("review")
			local ok, err = collections.create("review")
			assert.is_false(ok)
			assert.is_not_nil(err)
		end)

		it("rejects the reserved default name", function()
			local ok, err = collections.create("default")
			assert.is_false(ok)
			assert.is_not_nil(err)
		end)

		it("rejects an invalid name", function()
			assert.is_false(collections.create("a|b"))
		end)

		it("stores the trimmed name", function()
			collections.create("  review  ")
			assert.is_true(collections.exists("review"))
		end)

		it("treats names case-sensitively", function()
			collections.create("review")
			assert.is_true(collections.create("Review"))
			assert.are.same({ "default", "Review", "review" }, collections.list())
		end)
	end)

	describe("set_active", function()
		it("switches to an existing collection", function()
			collections.create("review")
			assert.is_true(collections.set_active("review"))
			assert.are.equal("review", collections.get_active())
		end)

		it("persists across a module reload", function()
			collections.create("review")
			collections.set_active("review")

			helpers.reset_modules()
			local haunt = require("haunt")
			haunt.setup({ data_dir = data_dir })
			require("haunt.persistence").set_data_dir(data_dir)
			local reloaded = require("haunt.collections")

			assert.are.equal("review", reloaded.get_active())
		end)

		it("rejects an unknown collection", function()
			local ok, err = collections.set_active("nope")
			assert.is_false(ok)
			assert.is_not_nil(err)
		end)

		it("rejects an invalid name", function()
			assert.is_false(collections.set_active(""))
		end)
	end)

	describe("delete", function()
		it("removes the collection", function()
			collections.create("review")
			assert.is_true(collections.delete("review"))
			assert.are.same({ "default" }, collections.list())
		end)

		it("refuses to delete the default collection", function()
			local ok, err = collections.delete("default")
			assert.is_false(ok)
			assert.is_not_nil(err)
			assert.is_true(collections.exists("default"))
		end)

		it("rejects an unknown collection", function()
			assert.is_false(collections.delete("nope"))
		end)

		it("falls back to default when deleting the active collection", function()
			collections.create("review")
			collections.set_active("review")
			collections.delete("review")
			assert.are.equal("default", collections.get_active())
		end)

		it("leaves an unrelated active collection alone", function()
			collections.create("review")
			collections.create("perf")
			collections.set_active("review")
			collections.delete("perf")
			assert.are.equal("review", collections.get_active())
		end)
	end)

	describe("list ordering", function()
		it("puts default first and sorts the rest", function()
			collections.create("zebra")
			collections.create("alpha")
			collections.create("mid")
			assert.are.same({ "default", "alpha", "mid", "zebra" }, collections.list())
		end)
	end)

	-- A corrupt or hand-edited registry must degrade to the default collection
	-- rather than wedging the plugin: get_active() sits in the path of every
	-- save and load.
	describe("malformed registry", function()
		local function reload_collections()
			helpers.reset_modules()
			local haunt = require("haunt")
			haunt.setup({ data_dir = data_dir })
			require("haunt.persistence").set_data_dir(data_dir)
			return require("haunt.collections")
		end

		it("falls back to default on undecodable JSON", function()
			vim.fn.writefile({ "{not json" }, data_dir .. "collections.json")
			local c = reload_collections()
			assert.are.equal("default", c.get_active())
			assert.are.same({ "default" }, c.list())
		end)

		it("falls back to default on an unknown registry version", function()
			helpers.create_registry_file(data_dir, {}, 999)
			local c = reload_collections()
			assert.are.equal("default", c.get_active())
		end)

		it("falls back to default when active names an unknown collection", function()
			local info = require("haunt.project").get_info()
			helpers.create_registry_file(data_dir, {
				[info.project_id] = { collections = { "default" }, active = "ghost" },
			})
			local c = reload_collections()
			assert.are.equal("default", c.get_active())
		end)

		it("injects default when the registry omits it", function()
			local info = require("haunt.project").get_info()
			helpers.create_registry_file(data_dir, {
				[info.project_id] = { collections = { "review" }, active = "review" },
			})
			local c = reload_collections()
			assert.is_true(c.exists("default"))
			assert.are.equal("review", c.get_active())
		end)

		it("falls back to default when the project entry is malformed", function()
			local info = require("haunt.project").get_info()
			helpers.create_registry_file(data_dir, {
				[info.project_id] = { collections = "not-a-list", active = "review" },
			})
			local c = reload_collections()
			assert.are.equal("default", c.get_active())
			assert.are.same({ "default" }, c.list())
		end)

		-- get_entry is the only path that feeds a storage key from a file a human
		-- could have edited, so names off disk get the same validation as names
		-- from the user.
		it("drops names that could forge a storage key", function()
			local info = require("haunt.project").get_info()
			helpers.create_registry_file(data_dir, {
				[info.project_id] = {
					collections = { "default", "ok", "bad|name", "bad^name" },
					active = "ok",
				},
			})
			local c = reload_collections()
			assert.are.same({ "default", "ok" }, c.list())
		end)

		it("falls back to default when active itself is an invalid name", function()
			local info = require("haunt.project").get_info()
			helpers.create_registry_file(data_dir, {
				[info.project_id] = { collections = { "default", "a^b" }, active = "a^b" },
			})
			local c = reload_collections()
			assert.are.equal("default", c.get_active())
		end)

		-- An unparseable registry degrades to empty on read; overwriting it would
		-- destroy every project's collections, so the first write preserves it.
		it("backs up an unreadable registry before overwriting it", function()
			local path = data_dir .. "collections.json"
			vim.fn.writefile({ "{ corrupt" }, path)

			local c = reload_collections()
			c.create("fresh")

			assert.are.equal(1, vim.fn.filereadable(path .. ".bak"))
			assert.are.equal("{ corrupt", vim.fn.readfile(path .. ".bak")[1])
			assert.is_true(c.exists("fresh"))
		end)

		it("deduplicates repeated names", function()
			local info = require("haunt.project").get_info()
			helpers.create_registry_file(data_dir, {
				[info.project_id] = { collections = { "default", "review", "review" }, active = "review" },
			})
			local c = reload_collections()
			assert.are.same({ "default", "review" }, c.list())
		end)
	end)

	describe("project scoping", function()
		it("keeps collections separate per project", function()
			local project_mock = require("tests.helpers.project_mock")

			project_mock.set({ root = "/tmp/a", branch = "main", project_id = "project-a" })
			collections.invalidate()
			collections.create("only-in-a")
			assert.is_true(collections.exists("only-in-a"))

			project_mock.set({ root = "/tmp/b", branch = "main", project_id = "project-b" })
			collections.invalidate()
			assert.is_false(collections.exists("only-in-a"))
			assert.are.same({ "default" }, collections.list())

			project_mock.restore()
		end)
	end)

	-- The registry is one file shared by every project and every running
	-- instance, and a write serializes the whole thing. Writers must merge
	-- against disk rather than a cache another instance has already invalidated.
	describe("concurrent writers", function()
		it("does not clobber a project added by another instance", function()
			local project_mock = require("tests.helpers.project_mock")

			-- This instance reads (and caches) the registry for project A.
			project_mock.set({ root = "/tmp/a", branch = "main", project_id = "project-a" })
			collections.invalidate()
			collections.create("in-a")

			-- Another instance adds a collection for project B behind our back.
			local registry = helpers.read_registry_file(data_dir)
			registry.projects["project-b"] = { collections = { "default", "in-b" }, active = "in-b" }
			vim.fn.writefile({ vim.json.encode(registry) }, data_dir .. "collections.json")

			-- We write again from our (now stale) cache.
			collections.create("also-in-a")

			local after = helpers.read_registry_file(data_dir)
			assert.is_not_nil(after.projects["project-b"], "project-b's entry was clobbered")
			assert.are.same({ "default", "in-b" }, after.projects["project-b"].collections)
			assert.is_true(vim.tbl_contains(after.projects["project-a"].collections, "also-in-a"))

			project_mock.restore()
		end)

		it("picks up a collection another instance added for this project", function()
			collections.create("mine")

			local info = require("haunt.project").get_info()
			local registry = helpers.read_registry_file(data_dir)
			table.insert(registry.projects[info.project_id].collections, "theirs")
			vim.fn.writefile({ vim.json.encode(registry) }, data_dir .. "collections.json")

			-- Our next write must not drop "theirs".
			collections.create("mine-2")

			local after = helpers.read_registry_file(data_dir)
			local names = after.projects[info.project_id].collections
			assert.is_true(vim.tbl_contains(names, "theirs"), "another instance's collection was dropped")
			assert.is_true(vim.tbl_contains(names, "mine-2"))
		end)
	end)

	describe("write failure", function()
		it("returns false when the registry cannot be written", function()
			local original = vim.fn.writefile
			vim.fn.writefile = function()
				return -1
			end

			local ok, err = collections.create("review")

			vim.fn.writefile = original

			assert.is_false(ok)
			assert.is_not_nil(err)
		end)
	end)
end)

---@module 'luassert'
---@diagnostic disable: need-check-nil, param-type-mismatch

local helpers = require("tests.helpers")

describe("haunt.import", function()
	local import
	local project_mock = require("tests.helpers.project_mock")

	before_each(function()
		helpers.reset_modules()
		package.loaded["haunt.import"] = nil

		local haunt = require("haunt")
		haunt.setup()
		import = require("haunt.import")

		project_mock.set({ root = "/fake/proj", branch = "main", project_id = "p-id" })
	end)

	after_each(function()
		project_mock.restore()
	end)

	---@param entries table
	---@return string
	local function json(entries)
		return vim.json.encode(entries)
	end

	describe("read_source", function()
		it("reads the current buffer by default", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[", '  {"file": "a.lua"}', "]" })
			vim.api.nvim_set_current_buf(bufnr)

			local text = import.read_source()
			assert.is_truthy(text:match('"file"'))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it('treats "%" as the current buffer', function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[]" })
			vim.api.nvim_set_current_buf(bufnr)

			assert.are.equal("[]", import.read_source("%"))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("reads a file path", function()
			local path = vim.fn.tempname() .. ".json"
			vim.fn.writefile({ '[{"file":"a.lua","line":1}]' }, path)

			local text = import.read_source(path)
			assert.is_truthy(text:match("a%.lua"))

			vim.fn.delete(path)
		end)

		it("errors on a missing file", function()
			local text, err = import.read_source("/nope/missing.json")
			assert.is_nil(text)
			assert.is_truthy(err:match("cannot read file"))
		end)
	end)

	describe("build_bookmarks", function()
		it("maps summary to the annotation", function()
			local bookmarks, stats = import.build_bookmarks(json({
				{ file = "src/a.lua", line = 12, summary = "a finding" },
			}))

			assert.are.equal(1, #bookmarks)
			assert.are.equal("a finding", bookmarks[1].note)
			assert.are.equal(12, bookmarks[1].line)
			assert.are.equal(1, stats.imported)
		end)

		it("accepts note as an alias for summary", function()
			local bookmarks = import.build_bookmarks(json({
				{ file = "src/a.lua", line = 1, note = "via note" },
			}))
			assert.are.equal("via note", bookmarks[1].note)
		end)

		it("resolves project-relative paths against the project root", function()
			local bookmarks = import.build_bookmarks(json({
				{ file = "source/Services/Lookup.cs", line = 45, summary = "x" },
			}))
			assert.are.equal("/fake/proj/source/Services/Lookup.cs", bookmarks[1].file)
		end)

		it("keeps absolute paths as-is", function()
			local bookmarks = import.build_bookmarks(json({
				{ file = "/elsewhere/b.lua", line = 3, summary = "x" },
			}))
			assert.are.equal("/elsewhere/b.lua", bookmarks[1].file)
		end)

		it("gives each bookmark a distinct id", function()
			local bookmarks = import.build_bookmarks(json({
				{ file = "a.lua", line = 1, summary = "one" },
				{ file = "b.lua", line = 2, summary = "two" },
			}))
			assert.are_not.equal(bookmarks[1].id, bookmarks[2].id)
		end)

		it("imports an entry with no summary", function()
			local bookmarks = import.build_bookmarks(json({ { file = "a.lua", line = 1 } }))
			assert.are.equal(1, #bookmarks)
			assert.is_nil(bookmarks[1].note)
		end)

		it("truncates a fractional line", function()
			local bookmarks = import.build_bookmarks(json({ { file = "a.lua", line = 4.7, summary = "x" } }))
			assert.are.equal(4, bookmarks[1].line)
		end)

		-- One bad record in a generated report should not cost the others.
		describe("malformed entries", function()
			it("skips entries missing a file", function()
				local bookmarks, stats = import.build_bookmarks(json({
					{ line = 1, summary = "no file" },
					{ file = "a.lua", line = 2, summary = "ok" },
				}))
				assert.are.equal(1, #bookmarks)
				assert.are.equal(1, stats.skipped)
				assert.are.equal(1, stats.imported)
			end)

			it("skips entries missing a line", function()
				local _, stats = import.build_bookmarks(json({ { file = "a.lua", summary = "no line" } }))
				assert.are.equal(1, stats.skipped)
			end)

			it("skips a non-numeric line", function()
				local _, stats = import.build_bookmarks(json({ { file = "a.lua", line = "12" } }))
				assert.are.equal(1, stats.skipped)
			end)

			it("skips a line below 1", function()
				local _, stats = import.build_bookmarks(json({ { file = "a.lua", line = 0 } }))
				assert.are.equal(1, stats.skipped)
			end)

			it("skips an empty file string", function()
				local _, stats = import.build_bookmarks(json({ { file = "", line = 1 } }))
				assert.are.equal(1, stats.skipped)
			end)

			it("skips a non-object entry", function()
				local _, stats = import.build_bookmarks('["just a string", {"file":"a.lua","line":1}]')
				assert.are.equal(1, stats.skipped)
				assert.are.equal(1, stats.imported)
			end)
		end)

		it("drops a repeated file:line", function()
			local bookmarks, stats = import.build_bookmarks(json({
				{ file = "a.lua", line = 5, summary = "first" },
				{ file = "a.lua", line = 5, summary = "second" },
			}))
			assert.are.equal(1, #bookmarks)
			assert.are.equal("first", bookmarks[1].note)
			assert.are.equal(1, stats.duplicates)
		end)

		it("keeps the same line in different files", function()
			local bookmarks = import.build_bookmarks(json({
				{ file = "a.lua", line = 5, summary = "one" },
				{ file = "b.lua", line = 5, summary = "two" },
			}))
			assert.are.equal(2, #bookmarks)
		end)

		describe("bad input", function()
			it("rejects undecodable JSON", function()
				local bookmarks, err = import.build_bookmarks("{ not json")
				assert.is_nil(bookmarks)
				assert.is_truthy(err:match("JSON decode failed"))
			end)

			it("rejects an empty source", function()
				local bookmarks, err = import.build_bookmarks("   ")
				assert.is_nil(bookmarks)
				assert.is_truthy(err:match("no JSON"))
			end)

			it("rejects a JSON object", function()
				local bookmarks, err = import.build_bookmarks('{"file":"a.lua","line":1}')
				assert.is_nil(bookmarks)
				assert.is_truthy(err:match("got an object"))
			end)

			it("accepts an empty array as zero entries", function()
				local bookmarks, stats = import.build_bookmarks("[]")
				assert.are.same({}, bookmarks)
				assert.are.equal(0, stats.imported)
			end)
		end)

		-- failure_scenario is a paragraph. Only the "above" box wraps multi-line
		-- text; at any other position it would bury the line in virtual text.
		describe("failure_scenario", function()
			local entry = {
				{ file = "a.lua", line = 1, summary = "the summary", failure_scenario = "the long detail" },
			}

			it("is dropped at the default virt_text_pos", function()
				local bookmarks, stats = import.build_bookmarks(json(entry))
				assert.are.equal("the summary", bookmarks[1].note)
				assert.is_false(stats.detail)
			end)

			it("is appended when virt_text_pos is above", function()
				require("haunt.config").setup({ virt_text_pos = "above" })

				local bookmarks, stats = import.build_bookmarks(json(entry))
				assert.are.equal("the summary\n\nthe long detail", bookmarks[1].note)
				assert.is_true(stats.detail)
			end)

			it("can be forced on", function()
				local bookmarks = import.build_bookmarks(json(entry), { detail = true })
				assert.are.equal("the summary\n\nthe long detail", bookmarks[1].note)
			end)

			it("can be forced off in above mode", function()
				require("haunt.config").setup({ virt_text_pos = "above" })

				local bookmarks = import.build_bookmarks(json(entry), { detail = false })
				assert.are.equal("the summary", bookmarks[1].note)
			end)

			it("accepts detail as an alias", function()
				local bookmarks =
					import.build_bookmarks(json({ { file = "a.lua", line = 1, summary = "s", detail = "d" } }), { detail = true })
				assert.are.equal("s\n\nd", bookmarks[1].note)
			end)

			it("stands alone when there is no summary", function()
				local bookmarks = import.build_bookmarks(
					json({ { file = "a.lua", line = 1, failure_scenario = "only detail" } }),
					{ detail = true }
				)
				assert.are.equal("only detail", bookmarks[1].note)
			end)
		end)

		it("ignores unknown keys", function()
			local bookmarks = import.build_bookmarks(json({
				{ file = "a.lua", line = 1, summary = "x", severity = "high", verdict = "CONFIRMED" },
			}))
			assert.are.equal(1, #bookmarks)
			assert.are.equal("x", bookmarks[1].note)
		end)
	end)
end)

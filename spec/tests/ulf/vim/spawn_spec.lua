local stub = require("luassert.stub")
local mock = require("luassert.mock")
-- local uv = mock(vim.uv)
local uv = vim.uv

describe("#ulf.vim", function()
	describe("#ulf.vim.spawn", function()
		describe("#ulf.vim.spawn.VimProcess", function()
			-- local orig = {
			-- 	uv = {},
			-- }
			-- before_each(function()
			-- 	uv.os_homedir.returns("/home/test")
			-- end)
			local VimProcess = require("ulf.vim.spawn").VimProcess
			describe("call VimProcess", function()
				it("returns a new VimProcess instance", function()
					local proc = VimProcess()
					assert(proc)
				end)
			end)
		end)
	end)
end)

#!/usr/bin/env nlua

local P = function(s)
	return print(require("ulf.lib.inspect")(s))
end
local function test_1()
	local VimProcess = require("ulf.vim.spawn").VimProcess

	local proc = VimProcess()

	proc:start({}, {
		nvim_executable = "/Users/al/.local/bin/nvim",
	})
	-- proc:connect()
	-- P(proc:is_running())
	P(proc.api.nvim_get_all_options_info())

	if proc:is_running() then
		P(proc.loop.cwd())
	end
end

local function test_2()
	package.path = package.path .. ";" .. "/Users/al/.local/share/nvim/lazy/mini.test/lua/?.lua"
	package.path = package.path .. ";" .. "/Users/al/.local/share/nvim/lazy/mini.test/lua/?/init.lua"
	local Child = require("mini.test").new_child_neovim()
	Child:start()
	-- P(Child.api.nvim_get_all_options_info())
	-- P(Child)
end

test_1()

---@class ulf.vim.spawn
local M = {}

_G.P = require("ulf.util.debug").debug_print

local uv = vim.uv
local H = {}

H.error = function(s)
	print(s)
end

H.error_with_emphasis = function(s)
	print(s)
end

-- TODO: Remove after compatibility with Neovim=0.9 is dropped
H.tbl_flatten = vim.fn.has("nvim-0.10") == 1 and function(x)
	return vim.iter(x):flatten(math.huge):totable()
end

---@type ulf.vim.spawn.VimProcess
local VimProcess = {} ---@diagnostic disable-line: missing-fields

--- `VimProcess` spawns Neovim using the job API
--- It is most useful in tests or when you want to use Neovim
--- as a utility to perform a certain task.
---
--- @see echasnovski/mini.test/lua/mini/test.lua for inspiration
---
---@class ulf.vim.spawn.VimProcess
---@field start function Start child process. See |MiniTest-child-neovim.start()|.
---@field stop function Stop current child process.
---@field restart function Restart child process: stop if running and then
---   start a new one. Takes same arguments as `child.start()` but uses values
---   from most recent `start()` call as defaults.
---
---@field type_keys function Emulate typing keys.
---   See |MiniTest-child-neovim.type_keys()|. Doesn't check for blocked state.
---
---@field cmd function Execute Vimscript code from a string.
---   A wrapper for |nvim_exec()| without capturing output.
---@field cmd_capture function Execute Vimscript code from a string and
---   capture output. A wrapper for |nvim_exec()| with capturing output.
---
---@field lua function Execute Lua code. A wrapper for |nvim_exec_lua()|.
---@field lua_notify function Execute Lua code without waiting for output.
---@field lua_get function Execute Lua code and return result. A wrapper
---   for |nvim_exec_lua()| but prepends string code with `return`.
---@field lua_func function Execute Lua function and return it's result.
---   Function will be called with all extra parameters (second one and later).
---   Note: usage of upvalues (data from outside function scope) is not allowed.
---
---@field is_blocked function Check whether child process is blocked.
---@field is_running function Check whether child process is currently running.
---
---@field ensure_normal_mode function Ensure normal mode.
---@field get_screenshot function Returns table with two "2d arrays" of single
---   characters representing what is displayed on screen and how it looks.
---   Has `opts` table argument for optional configuratnion.
---
---@field job table|nil Information about current job. If `nil`, child is not running.
---
---@field api vim.api Redirection table for `vim.api`. Doesn't check for blocked state.
---@field api_notify table Same as `api`, but uses |vim.rpcnotify()|.
---
---@field diagnostic table Redirection table for |vim.diagnostic|.
---@field fn table Redirection table for |vim.fn|.
---@field highlight table Redirection table for `vim.highlight` (|lua-highlight)|.
---@field json table Redirection table for `vim.json`.
---@field loop table Redirection table for |uv|.
---@field lsp table Redirection table for `vim.lsp` (|lsp-core)|.
---@field mpack table Redirection table for |vim.mpack|.
---@field spell table Redirection table for |vim.spell|.
---@field treesitter table Redirection table for |vim.treesitter|.
---@field ui table Redirection table for `vim.ui` (|lua-ui|). Currently of no
---   use because it requires sending function through RPC, which is impossible
---   at the moment.
---
---@field g table Redirection table for |vim.g|.
---@field b table Redirection table for |vim.b|.
---@field w table Redirection table for |vim.w|.
---@field t table Redirection table for |vim.t|.
---@field v table Redirection table for |vim.v|.
---@field env table Redirection table for |vim.env|.
---
---@field o table Redirection table for |vim.o|.
---@field go table Redirection table for |vim.go|.
---@field bo table Redirection table for |vim.bo|.
---@field wo table Redirection table for |vim.wo|.
---@overload fun(opts:table?):ulf.vim.spawn.VimProcess
VimProcess = setmetatable({}, {
	__call = function(t, ...)
		return t.new(...)
	end,
})

---@type ulf.vim.spawn.VimProcess
M.VimProcess = VimProcess

---@class ulf.vim.spawn.VimProcessOptions
local VimProcessDefaultOptions = {
	nvim_executable = vim.v.progpath,
	connection_timeout = 5000,
}

--- TODO: convert to map
--- local map = {
---   long = {
---     clean = true,
---     listen = true,
---   },
---   short = {
---    n = true,
---   },
---   set = {
---     lines = 24,
---     columns = 24,
---   },
--- }
--- @class ulf.vim.spawn.VimProcessArgs
local VimProcessDefaultArgs = {
	"--clean",
	"-n",
	"--listen",
	-- Setting 'lines' and 'columns' makes headless process more like
	-- interactive for closer to reality testing
	"--headless",
	"--cmd",
	"set lines=24 columns=80",
}

M.VimProcessDefaultArgs = VimProcessDefaultArgs
M.VimProcessDefaultOptions = VimProcessDefaultOptions

---comment
---@param opts table
---@return ulf.vim.spawn.VimProcess
function VimProcess.new(opts)
	local self = setmetatable({}, { __index = VimProcess })

	-- Wrappers for common `vim.xxx` objects (will get executed inside child)
	self.api = setmetatable({}, {
		__index = function(_, key)
			self:ensure_running()
			return function(...)
				P({
					"VimProcess.api",
					args = { ... },
					key = key,
				})
				return vim.rpcrequest(self.job.channel, key, ...)
			end
		end,
	})

	-- Variant of `api` functions called with `vim.rpcnotify`. Useful for making
	-- blocking requests (like `getcharstr()`).
	self.api_notify = setmetatable({}, {
		__index = function(_, key)
			self:ensure_running()
			return function(...)
				return vim.rpcnotify(self.job.channel, key, ...)
			end
		end,
	})

  --stylua: ignore start
  local supported_vim_tables = {
    -- Collections
    'diagnostic', 'fn', 'highlight', 'json', 'loop', 'lsp', 'mpack', 'spell', 'treesitter', 'ui',
    -- Variables
    'g', 'b', 'w', 't', 'v', 'env',
    -- Options (no 'opt' because not really useful due to use of metatables)
    'o', 'go', 'bo', 'wo',
  }
	--stylua: ignore end
	for _, v in ipairs(supported_vim_tables) do
		self[v] = self:redirect_to_child(v)
	end

	return self
end

function VimProcess:is_running() end
function VimProcess:is_blocked() end

function VimProcess:ensure_running()
	if self:is_running() then
		return
	end
	H.error("Child process is not running. Did you call `self:start()`?")
end

function VimProcess:prevent_hanging(method)
	if not self:is_blocked() then
		return
	end

	local msg = string.format("Can not use `self:%s` because child process is blocked.", method)
	H.error_with_emphasis(msg)
end
function VimProcess:start(args, opts)
	if self:is_running() then
		H.message("self process is already running. Use `self.restart()`.")
		return
	end

	args = args or {}
	opts = vim.tbl_deep_extend("force", { nvim_executable = vim.v.progpath, connection_timeout = 5000 }, opts or {})

	-- Make unique name for `--listen` pipe
	local job = { address = vim.fn.tempname() }

    --stylua: ignore
    local full_args = {
      opts.nvim_executable, '--clean', '-n', '--listen', job.address,
      -- Setting 'lines' and 'columns' makes headless process more like
      -- interactive for closer to reality testing
      '--headless', '--cmd', 'set lines=24 columns=80'
    }
	vim.list_extend(full_args, args)

	-- Using 'jobstart' for creating a job is crucial for getting this to work
	-- in Github Actions. Other approaches:
	-- - Using `{ pty = true }` seems crucial to make this work on GitHub CI.
	-- - Using `uv.spawn()` is doable, but has issues on Neovim>=0.9:
	--     - https://github.com/neovim/neovim/issues/21630
	--     - https://github.com/neovim/neovim/issues/21886
	--     - https://github.com/neovim/neovim/issues/22018
	job.id = vim.fn.jobstart(full_args)

	local step = 10
	local connected, i, max_tries = nil, 0, math.floor(opts.connection_timeout / step)
	repeat
		i = i + 1
		uv.sleep(step)
		connected, job.channel = pcall(vim.fn.sockconnect, "pipe", job.address, { rpc = true })
	until connected or i >= max_tries

	if not connected then
		local err = "  " .. job.channel:gsub("\n", "\n  ")
		H.error("Failed to make connection to self Neovim with the following error:\n" .. err)
		self.stop()
	end

	self.job = job
	self.start_args, self.start_opts = args, opts
end

function VimProcess:stop()
	if not self:is_running() then
		return
	end

	-- Properly exit Neovim. `pcall` avoids `channel closed by client` error.
	-- Also wait for it to actually close. This reduces simultaneously opened
	-- Neovim instances and CPU load (overall reducing flacky tests).
	pcall(self.cmd, "silent! 0cquit")
	vim.fn.jobwait({ self.job.id }, 1000)

	-- Close all used channels. Prevents `too many open files` type of errors.
	pcall(vim.fn.chanclose, self.job.channel)
	pcall(vim.fn.chanclose, self.job.id)

	-- Remove file for address to reduce chance of "can't open file" errors, as
	-- address uses temporary unique files
	pcall(vim.fn.delete, self.job.address)

	self.job = nil
end

---@param args? ulf.vim.spawn.VimProcessArgs
---@param opts? ulf.vim.spawn.VimProcessOptions
function VimProcess:restart(args, opts)
	args = args or self.start_args
	opts = vim.tbl_deep_extend("force", self.start_opts or {}, opts or {})

	self:stop()
	self:start(args, opts)
end

---@return table Emulates `vim.xxx` table (like `vim.fn`)
---@private
function VimProcess:redirect_to_child(tbl_name)
	-- TODO: try to figure out the best way to operate on tables with function
	-- values (needs "deep encode/decode" of function objects)
	return setmetatable({}, {
		__index = function(_, key)
			self:ensure_running()

			local short_name = ("%s.%s"):format(tbl_name, key)
			local obj_name = ("vim[%s][%s]"):format(vim.inspect(tbl_name), vim.inspect(key))

			P({
				"VimProcess.redirect_to_child",
				short_name = short_name,
				obj_name = obj_name,
			})
			self:prevent_hanging(short_name)

			---@type function
			local value_type = self.api.nvim_exec_lua(("return type(%s)"):format(obj_name), {})

			if value_type == "function" then
				-- This allows syntax like `child.fn.mode(1)`
				return function(...)
					self:prevent_hanging(short_name)
					return self.api.nvim_exec_lua(("return %s(...)"):format(obj_name), { ... })
				end
			end

			-- This allows syntax like `child.bo.buftype`
			self:prevent_hanging(short_name)
			return self.api.nvim_exec_lua(("return %s"):format(obj_name), {})
		end,
		__newindex = function(_, key, value)
			self:ensure_running()

			local short_name = ("%s.%s"):format(tbl_name, key)
			local obj_name = ("vim[%s][%s]"):format(vim.inspect(tbl_name), vim.inspect(key))

			-- This allows syntax like `child.b.aaa = function(x) return x + 1 end`
			-- (inherits limitations of `string.dump`: no upvalues, etc.)
			if type(value) == "function" then
				local dumped = vim.inspect(string.dump(value))
				value = ("loadstring(%s)"):format(dumped)
			else
				value = vim.inspect(value)
			end

			self:prevent_hanging(short_name)
			self.api.nvim_exec_lua(("%s = %s"):format(obj_name, value), {})
		end,
	})
end

-- Convenience wrappers
function VimProcess:type_keys(wait, ...)
	self:ensure_running()

	local has_wait = type(wait) == "number"
	---@type table
	local keys = has_wait and { ... } or { wait, ... }
	keys = H.tbl_flatten(keys)

	-- From `nvim_input` docs: "On execution error: does not fail, but
	-- updates v:errmsg.". So capture it manually. NOTE: Have it global to
	-- allow sending keys which will block in the middle (like `[[<C-\>]]` and
	-- `<C-n>`). Otherwise, later check will assume that there was an error.
	---@type string
	local cur_errmsg
	for _, k in
		ipairs(keys --[[ @as string[] ]])
	do
		if type(k) ~= "string" then
			error("In `type_keys()` each argument should be either string or array of strings.")
		end

		-- But do that only if Neovim is not "blocked". Otherwise, usage of
		-- `child.v` will block execution.
		if not self:is_blocked() then
			cur_errmsg = self.v.errmsg
			self.v.errmsg = ""
		end

		-- Need to escape bare `<` (see `:h nvim_input`)
		self.api.nvim_input(k == "<" and "<LT>" or k)

		-- Possibly throw error manually
		if not self.is_blocked() then
			if self.v.errmsg ~= "" then
				error(self.v.errmsg, 2)
			else
				self.v.errmsg = cur_errmsg or ""
			end
		end

		-- Possibly wait
		if has_wait and wait > 0 then
			uv.sleep(wait)
		end
	end
end

function VimProcess:cmd(str)
	self:ensure_running()
	self:prevent_hanging("cmd")
	return self.api.nvim_exec(str, false)
end

function VimProcess:cmd_capture(str)
	self:ensure_running()
	self:prevent_hanging("cmd_capture")
	return self.api.nvim_exec(str, true)
end

function VimProcess:lua(str, args)
	self:ensure_running()
	self:prevent_hanging("lua")
	return self.api.nvim_exec_lua(str, args or {})
end

function VimProcess:lua_notify(str, args)
	self:ensure_running()
	return self.api_notify.nvim_exec_lua(str, args or {})
end

function VimProcess:lua_get(str, args)
	self:ensure_running()
	self:prevent_hanging("lua_get")
	return self.api.nvim_exec_lua("return " .. str, args or {})
end

function VimProcess:lua_func(f, ...)
	self:ensure_running()
	self:prevent_hanging("lua_func")
	return self.api.nvim_exec_lua(
		"local f = ...; return assert(loadstring(f))(select(2, ...))",
		{ string.dump(f), ... }
	)
end

function VimProcess:is_blocked()
	self:ensure_running()
	return self.api.nvim_get_mode()["blocking"]
end

function VimProcess:is_running()
	return self.job ~= nil
end

-- Various wrappers
function VimProcess:ensure_normal_mode()
	self:ensure_running()
	self.type_keys([[<C-\>]], "<C-n>")
end

return M

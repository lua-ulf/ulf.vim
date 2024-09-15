---@class ulf.vim.project_root
---@overload fun(): string
local M = setmetatable({}, {
	__call = function(m)
		return m.get()
	end,
})

local uv = vim and uv or require("luv")
local tbl_contains = vim.tbl_contains
local tbl_filter = vim.tbl_filter
local uri_to_fname = vim.uri_to_fname
local is_win = LazyVim.is_win
local fs = {}
fs.dirname = vim.fs.dirname
fs.find = vim.fs.find

local pesc = vim.pesc
local Vim = {
	api = {},
	g = {},
}
Vim.api.nvim_buf_get_name = vim.api.nvim_buf_get_name
Vim.g.root_spec = vim.g.root_spec
Vim.api.nvim_get_current_buf = vim.api.nvim_get_current_buf
Vim.fn.fnamemodify = vim.fn.fnamemodify
Vim.api.nvim_create_user_command = vim.api.nvim_create_user_command
Vim.api.nvim_create_augroup = vim.api.nvim_create_augroup
Vim.inspect = vim.inspect
Vim.api.nvim_create_autocmd = vim.api.nvim_create_autocmd

local Path = require("ulf.lib.path")
local Lsp = LazyVim.lsp

---@class ulf.vim.project_root.LazyRoot
---@field paths string[]
---@field spec ulf.vim.project_root.LazyRootSpec

---@alias ulf.vim.project_root.LazyRootFn fun(buf: number): (string|string[])

---@alias ulf.vim.project_root.LazyRootSpec string|string[]|ulf.vim.project_root.LazyRootFn

---@type ulf.vim.project_root.LazyRootSpec[]
M.spec = { "lsp", { ".git", "lua" }, "cwd" }

M.detectors = {}

function M.detectors.cwd()
	return { uv.cwd() }
end

function M.detectors.lsp(buf)
	local bufpath = M.bufpath(buf)
	if not bufpath then
		return {}
	end
	local roots = {} ---@type string[]
	for _, client in pairs(Lsp.get_clients({ bufnr = buf })) do
		local workspace = client.config.workspace_folders
		for _, ws in pairs(workspace or {}) do
			roots[#roots + 1] = uri_to_fname(ws.uri)
		end
		if client.root_dir then
			roots[#roots + 1] = client.root_dir
		end
	end
	return tbl_filter(
		---@param path string
		function(path)
			---@type string
			path = Path.norm(path)
			return path and bufpath:find(path, 1, true) == 1
		end,
		roots
	)
end

---@param patterns string[]|string
function M.detectors.pattern(buf, patterns)
	patterns = type(patterns) == "string" and { patterns } or patterns
	local path = M.bufpath(buf) or uv.cwd()
	local pattern = fs.find(function(name)
		for _, p in ipairs(patterns) do
			if name == p then
				return true
			end
			if p:sub(1, 1) == "*" and name:find(pesc(p:sub(2)) .. "$") then
				return true
			end
		end
		return false
	end, { path = path, upward = true })[1]
	return pattern and { fs.dirname(pattern) } or {}
end

function M.bufpath(buf)
	return M.realpath(Vim.api.nvim_buf_get_name(assert(buf)))
end

function M.cwd()
	return M.realpath(uv.cwd()) or ""
end

function M.realpath(path)
	if path == "" or path == nil then
		return nil
	end
	path = uv.fs_realpath(path) or path
	return Path.norm(path)
end

---@param spec ulf.vim.project_root.LazyRootSpec
---@return ulf.vim.project_root.LazyRootFn
function M.resolve(spec)
	if M.detectors[spec] then
		return M.detectors[spec]
	elseif type(spec) == "function" then
		return spec
	end
	return function(buf)
		return M.detectors.pattern(buf, spec)
	end
end

---@param opts? { buf?: number, spec?: ulf.vim.project_root.LazyRootSpec[], all?: boolean }
function M.detect(opts)
	opts = opts or {}
	opts.spec = opts.spec or type(Vim.g.root_spec) == "table" and Vim.g.root_spec or M.spec
	opts.buf = (opts.buf == nil or opts.buf == 0) and Vim.api.nvim_get_current_buf() or opts.buf

	local ret = {} ---@type ulf.vim.project_root.LazyRoot[]
	for _, spec in ipairs(opts.spec) do
		local paths = M.resolve(spec)(opts.buf)
		paths = paths or {}
		paths = type(paths) == "table" and paths or { paths }
		local roots = {} ---@type string[]
		for _, p in ipairs(paths) do
			local pp = M.realpath(p)
			if pp and not tbl_contains(roots, pp) then
				roots[#roots + 1] = pp
			end
		end
		table.sort(roots, function(a, b)
			return #a > #b
		end)
		if #roots > 0 then
			ret[#ret + 1] = { spec = spec, paths = roots }
			if opts.all == false then
				break
			end
		end
	end
	return ret
end

function M.info()
	local spec = type(Vim.g.root_spec) == "table" and Vim.g.root_spec or M.spec

	local roots = M.detect({ all = true })
	local lines = {} ---@type string[]
	local first = true
	for _, root in ipairs(roots) do
		for _, path in ipairs(root.paths) do
			lines[#lines + 1] = ("- [%s] `%s` **(%s)**"):format(
				first and "x" or " ",
				path,
				type(root.spec) == "table" and table.concat(root.spec, ", ") or root.spec
			)
			first = false
		end
	end
	lines[#lines + 1] = "```lua"
	lines[#lines + 1] = "vim.g.root_spec = " .. Vim.inspect(spec)
	lines[#lines + 1] = "```"
	LazyVim.info(lines, { title = "LazyVim Roots" })
	return roots[1] and roots[1].paths[1] or uv.cwd()
end

---@type table<number, string>
M.cache = {}

function M.setup()
	Vim.api.nvim_create_user_command("UlfLazyRoot", function()
		require("ulf.vim.project_root").info()
		LazyVim.root.info()
	end, { desc = "UlfLazyVim roots for the current buffer" })

	-- FIX: doesn't properly clear cache in neo-tree `set_root` (which should happen presumably on `DirChanged`),
	-- probably because the event is triggered in the neo-tree buffer, therefore add `BufEnter`
	-- Maybe this is too frequent on `BufEnter` and something else should be done instead??
	Vim.api.nvim_create_autocmd({ "LspAttach", "BufWritePost", "DirChanged", "BufEnter" }, {
		group = Vim.api.nvim_create_augroup("lazyvim_root_cache", { clear = true }),
		callback = function(event)
			M.cache[event.buf] = nil
		end,
	})
end

-- returns the root directory based on:
-- * lsp workspace folders
-- * lsp root_dir
-- * root pattern of filename of the current buffer
-- * root pattern of cwd
---@param opts? {normalize?:boolean, buf?:number}
---@return string
function M.get(opts)
	opts = opts or {}
	local buf = opts.buf or Vim.api.nvim_get_current_buf()
	local ret = M.cache[buf]
	if not ret then
		local roots = M.detect({ all = false, buf = buf })
		ret = roots[1] and roots[1].paths[1] or uv.cwd()
		M.cache[buf] = ret
	end
	if opts and opts.normalize then
		return ret
	end
	return is_win() and ret:gsub("/", "\\") or ret
end

function M.git()
	local root = M.get()
	local git_root = fs.find(".git", { path = root, upward = true })[1]
	local ret = git_root and Vim.fn.fnamemodify(git_root, ":h") or root
	return ret
end

---@param opts? {hl_last?: string}
function M.pretty_path(opts)
	return ""
end

return M

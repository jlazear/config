local async = require('gitsigns.async')
local void = require('gitsigns.async').void
local scheduler = require('gitsigns.async').scheduler

local Status     = require("gitsigns.status")
local git        = require('gitsigns.git')
local manager    = require('gitsigns.manager')
local util       = require('gitsigns.util')
local hl         = require('gitsigns.highlight')

local gs_cache   = require('gitsigns.cache')
local cache      = gs_cache.cache
local CacheEntry = gs_cache.CacheEntry

local gs_config  = require('gitsigns.config')
local Config     = gs_config.Config
local config     = gs_config.config

local gs_debug   = require("gitsigns.debug")
local dprintf    = gs_debug.dprintf
local dprint     = gs_debug.dprint

local Debounce          = require("gitsigns.debounce")
local debounce_trailing = Debounce.debounce_trailing
local throttle_by_id    = Debounce.throttle_by_id

local api = vim.api
local uv = vim.loop
local current_buf = api.nvim_get_current_buf

local record M
  setup      : function(cfg: Config)
  detach     : function(bufnr: integer, _keep_signs: boolean)
  detach_all : function()
  attach     : function(cbuf: integer, ctx: GitContext, trigger: string)

  record GitContext
    toplevel: string
    gitdir: string
    file: string
    commit: string
    base: string
  end
end

local GitContext = M.GitContext

--- Detach Gitsigns from all buffers it is attached to.
function M.detach_all()
  for k, _ in pairs(cache as {integer:CacheEntry}) do
    M.detach(k)
  end
end

--- Detach Gitsigns from the buffer {bufnr}. If {bufnr} is not
--- provided then the current buffer is used.
---
--- Parameters: ~
---     {bufnr}  (number): Buffer number
function M.detach(bufnr: integer, _keep_signs: boolean)
  -- When this is called interactively (with no arguments) we want to remove all
  -- the signs, however if called via a detach event (due to nvim_buf_attach)
  -- then we don't want to clear the signs in case the buffer is just being
  -- updated due to the file externally changing. When this happens a detach and
  -- attach event happen in sequence and so we keep the old signs to stop the
  -- sign column width moving about between updates.
  bufnr = bufnr or current_buf()
  dprint('Detached')
  local bcache = cache[bufnr]
  if not bcache then
    dprint('Cache was nil')
    return
  end

  manager.detach(bufnr, _keep_signs)

  -- Clear status variables
  Status:clear(bufnr)

  cache:destroy(bufnr)
end

-- @return (string, string) Tuple of buffer name and commit
local function parse_fugitive_uri(name: string): string, string
  if vim.fn.exists('*FugitiveReal') == 0 then
    dprint("Fugitive not installed")
    return
  end

  local path = vim.fn.FugitiveReal(name)
  local commit = vim.fn.FugitiveParse(name)[1]:match('([^:]+):.*')
  if commit == '0' then
    -- '0' means the index so clear commit so we attach normally
    commit = nil
  end
  return path, commit
end

local function parse_gitsigns_uri(name: string): string, string
  -- TODO(lewis6991): Support submodules
  local _, _, root_path, commit, rel_path =
    name:find([[^gitsigns://(.*)/%.git/(.*):(.*)]])
  if commit == ':0' then
    -- ':0' means the index so clear commit so we attach normally
    commit = nil
  end
  if root_path then
    name = root_path .. '/' .. rel_path
  end
  return name, commit
end

local function get_buf_path(bufnr: integer): string, string
  local file =
    uv.fs_realpath(api.nvim_buf_get_name(bufnr))
      or
    api.nvim_buf_call(bufnr, function(): string
      return vim.fn.expand('%:p')
    end)

  if not vim.wo.diff then
    if vim.startswith(file, 'fugitive://') then
      local path, commit = parse_fugitive_uri(file)
      dprintf("Fugitive buffer for file '%s' from path '%s'", path, file)
      path = uv.fs_realpath(path)
      if path then
        return path, commit
      end
    end

    if vim.startswith(file, 'gitsigns://') then
      local path, commit = parse_gitsigns_uri(file)
      dprintf("Gitsigns buffer for file '%s' from path '%s'", path, file)
      path = uv.fs_realpath(path)
      if path then
        return path, commit
      end
    end
  end

  return file
end

local vimgrep_running = false

local function on_lines(_, bufnr: integer, _, first: integer, last_orig: integer, last_new: integer, byte_count: integer): boolean
  if first == last_orig and last_orig == last_new and byte_count == 0 then
    -- on_lines can be called twice for undo events; ignore the second
    -- call which indicates no changes.
    return
  end
  return manager.on_lines(bufnr, first, last_orig, last_new)
end

local function on_reload(_, bufnr: integer)
  local __FUNC__ = 'on_reload'
  dprint('Reload')
  manager.update_debounced(bufnr)
end

local function on_detach(_, bufnr: integer)
  M.detach(bufnr, true)
end

local function on_attach_pre(bufnr: integer): string, string
  local gitdir, toplevel: string, string
  if config._on_attach_pre then
    local res: any = async.wrap(config._on_attach_pre, 2)(bufnr)
    dprintf('ran on_attach_pre with result %s', vim.inspect(res))
    if res is table then
      if type(res.gitdir) == 'string' then
        gitdir = res.gitdir as string
      end
      if type(res.toplevel) == 'string' then
        toplevel = res.toplevel as string
      end
    end
  end
  return gitdir, toplevel
end

local function try_worktrees(_bufnr: integer, file: string, encoding: string): git.Obj
  if not config.worktrees then
    return
  end

  for _, wt in ipairs(config.worktrees) do
    local git_obj = git.Obj.new(file, encoding, wt.gitdir, wt.toplevel)
    if git_obj and git_obj.object_name then
      dprintf('Using worktree %s', vim.inspect(wt))
      return git_obj
    end
  end
end

-- Ensure attaches cannot be interleaved.
-- Since attaches are asynchronous we need to make sure an attach isn't
-- performed whilst another one is in progress.
local attach_throttled = throttle_by_id(function(cbuf: integer, ctx: GitContext, aucmd: string)
  local __FUNC__ = 'attach'
  if vimgrep_running then
    dprint('attaching is disabled')
    return
  end

  if cache[cbuf] then
    dprint('Already attached')
    return
  end

  if aucmd then
    dprintf('Attaching (trigger=%s)', aucmd)
  else
    dprint('Attaching')
  end

  if not api.nvim_buf_is_loaded(cbuf) then
    dprint('Non-loaded buffer')
    return
  end

  local encoding = vim.bo[cbuf].fileencoding
  if encoding == '' then
    encoding = 'utf-8'
  end
  local file: string
  local commit: string
  local gitdir_oap: string
  local toplevel_oap: string

  if ctx then
    gitdir_oap = ctx.gitdir
    toplevel_oap = ctx.toplevel
    file = ctx.toplevel .. util.path_sep .. ctx.file
    commit = ctx.commit
  else
    if api.nvim_buf_line_count(cbuf) > config.max_file_length then
      dprint('Exceeds max_file_length')
      return
    end

    if vim.bo[cbuf].buftype ~= '' then
      dprint('Non-normal buffer')
      return
    end

    file, commit = get_buf_path(cbuf)
    local file_dir = util.dirname(file)

    if not file_dir or not util.path_exists(file_dir) then
      dprint('Not a path')
      return
    end

    gitdir_oap, toplevel_oap = on_attach_pre(cbuf)
  end

  local git_obj = git.Obj.new(file, encoding, gitdir_oap, toplevel_oap)

  if not git_obj and not ctx then
    git_obj = try_worktrees(cbuf, file, encoding)
    scheduler()
  end

  if not git_obj then
    dprint('Empty git obj')
    return
  end
  local repo = git_obj.repo

  scheduler()
  Status:update(cbuf, {
    head   = repo.abbrev_head,
    root   = repo.toplevel,
    gitdir = repo.gitdir,
  })

  if vim.startswith(file, repo.gitdir..util.path_sep) then
    dprint('In non-standard git dir')
    return
  end

  if not ctx and (not util.path_exists(file) or uv.fs_stat(file).type == 'directory') then
    dprint('Not a file')
    return
  end

  if not git_obj.relpath then
    dprint('Cannot resolve file in repo')
    return
  end

  if not config.attach_to_untracked and git_obj.object_name == nil then
    dprint('File is untracked')
    return
  end

  -- On windows os.tmpname() crashes in callback threads so initialise this
  -- variable on the main thread.
  scheduler()

  if config.on_attach and config.on_attach(cbuf) == false then
    dprint('User on_attach() returned false')
    return
  end

  cache[cbuf] = CacheEntry.new {
    base           = ctx and ctx.base or config.base,
    file           = file,
    commit         = commit,
    gitdir_watcher = manager.watch_gitdir(cbuf, repo.gitdir),
    git_obj        = git_obj
  }

  if not api.nvim_buf_is_loaded(cbuf) then
    dprint('Un-loaded buffer')
    return
  end

  -- Make sure to attach before the first update (which is async) so we pick up
  -- changes from BufReadCmd.
  api.nvim_buf_attach(cbuf, false, {
    on_lines  = on_lines,
    on_reload = on_reload,
    on_detach = on_detach
  })

  -- Initial update
  manager.update(cbuf, cache[cbuf])

  if config.keymaps and not vim.tbl_isempty(config.keymaps) then
    require('gitsigns.mappings')(config.keymaps as {string:any}, cbuf)
  end
end)

--- Attach Gitsigns to the buffer.
---
--- Attributes: ~
---     {async}
---
--- Parameters: ~
---     {bufnr}  (number): Buffer number
---     {ctx}    (table|nil):
---              Git context data that may optionally be used to attach to any
---              buffer that represents a real git object.
---              • {file}: (string)
---                Path to the file represented by the buffer, relative to the
---                top-level.
---              • {toplevel}: (string)
---                Path to the top-level of the parent git repository.
---              • {gitdir}: (string)
---                Path to the git directory of the parent git repository
---                (typically the ".git/" directory).
---              • {commit}: (string)
---                The git revision that the file belongs to.
---              • {base}: (string|nil)
---                The git revision that the file should be compared to.
M.attach = void(function(bufnr: integer, ctx: GitContext, _trigger: string)
  attach_throttled(bufnr or current_buf(), ctx, _trigger)
end)

local function setup_cli()
  local funcs = M as {string:function}
  api.nvim_create_user_command('Gitsigns', function(params: api.UserCmdParams)
    require'gitsigns.cli'.run(funcs, params)
  end, {
    force = true,
    nargs = '*',
    range = true,
    complete = function(arglead: string, line: string): {string}
      return require'gitsigns.cli'.complete(funcs, arglead, line)
    end})
end

local function wrap_func(fn: function, ...: any): function()
  local args = {...}
  local nargs = select('#', ...)
  return function()
    fn(unpack(args, 1, nargs))
  end
end

local function autocmd(event: string, opts: function|vim.api.AutoCmdOpts)
  local opts0: vim.api.AutoCmdOpts = {}
  if opts is function then
    opts0.callback = wrap_func(opts)
  else
    opts0 = opts
  end
  opts0.group = 'gitsigns'
  api.nvim_create_autocmd(event, opts0)
end

local function on_or_after_vimenter(fn: function)
  if vim.v.vim_did_enter == 1 then
    fn()
  else
    api.nvim_create_autocmd('VimEnter', {
      callback = wrap_func(fn),
      once = true
    })
  end
end

--- Setup and start Gitsigns.
---
--- Attributes: ~
---     {async}
---
--- Parameters: ~
---     {cfg} Table object containing configuration for
---     Gitsigns. See |gitsigns-usage| for more details.
M.setup = void(function(cfg: Config)
  gs_config.build(cfg)

  if vim.fn.executable('git') == 0 then
    print('gitsigns: git not in path. Aborting setup')
    return
  end
  if config.yadm.enable and vim.fn.executable('yadm') == 0 then
    print("gitsigns: yadm not in path. Ignoring 'yadm.enable' in config")
    config.yadm.enable = false
    return
  end

  gs_debug.debug_mode = config.debug_mode
  gs_debug.verbose = config._verbose

  if config.debug_mode then
    for nm, f in pairs(gs_debug.add_debug_functions(cache)) do
      (M as {string:function})[nm] = f
    end
  end

  manager.setup()

  Status.formatter = config.status_formatter as function(Status.StatusObj): string

  -- Make sure highlights are setup on or after VimEnter so the colorscheme is
  -- loaded. Do not set them up with vim.schedule as this removes the intro
  -- message.
  on_or_after_vimenter(hl.setup_highlights)

  setup_cli()

  git.enable_yadm = config.yadm.enable
  git.set_version(config._git_version)
  scheduler()

  -- Attach to all open buffers
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if    api.nvim_buf_is_loaded(buf)
      and api.nvim_buf_get_name(buf) ~= '' then
      M.attach(buf, nil, 'setup')
      scheduler()
    end
  end

  api.nvim_create_augroup('gitsigns', {})

  autocmd('VimLeavePre' , M.detach_all)
  autocmd('ColorScheme' , hl.setup_highlights)
  autocmd('BufRead'     , wrap_func(M.attach, nil, nil, 'BufRead'))
  autocmd('BufNewFile'  , wrap_func(M.attach, nil, nil, 'BufNewFile'))
  autocmd('BufWritePost', wrap_func(M.attach, nil, nil, 'BufWritePost'))

  autocmd('OptionSet', {
    pattern = 'fileformat',
    callback = function()
      require('gitsigns.actions').refresh()
    end}
  )

  -- vimpgrep creates and deletes lots of buffers so attaching to each one will
  -- waste lots of resource and even slow down vimgrep.
  autocmd('QuickFixCmdPre', {
    pattern ='*vimgrep*',
    callback = function()
      vimgrep_running = true
    end
  })

  autocmd('QuickFixCmdPost', {
    pattern ='*vimgrep*',
    callback = function()
      vimgrep_running = false
    end
  })

  require('gitsigns.current_line_blame').setup()

  scheduler()
  manager.update_cwd_head()
  -- Need to debounce in case some plugin changes the cwd too often
  -- (like vim-grepper)
  autocmd('DirChanged', debounce_trailing(100, manager.update_cwd_head))
end)

return setmetatable(M, {
  __index = function(_, f: string): any
    return (require('gitsigns.actions') as {string:function})[f]
  end
})

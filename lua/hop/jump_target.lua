-- Jump targets.
--
-- Jump targets are locations in buffers where users might jump to. They are wrapped in a table and provide the
-- required information so that Hop can associate label and display the hints.
--
-- {
--   jump_targets = {},
--   indirect_jump_targets = {},
-- }
--
-- The `jump_targets` field is a list-table of jump targets. A single jump target is simply a location in a given
-- buffer. So you can picture a jump target as a triple (line, column, window).
--
-- {
--   line = 0,
--   column = 0,
--   window = 0,
-- }
--
-- Indirect jump targets are encoded as a flat list-table of pairs (index, score). This table allows to quickly score
-- and sort jump targets. The `index` field gives the index in the `jump_targets` list. The `score` is any number. The
-- rule is that the lower the score is, the less prioritized the jump target will be.
--
-- {
--   index = 0,
--   score = 0,
-- }
--
-- So for instance, for two jump targets, a jump target generator must return such a table:
--
-- {
--   jump_targets = {
--     { line = 1, column = 14, buffer = 0, window = 0 },
--     { line = 2, column = 1, buffer = 0, window = 0 },
--   },
--
--   indirect_jump_targets = {
--     { index = 0, score = 14 },
--     { index = 1, score = 7 },
--   },
-- }
--
-- This is everything you need to know to extend Hop with your own jump targets.

local hint = require'hop.hint'
local window = require'hop.window'
local mappings = require'hop.mappings'

local M = {}

-- Manhattan distance with column and row, weighted on x so that results are more packed on y.
function M.manh_dist(a, b, x_bias)
  local bias = x_bias or 10
  return bias * math.abs(b[1] - a[1]) + math.abs(b[2] - a[2])
end

-- Return the character index of col position in line
-- col index is 1-based in cell, char index returned is 0-based
local function str_col2char(line, col)
  if col <= 0 then
    return 0
  end

  local lw = vim.fn.strdisplaywidth(line)
  local lc = vim.fn.strchars(line)
  -- No multi-byte character
  if lw == lc then
    return col
  end
  -- Line is shorter than col, all line should include
  if lw <= col then
    return lc
  end

  local lst
  if lc >= col then
    -- Line is very long
    lst = vim.fn.split(vim.fn.strcharpart(line, 0, col), '\\zs')
  else
    lst = vim.fn.split(line, '\\zs')
  end
  local i = 0
  local w = 0
  repeat
    i = i + 1
    w = w + vim.fn.strdisplaywidth(lst[i])
  until (w >= col)
  return i
end

-- Mark the current line with jump targets.
--
-- Returns the jump targets as described above.
local function mark_jump_targets_line(buf_handle, win_context, line_context, regex, direction, hint_position)
  local jump_targets = {}
  local end_index = nil

  if win_context.win_width ~= nil then
    end_index = win_context.col_offset + win_context.win_width
  else
    end_index = vim.fn.strdisplaywidth(line_context.line)
  end

  -- Handle shifted_line with str_col2char for multiple-bytes chars
  local left_idx = str_col2char(line_context.line, win_context.col_offset)
  local right_idx = str_col2char(line_context.line, end_index)
  local shifted_line = vim.fn.strcharpart(line_context.line, left_idx, right_idx - left_idx)
  local col_bias = vim.fn.byteidx(line_context.line, left_idx)

  -- modify the shifted line to take the direction mode into account, if any
  -- FIXME: we also need to do that for the cursor
  if direction == hint.HintDirection.AFTER_CURSOR then
    -- we want to change the start offset so that we ignore everything before the cursor
    shifted_line = shifted_line:sub(win_context.cursor_pos[2] - col_bias + 1)
    col_bias = win_context.cursor_pos[2]
  elseif direction == hint.HintDirection.BEFORE_CURSOR then
    -- we want to change the end
    shifted_line = shifted_line:sub(1, win_context.cursor_pos[2] - col_bias + 1)
  end
  if shifted_line == "" and win_context.col_offset > 0 then
    -- No possible position to place target
    return jump_targets
  end

  -- match context for regex match
  local match_context = {
    cursor_vcol = win_context.cursor_vcol,
    direction = direction,
  }

  local col = 1
  while true do
    local s = shifted_line:sub(col)
    local b, e = regex.match(s, match_context)

    if b == nil then
      break
    end
    -- Preview need a length to highlight the matched string. Zero means nothingh to highlight.
    local matched_length = e - b
    -- As the make for jump target must be placed at a cell (but some pattern like '^' is
    -- placed between cells), we should make sure e > b
    if b == e then
      e = e + 1
    end

    local colp = col + b
    if hint_position == hint.HintPosition.MIDDLE then
      colp = col + math.floor((b + e) / 2)
    elseif hint_position == hint.HintPosition.END then
      colp = col + e - 1
    end
    jump_targets[#jump_targets + 1] = {
      line = line_context.line_nr,
      column = math.max(1, colp + col_bias),
      length = math.max(0, matched_length),
      buffer = buf_handle,
      window = win_context.hwin,
    }

    if regex.oneshot then
      break
    else
      col = col + e
    end

    if col > #shifted_line then
      break
    end
  end

  return jump_targets
end

-- Create jump targets for a given indexed line.
--
-- This function creates the jump targets for the current (indexed) line and appends them to the input list of jump
-- targets `jump_targets`.
--
-- Indirect jump targets are used later to sort jump targets by score and create hints.
local function create_jump_targets_for_line(
  buf_handle,
  win_context,
  line_context,
  jump_targets,
  indirect_jump_targets,
  regex,
  direction,
  hint_position
)
  -- first, create the jump targets for the ith line
  local line_jump_targets = mark_jump_targets_line(buf_handle, win_context, line_context, regex, direction, hint_position)

  -- then, append those to the input jump target list and create the indexed jump targets
  local win_bias = math.abs(vim.api.nvim_get_current_win() - win_context.hwin) * 1000
  for _, jump_target in pairs(line_jump_targets) do
    jump_targets[#jump_targets + 1] = jump_target

    indirect_jump_targets[#indirect_jump_targets + 1] = {
      index = #jump_targets,
      score = M.manh_dist(win_context.cursor_pos, { jump_target.line, jump_target.column }) + win_bias
    }
  end
end

-- Create jump targets by scanning lines in the currently visible buffer.
--
-- This function takes a regex argument, which is an object containing a match function that must return the span
-- (inclusive beginning, exclusive end) of the match item, or nil when no more match is possible. This object also
-- contains the `oneshot` field, a boolean stating whether only the first match of a line should be taken into account.
--
-- This function returns the lined jump targets (an array of N lines, where N is the number of currently visible lines).
-- Lines without jump targets are assigned an empty table ({}). For lines with jump targets, a list-table contains the
-- jump targets as pair of { line, col }.
--
-- In addition the jump targets, this function returns the total number of jump targets (i.e. this is the same thing as
-- traversing the lined jump targets and summing the number of jump targets for all lines) as a courtesy, plus «
-- indirect jump targets. » Indirect jump targets are encoded as a flat list-table containing three values: i, for the
-- ith line, j, for the rank of the jump target, and dist, the score distance of the associated jump target. This list
-- is sorted according to that last dist parameter in order to know how to distribute the jump targets over the buffer.
function M.jump_targets_by_scanning_lines(regex)
  return function(opts)
    -- get the window context; this is used to know which part of the visible buffer is to hint
    local all_ctxs = window.get_window_context(opts.multi_windows)
    local jump_targets = {}
    local indirect_jump_targets = {}

    -- Iterate all buffers
    for _, bctx in ipairs(all_ctxs) do
      -- Iterate all windows of a same buffer
      for _, wctx in ipairs(bctx.contexts) do
        window.clip_window_context(wctx, opts.direction)
        -- Get all lines' context
        local lines = window.get_lines_context(bctx.hbuf, wctx)

        -- in the case of a direction, we want to treat the first or last line (according to the direction) differently
        if opts.direction == hint.HintDirection.AFTER_CURSOR then
          -- the first line is to be checked first
          create_jump_targets_for_line(bctx.hbuf, wctx, lines[1], jump_targets, indirect_jump_targets, regex, opts.direction, opts.hint_position)
          for i = 2, #lines do
            create_jump_targets_for_line(bctx.hbuf, wctx, lines[i], jump_targets, indirect_jump_targets, regex, nil, opts.hint_position)
          end
        elseif opts.direction == hint.HintDirection.BEFORE_CURSOR then
          -- the last line is to be checked last
          for i = 1, #lines - 1 do
            create_jump_targets_for_line(bctx.hbuf, wctx, lines[i], jump_targets, indirect_jump_targets, regex, nil, opts.hint_position)
          end
          create_jump_targets_for_line(bctx.hbuf, wctx, lines[#lines], jump_targets, indirect_jump_targets, regex, opts.direction, opts.hint_position)
        else
          for i = 1, #lines do
            create_jump_targets_for_line(bctx.hbuf, wctx, lines[i], jump_targets, indirect_jump_targets, regex, nil, opts.hint_position)
          end
        end

      end
    end

    M.sort_indirect_jump_targets(indirect_jump_targets, opts)

    return { jump_targets = jump_targets, indirect_jump_targets = indirect_jump_targets }
  end
end

-- Jump target generator for regex applied only on the cursor line.
function M.jump_targets_for_current_line(regex)
  return function(opts)
    local context = window.get_window_context(false)[1].contexts[1]
    local line_n = context.cursor_pos[1]
    local line = vim.api.nvim_buf_get_lines(0, line_n - 1, line_n, false)
    local jump_targets = {}
    local indirect_jump_targets = {}

    create_jump_targets_for_line(
      0,
      context,
      { line_nr = line_n - 1, line = line[1] },
      jump_targets,
      indirect_jump_targets,
      regex,
      opts.direction,
      opts.hint_position
    )

    M.sort_indirect_jump_targets(indirect_jump_targets, opts)

    return { jump_targets = jump_targets, indirect_jump_targets = indirect_jump_targets }
  end
end

-- Apply a score function based on the Manhattan distance to indirect jump targets.
function M.sort_indirect_jump_targets(indirect_jump_targets, opts)
  local score_comparison = nil
  if opts.reverse_distribution then
    score_comparison = function (a, b) return a.score > b.score end
  else
    score_comparison = function (a, b) return a.score < b.score end
  end

  table.sort(indirect_jump_targets, score_comparison)
end

-- Regex modes for the buffer-driven generator.
local function starts_with_uppercase(s)
  if #s == 0 then
    return false
  end

  local f = s:sub(1, vim.fn.byteidx(s, 1))
  -- if it’s a space, we assume it’s not uppercase, even though Lua doesn’t agree with us; I mean, Lua is horrible, who
  -- would like to argue with that creature, right?
  if f == ' ' then
    return false
  end

  return f:upper() == f
end

-- Regex by searching a pattern.
function M.regex_by_searching(pat, plain_search)
  if plain_search then
    pat = vim.fn.escape(pat, '\\/.$^~[]')
  end
  local re = vim.regex(pat)
  return {
    oneshot = false,
    match = function(s)
      return re:match_str(s)
    end
  }
end

-- Wrapper over M.regex_by_searching to add support for case sensitivity.
function M.regex_by_case_searching(pat, plain_search, opts)
  local pat_special = ''
  if vim.o.smartcase then
    if not starts_with_uppercase(pat) then
      pat_special = '\\c'
    end
  elseif opts.case_insensitive then
    pat_special = '\\c'
  end

  local pat_mappings = mappings.checkout(pat, opts)

  if plain_search then
    pat = vim.fn.escape(pat, '\\/.$^~[]')
  end
  if pat_mappings ~= '' then
    pat = string.format([[\(%s\)\|\(%s\)]], pat, pat_mappings)
  end
  pat = pat .. pat_special

  local re = vim.regex(pat)
  return {
    oneshot = false,
    match = function(s)
      return re:match_str(s)
    end
  }
end

-- Word regex.
function M.regex_by_word_start()
  return M.regex_by_searching('\\k\\+')
end

-- Line regex.
function M.regex_by_line_start()
  local pat = vim.regex("^")
  return {
    oneshot = true,
    match = function(s)
      return pat:match_str(s)
    end
  }
end

-- Line regex skipping finding the first non-whitespace character on each line.
function M.regex_by_line_start_skip_whitespace()
  local pat = vim.regex("\\S")
  return {
    oneshot = true,
    match = function(s)
      return pat:match_str(s)
    end
  }
end

-- Column regex that targets to cursor column of line
function M.regex_by_line_cursor()
  return {
    oneshot = true,
    match = function(s, mctx)
      if mctx.direction == hint.HintDirection.AFTER_CURSOR then
        return 0, 1
      end
      local idx = str_col2char(s, mctx.cursor_vcol)
      local col = vim.fn.byteidx(s, idx)
      if -1 < col and col < #s then
        return col, col + 1
      end
    end
  }
end

-- Anywhere regex.
function M.regex_by_anywhere()
  return M.regex_by_searching('\\v(<.|^$)|(.>|^$)|(\\l)\\zs(\\u)|(_\\zs.)|(#\\zs.)')
end

return M

-- nursor: parsing cursor-agent tool_call events and presenting file changes
-- (inline unified-diff hunks + a side-by-side diff view).
local M = {}

function M.relpath(p)
  if not p or p == "" then
    return "?"
  end
  local rel = vim.fn.fnamemodify(p, ":.")
  return rel ~= "" and rel or p
end

-- A tool_call event carries a single keyed payload, e.g.
--   obj.tool_call = { editToolCall = { args = {...}, result = {...} } }
-- Returns name (string) and payload (table) or nil.
function M.parse_tool(obj)
  local tc = obj.tool_call
  if type(tc) ~= "table" then
    return nil
  end
  -- The payload sits alongside bookkeeping keys (toolCallId,
  -- hookAdditionalContexts, startedAtMs, ...). The tool entry is the one whose
  -- key ends in "ToolCall" and whose value is a table.
  for k, v in pairs(tc) do
    if type(k) == "string" and k:match("ToolCall$") and type(v) == "table" then
      return k, v
    end
  end
  return nil
end

-- Short human label for the tool (strips the trailing "ToolCall").
function M.short_name(name)
  return (name or "tool"):gsub("ToolCall$", "")
end

-- Build a change table from an edit-like tool payload, or nil if this tool
-- did not modify a file.
function M.change_from_payload(name, payload)
  local res = payload and payload.result
  local success = res and res.success
  if type(success) ~= "table" then
    return nil
  end
  if not (success.diffString or success.afterFullFileContent) then
    return nil
  end
  local path = success.path or (payload.args and payload.args.path)
  return {
    tool = M.short_name(name),
    path = path,
    rel = M.relpath(path),
    diff = success.diffString,
    before = success.beforeFullFileContent,
    after = success.afterFullFileContent,
    added = success.linesAdded,
    removed = success.linesRemoved,
  }
end

-- A one-line summary for non-edit tools (read/ls/grep/shell/...).
function M.tool_summary(name, payload)
  local short = M.short_name(name)
  local args = (payload and payload.args) or {}
  if args.path then
    return short .. " " .. M.relpath(args.path)
  end
  if args.command then
    return short .. ": " .. tostring(args.command)
  end
  if args.query then
    return short .. ": " .. tostring(args.query)
  end
  if args.target_file then
    return short .. " " .. M.relpath(args.target_file)
  end
  return short
end

-- Hunk lines from a unified diff, dropping the ---/+++ file headers.
function M.diff_hunks(diffstr)
  local out = {}
  for _, l in ipairs(vim.split(diffstr or "", "\n", { plain = true })) do
    if not (l:match("^%-%-%- ") or l:match("^%+%+%+ ")) then
      table.insert(out, l)
    end
  end
  return out
end

-- Open a side-by-side diff: the agent's pre-edit content (left) vs the file as
-- it is now on disk (right). Falls back to the captured "after" content when
-- the file is not readable.
function M.show(change)
  if not change then
    return
  end

  vim.cmd("tabnew")
  if change.path and vim.fn.filereadable(change.path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(change.path))
  else
    local after = vim.split(change.after or "", "\n", { plain = true })
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, after)
    vim.bo[b].buftype = "nofile"
    pcall(vim.api.nvim_buf_set_name, b, "nursor://after/" .. (change.rel or "file"))
  end
  vim.cmd("diffthis")
  local ft = vim.bo.filetype

  -- Left pane: the captured "before" content as a read-only scratch buffer.
  vim.cmd("leftabove vnew")
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(change.before or "", "\n", { plain = true }))
  vim.bo[b].modifiable = false
  if ft and ft ~= "" then
    vim.bo[b].filetype = ft
  end
  pcall(vim.api.nvim_buf_set_name, b, "nursor://before/" .. (change.rel or "file"))
  vim.cmd("diffthis")
end

return M

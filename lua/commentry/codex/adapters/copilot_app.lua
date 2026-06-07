--- copilot_app adapter for commentry.nvim
--- Sends review comments to the GitHub Copilot App via WebSocket bridge.
--- Drop-in replacement for the sidekick adapter.

local Adapter = require("commentry.codex.adapter")

local M = {}

local uv = vim.uv or vim.loop

-- ──────────────────────────── state ────────────────────────────

local bridge_job = nil
local connected = false
local workspaces = {} -- raw workspace list from app
local resolved_ws = nil -- matched workspace { id, name, path, session? }
local session_id = nil -- active session for resolved workspace
local stdout_buf = ""
local pending_callbacks = {} -- type → callback for request/response pairs
local on_reply_cb = nil -- callback for incoming agent replies

-- ──────────────────────────── bridge lifecycle ────────────────────────────

local function bridge_script_path()
  local info = debug.getinfo(1, "S")
  local src = info.source:sub(2)
  -- adapters/copilot_app.lua → adapters/ → codex/ → commentry/ → lua/ → plugin root
  local plugin_root = vim.fn.fnamemodify(src, ":h:h:h:h:h")
  return plugin_root .. "/bridge.mjs"
end

local function send_ws(msg)
  if not bridge_job then
    return false
  end
  local json = vim.json.encode(msg)
  vim.fn.chansend(bridge_job, json .. "\n")
  return true
end

local function handle_message(msg)
  local t = msg.type

  if t == "__connected" then
    connected = true
    send_ws({ type = "list_workspaces" })
    return
  end

  if t == "__error" then
    vim.schedule(function()
      vim.notify("[copilot-app] " .. (msg.message or "bridge error"), vim.log.levels.ERROR)
    end)
    return
  end

  if t == "workspace_list" then
    workspaces = msg.workspaces or {}
    vim.schedule(function()
      M._resolve_workspace()
    end)
    return
  end

  if t == "workspace_session" then
    local s = msg.session
    if s then
      session_id = s.sessionId or s.session_id
    end
    local cb = pending_callbacks["workspace_session"]
    if cb then
      pending_callbacks["workspace_session"] = nil
      vim.schedule(function()
        cb(session_id)
      end)
    end
    return
  end

  if t == "inline_review_reply_saved" then
    local reply = msg.reply
    if on_reply_cb then
      vim.schedule(function()
        on_reply_cb(reply)
      end)
    else
      -- Default: show notification
      vim.schedule(function()
        local text = type(reply) == "table" and reply.text or "(no text)"
        local preview = #text > 120 and text:sub(1, 117) .. "..." or text
        vim.notify("[copilot-app] Agent replied: " .. preview, vim.log.levels.INFO)
      end)
    end
    return
  end
end

local function on_stdout(_, data, _)
  if not data or #data == 0 then
    return
  end
  -- Neovim splits on newlines: data = { "partial", "line2", "line3", "" }
  -- data[1] completes the previous incomplete line in stdout_buf.
  -- data[2..n] are new line starts. An empty trailing element means the
  -- prior element ended with a newline (complete line).
  stdout_buf = stdout_buf .. data[1]
  for i = 2, #data do
    if stdout_buf ~= "" then
      local ok, msg = pcall(vim.json.decode, stdout_buf)
      if ok then
        handle_message(msg)
      end
    end
    stdout_buf = data[i]
  end
end

local function on_stderr(_, data, _)
  for _, line in ipairs(data) do
    if line ~= "" and (line:match("error") or line:match("cannot")) then
      vim.schedule(function()
        vim.notify("[copilot-app] " .. line, vim.log.levels.ERROR)
      end)
    end
  end
end

local function on_exit(_, code, _)
  bridge_job = nil
  connected = false
  stdout_buf = ""
  session_id = nil
  resolved_ws = nil
  if code ~= 0 then
    vim.schedule(function()
      vim.notify("[copilot-app] bridge exited (" .. code .. ")", vim.log.levels.WARN)
    end)
  end
end

function M.connect(opts)
  opts = opts or {}
  if bridge_job then
    return
  end

  local node = opts.node or "node"
  local script = bridge_script_path()

  bridge_job = vim.fn.jobstart({ node, script }, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if bridge_job <= 0 then
    bridge_job = nil
    vim.notify("[copilot-app] failed to start bridge", vim.log.levels.ERROR)
  end
end

function M.disconnect()
  if bridge_job then
    vim.fn.jobstop(bridge_job)
    bridge_job = nil
    connected = false
    session_id = nil
    resolved_ws = nil
  end
end

function M.is_connected()
  return connected and resolved_ws ~= nil and session_id ~= nil
end

-- ──────────────────────────── workspace resolution ────────────────────────────

function M._resolve_workspace()
  local cwd = vim.fn.resolve(vim.fn.getcwd())
  local git_root = vim.fn.resolve(vim.fn.systemlist("git rev-parse --show-toplevel")[1] or cwd)

  local best, best_len = nil, 0
  for _, ws in ipairs(workspaces) do
    local p = vim.fn.resolve(ws.path or "")
    if p ~= "" then
      -- Prefer exact match, then longest prefix match
      if p == cwd or p == git_root then
        best = ws
        best_len = math.huge
      elseif best_len < math.huge then
        if vim.startswith(cwd, p .. "/") or vim.startswith(p, cwd .. "/")
            or vim.startswith(git_root, p .. "/") or vim.startswith(p, git_root .. "/") then
          if #p > best_len then
            best = ws
            best_len = #p
          end
        end
      end
    end
  end

  resolved_ws = best
  if not best then
    return
  end

  -- Try to get session from workspace_list payload
  local s = best.session
  if s then
    session_id = s.sessionId or s.session_id
  end

  if not session_id then
    send_ws({ type = "get_workspace_session", workspace_id = best.id })
  end
end

-- ──────────────────────────── helpers ────────────────────────────

local function uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end))
end

--- Get git diff context for a file around specific lines
local function get_diff_context(file_path, project_root)
  local diff = vim.fn.systemlist(
    string.format(
      "cd %s && git diff HEAD -- %s 2>/dev/null",
      vim.fn.shellescape(project_root or "."),
      vim.fn.shellescape(file_path)
    )
  )
  if diff and #diff > 0 then
    return table.concat(diff, "\n")
  end
  return "(no diff context available)"
end

--- Build a review prompt matching the app's buildInlineReviewPrompt
local function build_review_prompt(item, ws_id, project_root)
  local comment_id = item._copilot_comment_id
  local thread_id = "thread:" .. comment_id
  local thread_token = item._copilot_thread_token
  local reply_to_id = comment_id

  local line_label
  if item.line_start == item.line_end or not item.line_end then
    line_label = string.format("Line: %d", item.line_start or 1)
  else
    line_label = string.format("Lines: %d-%d", item.line_start, item.line_end)
  end

  local diff_context = get_diff_context(item.file_path or "", project_root or "")

  return string.format(
    [[[INLINE CODE REVIEW]

Address the reviewer's comments about selected lines in a diff.

Workspace ID: %s

---
Comment ID: %s
Thread ID: %s
Thread token: %s
Replying to message: %s
File: %s
%s
Type: %s

User comment:
"%s"

Selected diff:
%s

ACTION-FIRST WORKFLOW (this is your own code — you are the author):
- If the user requests a change, fix, or improvement: make the code change FIRST using your editing tools, then call reply_to_comment to summarize what you changed and why.
- If the user is asking a question or requesting clarification: answer it directly via reply_to_comment.

INSTRUCTIONS:
1. Use the exact Thread ID above; include Comment ID for compatibility.
2. Always finish by calling reply_to_comment with:
   - threadId: "%s"
   - commentId: "%s"
   - threadToken: "%s"
   - workspaceId: "%s"
   - replyToMessageId: "%s"
   - response: a summary of what you did, or your answer

Do not reply directly in chat. Always call reply_to_comment as the final step.
Pass replyToMessageId through verbatim.
After reply_to_comment returns, immediately end your turn.
]],
    ws_id or "unknown",
    comment_id,
    thread_id,
    thread_token,
    reply_to_id,
    item.file_path or "unknown",
    line_label,
    item.comment_type or "note",
    item.body or "",
    diff_context,
    thread_id,
    comment_id,
    thread_token,
    ws_id or "",
    reply_to_id
  )
end

-- ──────────────────────────── adapter interface ────────────────────────────

--- Returns the current target (session + workspace) if connected.
---@return table|nil
function M.current_target()
  if not M.is_connected() then
    return nil
  end
  return {
    session_id = session_id,
    workspace = resolved_ws and resolved_ws.id or nil,
  }
end

--- Async target resolution. Connects if needed, waits for workspace match.
---@param cb fun(target:table|nil, err_code:string|nil, err_message:string|nil)
function M.resolve_target_async(cb)
  cb = type(cb) == "function" and cb or function() end

  if M.is_connected() then
    cb({
      session_id = session_id,
      workspace = resolved_ws and resolved_ws.id or nil,
    }, nil, nil)
    return
  end

  -- Not connected — try to connect and wait
  if not bridge_job then
    M.connect()
  end

  -- Poll for connection (up to 5 seconds)
  local attempts = 0
  local timer = uv.new_timer()
  timer:start(500, 500, vim.schedule_wrap(function()
    attempts = attempts + 1
    if M.is_connected() then
      timer:stop()
      timer:close()
      cb({
        session_id = session_id,
        workspace = resolved_ws and resolved_ws.id or nil,
      }, nil, nil)
      return
    end
    if attempts >= 10 then
      timer:stop()
      timer:close()
      if not connected then
        cb(nil, "ADAPTER_UNAVAILABLE", "Could not connect to Copilot App. Is it running?")
      elseif not resolved_ws then
        cb(nil, "NO_TARGET", "No matching workspace found. Open this repo in the Copilot App.")
      elseif not session_id then
        cb(nil, "NO_TARGET", "Workspace found but no active session. Start a session in the Copilot App.")
      else
        cb(nil, "ADAPTER_UNAVAILABLE", "Connection timed out.")
      end
    end
  end))
end

--- Send review items to the Copilot App.
--- Each item gets: save_inline_review_comment + send_message (one prompt per comment).
---@param payload any
---@param target? table
---@return boolean ok, commentry.CodexError? err, table? details
function M.send(payload, target)
  if not M.is_connected() then
    return false, Adapter.error("ADAPTER_UNAVAILABLE")
  end

  if type(payload) ~= "table" then
    return false, Adapter.error("INTERNAL_ERROR")
  end

  local items = payload.items or {}
  if #items == 0 then
    return true, nil, { dispatched_items = 0 }
  end

  local ws_id = resolved_ws and resolved_ws.id or (target and target.workspace)
  local sid = session_id or (target and target.session_id)
  if not sid then
    return false, Adapter.error("NO_TARGET")
  end

  local project_root = nil
  if type(payload.context) == "table" then
    project_root = payload.context.root or payload.context.repo_root or payload.context.project_root
  end

  local now = os.date("!%Y-%m-%dT%H:%M:%S.000Z")

  for _, item in ipairs(items) do
    local comment_id = "nvim-" .. uuid()
    local thread_token = "nvim:" .. (ws_id or "") .. ":" .. uuid()

    item._copilot_comment_id = comment_id
    item._copilot_thread_token = thread_token

    -- Step 1: Save comment to the app (persists to SQLite, shows in UI)
    send_ws({
      type = "save_inline_review_comment",
      comment = {
        id = comment_id,
        workspaceId = ws_id,
        filePath = item.file_path or "",
        lineStart = item.line_start or item.line_number or 1,
        lineEnd = item.line_end or item.line_start or item.line_number or 1,
        text = item.body or "",
        createdAt = now,
        status = "investigating",
        replies = {},
        isAgentComment = false,
        severity = (item.comment_type == "issue") and "warning" or "info",
        threadToken = thread_token,
      },
    })

    -- Step 2: Send review prompt to trigger the agent (one per comment)
    local prompt = build_review_prompt(item, ws_id, project_root)
    send_ws({
      type = "send_message",
      session_id = sid,
      prompt = prompt,
      mode = "enqueue",
    })
  end

  return true, nil, { dispatched_items = #items }
end

--- Check if the adapter is available.
---@param target? table
---@return boolean
function M.available(target)
  if target then
    return type(target) == "table" and type(target.session_id) == "string" and target.session_id ~= ""
  end
  -- Check if the Copilot App's WS files exist
  local run_dir = vim.fn.expand("~/.copilot/run")
  local port_file = run_dir .. "/ws.port"
  return vim.fn.filereadable(port_file) == 1
end

--- Set a callback for incoming agent replies.
---@param cb fun(reply: table)|nil
function M.on_reply(cb)
  on_reply_cb = cb
end

--- Debug: expose internal state for troubleshooting
function M._debug()
  return {
    bridge_job = bridge_job,
    connected = connected,
    resolved_ws = resolved_ws,
    session_id = session_id,
    workspaces_count = #workspaces,
    stdout_buf_len = #stdout_buf,
  }
end

--- Clean up on VimLeavePre
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.disconnect()
  end,
})

return M

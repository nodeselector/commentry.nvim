local Adapter = require("commentry.codex.adapter")
local Comments = require("commentry.comments")
local Config = require("commentry.config")
local Diffview = require("commentry.diffview")
local Payload = require("commentry.codex.payload")

local M = {}

---@param code "NO_TARGET"|"ADAPTER_UNAVAILABLE"|"TRANSPORT_FAILED"|"INTERNAL_ERROR"
---@param message string
---@return table
local function fail(code, message)
  local canonical = Adapter.error(code)
  return {
    ok = false,
    code = canonical.code,
    message = message or canonical.message,
    retryable = canonical.retryable,
  }
end

---@param target table
---@return table
local function public_target(target)
  local copy = vim.deepcopy(target or {})
  copy.send = nil
  return copy
end

---@param payload table
---@param target table
---@param adapter_name string
---@return table
local function success(payload, target, adapter_name, details)
  local dispatched_items = #payload.items
  if type(details) == "table" and type(details.dispatched_items) == "number" then
    dispatched_items = details.dispatched_items
  end

  return {
    ok = true,
    code = "OK",
    target = public_target(target),
    adapter = adapter_name,
    dispatched_items = dispatched_items,
  }
end

---@param name string
---@return table|nil
local function load_adapter(name)
  local ok, mod = pcall(require, "commentry.codex.adapters." .. name)
  if ok and type(mod) == "table" and type(mod.send) == "function" then
    return mod
  end
  return nil
end

---@return table|nil, string|nil, "NO_TARGET"|"ADAPTER_UNAVAILABLE"|nil
local function resolve_target()
  local configured = Config.codex and Config.codex.adapter or {}
  local selected = configured.select or "auto"

  -- "auto" defaults to sidekick for backward compat
  local adapter_name = selected == "auto" and "sidekick" or selected

  local adapter_mod = load_adapter(adapter_name)
  if type(adapter_mod) ~= "table" or type(adapter_mod.send) ~= "function" then
    return nil, nil, "ADAPTER_UNAVAILABLE"
  end

  local attached = type(adapter_mod.current_target) == "function" and adapter_mod.current_target() or nil
  local target = {
    session_id = type(attached) == "table" and attached.session_id or nil,
    workspace = type(attached) == "table" and attached.workspace or nil,
    send = adapter_mod.send,
  }

  if type(target.session_id) ~= "string" or target.session_id == "" then
    return nil, nil, "NO_TARGET"
  end

  return target, adapter_name, nil
end

---@param cb fun(target:table|nil, adapter_name:string|nil, err_code:string|nil, err_message:string|nil)
local function resolve_target_async(cb)
  local configured = Config.codex and Config.codex.adapter or {}
  local selected = configured.select or "auto"

  -- "auto" defaults to sidekick for backward compat
  local adapter_name = selected == "auto" and "sidekick" or selected

  local adapter_mod = load_adapter(adapter_name)
  if type(adapter_mod) ~= "table" or type(adapter_mod.send) ~= "function" then
    cb(nil, nil, "ADAPTER_UNAVAILABLE", nil)
    return
  end

  if type(adapter_mod.resolve_target_async) == "function" then
    adapter_mod.resolve_target_async(function(attached, err_code, err_message)
      if type(attached) ~= "table" or type(attached.session_id) ~= "string" or attached.session_id == "" then
        cb(nil, nil, err_code or "NO_TARGET", err_message)
        return
      end

      cb({
        session_id = attached.session_id,
        workspace = attached.workspace,
        send = adapter_mod.send,
      }, adapter_name, nil, nil)
    end)
    return
  end

  local attached = type(adapter_mod.current_target) == "function" and adapter_mod.current_target() or nil
  local target = {
    session_id = type(attached) == "table" and attached.session_id or nil,
    workspace = type(attached) == "table" and attached.workspace or nil,
    send = adapter_mod.send,
  }
  if type(target.session_id) ~= "string" or target.session_id == "" then
    cb(nil, nil, "NO_TARGET", nil)
    return
  end
  cb(target, adapter_name, nil, nil)
end

---@param opts table
---@return table|nil, table
local function build_send_context(opts)
  local file_context = opts.file_context
  local file_err = nil
  if type(Diffview.current_file_context) ~= "function" then
    return nil, fail("INTERNAL_ERROR", "No active review context available.")
  end
  if type(file_context) ~= "table" then
    file_context, file_err = Diffview.current_file_context()
  end
  if type(file_context) ~= "table" or type(file_context.view) ~= "table" then
    return nil, fail("INTERNAL_ERROR", file_err or "No active review context available.")
  end

  local view = opts.view or file_context.view

  local review_context = opts.context
  local context_err = nil
  if type(review_context) ~= "table" and type(Diffview.resolve_review_context) == "function" then
    review_context, context_err = Diffview.resolve_review_context(opts.args, view)
  end

  local comments_context_id = nil
  if type(Comments.context_id_for_view) == "function" then
    comments_context_id = Comments.context_id_for_view(view)
  end

  if type(review_context) ~= "table" then
    return nil, fail("INTERNAL_ERROR", context_err or file_err or "No active review context available.")
  end

  local context_id = comments_context_id or review_context.context_id
  if type(context_id) ~= "string" or context_id == "" then
    return nil, fail("INTERNAL_ERROR", "No active review context available.")
  end

  local items = {}
  if type(Comments.reconcile_review) == "function" then
    Comments.reconcile_review(view)
  end
  if type(Comments.exportable_comments) == "function" then
    local exported = Comments.exportable_comments(context_id)
    if type(exported) == "table" then
      items = exported
    end
  end

  local scoped_context = vim.deepcopy(review_context)
  scoped_context.context_id = context_id

  local payload = Payload.build_payload(scoped_context, {
    review_meta = {
      mode = review_context.mode,
      revisions = review_context.revisions,
      revision_anchors = review_context.revision_anchors,
    },
    items = items,
    provenance = {
      root = review_context.root,
    },
  })

  return {
    payload = payload,
  }, nil
end

---@param opts? table
---@return table
function M.send_current_review(opts)
  opts = opts or {}
  local prepared, prep_err = build_send_context(opts)
  if not prepared then
    return prep_err
  end

  local target, adapter_name, target_err = resolve_target()
  if target == nil then
    if target_err == "ADAPTER_UNAVAILABLE" then
      return fail(
        "ADAPTER_UNAVAILABLE",
        "Codex adapter is unavailable. Ensure Sidekick runtime is installed and loaded."
      )
    end
    return fail("NO_TARGET", "No attached Codex session target available. Attach a Sidekick session and retry.")
  end

  local ok, err, details = Adapter.send(prepared.payload, target)
  if not ok then
    return {
      ok = false,
      code = err.code,
      message = err.message,
      retryable = err.retryable,
    }
  end

  return success(prepared.payload, target, adapter_name, details)
end

---@param opts? table
---@param cb? fun(result: table)
function M.send_current_review_async(opts, cb)
  opts = opts or {}
  cb = type(cb) == "function" and cb or function() end

  local prepared, prep_err = build_send_context(opts)
  if not prepared then
    cb(prep_err)
    return
  end

  resolve_target_async(function(target, adapter_name, target_err, target_message)
    if target == nil then
      if target_err == "ADAPTER_UNAVAILABLE" then
        cb(
          fail(
            "ADAPTER_UNAVAILABLE",
            target_message or "Codex adapter is unavailable. Ensure Sidekick runtime is installed and loaded."
          )
        )
        return
      end
      cb(
        fail(
          "NO_TARGET",
          target_message or "No attached Codex session target available. Attach a Sidekick session and retry."
        )
      )
      return
    end

    local ok, err, details = Adapter.send(prepared.payload, target)
    if not ok then
      cb({
        ok = false,
        code = err.code,
        message = err.message,
        retryable = err.retryable,
      })
      return
    end

    cb(success(prepared.payload, target, adapter_name or "sidekick", details))
  end)
end

return M

-- terat.lua - Ctrl+Shift+I asks a question in this pane.
--
-- Add to your Rex config:
--   dofile(os.getenv("HOME") .. "/Projects/terat/terat.lua")
--
-- Rex takes Ctrl+Shift+I before the shell sees it, so this action puts `terat`
-- into the focused pane. The prompt becomes 🟅, you ask a question, and your
-- normal prompt comes back. It uses the terminal's own API, so it needs no
-- external programs.

rex.action{
  name        = "terat",
  title       = "terat: Ask in This Terminal",
  description = "Ask one question in this pane. Empty line returns.",
  keywords    = "ask agent ai llm chat terat star",
  run = function(ctx)
    if not ctx.session_id or not ctx.block_id then
      error("no focused terminal", 0)
    end

    -- Type the command, then press Return.
    local _, err = rex.call("block.event", {
      session_id = ctx.session_id,
      block_id   = ctx.block_id,
      event      = { type = "paste", payload = { text = "terat-ask" } },
    })
    if err ~= nil then error(err, 0) end

    local _, err2 = rex.call("block.event", {
      session_id = ctx.session_id,
      block_id   = ctx.block_id,
      event      = { type = "key", payload = { key = "enter" } },
    })
    if err2 ~= nil then error(err2, 0) end
  end,
}

rex.bind("ctrl+shift+i", "terat")
rex.bind("shift+cmd+i", "terat")

-- terat.lua - the Rex half of ask mode: Cmd+Shift+I toggles it in this pane.
--
-- Add to your Rex config:
--   dofile(os.getenv("HOME") .. "/Projects/terat/terat.lua")
-- Then: rex config reload
--
-- Rex claims the key before the shell sees it, so the action tells the shell
-- directly: Ctrl-X i is a binding of its own (see terat.zsh), so nothing is
-- typed, no Return is needed, and the line you were writing is left alone. It
-- flips the mode either way, so the same key enters and leaves and Rex never
-- has to know which state the pane is in.

rex.action{
  name        = "terat",
  title       = "terat: Toggle Ask Mode",
  description = "Switch this pane in and out of ask mode: the prompt changes between ❯ and 🟅.",
  category    = "Terminal",
  keywords    = "ask agent ai llm chat terat prompt question toggle exit",

  run = function(ctx)
    if ctx.session_id == nil or ctx.block_id == nil then
      error("no focused terminal", 0)
    end

    -- Ctrl-X i, the shell's own toggle binding. Two bytes and no Return: the
    -- shell acts on the key instead of running a command, so `terat` never
    -- appears on the line, no newline is added and whatever was half-typed is
    -- still there when you come back out of the mode.
    local _, err = rex.call("com.superlogical.terminal.write", {
      session_id = ctx.session_id,
      block_id   = ctx.block_id,
      args       = { data = string.char(24) .. "i" },
    })
    if err ~= nil then
      error(err, 0)
    end
  end,
}

-- Cmd+Shift+I, and Ctrl+Shift+I for keyboards or habits that use it.
rex.bind("shift+cmd+i", "terat")
rex.bind("ctrl+shift+i", "terat")

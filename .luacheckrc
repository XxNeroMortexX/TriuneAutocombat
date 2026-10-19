---@diagnostic disable: lowercase-global, undefined-global
-- .luacheckrc — Luacheck configuration for TriuneAutocombat
-- Runs on CI via `luacheck TAC/` to catch typos, unused vars, shadowed
-- locals, and references to undefined globals.

std = "luajit"

-- Maximum line length (disabled — some UI lines are naturally long)
max_line_length = false

-- Globals the scripts assign (DATA is the shared game-data table)
globals = {
    "DATA",
}

-- Read-only globals (can be read but not assigned)
read_globals = {
    -- MacroQuest / ImGui globals that MQ injects at runtime (read-only:
    -- luacheck flags any accidental assignment to them)
    "mq",
    "ImGui",
    "ImGuiCond",
    "ImGuiCol",
    "ImGuiStyleVar",
    "ImGuiTableFlags",
    "ImGuiTableColumnFlags",
    "ImGuiSelectableFlags",
    "ImGuiWindowFlags",
    "ImGuiTreeNodeFlags",
    "ImGuiTabBarFlags",
    "ImGuiTabItemFlags",
    "ImGuiMouseCursor",
    "ImGuiInputTextFlags",
    "ImGuiHoveredFlags",
    "ImGuiComboFlags",
    "ImGuiPopupFlags",
    "ImGuiMod",
    "ImGuiKey",
    "ImVec2",
    "ImVec4",
    "IM_COL32",
    "bit",
    "clearCursor",
    os = { fields = { "clock", "time", "date", "difftime" } },
    string = { fields = { "format", "find", "match", "gmatch", "gsub",
                          "sub", "upper", "lower", "len", "rep", "byte",
                          "char", "reverse" } },
    table  = { fields = { "insert", "remove", "sort", "concat", "maxn" } },
    math   = { fields = { "floor", "ceil", "abs", "min", "max", "sqrt",
                          "huge", "random", "randomseed", "pi", "fmod",
                          "sin", "cos", "atan2" } },
    io     = { fields = { "open", "read", "write", "close" } },
}

-- Per-file overrides
files["TAC/config/triune_data.lua"] = {
    -- Generated file; suppress all warnings
    ignore = { "" },
}

-- Common suppressions for the MQ pcall-guard pattern, ImGui callbacks, and formatting
ignore = {
    "611",           -- line contains only whitespace
    "612",           -- line contains trailing whitespace
    "613",           -- trailing whitespace inside string
    "621",           -- inconsistent indentation
    "212",           -- unused argument (event handlers, ImGui callbacks)
    "212/_%w*",      -- unused loop variable starting with _
    "431",           -- shadowing upvalue (very common with pcall patterns; ~10 hits in TAC/)
    "432",           -- shadowing upvalue argument
    "542",           -- empty if branch (used deliberately with a comment to short-circuit an elseif chain)
}

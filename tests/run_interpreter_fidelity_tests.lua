-- Refuses a Lua interpreter whose C runtime formats numbers differently from
-- the game. Canonical JSON (tpf2_mp/json.lua) renders non-integers with
-- string.format("%.17g"), and every proposal, checkpoint, and parity digest is
-- a hash of that text. TransportFever2.exe links the Universal CRT, whose
-- printf is correctly rounded, and the Python companion reproduces %.17g with
-- exact decimal arithmetic. Lua for Windows 5.1.5 links MSVCR80, which
-- misrounds ties in the 17th digit and prints three-digit exponents, so digests
-- pinned under it do not match the running game. tools/ci/build_lua51.ps1
-- builds a faithful interpreter.
local probes = {
  { "string.format('%.17g', -41.50114440917969)", string.format("%.17g", -41.50114440917969),
    "-41.501144409179688" },
  { "string.format('%.17g', 8.236854553222656)", string.format("%.17g", 8.236854553222656),
    "8.2368545532226562" },
  { "string.format('%.17g', 1.5e17)", string.format("%.17g", 1.5e17), "1.5e+17" },
  { "string.format('%.0f', 3.0)", string.format("%.0f", 3.0), "3" },
}
local failures = {}
for _, probe in ipairs(probes) do
  local label, actual, expected = probe[1], probe[2], probe[3]
  if actual ~= expected then
    failures[#failures + 1] = string.format("  %s -> %q (expected %q)", label, actual, expected)
  end
end
if #failures > 0 then
  io.stderr:write("FAIL Lua interpreter number formatting differs from the game's C runtime:\n",
    table.concat(failures, "\n"), "\n",
    "This interpreter cannot reproduce canonical digests. Build a faithful Lua 5.1.5 with\n",
    "  powershell -File tools\\ci\\build_lua51.ps1 -OutputDirectory <dir>\n",
    "and set TPF2MP_LUA to <dir>\\lua.exe before running tools\\run_tests.ps1.\n")
  os.exit(1)
end
print(string.format("PASS interpreter %s formats canonical numbers like the game runtime (%d probes)",
  _VERSION, #probes))

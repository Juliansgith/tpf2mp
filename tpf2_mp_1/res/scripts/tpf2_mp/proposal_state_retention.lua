local M = {}

function M.releaseTerminalRuntime(state)
  local world = type(state) == "table" and type(state.world) == "table" and state.world or nil
  local proposals = world and type(world.proposals) == "table" and world.proposals or nil
  local byId = proposals and type(proposals.byId) == "table" and proposals.byId or nil
  if not byId then return end
  for _, record in pairs(byId) do
    if type(record) == "table"
      and (record.status == "applied" or record.status == "failed") then
      -- Construction scratch contains a full native-world snapshot.  Terminal
      -- records retain their signed transaction/result, so the scratch has no
      -- role in completion retry, consensus, diagnostics or recovery.
      record.constructionPending = nil
    end
  end
end

return M

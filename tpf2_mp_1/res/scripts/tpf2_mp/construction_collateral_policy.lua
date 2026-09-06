local M = {}

-- Collateral is authorised and verified while it still exists, before the
-- first irreversible bulldoze. Every later native replay must omit those
-- roots: resolving an intentionally retired construction turns a successful
-- first stage into a deterministic post-mutation fault. Keep the state bit as
-- the primary contract and recognise persisted replay paths for compatibility
-- with transient records written before the bit was introduced.
function M.omit(record)
  if type(record) ~= "table" then return false end
  local pending = record.constructionPending
  if type(pending) == "table" and pending.collateralRetired == true then
    return true
  end
  return record.replayPath == "staged-gui-build-proposal"
    or record.replayPath == "helper-depot-connection"
end

return M

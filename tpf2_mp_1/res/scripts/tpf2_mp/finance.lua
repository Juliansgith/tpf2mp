local util = require "tpf2_mp/util"

local M = {}

-- Exact floor(value * numerator / denominator) for non-negative authored
-- integers without first constructing a potentially unsafe Lua double. The
-- quotient/remainder split is mirrored by the companion replayer.
local function scaledFloor(value, numerator, denominator)
  value = math.max(0, util.integer(value, 0))
  numerator = math.max(0, util.integer(numerator, 0))
  denominator = math.max(1, util.integer(denominator, 1))
  local quotient = math.floor(value / denominator)
  local remainder = value - quotient * denominator
  return quotient * numerator + math.floor(remainder * numerator / denominator)
end

function M.newState()
  return {
    totalPaid = 0,
    lastPayouts = {},
    startingCash = {
      target = 0,
      totalGranted = 0,
      grants = {},
      repairs = 0,
      lastReason = nil,
      lastError = nil,
    },
    transfers = {
      nextSeq = 1,
      items = {},
      totalAbsolute = 0,
      failures = 0,
    },
    neutralizer = {
      enabled = false,
      lastTimeMs = nil,
      totalNeutralized = 0,
      lastNativeIncome = 0,
      lastError = nil,
    },
    -- Native player accounts are machine-local presentation state. Build
    -- journal entries can become visible on different engine updates and the
    -- base game can add peer-local maintenance entries. Network play therefore
    -- owns a small ordered account ledger and treats native balances as a cache
    -- that is reconciled after authoritative finance events.
    networkAccounts = {
      version = 1,
      initialized = false,
      accounts = {},
      nextEntrySeq = 1,
      entries = {},
      totalApplied = 0,
      reconciliation = {
        attempts = 0,
        commands = 0,
        failures = 0,
        totalAbsolute = 0,
        lastReason = nil,
        lastError = nil,
        items = {},
        pending = {},
      },
    },
  }
end

function M.ensureNetworkAccounts(state)
  local defaults = M.newState().networkAccounts
  local ledger = state.networkAccounts
  if type(ledger) ~= "table" then
    ledger = defaults
    state.networkAccounts = ledger
  end
  if ledger.version == nil then ledger.version = defaults.version end
  if ledger.initialized == nil then ledger.initialized = false end
  if ledger.bankruptCid ~= nil and type(ledger.bankruptCid) ~= "string" then
    ledger.bankruptCid = nil
  end
  ledger.accounts = ledger.accounts or {}
  ledger.nextEntrySeq = math.max(1, util.integer(ledger.nextEntrySeq, 1))
  ledger.entries = ledger.entries or {}
  ledger.totalApplied = util.integer(ledger.totalApplied, 0)
  ledger.reconciliation = ledger.reconciliation or defaults.reconciliation
  local reconciliation = ledger.reconciliation
  reconciliation.attempts = math.max(0, util.integer(reconciliation.attempts, 0))
  reconciliation.commands = math.max(0, util.integer(reconciliation.commands, 0))
  reconciliation.failures = math.max(0, util.integer(reconciliation.failures, 0))
  reconciliation.totalAbsolute = math.max(0, util.integer(reconciliation.totalAbsolute, 0))
  reconciliation.items = reconciliation.items or {}
  reconciliation.pending = reconciliation.pending or {}
  return ledger
end

local function appendBounded(items, value, maximum)
  items[#items + 1] = value
  while #items > maximum do table.remove(items, 1) end
end

function M.initialiseNetworkAccounts(state, companyCids, startingCash, context)
  local ledger = M.ensureNetworkAccounts(state)
  startingCash = math.max(0, util.integer(startingCash, 0))
  ledger.initialized = true
  ledger.accounts = {}
  ledger.nextEntrySeq = 1
  ledger.entries = {}
  ledger.totalApplied = 0
  ledger.bankruptCid = nil
  ledger.reconciliation.pending = {}
  ledger.initializedContext = util.deepCopy(context or {})
  for _, companyCid in ipairs(companyCids or {}) do
    companyCid = tostring(companyCid)
    ledger.accounts[companyCid] = {
      companyCid = companyCid,
      balance = startingCash,
      loan = 0,
      totalCredits = 0,
      totalDebits = 0,
      entryCount = 0,
    }
  end
  return ledger
end

function M.networkAccount(state, companyCid)
  local ledger = M.ensureNetworkAccounts(state)
  return ledger.accounts[tostring(companyCid or "")]
end

function M.networkDigestView(state)
  local ledger = M.ensureNetworkAccounts(state)
  local accounts = {}
  for _, companyCid in ipairs(util.sortedKeys(ledger.accounts)) do
    local account = ledger.accounts[companyCid]
    accounts[companyCid] = {
      balance = util.integer(account.balance, 0),
      loan = util.integer(account.loan, 0),
      -- Solvency state decides who is still in the match, so it converges.
      insolventSettlements = util.integer(account.insolventSettlements, 0),
      creditLimit = util.integer(account.creditLimit, 0),
    }
  end
  local result = {
    version = util.integer(ledger.version, 1),
    initialized = ledger.initialized == true,
    accounts = accounts,
  }
  if type(ledger.bankruptCid) == "string" and ledger.bankruptCid ~= "" then
    result.bankruptCid = ledger.bankruptCid
  end
  return result
end

-- Competitive credit and insolvency.
--
-- The concept names "no bankruptcy pressure" as a defect of the vanilla
-- economy, so the competitive ruleset has to supply it: capital committed to
-- a contested corridor must be able to cost a player the match. Credit is
-- sized from what a company has actually earned, interest is charged every
-- settlement, and a company that cannot cover its debt gets a countdown
-- rather than an instant loss - a bad quarter should hurt, not end you.
--
-- Every value is deterministic integer arithmetic over authored state, so
-- both peers reach the same verdict from the same ordered settlement.
M.CREDIT = {
  baseLimitCents = 500000000,      -- credit available before any trading
  revenueMultiple = 4,             -- plus this many settlements of revenue
  interestPermille = 15,           -- charged per settlement on drawn credit
  insolventSettlements = 3,        -- consecutive breaches before bankruptcy
}

-- A company may borrow against its established earning power, not its
-- ambitions: the limit follows settled revenue, so a player who has not yet
-- earned anything cannot leverage into a corridor war.
-- Match rules override the defaults; absent rules keep them.
function M.creditRules(rules)
  rules = type(rules) == "table" and rules or {}
  return {
    baseLimitCents = util.integer(rules.creditBaseLimitCents, M.CREDIT.baseLimitCents),
    revenueMultiple = util.integer(rules.creditRevenueMultiple, M.CREDIT.revenueMultiple),
    interestPermille = util.integer(rules.creditInterestPermille, M.CREDIT.interestPermille),
    insolventSettlements = util.integer(rules.insolventSettlements, M.CREDIT.insolventSettlements),
    bankruptcyEnabled = rules.bankruptcyEnabled ~= false,
  }
end

function M.creditLimit(ledgerCompany, settlementCount, rules, periodSeconds)
  local credit = M.creditRules(rules)
  local settled = math.max(0, util.integer(ledgerCompany
    and (ledgerCompany.netRevenueCents ~= nil and ledgerCompany.netRevenueCents
      or ledgerCompany.revenueCents), 0))
  local settlements = math.max(1, util.integer(settlementCount, 1))
  local period = math.max(60, util.integer(periodSeconds, 3600))
  local average = math.floor(settled / settlements)
  local perHour = scaledFloor(average, 3600, period)
  return credit.baseLimitCents + perHour * credit.revenueMultiple
end

-- Charges interest on drawn credit and advances (or clears) each company's
-- insolvency countdown. Returns a per-company report plus the cid of any
-- company that has now failed.
function M.chargeCreditAndAssessSolvency(
  state, companyCids, economyLedger, context, rules, periodSeconds)
  local ledger = M.ensureNetworkAccounts(state)
  local credit = M.creditRules(rules)
  local ledgerCompanies = economyLedger and economyLedger.companies or {}
  local settlementCount = economyLedger and economyLedger.settlementCount or 1
  local period = math.max(60, util.integer(periodSeconds, 3600))
  local breachLimit = credit.insolventSettlements > 0
    and math.max(1, math.floor((credit.insolventSettlements * 3600 + period - 1) / period)) or 0
  local report, bankruptCid = {}, nil
  for _, companyCid in ipairs(companyCids or {}) do
    local account = ledger.accounts[companyCid]
    if account then
      local limit = M.creditLimit(
        ledgerCompanies[companyCid], settlementCount, rules, period)
      local balance = util.integer(account.balance, 0)
      local drawn = balance < 0 and -balance or 0
      local interest = scaledFloor(
        drawn, credit.interestPermille * period, 3600000)
      if interest > 0 then
        M.applyNetworkDelta(state, companyCid, -interest, {
          kind = "credit-interest", drawn = drawn, reason = context and context.reason or nil,
        })
        account = ledger.accounts[companyCid]
        balance = util.integer(account.balance, 0)
        drawn = balance < 0 and -balance or 0
      end
      local breached = drawn > limit
      account.insolventSettlements = breached
        and (util.integer(account.insolventSettlements, 0) + 1) or 0
      account.creditLimit = limit
      -- Elimination is opt-out. With bankruptcy disabled, or the breach
      -- threshold set to zero, debt still charges interest and still limits
      -- what a company can afford, but nobody is removed from the match.
      if credit.bankruptcyEnabled and breachLimit > 0
        and account.insolventSettlements >= breachLimit
        and not bankruptCid then
        bankruptCid = companyCid
      end
      report[companyCid] = {
        balance = balance,
        drawn = drawn,
        limit = limit,
        interestCents = interest,
        breached = breached,
        insolventSettlements = account.insolventSettlements,
        insolventSettlementLimit = breachLimit,
      }
    end
  end
  -- This verdict authors match termination. Keep it in the canonical ledger
  -- rather than a diagnostic probe so checkpoint digests enforce agreement.
  ledger.bankruptCid = bankruptCid
  return report, bankruptCid
end

function M.applyNetworkDelta(state, companyCid, amount, context)
  local ledger = M.ensureNetworkAccounts(state)
  if ledger.initialized ~= true then return false, "canonical network accounts are not initialised" end
  companyCid = tostring(companyCid or "")
  local account = ledger.accounts[companyCid]
  if not account then return false, "canonical network account is unavailable for " .. companyCid end
  amount = util.integer(amount, 0)
  local before = util.integer(account.balance, 0)
  local entry = {
    seq = ledger.nextEntrySeq,
    companyCid = companyCid,
    amount = amount,
    before = before,
    after = before + amount,
    context = util.deepCopy(context or {}),
  }
  ledger.nextEntrySeq = ledger.nextEntrySeq + 1
  account.balance = entry.after
  account.entryCount = math.max(0, util.integer(account.entryCount, 0)) + 1
  if amount >= 0 then
    account.totalCredits = math.max(0, util.integer(account.totalCredits, 0)) + amount
  else
    account.totalDebits = math.max(0, util.integer(account.totalDebits, 0)) - amount
  end
  ledger.totalApplied = util.integer(ledger.totalApplied, 0) + amount
  appendBounded(ledger.entries, entry, 256)
  return true, util.deepCopy(entry)
end

local function ensureTransfers(state)
  state.transfers = state.transfers or {}
  state.transfers.nextSeq = state.transfers.nextSeq or 1
  state.transfers.items = state.transfers.items or {}
  state.transfers.totalAbsolute = state.transfers.totalAbsolute or 0
  state.transfers.failures = state.transfers.failures or 0
  return state.transfers
end

local function recordTransfer(state, value)
  local transfers = ensureTransfers(state)
  value.seq = transfers.nextSeq
  transfers.nextSeq = transfers.nextSeq + 1
  transfers.items[#transfers.items + 1] = value
  while #transfers.items > 128 do table.remove(transfers.items, 1) end
  if value.ok and not value.noop then
    transfers.totalAbsolute = transfers.totalAbsolute + math.abs(value.nativeDelta or 0)
  elseif not value.ok then
    transfers.failures = transfers.failures + 1
  end
  return value
end

local function categoryOther()
  local category = api.type.JournalEntryCategory.new()
  category.type = 6
  category.carrier = 3
  category.construction = 6
  category.maintenance = 2
  category.other = 0
  return category
end

function M.book(playerId, amount)
  amount = util.integer(amount, 0)
  if amount == 0 then return true end
  local bookJournalEntry = util.commandFactory("bookJournalEntry")
  if api and api.cmd and type(api.cmd.sendCommand) == "function" and bookJournalEntry then
    local journal = api.type.JournalEntry.new()
    journal.amount = amount
    journal.category = categoryOther()
    journal.time = -1
    local ok, err = util.sendCommand(
      bookJournalEntry(playerId, journal), nil, "mod.finance.book-journal-entry")
    if ok then return true end
    return false, err
  end
  if game and game.interface and game.interface.book and playerId == game.interface.getPlayer() then
    return pcall(game.interface.book, amount)
  end
  return false, "no arbitrary-player journal command available"
end

local function nativeBalance(playerId)
  if not (game and game.interface and type(game.interface.getEntity) == "function") then return nil end
  local ok, entity = pcall(game.interface.getEntity, playerId)
  if not ok or not entity then return nil end
  return tonumber(entity.balance)
end

-- Move every local native representative toward the replicated balance. A
-- successful journal command is sufficient here: Build 35924 may expose the
-- resulting balance on a later engine update, so the post-read is diagnostic
-- and deliberately is not treated as a synchronous postcondition.
function M.reconcileNetworkAccounts(state, companies, context)
  local ledger = M.ensureNetworkAccounts(state)
  if ledger.initialized ~= true then return false, "canonical network accounts are not initialised" end
  local reconciliation = ledger.reconciliation
  reconciliation.attempts = reconciliation.attempts + 1
  reconciliation.lastReason = tostring(type(context) == "table" and context.reason or context or "ordered-event")
  reconciliation.lastError = nil
  local run = {
    reason = reconciliation.lastReason,
    context = util.deepCopy(type(context) == "table" and context or {}),
    accounts = {},
    ok = true,
  }
  local errors = {}
  local contextTick = type(context) == "table" and tonumber(context.tick) or nil
  local clock = contextTick or reconciliation.attempts
  for _, companyCid in ipairs(util.sortedKeys(ledger.accounts)) do
    local account = ledger.accounts[companyCid]
    local company = type(companies) == "table" and companies[companyCid] or nil
    local playerId = company and tonumber(company.playerId) or nil
    local before = playerId and nativeBalance(playerId) or nil
    local target = util.integer(account.balance, 0)
    local adjustment = before and (target - util.integer(before, 0)) or nil
    local booked, bookingError = false, nil
    local waiting, commandIssued = false, false
    local pending = reconciliation.pending[companyCid]
    if not playerId then
      bookingError = "native player binding is unavailable"
    elseif before == nil then
      bookingError = "native balance is unavailable"
    elseif adjustment == 0 then
      booked = true
      reconciliation.pending[companyCid] = nil
    elseif pending and clock - (contextTick and util.integer(pending.issuedTick, clock)
      or util.integer(pending.issuedAttempt, clock)) < 15 then
      -- Journal commands become visible asynchronously. Poll every update, but
      -- never issue the same correction repeatedly while the previous command
      -- is still in flight.
      booked = true
      waiting = true
    else
      booked, bookingError = M.book(playerId, adjustment)
      if booked then
        commandIssued = true
        reconciliation.commands = reconciliation.commands + 1
        reconciliation.totalAbsolute = reconciliation.totalAbsolute + math.abs(adjustment)
        reconciliation.pending[companyCid] = {
          target = target,
          before = before,
          adjustment = adjustment,
          issuedTick = contextTick,
          issuedAttempt = reconciliation.attempts,
        }
      end
    end
    local after = playerId and nativeBalance(playerId) or nil
    if after ~= nil and math.abs(after - target) < 0.5 then
      reconciliation.pending[companyCid] = nil
      waiting = false
    end
    local item = {
      companyCid = companyCid,
      playerId = playerId,
      target = target,
      before = before,
      adjustment = adjustment,
      after = after,
      settledImmediately = booked == true and after ~= nil and math.abs(after - target) < 0.5,
      waiting = waiting,
      commandIssued = commandIssued,
      ok = booked == true,
      error = not booked and tostring(bookingError) or nil,
    }
    run.accounts[companyCid] = item
    if not booked then
      run.ok = false
      errors[#errors + 1] = companyCid .. ": " .. item.error
    end
  end
  if not run.ok then
    reconciliation.failures = reconciliation.failures + 1
    reconciliation.lastError = table.concat(errors, "; ")
  end
  run.error = reconciliation.lastError
  appendBounded(reconciliation.items, util.deepCopy(run), 64)
  return run.ok, run
end

-- Reallocate a signed balance change that originally landed on the native UI
-- player. A negative delta is a cost; a positive delta is income/refund.
-- The two compensating journal entries preserve total money across players.
function M.transferNativeDelta(state, nativePlayerId, companyPlayerId, nativeDelta, context)
  nativeDelta = util.integer(nativeDelta, 0)
  local record = {
    nativePlayerId = nativePlayerId,
    companyPlayerId = companyPlayerId,
    nativeDelta = nativeDelta,
    context = util.deepCopy(context or {}),
    ok = false,
  }
  if nativeDelta == 0 or nativePlayerId == companyPlayerId then
    record.ok = true
    record.noop = true
    return true, recordTransfer(state, record)
  end

  local reversed, reverseError = M.book(nativePlayerId, -nativeDelta)
  if not reversed then
    record.error = tostring(reverseError)
    return false, recordTransfer(state, record)
  end

  local applied, applyError = M.book(companyPlayerId, nativeDelta)
  if not applied then
    local rolledBack, rollbackError = M.book(nativePlayerId, nativeDelta)
    record.error = tostring(applyError)
    record.rollbackOk = rolledBack and true or false
    record.rollbackError = rollbackError and tostring(rollbackError) or nil
    return false, recordTransfer(state, record)
  end

  record.ok = true
  return true, recordTransfer(state, record)
end

-- Close a proxy turn that began by mirroring the company's starting balance
-- onto the control player. On success the company receives only the gameplay
-- delta and the control player returns to its neutral baseline. The begin/end
-- mirror entries and settlement entries sum to zero across all players.
function M.settleProxyTurn(state, controlPlayerId, companyPlayerId, turnStart, turnEnd, controlBaseline, context)
  turnStart = util.integer(turnStart, 0)
  turnEnd = util.integer(turnEnd, turnStart)
  controlBaseline = util.integer(controlBaseline, turnStart)
  local nativeDelta = turnEnd - turnStart
  local resetDelta = controlBaseline - turnStart
  local record = {
    nativePlayerId = controlPlayerId,
    companyPlayerId = companyPlayerId,
    nativeDelta = nativeDelta,
    mirrorResetDelta = resetDelta,
    context = util.deepCopy(context or {}),
    kind = "proxy-turn-settlement",
    ok = false,
  }

  local reversed, reverseError = M.book(controlPlayerId, -nativeDelta)
  if not reversed then
    record.error = tostring(reverseError)
    return false, recordTransfer(state, record)
  end
  local applied, applyError = M.book(companyPlayerId, nativeDelta)
  if not applied then
    local rolledBack, rollbackError = M.book(controlPlayerId, nativeDelta)
    record.error = tostring(applyError)
    record.rollbackOk = rolledBack and true or false
    record.rollbackError = rollbackError and tostring(rollbackError) or nil
    return false, recordTransfer(state, record)
  end
  local reset, resetError = M.book(controlPlayerId, resetDelta)
  if not reset then
    local companyRollback, companyRollbackError = M.book(companyPlayerId, -nativeDelta)
    local controlRollback, controlRollbackError = M.book(controlPlayerId, nativeDelta)
    record.error = tostring(resetError)
    record.rollbackOk = companyRollback and controlRollback
    record.companyRollbackError = companyRollbackError and tostring(companyRollbackError) or nil
    record.controlRollbackError = controlRollbackError and tostring(controlRollbackError) or nil
    return false, recordTransfer(state, record)
  end

  record.ok = true
  record.noop = nativeDelta == 0 and resetDelta == 0
  return true, recordTransfer(state, record)
end

function M.payResults(state, companies, results, payoutDollars)
  state.lastPayouts = {}
  local errors = {}
  for _, companyCid in ipairs(util.sortedKeys(results.companies or {})) do
    local companyResult = results.companies[companyCid]
    local company = companies[companyCid]
    local amount = type(payoutDollars) == "table" and payoutDollars[companyCid]
    if amount == nil then
      amount = math.floor(((companyResult.netRevenueCents ~= nil
        and companyResult.netRevenueCents or companyResult.revenueCents) or 0) / 100)
    end
    amount = util.integer(amount, 0)
    if company and company.playerId and amount ~= 0 then
      local ok, err = M.book(company.playerId, amount)
      state.lastPayouts[companyCid] = { amount = amount, ok = ok, error = err }
      if ok then state.totalPaid = (state.totalPaid or 0) + amount else errors[#errors + 1] = tostring(err) end
    else
      state.lastPayouts[companyCid] = { amount = amount, ok = false, error = "company has no native player binding" }
    end
  end
  return #errors == 0, errors
end

local function journalSum(value)
  if type(value) == "number" then return value end
  if type(value) == "table" then return tonumber(value._sum) or 0 end
  return 0
end

function M.updateNeutralizer(state)
  local probe = state.neutralizer
  if not probe.enabled then return true end
  if not (game and game.interface and game.interface.getGameTime and game.interface.getPlayerJournal) then
    probe.lastError = "legacy journal reader unavailable"
    return false, probe.lastError
  end

  local nowMs = math.floor((game.interface.getGameTime().time or 0) * 1000)
  if not probe.lastTimeMs then probe.lastTimeMs = nowMs; return true end
  if nowMs <= probe.lastTimeMs then return true end

  local ok, journal = pcall(game.interface.getPlayerJournal, probe.lastTimeMs + 1, nowMs, false)
  probe.lastTimeMs = nowMs
  if not ok or type(journal) ~= "table" then
    probe.lastError = "journal read failed: " .. tostring(journal)
    return false, probe.lastError
  end

  local income = journalSum(journal.income)
  probe.lastNativeIncome = income
  if income > 0 then
    local playerId = game.interface.getPlayer()
    local booked, err = M.book(playerId, -income)
    if not booked then probe.lastError = tostring(err); return false, err end
    probe.totalNeutralized = (probe.totalNeutralized or 0) + income
  end
  probe.lastError = nil
  return true
end

return M

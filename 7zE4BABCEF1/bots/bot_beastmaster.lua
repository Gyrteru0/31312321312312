------------------------------------------------------------
-- bot_beastmaster.lua
-- Anti-AFK economy fix for the 1v1 mid SF lobby: without active teammates Valve grants every
-- player a gold spike at the 5 minute mark. These four bots walk to one jungle camp, all of
-- them focus a SINGLE creep, and leave as soon as at least one creep dies. Then they park far
-- away (out of aggro range) until the next cycle.
------------------------------------------------------------

local safeCamp = {
    [TEAM_RADIANT] = Vector(244, -5567),
    [TEAM_DIRE]    = Vector(-994, 4195),
}

-- Wait spot: 1500 units from the camp (out of aggro range)
local waitSpot = {
    [TEAM_RADIANT] = Vector(244, -4000),
    [TEAM_DIRE]    = Vector(-994, 2700),
}

local CYCLE       = 120   -- one farm attempt every 2 minutes
local FARM_TIME   = 20    -- hard cap for the farm phase (a kill ends it earlier)
local CAMP_RADIUS = 900   -- only the creeps of THIS camp
local START_TIME  = 60

-- Per-bot state (each bot runs its own script instance).
local S = {
    cycle      = -1,
    startCount = nil,
    killed     = false,
}

-- Alive neutral creeps belonging to this camp.
local function CampCreeps(bot, camp)
    local list = bot:GetNearbyNeutralCreeps(1400) or {}
    local out = {}
    for _, c in pairs(list) do
        if c and c:IsAlive() and GetUnitToLocationDistance(c, camp) <= CAMP_RADIUS then
            table.insert(out, c)
        end
    end
    return out
end

-- All four bots must hit the SAME creep. Primary key: the creep an ally is already attacking
-- (so the group does not flip targets mid-fight). Fallback: the lowest HP one, ties broken by
-- the distance to the camp centre - a rule that does not depend on where this bot is standing.
local function SharedTarget(bot, creeps, camp)
    if #creeps == 0 then return nil end

    local attacked = {}
    local allies = bot:GetNearbyHeroes(1600, false, BOT_MODE_NONE) or {}
    for _, h in pairs(allies) do
        if h and h ~= bot and h.GetAttackTarget then
            local ok, tgt = pcall(h.GetAttackTarget, h)
            if ok and tgt then attacked[tgt] = (attacked[tgt] or 0) + 1 end
        end
    end

    local best, bestScore = nil, math.huge
    for _, c in ipairs(creeps) do
        local hp = c:GetHealth() or 0
        local score = -(attacked[c] or 0) * 1000000
            + hp * 100
            + GetUnitToLocationDistance(c, camp)
        if score < bestScore then
            bestScore = score
            best = c
        end
    end
    return best
end

function Think()
    local bot = GetBot()
    if bot == nil or not bot:IsAlive() then return end
    if DotaTime() < START_TIME then return end

    local team = GetTeam()
    local camp = safeCamp[team]
    local wait = waitSpot[team]
    if camp == nil or wait == nil then return end

    local timeInCycle = DotaTime() % CYCLE
    local cycle = math.floor(DotaTime() / CYCLE)

    ------------------------------------------------
    -- WAIT PHASE: park far away and regen
    ------------------------------------------------
    if timeInCycle >= FARM_TIME then
        S.cycle = -1
        S.startCount = nil
        S.killed = false
        bot:Action_MoveToLocation(wait)
        return
    end

    ------------------------------------------------
    -- FARM PHASE
    ------------------------------------------------
    if S.cycle ~= cycle then
        S.cycle = cycle
        S.startCount = nil
        S.killed = false
    end

    local creeps = CampCreeps(bot, camp)

    if S.startCount == nil then
        S.startCount = #creeps          -- first look at the camp this cycle
    elseif #creeps > S.startCount then
        S.startCount = #creeps          -- camp respawned / creeps wandered in
    elseif #creeps < S.startCount then
        S.killed = true                 -- at least one creep died
    end

    -- Done for this cycle: a creep is dead (or the camp is empty) - leave immediately.
    if S.killed or #creeps == 0 then
        bot:Action_MoveToLocation(wait)
        return
    end

    local target = SharedTarget(bot, creeps, camp)
    if target then
        bot:Action_AttackUnit(target, true)
        return
    end

    bot:Action_AttackMove(camp)
end

function AbilityLevelUpThink()
    local bot = GetBot()
    if bot == nil then return end
    if bot:GetAbilityPoints() < 1 then return end

    local axes = bot:GetAbilityByName("beastmaster_wild_axes")
    if axes ~= nil and axes:CanAbilityBeUpgraded() then
        bot:ActionImmediate_LevelAbility("beastmaster_wild_axes")
        return
    end

    local inner = bot:GetAbilityByName("beastmaster_inner_beast")
    if inner ~= nil and inner:CanAbilityBeUpgraded() then
        bot:ActionImmediate_LevelAbility("beastmaster_inner_beast")
    end
end

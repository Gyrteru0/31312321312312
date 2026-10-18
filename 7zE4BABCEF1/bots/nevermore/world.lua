--
-- The per-tick world snapshot: collect the unit lists, the enemy, the towers and the enemy's presence
-- (alive / when last seen) once. The W.s table is reused (no per-tick allocations).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local W = {}

-- Buffers for the filtered creep lists (reused every tick)
local ENEMY_CREEPS_BUF, ALLY_CREEPS_BUF = {}, {}
local function FilterQueryable(list, buf)
    for i = #buf, 1, -1 do buf[i] = nil end
    if not list then return buf end
    local n = 0
    for _, u in pairs(list) do
        if U.CanQuery(u) then
            n = n + 1
            buf[n] = u
        end
    end
    return buf
end

W.s = {
    now = 0,
    bot = nil,
    enemy = nil, -- The visible enemy hero (queryable) or nil
    enemyAny = nil, -- The enemy handle even if not visible (may not be queryable)
    enemyVisible = false,
    enemyAlive = true,
    enemyLastSeen = -1, -- The GameTime when he was last seen
    enemyLastLoc = nil,
    enemyAbsentFor = 0, -- seconds unseen (0 if visible)
    enemyDist = 99999,
    enemyCreeps = nil,
    allyCreeps = nil,
    enemyTowers = nil,
    allyTowers = nil,
    enemyT1 = nil, -- The enemy T1 handle (if alive and accessible)
    enemyT1Alive = true,
    allyT1 = nil,
    myKills = 0,
    myDeaths = 0,
    enemyKills = 0,
    enemyDeaths = 0,
}

local EMPTY = {}

local function FindT1(towers)
    for _, t in pairs(towers or EMPTY) do
        if t and t:IsAlive() then
            local name = t:GetUnitName() or ""
            if name:find("tower1") then return t end
        end
    end
    return nil
end

local function SafeGetTower(team, idx)
    if type(GetTower) ~= "function" then return nil end
    local ok, t = pcall(GetTower, team, idx)
    if ok then return t end
    return nil
end

-- This API exposes only visible teleport effects, not hidden cast destinations.
function W.ReadIncomingTeleports(bot, s)
    s.incomingEnemyTPs = {}
    if type(GetIncomingTeleports) ~= "function" then return end
    local ok, list = pcall(GetIncomingTeleports)
    if not ok or type(list) ~= "table" then return end
    local enemyIds = {}
    local known = s.enemyAny or s.enemy
    if known and known.GetPlayerID then enemyIds[known:GetPlayerID()] = true end
    if type(GetTeamPlayers) == "function" then
        local team = bot:GetTeam() == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
        for _, id in pairs(GetTeamPlayers(team) or {}) do enemyIds[id] = true end
    end
    for _, tp in pairs(list) do
        if enemyIds[tp.playerid] and tp.location and type(tp.location.x) == "number" and type(tp.location.y) == "number" and type(tp.time_remaining) == "number"
            and tp.time_remaining >= 0 and tp.time_remaining <= 15 then
            s.incomingEnemyTPs[#s.incomingEnemyTPs + 1] = tp
        end
    end
end

function W.Update(bot)
    local s = W.s
    local now = GameTime()
    s.now = now
    s.bot = bot

    -- The enemy: first from the global list (visibility/presence), then the nearby list.
    local enemy = nil
    local enemyAny = nil
    if type(GetUnitList) == "function" and UNIT_LIST_ENEMY_HEROES then
        local list = GetUnitList(UNIT_LIST_ENEMY_HEROES)
        for _, h in pairs(list or EMPTY) do
            if h then
                enemyAny = enemyAny or h
                if U.CanQuery(h) then
                    enemy = h
                    break
                end
            end
        end
    end
    if not enemy then
        local near = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE)
        for _, h in pairs(near or EMPTY) do
            if U.CanQuery(h) then
                enemy = h
                break
            end
        end
    end
    s.enemy = enemy
    s.enemyAny = enemyAny or enemy
    s.enemyVisible = enemy ~= nil
    if enemy then
        s.enemyLastSeen = now
        s.enemyLastLoc = enemy:GetLocation()
        s.enemyAbsentFor = 0
        s.enemyDist = GetUnitToLocationDistance(bot, s.enemyLastLoc)
        s.enemyAlive = enemy:IsAlive()
    else
        if s.enemyLastSeen >= 0 then
            s.enemyAbsentFor = now - s.enemyLastSeen
        else
            s.enemyAbsentFor = 0
        end
        s.enemyDist = 99999
        -- Is the invisible enemy alive
        local alive = true
        local h = s.enemyAny
        if h and h.GetPlayerID and type(IsHeroAlive) == "function" then
            local ok, pid = pcall(h.GetPlayerID, h)
            if ok and pid and pid >= 0 then
                local ok2, res = pcall(IsHeroAlive, pid)
                if ok2 and res ~= nil then alive = res end
            end
        end
        s.enemyAlive = alive
    end

    -- Score
    if s.enemyAny and s.enemyAny.GetPlayerID and type(GetHeroKills) == "function" then
        local ok, pid = pcall(s.enemyAny.GetPlayerID, s.enemyAny)
        if ok and pid and pid >= 0 then
            local ok1, k = pcall(GetHeroKills, pid)
            local ok2, d = pcall(GetHeroDeaths, pid)
            if ok1 and k then s.enemyKills = k end
            if ok2 and d then s.enemyDeaths = d end
        end
    end
    if type(GetHeroKills) == "function" then
        local pid = bot:GetPlayerID()
        local ok1, k = pcall(GetHeroKills, pid)
        local ok2, d = pcall(GetHeroDeaths, pid)
        if ok1 and k then s.myKills = k end
        if ok2 and d then s.myDeaths = d end
    end

    -- Units
    -- GetNearbyLaneCreeps(..., true) may return enemy creeps in fog (the handle exists but
    -- cannot be queried): every GetHealth/GetLocation on such a creep logs "[Developer] ... cannot be
    -- seen" to the console and a last hit/push on it is an order into thin air. We filter via CanQuery into two
    -- reused tables (no per-tick allocations).
    s.enemyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1200, true), ENEMY_CREEPS_BUF)
    s.allyCreeps = FilterQueryable(bot:GetNearbyLaneCreeps(1200, false), ALLY_CREEPS_BUF)
    s.enemyTowers = bot:GetNearbyTowers(1200, true) or EMPTY
    s.allyTowers = bot:GetNearbyTowers(1200, false) or EMPTY

    -- The T1 towers (via the global GetTower when available; otherwise from the nearby list)
    local enemyTeam = (bot:GetTeam() == TEAM_RADIANT) and TEAM_DIRE or TEAM_RADIANT
    local t1 = nil
    if TOWER_MID_1 ~= nil then
        t1 = SafeGetTower(enemyTeam, TOWER_MID_1)
    end
    if t1 then
        local okAlive, alive = pcall(t1.IsAlive, t1)
        if okAlive and alive == false then
            s.enemyT1Alive = false
            t1 = nil
        elseif okAlive and alive then
            local okLoc, loc = pcall(t1.GetLocation, t1)
            if okLoc and loc then
                s.enemyT1Alive = true
            else
                t1 = nil -- The handle exists but cannot be queried: take it from the nearby list
            end
        else
            t1 = nil
        end
    end
    if not t1 then
        local nearT1 = FindT1(s.enemyTowers)
        if nearT1 then
            t1 = nearT1
            s.enemyT1Alive = true
        end
    end
    s.enemyT1 = t1
    s.allyT1 = FindT1(s.allyTowers)
    W.ReadIncomingTeleports(bot, s)

    return s
end

-- The enemy is "absent": dead or unseen for longer than absentSec.
function W.EnemyAbsent(absentSec)
    local s = W.s
    if not s.enemyAlive then return true end
    if s.enemyVisible then return false end
    return s.enemyAbsentFor >= (absentSec or 5.0)
end

-- Hook for utils (utils cannot require world because of the cycle)
U._W = W

return W

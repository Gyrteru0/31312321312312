--
-- Lane logic: the wave front, the enemy T1 threat (creep shield), the zoning position,
-- the push plan. Pure computation over the world snapshot; no per-tick allocations (except Vector).

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local LN = {}

local TOWER_RANGE = (C.TOWER and C.TOWER.ATTACK_RANGE) or 700
local TOWER_SAFE  = (C.TOWER and C.TOWER.SAFE_RADIUS) or 780
local EMPTY = {}

local function IsSiege(unit)
    local name = unit:GetUnitName() or ""
    return name:find("siege") ~= nil or name:find("catapult") ~= nil
end
LN.IsSiege = IsSiege

local function EnemyT1Pos(bot)
    return (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
end
LN.EnemyT1Pos = EnemyT1Pos

-- The wave

-- My front creep = the one closest to the enemy T1 (not to the map centre - that was a bug
-- in the old version when the wave moved past the centre).
function LN.FrontAllyCreep(bot, allyCreeps)
    local target = EnemyT1Pos(bot)
    local best, bestD = nil, math.huge
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, target)
            if d < bestD then
                bestD = d
                best = c
            end
        end
    end
    return best, bestD
end

-- The centre of my wave (the average position of the live creeps) -> Vector or nil
function LN.AllyWaveCenter(allyCreeps)
    local n, sx, sy, sz = 0, 0, 0, 0
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() then
            local l = c:GetLocation()
            n = n + 1
            sx, sy, sz = sx + l.x, sy + l.y, sz + l.z
        end
    end
    if n == 0 then return nil end
    return Vector(sx / n, sy / n, sz / n)
end

-- The enemy is "busy with the wave": hitting a creep / far from us.
function LN.EnemyBusyWithWave(bot, enemy)
    if not U.CanQuery(enemy) then return true end
    local tgt = enemy.GetAttackTarget and enemy:GetAttackTarget()
    if tgt and tgt ~= bot and U.CanQuery(tgt) then
        local isHero = tgt.IsHero and tgt:IsHero()
        if not isHero then return true end
    end
    return false
end

-- Enemy tower threat

-- Creep shield: is there a live (non-siege) allied creep inside the tower radius that is closer to the
-- tower than refLoc (where I stand/will stand) and that the tower is not about to kill.
-- Returns count, closestCreepDist.
function LN.TowerShieldCount(tower, allyCreeps, refLoc)
    if not tower then return 0, math.huge end
    local tLoc = tower:GetLocation()
    local refDist = refLoc and U.DistanceBetweenLocations(tLoc, refLoc) or math.huge
    local count, closest = 0, math.huge
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() and not IsSiege(c) then
            local d = GetUnitToLocationDistance(c, tLoc)
            if d <= TOWER_RANGE + 40 and d < refDist - 25 and ((c:GetHealth() or 0) >= 110 or c:HasModifier("modifier_fountain_glyph")) then
                count = count + 1
                if d < closest then closest = d end
            end
        end
    end
    return count, closest
end

-- The tower threat level for the point refLoc (the bot's current position by default):
-- 0 - outside the tower radius;
-- 1 - inside the radius but under a shield (a creep is closer, the tower is not hitting us);
-- 2 - inside the radius without a shield, or the tower is already targeting us.
function LN.TowerDanger(bot, tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return 0 end
    refLoc = refLoc or bot:GetLocation()
    local d = U.DistanceBetweenLocations(tower:GetLocation(), refLoc)
    if d > TOWER_SAFE then return 0 end
    -- GetAttackTarget on an invisible tower -> a "cannot be seen" warning: only when it is visible
    local tgt = nil
    if tower.GetAttackTarget and (not tower.CanBeSeen or tower:CanBeSeen()) then tgt = tower:GetAttackTarget() end
    if tgt == bot then return 2 end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.0) then return 2 end
    local shield = LN.TowerShieldCount(tower, allyCreeps, refLoc)
    if shield >= 1 then return 1 end
    return 2
end

-- The point to leave the tower radius.
-- The previous direction was a mix of "away from the tower" and "toward my fountain". Behind the tower those
-- vectors are opposite, their sum nearly cancelled and the escape point ended up next to us (or even
-- on the tower) - the hero stamped in place under its shots. Now:
-- * the direction is chosen stably (we only turn sideways/backwards when it does not lead deeper);
-- * the point is always at least ESCAPE_RADIUS from the tower AND at least ESCAPE_MIN_STEP from us,
-- so the escape order really takes us out of the shots instead of "moving 20 units".
function LN.TowerEscapePoint(bot, tower)
    local cfg = C.TOWER or {}
    local radius = cfg.ESCAPE_RADIUS or 900
    local minStep = cfg.ESCAPE_MIN_STEP or 240
    local fountain = U.GetFountain(bot)
    local tLoc = tower:GetLocation()
    local botLoc = bot:GetLocation()

    local away = botLoc - tLoc
    local dBot = U.DistanceBetweenLocations(botLoc, tLoc)
    if dBot < 1 then away = fountain - tLoc end
    away = away:Normalized()

    local toHome = fountain - tLoc
    if U.DistanceBetweenLocations(fountain, tLoc) < 1 then toHome = away end
    toHome = toHome:Normalized()
    local align = away.x * toHome.x + away.y * toHome.y

    -- The perpendicular to the AXIS "tower -> my fountain" (not to "away from the tower"): it is the same for the whole map,
    -- so the escape side does not jump when the hero stands exactly on that axis.
    -- The perpendicular to away degenerates at align ~ -1: the smallest hero movement flipped
    -- the direction by 180 degrees - that was the "jitters in place under the tower".
    local perp = Vector(-toHome.y, toHome.x, 0)

    local dir
    if align < -0.5 then
        -- We are deep BEHIND the tower: the shortest way out is sideways, with a slight outward tilt.
        -- The old mix away*0.55 + toHome*0.45 at align = -1 summed to -0.10*toHome,
        -- i.e. it led even deeper into the enemy base.
        dir = (away * 0.35 + perp * 0.94):Normalized()
    else
        -- The normal case: outward with a tilt toward my fountain. The 0.75/0.30 mix never cancels
        -- for any align, so the direction is always stable.
        dir = (away * 0.75 + toHome * 0.30):Normalized()
    end

    local extra = minStep - (radius - dBot)
    if extra < 0 then extra = 0 end
    -- +60: the point is safely BEYOND the escape radius, otherwise on arrival d == radius and the escape
    -- commitment would not clear until its timer expired
    return tLoc + dir * (radius + extra + 60)
end

-- A point on the far side of the enemy tower (the tower stands between it and our fountain).
-- Do not go there without a creep shield: the way back leads through its attack radius.
function LN.IsBeyondTower(bot, tower, loc)
    if not tower or not loc then return false end
    local okL, tLoc = pcall(tower.GetLocation, tower)
    if not okL or not tLoc then return false end
    local fountain = U.GetFountain(bot)
    if U.DistanceBetweenLocations(fountain, tLoc) < 1 then return false end
    local toHome = (fountain - tLoc):Normalized()
    local v = loc - tLoc
    return (v.x * toHome.x + v.y * toHome.y) < -60
end

-- Zoning

-- The position between the enemy and my wave at distance holdDist from the enemy.
-- Do not move further than maxFromWave from the wave; do not go under the enemy T1.
function LN.ZonePosition(bot, enemy, allyCreeps, holdDist, maxFromWave)
    if not U.CanQuery(enemy) then return nil end
    local enLoc = enemy:GetLocation()
    local waveCenter = LN.AllyWaveCenter(allyCreeps)
    local anchor = waveCenter or U.GetFountain(bot)
    local dir = anchor - enLoc
    local dAnchor = U.DistanceBetweenLocations(anchor, enLoc)
    if dAnchor < 1 then dir = U.GetFountain(bot) - enLoc end
    dir = dir:Normalized()
    local hold = holdDist or 520
    local pos = enLoc + dir * hold
    if waveCenter then
        local dWave = U.DistanceBetweenLocations(pos, waveCenter)
        local limit = maxFromWave or 520
        if dWave > limit then
            -- The enemy is far from the wave: stay by the wave on the enemy's side
            local toEnemy = (enLoc - waveCenter):Normalized()
            pos = waveCenter + toEnemy * limit
        end
    end
    return pos
end

-- How close the enemy is to my wave (the minimum distance to one of my creeps).
function LN.EnemyDistToAllyWave(enemy, allyCreeps)
    if not U.CanQuery(enemy) then return math.huge end
    local eLoc = enemy:GetLocation()
    local best = math.huge
    for _, c in pairs(allyCreeps or EMPTY) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, eLoc)
            if d < best then best = d end
        end
    end
    return best
end

-- Push

-- The best push target among the enemy creeps (closer and lower HP are preferred).
-- The creep to push with right clicks. Hit the "fat" creeps: a creep our own creeps will finish anyway
-- (HP <= ~2.5 of my hits) is a last-hit candidate, and push-hitting it only breaks the last-hit timing
-- (previously low HP was preferred instead -> creeps were "cut" into the zone where our own finished them).
function LN.PushHpFloor(bot, c, allyCreeps)
    -- below this HP a creep is a last-hit candidate, do not touch it with a push hit:
    -- 2.5 of my hits + what my creeps take off it in ~1.2 s (while my attack cycle is in flight)
    local myDmg = bot:GetAttackDamage() or 50
    local focus = 0
    for _, a in pairs(allyCreeps or EMPTY) do
        if a and U.CanQuery(a) and a:GetAttackTarget() == c then focus = focus + 1 end
    end
    return myDmg * 2.5 + focus * 21 * 1.2
end

function LN.BestPushCreep(bot, enemyCreeps, maxRange, allyCreeps)
    local best, bestScore = nil, math.huge
    local fallback, fallbackScore = nil, math.huge
    for _, c in pairs(enemyCreeps or EMPTY) do
        if c and U.CanQuery(c) then
            local d = GetUnitToLocationDistance(bot, c:GetLocation())
            if d <= (maxRange or 700) then
                local hp = c:GetHealth() or 0
                local score = -hp + d * 0.15
                if IsSiege(c) then score = score + 200 end
                if hp > LN.PushHpFloor(bot, c, allyCreeps) then
                    if score < bestScore then bestScore, best = score, c end
                else
                    if d < fallbackScore then fallbackScore, fallback = d, c end
                end
            end
        end
    end
    return best or fallback
end

-- Can we hit the T1: a shield of >= minShield creeps (closer to the tower than me), the tower is not on me.
function LN.CanHitTower(bot, tower, allyCreeps, minShield)
    if not tower or not tower:IsAlive() then return false end
    local danger = LN.TowerDanger(bot, tower, allyCreeps, nil)
    if danger >= 2 then return false end
    local shield = LN.TowerShieldCount(tower, allyCreeps, bot:GetLocation())
    return shield >= (minShield or 2)
end

-- How many of my hits are left before the tower falls (math.huge if there is no data).
function LN.TowerHitsToKill(bot, tower)
    if not tower or not U.CanQuery(tower) then return math.huge end
    local okA, alive = pcall(tower.IsAlive, tower)
    if not okA or not alive then return math.huge end
    local okH, hp = pcall(tower.GetHealth, tower)
    if not okH or type(hp) ~= "number" or hp <= 0 then return math.huge end
    local raw = bot:GetAttackDamage() or 0
    if raw <= 0 then return math.huge end
    local okD, dmg = pcall(tower.GetActualIncomingDamage, tower, raw, DAMAGE_TYPE_PHYSICAL)
    if not okD or type(dmg) ~= "number" or dmg <= 0 then return math.huge end
    return math.ceil(hp / dmg)
end

-- The tower is nearly down - finish it despite the shield, HP and the "burn" (breaking the T1 wins).
-- The condition is self-consistent: HP must last exactly as many of its shots as there are
-- of my hits left - i.e. we break the tower before it kills us.
function LN.IsTowerFinishable(bot, tower)
    local cfg = C.PUSH or {}
    local hits = LN.TowerHitsToKill(bot, tower)
    if hits > (cfg.TOWER_FINISH_HITS or 3) then return false end
    local hp = bot:GetHealth() or 0
    local hpPct = hp / math.max(1, bot:GetMaxHealth() or 1)
    if hpPct < (cfg.TOWER_FINISH_MIN_HP or 0.22) then return false end
    local okD, tDmg = pcall(tower.GetAttackDamage, tower)
    if okD and type(tDmg) == "number" and tDmg > 0 then
        local okI, per = pcall(bot.GetActualIncomingDamage, bot, tDmg, DAMAGE_TYPE_PHYSICAL)
        if okI and type(per) == "number" and per > 0 and hp < per * hits then return false end
    end
    return true
end


return LN

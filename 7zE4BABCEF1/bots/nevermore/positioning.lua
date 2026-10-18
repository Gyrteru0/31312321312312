
local C = require("bots/nevermore/constants")

local P = {}

function P.GetFountain(bot)
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function P.GetT1Tower(bot)
    -- Map coordinates change; use the actual allied mid T1, not an old map's point.
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local tower = GetTower(bot:GetTeam(), TOWER_MID_1)
        if tower and tower:IsAlive() then return tower:GetLocation() end
    end
    return bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.RADIANT_T1 or C.POSITIONS.DIRE_T1
end

function P.GetT1Close(bot, distance)
    local tower = P.GetT1Tower(bot)
    local enemyTeam = bot:GetTeam() == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
    local enemyLoc = bot:GetTeam() == TEAM_RADIANT and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    if type(GetTower) == "function" and TOWER_MID_1 ~= nil then
        local enemyTower = GetTower(enemyTeam, TOWER_MID_1)
        if enemyTower then enemyLoc = enemyTower:GetLocation() end
    end
    local home = (enemyLoc - tower):Normalized()
    -- Default hold: 180; safe wave scouting requests 500 on the same axis.
    return tower + home * (distance or 180)
end

function P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, prepareTarget, mode)
    local fountain = P.GetFountain(bot)

    if not allyCreeps or #allyCreeps == 0 then return P.GetT1Close(bot) end

    if prepareTarget and prepareTarget:IsAlive() then
        local numEnemies = enemyCreeps and #enemyCreeps or 0
        if (allyCreeps and #allyCreeps > 0) or numEnemies <= 2 then
            local dir = (fountain - prepareTarget:GetLocation()):Normalized()
            return prepareTarget:GetLocation() + dir * 150
        end
    end

    -- The front creep = the one closest to the ENEMY T1 (previously the one closest to the map centre was taken,
    -- and when the wave moved past the centre the bot stood behind the last creep - last hits were lost).
    local enemyT1 = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.DIRE_T1 or C.POSITIONS.RADIANT_T1
    local frontAlly = allyCreeps[1]
    local minDist = math.huge
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local d = GetUnitToLocationDistance(c, enemyT1)
            if d < minDist then
                minDist = d
                frontAlly = c
            end
        end
    end
    local dir = (fountain - frontAlly:GetLocation()):Normalized()
    local dist_from_creeps = 450
    if mode == "PASSIVE" then
        dist_from_creeps = 650
    elseif mode == "AGGRESSIVE" then
        dist_from_creeps = 250
    end
    return frontAlly:GetLocation() + dir * dist_from_creeps
end

return P

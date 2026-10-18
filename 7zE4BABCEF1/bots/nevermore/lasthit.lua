
local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local L = {}

-- Skip windows our next projectile cannot reach; do not let a doomed creep block the wave.
function L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNear)
    local best, bestScore, bestDeny=nil,math.huge,false
    local function consider(c,deny,attackers)
        if not U.CanQuery(c) then return end
        if deny and c:GetHealth()/math.max(1,c:GetMaxHealth())>C.LASTHIT.DENY_HP_THRESHOLD then return end
        local opening,closing=U.GetTimeToKillable(bot,c,attackers)
        if opening<0 or opening>=5 then return end
        closing=closing or 999
        local earliest,latest=U.GetAttackImpactWindow(bot,c)
        local lead=opening>0 and ((C.LASTHIT and C.LASTHIT.IMPACT_LEAD) or 0.025) or 0
        local arrival=math.max(latest,opening+lead+(latest-earliest))
        if arrival>=closing-0.03 then return end
        local score=math.max(opening,earliest)
        local name=c:GetUnitName() or ""
        if name:find("ranged") then score=score-0.12 end
        if name:find("flagbearer") then score=score-0.10 end
        if name:find("siege") then score=score-0.08 end
        -- Take a reachable expiring window before a creep that can wait another attack cycle.
        if closing<arrival+bot:GetSecondsPerAttack() then score=score-0.30 end
        if deny then score=score+((enemyNear==false) and 1.2 or 0.2) end
        if score<bestScore then best,bestScore,bestDeny=c,score,deny end
    end
    for _,c in pairs(enemyCreeps or {}) do consider(c,false,allyAttackers) end
    for _,c in pairs(allyCreeps or {}) do consider(c,true,enemyAttackers) end
    return best,bestDeny
end

return L


local C = require("bots/nevermore/constants")
local S = require("bots/nevermore/souls")

local U = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

local function Atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function Clamp(v, minValue, maxValue)
    if v < minValue then return minValue end
    if v > maxValue then return maxValue end
    return v
end

function U.CanQuery(unit)
    if not unit then return false end
    if not unit:IsAlive() then return false end
    if unit.CanBeSeen and not unit:CanBeSeen() then return false end
    return true
end

function U.MergeLists(list1, list2)
    local result = {}
    if list1 then for _, v in pairs(list1) do table.insert(result, v) end end
    if list2 then for _, v in pairs(list2) do table.insert(result, v) end end
    return result
end

function U.DistanceBetweenLocations(a, b)
    if not a or not b then return math.huge end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

function U.GetRazeLabelByDistance(dist, radius)
    radius = radius or C.RAZE.STRICT_RADIUS
    local candidates = {
        { label = "near", center = C.RAZE.NEAR_CENTER },
        { label = "mid",  center = C.RAZE.MID_CENTER  },
        { label = "far",  center = C.RAZE.FAR_CENTER  },
    }
    local bestLabel = nil
    local bestDiff = math.huge
    for _, v in ipairs(candidates) do
        local diff = math.abs(dist - v.center)
        if diff < bestDiff then
            bestDiff = diff
            bestLabel = v.label
        end
    end
    if bestDiff <= radius then
        return bestLabel, bestDiff
    end
    return nil, bestDiff
end

function U.GetRazeCenterByLabel(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid"  then return C.RAZE.MID_CENTER end
    if label == "far"  then return C.RAZE.FAR_CENTER end
    return nil
end


function U.GetTeamFountain(team)
    return team == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function U.GetFountain(bot)
    return U.GetTeamFountain(bot:GetTeam())
end

-- Context for forecasting the target (creep) HP under attacker hits.
-- Discrete hit model. For every attacker hitting the target we take the time of its
-- last attack (GetLastAttackTime) and its attack period (GetSecondsPerAttack): the next attack
-- lands at lastAttack + spa (+ projectile flight for ranged/towers). This removes the main source
-- of "hit too early / too late" errors - the averaged DPS that smeared
-- the discrete creep hits (21 damage once a second) over time.
-- If the attacker's rhythm is unknown (it just arrived/switched targets, no GetLastAttackTime) -
-- the hit counts as "uncertain": in the pessimistic estimate (HP at my impact) it lands
-- late, in the optimistic one (does the creep die before my impact) - early.
-- Observe attack-animation starts; never turn an unknown mid-cycle animation
-- into a guaranteed hit. Weak keys do not retain dead creeps for the whole match.
local swing = setmetatable({}, {__mode = "k"})
local function ObservedWindup(atk, target, now, ap)
    if not atk.GetAnimActivity or not atk.GetAnimCycle then return nil end
    local activity = atk:GetAnimActivity()
    local attacking = (ACTIVITY_ATTACK ~= nil and activity == ACTIVITY_ATTACK)
        or (ACTIVITY_ATTACK2 ~= nil and activity == ACTIVITY_ATTACK2)
    if not attacking then swing[atk] = nil; return nil end
    local cycle = atk:GetAnimCycle()
    local old = swing[atk]
    if not old or old.target ~= target or cycle + 0.05 < old.cycle then
        old = {target = target, start = now, known = cycle <= 0.08}
        swing[atk] = old
    end
    old.cycle = cycle
    if old.known and now - old.start <= ap then
        return math.max(0, ap - (now - old.start))
    end
    return nil
end

local function AttackerNextImpact(atk, target, now)
    -- returns tImpact (seconds from now), period, certain(bool), travel
    local spa = atk:GetSecondsPerAttack()
    if not spa or spa <= 0 then spa = 1.0 end
    local travel = 0
    local ranged = false
    if atk:IsTower() then
        ranged = true
        travel = GetUnitToLocationDistance(target, atk:GetLocation()) / 750 + 0.07
    else
        local ps = atk.GetAttackProjectileSpeed and atk:GetAttackProjectileSpeed() or 0
        if ps and ps > 0 then
            ranged = true
            travel = GetUnitToLocationDistance(target, atk:GetLocation()) / ps
        elseif (atk:GetUnitName() or ""):find("siege") then
            ranged = true
            travel = GetUnitToLocationDistance(target, atk:GetLocation()) / 1100
        end
    end
    local last = nil
    if atk.GetLastAttackTime then
        local ok, v = pcall(atk.GetLastAttackTime, atk)
        if ok and type(v) == "number" and v > 0 then last = v end
    end
    local ap = (atk.GetAttackPoint and atk:GetAttackPoint()) or 0.5
    local windup = ObservedWindup(atk, target, now, ap)
    if windup then return windup + travel, spa, true, travel, ranged end
    if last and (now - last) <= spa + 0.35 then
        local tNext = (last + spa) - now
        if tNext < 0.02 then tNext = 0.02 end
        return tNext + travel, spa, true, travel, ranged
    end
    -- Rhythm unknown: the first hit no earlier than the attack point, no later than a full cycle
    return ap + travel, spa, false, travel, ranged
end

-- Simulations must not mutate the shared live snapshot.
function U.WithHypotheticalDamage(ctx, damage)
    local copy = {}
    for k, v in pairs(ctx) do copy[k] = v end
    copy.hp = ctx.hp - damage
    return copy
end

function U.BeginPredictionFrame()
    U._predictionFrame = {time = GameTime(), targets = {}}
end

function U.GetTargetPredictionContext(target, all_attackers)
    local now = GameTime()
    local frame = U._predictionFrame
    local cached = frame and frame.time == now and frame.targets[target]
    if cached and cached.attackers == all_attackers then return cached.ctx end
    local ctx = {
        hp = target:GetHealth(),
        regen = target:GetHealthRegen() or 0,
        projs = target:GetIncomingTrackingProjectiles() or {},
        dps = 0, -- fallback averaged model (attackers without data)
        hits = {}, -- Discrete hits: { t, period, dmgLo, dmgHi, certain, slack }
        scheduled = {}, -- caster -> true: the repeats of its projectiles are already accounted for in hits
        projDmg = {}, -- caster -> the damage of its in-flight projectile
    }

    local flying_casters = {}
    for _, p in pairs(ctx.projs) do
        if p.is_attack and p.caster and U.CanQuery(p.caster) then
            flying_casters[p.caster] = true
        end
    end

    if all_attackers then
        for _, atk in pairs(all_attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then
                local avgDmg = atk:GetAttackDamage() or 0
                if avgDmg > 0 then
                    local var = 0
                    if atk.GetBaseDamageVariance then
                        local ok, v = pcall(atk.GetBaseDamageVariance, atk)
                        if ok and type(v) == "number" then var = v end
                    end
                    local dmgLo = target:GetActualIncomingDamage(avgDmg - var, DAMAGE_TYPE_PHYSICAL)
                    local dmgHi = target:GetActualIncomingDamage(avgDmg + var, DAMAGE_TYPE_PHYSICAL)
                    if atk:IsTower() or ((atk:GetUnitName() or ""):find("siege")) then
                        -- Tower/siege: no spread - the average damage
                        dmgLo = target:GetActualIncomingDamage(avgDmg, DAMAGE_TYPE_PHYSICAL)
                        dmgHi = dmgLo
                    end
                    ctx.projDmg[atk] = (dmgLo + dmgHi) * 0.5
                    local tImpact, period, certain, travel, ranged = AttackerNextImpact(atk, target, now)
                    -- The attacker itself is near death (one creep hit kills it): its future hits may
                    -- not happen -> the pessimistic estimate does not count them
                    local fragile = (not atk:IsTower()) and ((atk:GetHealth() or 999) <= 30)
                    -- The enemy hero is an unreliable "attacker" (he cancels swings, walks away, hits
                    -- with single clicks): we do not model his damage in any mode (otherwise the bot would either
                    -- count on his attack or "yield" a contested creep to him). Instead we
                    -- mark the target as CONTESTED (ctx.contested): the last hit uses the average model rather than
                    -- the pessimistic one - a 50/50 chance beats a guaranteed "he took it".
                    local isHero = (atk.IsHero and atk:IsHero()) and true or false
                    if isHero then ctx.contested = true end
                    if flying_casters[atk] then
                        -- His projectile is already in flight (counted in projs): the next LAUNCH is period after
                        -- his last attack -> the first "ours" hit = tImpact (it already includes period)
                        if not certain then
                            tImpact = period + travel
                            certain = true -- A projectile in flight = he is in his attack rhythm
                        end
                    end
                    ctx.scheduled[atk] = true
                    table.insert(ctx.hits, {
                        t = tImpact, period = period, dmgLo = dmgLo, dmgHi = dmgHi,
                        certain = certain, fragile = fragile, hero = isHero,
                        -- Uncertain hit: may land up to slack later (until the end of the cycle)
                        slack = certain and 0.0 or math.max(0, period - ((atk.GetAttackPoint and atk:GetAttackPoint()) or 0.5)),
                    })
                end
            end
        end
    end
    -- Snapshot projectile speed/damage once, not in every prediction sample.
    ctx.projectileHits = {}
    for _, projectile in pairs(ctx.projs) do
        local caster = projectile.caster
        if projectile.is_attack and caster and projectile.location and U.CanQuery(caster) then
            local speed = caster:GetAttackProjectileSpeed() or 0
            local tower = caster:IsTower()
            if speed <= 0 then speed = tower and 750 or 900 end
            local t = GetUnitToLocationDistance(target, projectile.location) / speed + (tower and 0.07 or 0)
            local dmg = ctx.projDmg[caster] or target:GetActualIncomingDamage(caster:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
            -- A launched projectile remains real even if its caster changed target;
            -- imaginary repeat attacks from that caster must NOT be added.
            table.insert(ctx.projectileHits, {t = t, dmg = dmg})
        end
    end
    if frame and frame.time == now then
        frame.targets[target] = {attackers = all_attackers, ctx = ctx}
    end
    return ctx
end

-- mode: nil/"avg" - average damage, uncertain hits at face value;
-- "max"     - pessimistic for the last hit (the creep stays with MORE HP): uncertain
-- hits late, damage minimal;
-- "min"     - the creep dies EARLIER: uncertain hits early, damage maximal.
function U.PredictHPWithContext(ctx, target, time_in_future, mode)
    if ctx.hp <= 0 then return 0 end
    mode = mode or "avg"
    local predicted_hp = ctx.hp + ((ctx.regen or 0) * time_in_future)
    if ctx.dps and ctx.dps > 0 then
        predicted_hp = predicted_hp - (ctx.dps * time_in_future)
    end

    -- Immutable per-frame projectile snapshot: no engine queries in the inner loop.
    for _, hit in ipairs(ctx.projectileHits or {}) do
        if hit.t <= time_in_future then predicted_hp = predicted_hp - hit.dmg end
    end

    -- Discrete attacker hits
    if ctx.hits then
        for _, h in ipairs(ctx.hits) do
            local dmg
            if mode == "max" then dmg = h.fragile and 0 or h.dmgLo
            elseif mode == "min" then dmg = h.dmgHi
            else dmg = (h.dmgLo + h.dmgHi) * 0.5 end
            if h.hero then dmg = 0 end -- The hero's attack is not modelled (see ctx.contested)
            local t = h.t
            if not h.certain then
                if mode == "max" then t = t + (h.slack or 0)
                elseif mode == "avg" then t = t + (h.slack or 0) * 0.5 end
            end
            while t <= time_in_future do
                predicted_hp = predicted_hp - dmg
                t = t + h.period
            end
        end
    end

    -- The old format (virtual_projs) - in case of external calls
    if ctx.virtual_projs then
        for _, vp in pairs(ctx.virtual_projs) do
            if vp.t_impact <= time_in_future then
                predicted_hp = predicted_hp - vp.actualDmg
                local next_impact = vp.t_impact + vp.bat
                while next_impact <= time_in_future do
                    predicted_hp = predicted_hp - vp.actualDmg
                    next_impact = next_impact + vp.bat
                end
            end
        end
    end

    return predicted_hp
end

function U.HasLasthitWindow(ctx, target, my_dmg, min_time)
    min_time = min_time or 0
    for t = 0.05, 3.0, 0.05 do
        local hp = U.PredictHPWithContext(ctx, target, t)
        if hp <= 0 then
            return false
        elseif hp <= my_dmg then
            if t >= min_time then return true end
        end
    end
    return false
end

-- My damage model. GetAttackDamage() in the Bot API may return either the average or an
-- already "rolled" random damage (like GetAttackDamage in the server API). Previously the spread
-- was subtracted from it too: on a minimum roll the threshold was lowered by the whole spread (up to 6 HP
-- at level 1 - a third of a creep hit), and finishing was systematically late precisely
-- early in the game where the spread is large relative to the damage. We detect the semantics at runtime from a
-- window of recent values: they jump around (non-monotonic) -> rolls: the window minimum = my minimum;
-- constant -> average: the minimum = average - half the base damage spread (SF 16-22 -> 3).
U._dmg = { buf = {}, n = 0, idx = 0, cap = 45, mode = "avg", reported = false }
local function MyDamageMinAvg(bot)
    local d = U._dmg
    local v = bot:GetAttackDamage() or 0
    d.idx = d.idx % d.cap + 1
    d.buf[d.idx] = v
    if d.n < d.cap then d.n = d.n + 1 end
    local lo, hi = math.huge, -math.huge
    local flips, prev, dir = 0, nil, 0
    for k = 1, d.n do
        local i = (d.idx - d.n + k - 1) % d.cap + 1
        local x = d.buf[i]
        if x < lo then lo = x end
        if x > hi then hi = x end
        if prev then
            local nd = 0
            if x > prev then nd = 1 elseif x < prev then nd = -1 end
            if nd ~= 0 then
                if dir ~= 0 and nd ~= dir then flips = flips + 1 end
                dir = nd
            end
        end
        prev = x
    end
    local half = (C.HERO and C.HERO.DAMAGE_HALF_RANGE) or 3
    local rolled = (hi - lo) >= 3 and flips >= 3
    local mode = rolled and "rolled" or "avg"
    local changed = (mode ~= d.mode)
    d.mode = mode
    -- Report once to the console which semantics GetAttackDamage has (for cross-checking in game)
    if (not d.reported and d.n >= 25) or (changed and U.DEBUG) then
        d.reported = true
        local okV, bv = pcall(bot.GetBaseDamageVariance, bot)
        print(string.format("[SF-BOT] damage model: %s (window %.0f..%.0f, n=%d, api variance=%s, half-range used=%d)",
            mode, lo, hi, d.n, okV and tostring(bv) or "?", half))
    end
    if rolled then
        local est = lo
        if d.n < 25 then est = lo - 1 end -- The window is still short: the minimum may not have appeared yet
        return est, (lo + hi) * 0.5
    end
    return v - half, v
end

function U.SFDamageRange(bot, target)
    local rawMin, rawAvg = MyDamageMinAvg(bot)
    local actualMin = target:GetActualIncomingDamage(rawMin, DAMAGE_TYPE_PHYSICAL)
    local actualAvg = target:GetActualIncomingDamage(rawAvg, DAMAGE_TYPE_PHYSICAL)

    if target and target:IsAlive() then
        local name = target:GetUnitName() or ""
        if name:find("siege") then
            actualMin = actualMin * 0.5
            actualAvg = actualAvg * 0.5
        end
    end

    return { min = actualMin, avg = actualAvg }
end

function U.GetEffectiveDamageAndMargin(bot, target, attackersCount)
    local range = U.SFDamageRange(bot, target)
    local base_margin = 0
    if attackersCount and attackersCount >= 3 then base_margin = 2 end
    return range.min, base_margin
end

-- Earliest/latest impact of a NEW attack order. Walking and attack cooldown run concurrently.
function U.GetAttackImpactWindow(bot,target)
    local loc,goal=bot:GetLocation(),target:GetLocation()
    local distance=U.DistanceBetweenLocations(loc,goal)
    local range=bot:GetAttackRange() or 525
    local speed=math.max(1,bot:GetCurrentMovementSpeed() or 305)
    local projectileSpeed=math.max(1,bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED)
    local angle=U.GetAngleDifference(bot,goal)
    local turn=angle>15 and 0.03*math.rad(angle)/0.9 or 0
    local walk=math.max(0,distance-range)/speed
    local paddedWalk=distance>range and (distance-range+25)/speed or 0
    local ready=0
    local last=bot.GetLastAttackTime and bot:GetLastAttackTime() or -100
    if last>0 then ready=math.max(0,last+bot:GetSecondsPerAttack()-GameTime()) end
    local ap=bot:GetAttackPoint() or 0.5
    local flight=math.min(distance,range)/projectileSpeed
    return math.max(walk+turn+ap,ready)+flight,
        math.max(paddedWalk+turn+ap,ready)+flight+(C.LASTHIT.NET_LATENCY or 0.05)
end

function U.LastHitImpactFits(earliest, latest, opening, closing)
    if opening < 0 or opening >= 999 then return false end
    -- An already killable creep needs no additional wait.
    local lead = opening > 0 and ((C.LASTHIT and C.LASTHIT.IMPACT_LEAD) or 0.025) or 0
    return earliest >= opening + lead and (not closing or latest < closing - 0.03)
end

-- When the creep becomes killable by my attack.
-- Returns t, tEnd, gamble:
-- t     = 0      - killable right now (HP <= threshold);
-- t     > 0      - in t seconds the HP will (pessimistically) certainly drop to the threshold;
-- t     = -1     - our own creeps kill it before it becomes killable (no window);
-- t     = 999    - it will not become killable within the 5 s horizon;
-- tEnd           - the moment the creep may die without me (optimistic): my attack
-- must land in [t, tEnd);
-- gamble = true  - there is no guaranteed window, t comes from the average model (a chance, not a guarantee).
function U.GetTimeToKillable(bot, target, attackers)
    local atkCount = 0
    if attackers then
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target
                and not (atk.IsHero and atk:IsHero()) then -- A hero does not increase the margin
                atkCount = atkCount + 1
            end
        end
    end

    local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
    local kill_threshold = dmg - safety_margin
    local currentHP = target:GetHealth()

    local ctx = U.GetTargetPredictionContext(target, attackers)
    -- A contested creep (the enemy hero is already targeting it) - the "safe" window is computed with
    -- the average model: waiting for the pessimistic moment means giving the creep to him
    local safeMode = ctx.contested and "avg" or "max"
    -- HP drops at discrete impacts, not on a 50-ms sampling grid. Evaluate each
    -- possible impact once and preserve the conservative/average fallback policy.
    local events = {0}
    for _, hit in ipairs(ctx.projectileHits or {}) do
        if hit.t >= 0 and hit.t <= 5 then events[#events + 1] = hit.t + 0.000001 end
    end
    for _, hit in ipairs(ctx.hits or {}) do
        if not hit.hero and hit.period > 0 then
            for _, offset in ipairs({0, (hit.slack or 0) * 0.5, hit.slack or 0}) do
                local t = math.max(0, hit.t + offset)
                while t <= 5 do
                    events[#events + 1] = t + 0.000001
                    t = t + hit.period
                end
            end
        end
    end
    table.sort(events)
    local unique = {}
    for _, t in ipairs(events) do
        if #unique == 0 or t - unique[#unique] > 0.00001 then unique[#unique + 1] = t end
    end
    events = unique
    local tSafe, tDie = nil, nil
    for _, t in ipairs(events) do
        if not tDie then
            local lo = U.PredictHPWithContext(ctx, target, t, "min")
            if lo <= 0 then tDie = t end
        end
        if not tSafe then
            local hi = U.PredictHPWithContext(ctx, target, t, safeMode)
            if hi <= kill_threshold then tSafe = t end
        end
        if tSafe and tDie then break end
    end
    if tSafe and (not tDie or tSafe < tDie) then
        return tSafe, tDie or 999, ctx.contested and true or false
    end
    -- No guaranteed window: the average model (a chance)
    for _, t in ipairs(events) do
        local predHP = U.PredictHPWithContext(ctx, target, t, "avg")
        if predHP <= 0 then
            return -1, t, true
        elseif predHP <= kill_threshold then
            return t, tDie or 999, true
        end
    end
    return 999, 999, false
end

function U.GetActiveItemByName(bot, name)
    local slot = bot:FindItemSlot(name)
    if slot >= 0 and slot <= 5 then
        local item = bot:GetItemInSlot(slot)
        if item and item:IsFullyCastable() then return item end
    end
    return nil
end

local function TPFromHandle(item)
    if not item then return nil end
    local okN, nm = pcall(function() return item:GetName() end)
    if okN and type(nm) == "string" and nm:find("tpscroll") then return item end
    return nil
end

function U.GetTPScroll(bot)
    -- In the real API the TP scroll lives in a dedicated slot that GetItemInSlot/FindItemSlot
    -- do not always see (the Item_Slot_Types enum has no "TP" type at all). Try every way:
    -- FindItemSlot -> slot scan -> GetAbilityByName (items in the engine are the same handles as abilities).
    local ok, slot = pcall(function() return bot:FindItemSlot("item_tpscroll") end)
    if ok and type(slot) == "number" and slot >= 0 then
        local okI, item = pcall(function() return bot:GetItemInSlot(slot) end)
        if okI then
            local it = TPFromHandle(item)
            if it then return it, slot end
        end
    end
    for i = 0, 16 do
        local okI, item = pcall(function() return bot:GetItemInSlot(i) end)
        if okI then
            local it = TPFromHandle(item)
            if it then return it, i end
        end
    end
    local okA, ab = pcall(function() return bot:GetAbilityByName("item_tpscroll") end)
    if okA then
        local it = TPFromHandle(ab)
        if it then return it, -1 end
    end
    return nil, -1
end

-- The enemy is teleporting (an item_tpscroll channel). SF has no other channels, so
-- IsChanneling without an active ability name also counts as a TP.
function U.IsEnemyTPChanneling(enemy)
    if not enemy then return false end
    local okC, ch = pcall(function() return enemy:IsChanneling() end)
    if not okC or not ch then return false end
    local okA, ab = pcall(function() return enemy:GetCurrentActiveAbility() end)
    if okA and ab then
        local okN, nm = pcall(function() return ab:GetName() end)
        if okN and nm ~= "item_tpscroll" then return false end
    end
    return true
end

function U.GetConsumableManaBurst(unit)
    if not unit then return 0 end
    local burst = 0
    burst = burst + U.GetMangoMana(unit) -- By charges
    return burst
end

function U.GetStickCharges(unit)
    if not unit then return 0 end
    local best = 0
    for i = 0, 8 do
        local item = unit:GetItemInSlot(i)
        if item then
            local name = item:GetName()
            if name == "item_magic_wand" or name == "item_magic_stick" then
                local charges = (item.GetCurrentCharges and item:GetCurrentCharges()) or 0
                if charges > best then best = charges end
            end
        end
    end
    return best
end

-- Mangoes stack as charges in one slot: count the CHARGES (each = +100 mana, eaten
-- instantly), not "has the item = +100". Main inventory only (0-5): you cannot eat from the backpack.
-- For the enemy hero - the same slot walk (the Bot API exposes the items of a visible hero).
function U.GetMangoCharges(unit)
    if not unit then return 0 end
    local total = 0
    for i = 0, 5 do
        local okI, item = pcall(unit.GetItemInSlot, unit, i)
        if okI and item then
            local okN, name = pcall(item.GetName, item)
            if okN and name == "item_enchanted_mango" then
                local ch = 1
                if item.GetCurrentCharges then
                    local okC, c = pcall(item.GetCurrentCharges, item)
                    if okC and type(c) == "number" and c > 0 then ch = c end
                end
                total = total + ch
            end
        end
    end
    if total > 4 then total = 4 end
    return total
end

function U.GetMangoMana(unit)
    return U.GetMangoCharges(unit) * 100
end

function U.GetPotentialManaForRaze(unit)
    if not unit then return 0 end
    local mana = unit:GetMana() or 0
    mana = mana + U.GetConsumableManaBurst(unit)
    local charges = U.GetStickCharges(unit)
    if charges > 0 then
        mana = mana + charges * 15
    end
    return mana
end

function U.HasBoots(unit)
    if not unit then return false end
    return U.HasItem(unit, "item_boots") or U.HasItem(unit, "item_power_treads")
end

function U.HasItem(unit, item_name)
    if not unit then return false end
    if not U.CanQuery(unit) and not unit:IsBot() then return false end
    for i = 0, 8 do -- inventory + backpack (the stash/TP slot is not counted)
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then return true end
    end
    return false
end

function U.GetItemCount(unit, item_name)
    if not unit then return 0 end
    if not U.CanQuery(unit) and not unit:IsBot() then return 0 end
    local count = 0
    for i = 0, 8 do
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then
            count = count + 1
        end
    end
    return count
end

function U.GetLaneItemPower(unit)
    if not unit then return 0 end
    local score = 0
    score = score + U.GetItemCount(unit, "item_bracer") * 0.90
    score = score + U.GetItemCount(unit, "item_magic_wand") * 0.35
    score = score + U.GetItemCount(unit, "item_magic_stick") * 0.20
    if U.HasItem(unit, "item_boots") then score = score + 0.25 end
    if U.HasItem(unit, "item_power_treads") then score = score + 0.50 end
    if U.HasItem(unit, "item_kaya") then score = score + 1.00 end
    if U.HasItem(unit, "item_dragon_lance") then score = score + 0.90 end
    return score
end

function U.ManageInventorySlots(bot)
    for bpSlot = 6, 8 do
        local bpItem = bot:GetItemInSlot(bpSlot)
        if bpItem then
            local bpPrio = C.ITEM_PRIORITY[bpItem:GetName()] or 0
            if bpItem:GetName() == "item_ward_observer" then bpPrio = 999 end
            local worstSlot = -1
            local worstPrio = 999
            local hasEmptySlot = false
            for invSlot = 0, 5 do
                local invItem = bot:GetItemInSlot(invSlot)
                if not invItem then
                    hasEmptySlot = true
                    worstSlot = invSlot
                    break
                else
                    local invPrio = C.ITEM_PRIORITY[invItem:GetName()] or 0
                    if invPrio < worstPrio then
                        worstPrio = invPrio
                        worstSlot = invSlot
                    end
                end
            end
            if hasEmptySlot or bpPrio > worstPrio then
                bot:ActionImmediate_SwapItems(bpSlot, worstSlot)
                return
            end
        end
    end
end


function U.IsEnemyCastingRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if (r1 and r1:IsInAbilityPhase()) or
       (r2 and r2:IsInAbilityPhase()) or
       (r3 and r3:IsInAbilityPhase()) then
        return true
    end
    return false
end

function U.EnemyHasRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    if r1 and r1:GetLevel() > 0 then return true end
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    if r2 and r2:GetLevel() > 0 then return true end
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if r3 and r3:GetLevel() > 0 then return true end
    return false
end

U._razeTracker = {
    enemies = {},
    lastMissTime = -math.huge,
    lastMissEntindex = nil,
}

local function _getEnemyRazeTrackerEntry(enemy)
    if not enemy then return nil end
    local key = (enemy.GetPlayerID and enemy:GetPlayerID()) or tostring(enemy)
    if key == nil or (type(key) == "number" and key < 0) then key = tostring(enemy) end
    local entry = U._razeTracker.enemies[key]
    if not entry then
        entry = {
            wasCasting = false,
            lastPhaseEndTime = -math.huge,
            pendingMissCheck = false,
            pendingLabel = nil,
            prevDebuffStacks = 0,
            prevDebuffRemain = 0,
            lastHitLabel = nil,
            lastHitTime = -math.huge,
        }
        U._razeTracker.enemies[key] = entry
    end
    return entry
end

function U.UpdateEnemyRazeMissTracker(bot, enemy)
    if not U.CanQuery(enemy) then return end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return end

    local now = GameTime()
    local casting = U.IsEnemyCastingRaze(enemy)
    local stacksNow = U.GetShadowrazeDebuff(bot) or 0
    local previousStacks = entry.observedStacks or stacksNow
    if casting and not entry.wasCasting then
        entry.hitDuringCast = false
        entry.pendingLabel = nil
        for i, label in ipairs({"near", "mid", "far"}) do
            local ab = enemy:GetAbilityByName("nevermore_shadowraze" .. i)
            if ab and ab:IsInAbilityPhase() then entry.pendingLabel = label; break end
        end
    end
    local hitNow = stacksNow > previousStacks
    if hitNow then
        entry.lastHitTime = now
        entry.lastHitLabel = entry.pendingLabel
            or U.GetRazeLabelByDistance(GetUnitToLocationDistance(enemy, bot:GetLocation()), C.RAZE.HIT_RADIUS)
        entry.hitDuringCast = true
        entry.pendingMissCheck = false
    end
    entry.observedStacks = stacksNow

    if entry.wasCasting and not casting then
        entry.lastPhaseEndTime = now
        entry.pendingMissCheck = not entry.hitDuringCast
        entry.prevDebuffStacks = previousStacks
        local castDist = GetUnitToLocationDistance(enemy, bot:GetLocation())
        entry.pendingLabel = entry.pendingLabel or U.GetRazeLabelByDistance(castDist, C.RAZE.HIT_RADIUS)
    end

    entry.wasCasting = casting

    if entry.pendingMissCheck then
        local stacksNow = U.GetShadowrazeDebuff(bot) or 0
        if stacksNow > entry.prevDebuffStacks then
            entry.pendingMissCheck = false
            entry.lastHitLabel = entry.pendingLabel
                or U.GetRazeLabelByDistance(GetUnitToLocationDistance(enemy, bot:GetLocation()), C.RAZE.HIT_RADIUS)
            entry.lastHitTime = now
            entry.pendingLabel = nil
        elseif (now - entry.lastPhaseEndTime) >= C.RAZE.MISS_DETECT_WINDOW then
            entry.pendingMissCheck = false
            U._razeTracker.lastMissTime = now
            U._razeTracker.lastMissEntindex = (enemy.GetPlayerID and enemy:GetPlayerID()) or nil
            entry.pendingLabel = nil
        end
    end
end

function U.HasEnemyMissedRazeRecently()
    return (GameTime() - (U._razeTracker.lastMissTime or -math.huge)) <= C.RAZE.MISS_ADVANTAGE_TIME
end


function U.GetRecentEnemyRazeHitLabel(enemy)
    if not enemy then return nil end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return nil end
    return entry.lastHitLabel
end

function U.GetRecentEnemyRazeHitAge(enemy)
    if not enemy then return math.huge end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return math.huge end
    return GameTime() - (entry.lastHitTime or -math.huge)
end

function U.IsSecondStackDangerActive(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 or rem_time <= C.RAZE.RETREAT_MIN_REMAIN then
        return false, nil
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemy)
    if not hitLabel then return false, nil end
    return true, hitLabel
end

-- Is it safe for me to be in band label (at ~center(label) I stand in HIS
-- label band). It is safe while HIS copy of that band is on cooldown / unlearned / out of mana: he has nothing
-- to answer with. This is more precise than the old rule "only the band he hit us with last is safe".
function U.IsBandSafeForMe(enemy, label, marginSec)
    local K = U._K
    if not K or not K.BandSafeFromEnemy then return false end
    return K.BandSafeFromEnemy(enemy, label, marginSec or (C.RAZE.CAST_POINT + 0.15))
end



function U.IsEnemyHighValueRegen(enemy)
    if not U.CanQuery(enemy) then return false end
    if enemy:HasModifier("modifier_flask_healing") then return true end
    if enemy:HasModifier("modifier_clarity_potion") then return true end
    if enemy:HasModifier("modifier_bottle_regeneration") then return true end
    return false
end

function U.GetPlaystyle(bot, enemy, allyCreeps, enemyCreeps)
    if not U.CanQuery(enemy) then return "NEUTRAL" end

    local score = 0
    local myLvl = bot:GetLevel() or 1
    local eLvl = enemy:GetLevel() or 1
    score = score + (myLvl - eLvl) * 1.5

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    local myRazeLvl = q and q:GetLevel() or 0
    local eRazeLvl = eq and eq:GetLevel() or 0
    if myRazeLvl > eRazeLvl then score = score + 2.5 end
    if myRazeLvl < eRazeLvl then score = score - 2.5 end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local eHpPct = enemy:GetHealth() / enemy:GetMaxHealth()
    score = score + (myHpPct - eHpPct) * 3.2
    if bot:GetHealth() < 400 then score = score - 2.0 end
    if enemy:GetHealth() < 350 then score = score + 0.8 end

    local eHasMango = U.HasItem(enemy, "item_enchanted_mango")
    local myHasMango = U.HasItem(bot, "item_enchanted_mango")
    local eTotalMana = enemy:GetMana() + (eHasMango and 100 or 0)
    local myTotalMana = bot:GetMana() + (myHasMango and 100 or 0)
    if myTotalMana >= 150 and eTotalMana < 75 then score = score + 2.0 end
    if eTotalMana >= 150 and myTotalMana < 75 then score = score - 1.5 end

    local soulDmgDiff = S.GetSoulDamageBonus(bot) - S.GetSoulDamageBonus(enemy)
    score = score + Clamp(soulDmgDiff / 14.0, -2.5, 2.5)

    local itemPowerDiff = U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemy)
    score = score + Clamp(itemPowerDiff, -2.0, 2.0)

    local allyCount = allyCreeps and #allyCreeps or 0
    local enemyCount = enemyCreeps and #enemyCreeps or 0
    score = score + ((allyCount - enemyCount) * 0.25)

    if U.HasEnemyMissedRazeRecently() then score = score + 3.5 end
    if U.HasItem(bot, "item_power_treads") and not U.HasBoots(enemy) then
        score = score + 2.5
    end

    if score <= -2.0 then
        return "PASSIVE"
    elseif score >= 0.8 then
        return "AGGRESSIVE"
    else
        return "NEUTRAL"
    end
end

function U.GetShadowrazeDebuff(unit)
    if not unit then return 0, 0, -1 end
    local numModifiers = unit:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = unit:GetModifierName(i)
            if modName == "modifier_nevermore_shadowraze_debuff" then
                local stacks = unit:GetModifierStackCount(i) or 0
                local remaining = unit:GetModifierRemainingDuration(i) or 0
                return stacks, remaining, i
            end
        end
    end
    return 0, 0, -1
end

-- Position prediction from the REAL velocity (GetVelocity), not "facing x max speed".
-- The old version assumed that a standing enemy (e.g. finishing a creep) moves ~190 units
-- toward his facing in 0.62 s -> razes at a standing enemy missed systematically.
function U.PredictPosition(unit, delay)
    local loc = unit:GetLocation()
    if not loc then return loc end
    delay = delay or 0
    local vel = nil
    if unit.GetVelocity then
        local ok, v = pcall(unit.GetVelocity, unit)
        if ok and v and v.x then vel = v end
    end
    if vel then
        local sp = math.sqrt(vel.x * vel.x + vel.y * vel.y)
        if sp < 40 then return loc end
        local maxSp = unit:GetCurrentMovementSpeed() or 0
        local vx, vy = vel.x, vel.y
        if maxSp > 0 and sp > maxSp * 1.05 then
            vx, vy = vx / sp * maxSp, vy / sp * maxSp
        end
        local stability = 1
        if unit.GetMovementDirectionStability then
            stability = unit:GetMovementDirectionStability() or 1
        end
        if stability < 0.5 then delay = delay * 0.5 end
        -- Reversal smoothing is per unit and per frame: midpoint/landing queries
        -- must use the same estimate, regardless of their call order.
        U._motionHistory = U._motionHistory or setmetatable({}, {__mode = "k"})
        local hist = U._motionHistory[unit]
        local nowT = GameTime()
        if not hist or hist.t ~= nowT then
            local scale = 1
            if hist and nowT > hist.t and nowT - hist.t <= 0.35 then
                local pmag = math.sqrt(hist.rawX * hist.rawX + hist.rawY * hist.rawY)
                if pmag > 40 and sp > 40 and (hist.rawX * vel.x + hist.rawY * vel.y) / (pmag * sp) < 0.7 then
                    scale = 0.6
                    vx, vy = vx * 0.6 + hist.rawX * 0.4, vy * 0.6 + hist.rawY * 0.4
                end
            end
            local smoothSpeed = math.sqrt(vx * vx + vy * vy)
            if maxSp > 0 and smoothSpeed > maxSp then
                vx, vy = vx / smoothSpeed * maxSp, vy / smoothSpeed * maxSp
            end
            hist = {t = nowT, rawX = vel.x, rawY = vel.y, vx = vx, vy = vy, scale = scale}
            U._motionHistory[unit] = hist
        end
        vx, vy, delay = hist.vx, hist.vy, delay * hist.scale
        return Vector(loc.x + vx * delay, loc.y + vy * delay, loc.z)
    end
    -- Native extrapolation also handles standing units; facing alone is not velocity.
    if unit.GetExtrapolatedLocation then
        local ok, predicted = pcall(unit.GetExtrapolatedLocation, unit, delay)
        if ok and predicted then return predicted end
    end
    -- Last-resort fallback for API variants without motion queries.
    local stability = 1
    if unit.GetMovementDirectionStability then
        stability = unit:GetMovementDirectionStability() or 1
    end
    if stability < 0.5 then return loc end
    local speed = unit:GetCurrentMovementSpeed() or 0
    local facingRad = math.rad(unit:GetFacing() or 0)
    return Vector(
        loc.x + math.cos(facingRad) * speed * delay,
        loc.y + math.sin(facingRad) * speed * delay,
        loc.z
    )
end

function U.GetAngleDifference(bot, targetLoc)
    local botLoc = bot:GetLocation()
    local facing = bot:GetFacing()
    local angleToTarget = math.deg(Atan2(targetLoc.y - botLoc.y, targetLoc.x - botLoc.x))
    if angleToTarget < 0 then angleToTarget = angleToTarget + 360 end
    local diff = math.abs(facing - angleToTarget)
    if diff > 180 then diff = 360 - diff end
    return diff
end

function U.GetRazeAbilityData(ability)
    if not ability then return nil end
    local name = ability:GetName()
    if name == "nevermore_shadowraze1" then return { center = C.RAZE.NEAR_CENTER, label = "near" } end
    if name == "nevermore_shadowraze2" then return { center = C.RAZE.MID_CENTER,  label = "mid" } end
    if name == "nevermore_shadowraze3" then return { center = C.RAZE.FAR_CENTER,  label = "far" } end
    return nil
end

function U.GetFacingVector(unit)
    local rad = math.rad(unit:GetFacing() or 0)
    return Vector(math.cos(rad), math.sin(rad), 0)
end

function U.GetRazeCircleCenter(bot, centerDistance)
    local loc = bot:GetLocation()
    local forward = U.GetFacingVector(bot)
    return Vector(
        loc.x + forward.x * centerDistance,
        loc.y + forward.y * centerDistance,
        loc.z
    )
end

function U.GetRazeHitErrorWithCurrentFacing(bot, targetLoc, centerDistance)
    local center = U.GetRazeCircleCenter(bot, centerDistance)
    return U.DistanceBetweenLocations(center, targetLoc)
end

function U.GetRazeHitErrorWithDesiredFacing(bot, targetLoc, centerDistance)
    local dist = GetUnitToLocationDistance(bot, targetLoc)
    return math.abs(dist - centerDistance)
end

function U.IsRazeAbilityCastable(bot, ability)
    if not ability or not ability:IsFullyCastable() then return false end
    return bot:GetMana() >= 75
end

-- Robust raze aiming. The raze circle (R=250) must cover the enemy both where he is
-- NOW and where he will be after delay if he keeps moving. We aim at the middle
-- of the segment between those points. A single predicted point caused systematic misses:
-- the enemy stopped - a "forward" miss (the raze landed where he "should have arrived"), the enemy walked/accelerated
-- after our decision - a "backward" miss.
-- Returns: errAim (the worst error with a perfect turn toward aim), errFacing (the same
-- at the CURRENT facing - the raze flies where we look), aim (the aim point), pPred.
-- Three points (now / middle of the cast / landing) and aiming at the middle of the widest
-- pair. An enemy turning during the cast is covered better, and one leaving the circle during the
-- cast is filtered out by the growing worst error - instead of casting "after him" and missing.
function U.RobustRazeErrors(bot, target, center, delay)
    local land = C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08)
    delay = delay or C.RAZE.PREDICT_DELAY
    if delay < land then delay = land end
    local botLoc = bot:GetLocation()
    local pNow = target:GetLocation()
    local pMid = U.PredictPosition(target, delay * 0.5) or pNow
    local pPred = U.PredictPosition(target, delay) or pNow

    local function Dist2(a, b)
        local ax, ay = a.x - b.x, a.y - b.y
        return ax * ax + ay * ay
    end
    local dEnd, dMidA, dMidB = Dist2(pNow, pPred), Dist2(pNow, pMid), Dist2(pMid, pPred)
    local pa, pb = pNow, pPred
    if dMidA > dEnd and dMidA >= dMidB then
        pa, pb = pNow, pMid
    elseif dMidB > dEnd and dMidB > dMidA then
        pa, pb = pMid, pPred
    end
    local aim = Vector((pa.x + pb.x) * 0.5, (pa.y + pb.y) * 0.5, pNow.z)

    local dx, dy = aim.x - botLoc.x, aim.y - botLoc.y
    local d = math.sqrt(dx * dx + dy * dy)
    local ux, uy
    if d < 1 then
        local f = U.GetFacingVector(bot)
        ux, uy = f.x, f.y
    else
        ux, uy = dx / d, dy / d
    end
    local function worst(cx, cy)
        local e1 = math.sqrt((pNow.x - cx) * (pNow.x - cx) + (pNow.y - cy) * (pNow.y - cy))
        local e2 = math.sqrt((pMid.x - cx) * (pMid.x - cx) + (pMid.y - cy) * (pMid.y - cy))
        local e3 = math.sqrt((pPred.x - cx) * (pPred.x - cx) + (pPred.y - cy) * (pPred.y - cy))
        local m = e1
        if e2 > m then m = e2 end
        if e3 > m then m = e3 end
        return m
    end
    local errAim = worst(botLoc.x + ux * center, botLoc.y + uy * center)
    local f = U.GetFacingVector(bot)
    local errFacing = worst(botLoc.x + f.x * center, botLoc.y + f.y * center)
    return errAim, errFacing, aim, pPred
end

-- Will the raze hit at the CURRENT facing (robustly: for both the current and the predicted point).
-- The third value is the aim point (for turning), not the "predicted position" as before.
function U.WillRazeHit(bot, ability, target, delay, strict)
    if not ability or not target or not target:IsAlive() then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, delay or C.RAZE.CAST_POINT)
    local limit = strict and C.RAZE.STRICT_RADIUS or (C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30))
    return errFacing <= limit, errFacing, aim, errAim
end

function U.GetBestRaze(bot, target, mode, isLethalChase, forceExtend)
    if bot:GetMana() < 75 then return nil, nil, nil end
    if not U.CanQuery(target) then return nil, nil, nil end

    isLethalChase = isLethalChase or false
    forceExtend = forceExtend or false

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")

    local stacks, rem_time = U.GetShadowrazeDebuff(target)
    local lowHpFinish = target:GetHealth() <= 380
    local lethalWithTwo = U.GetTwoRazeDamage(bot, target) >= target:GetHealth() * 0.95
    -- "Lethal with two" - only with razes that are REALLY available (cooldowns/mana), otherwise
    -- the "finish mode" engaged with one raze left and produced risky casts
    local Rk = U._K and U._K._race
    if Rk and Rk.valid then lethalWithTwo = Rk.canKillSoon end
    local interruptRegen = U.IsEnemyHighValueRegen(target)
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local mustKillNow = lethalWithTwo or lowHpFinish or isLethalChase or forceExtend

    -- The rule "one stack and more than EXTEND_AT until it expires -> do not cast" was REMOVED. It postponed
    -- the second raze by ~3 s for the sake of "extending" the stack while a leaving enemy left all
    -- the bands in that time: the second stack (free, he cannot answer) was lost. Now the second/third raze goes
    -- out immediately if it covers robustly; mana discipline belongs to the caller (HarassManaOK/followUp).

    local predLoc = U.PredictPosition(target, C.RAZE.PREDICT_DELAY)
    local myDist = GetUnitToLocationDistance(bot, predLoc)
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)
    local robustMargin = C.RAZE.ROBUST_MARGIN or 30
    local targetStationary = true
    if target.GetVelocity then
        local okV, tv = pcall(target.GetVelocity, target)
        if okV and tv and tv.x then
            targetStationary = math.sqrt(tv.x * tv.x + tv.y * tv.y) < 60
        end
    end
    -- He is leaving us carrying our stack - the finish must be the far band
    local enemyFleeing = (U._K and U._K.IsEnemyMovingAway(bot, target)) or false

    local candidates = {
        { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" },
        { ability = w, center = C.RAZE.MID_CENTER,  label = "mid"  },
        { ability = e, center = C.RAZE.FAR_CENTER,  label = "far"  },
    }

    local best = nil
    local bestScore = math.huge

    for _, candidate in ipairs(candidates) do
        local ability = candidate.ability
        local data = U.GetRazeAbilityData(ability)
        if data and U.IsRazeAbilityCastable(bot, ability) then
            local allow = true

            -- The band ban is now cooldown-driven: a band is safe while HIS copy of that
            -- band is on cooldown (nothing to answer with). The old "only the band he
            -- hit us with last" is kept as a fallback - the tracker may have missed the cast.
            if secondStackActive and data.label ~= safeReplyLabel
                and not U.IsBandSafeForMe(target, data.label, C.RAZE.CAST_POINT + 0.15) then
                allow = false
            end

            if data.label == "far" and mode == "NEUTRAL" and stacks == 0
               and not secondStackActive
               and not U.IsEnemyCastingRaze(target)
               and not interruptRegen and not enemyMissed and not mustKillNow then
                allow = false
            end

            if allow then
                -- Robust error: the worst of the two points (now / after PREDICT_DELAY) when aiming
                -- at their middle. The limit is the circle radius minus a margin; for finishing/extending/answering
                -- the margin is smaller (not missing the chance matters more), for harass - larger (not missing matters more).
                local errAim, errFacing, aimLoc = U.RobustRazeErrors(bot, target, data.center, C.RAZE.PREDICT_DELAY)
                local plannedError = errAim
                local limit = C.RAZE.HIT_RADIUS - robustMargin
                if targetStationary then
                    -- A standing enemy may start moving during the cast: a margin from the circle edge is needed
                    -- (100 u ~ 0.33 s of his walking); such an enemy at the band edge is not touched
                    limit = C.RAZE.HIT_RADIUS - 100
                    -- Finishing a stack (the enemy is already hit, the stack has >= 1.2 s) - a softer margin (60 u):
                    -- the value of a hit is higher and the "robust" error already accounts for both points
                    if stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then
                        limit = C.RAZE.HIT_RADIUS - 60
                    end
                end
                -- "Pure" harass (not a finish, not an answer to his raze, not a stack): a reacting enemy
                -- leaves the circle during the cast (0.55 s ~ 150 u) if it is < ~110 u from the circle edge. So for
                -- harass we require errAim <= 160 (closer to the band centre) instead of 220 "at the edge".
                local followUpStack = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
                if not (mustKillNow or forceExtend or interruptRegen or secondStackActive or followUpStack) then
                    limit = math.min(limit, C.RAZE.HIT_RADIUS - (C.RAZE.HARASS_MARGIN or 90))
                end
                if mustKillNow or forceExtend or interruptRegen or secondStackActive then
                    limit = C.RAZE.HIT_RADIUS - 10
                    -- A STANDING enemy at the band edge reacts to the cast animation (0.55 s = 150+ u
                    -- of walking): if this raze does not kill him on its own, keep the margin from the edge -
                    -- otherwise the cycle "cast at the edge -> he stepped -> cancel -> cast" (and a miss in game).
                    local killNow = Rk and Rk.valid and Rk.canKillNow
                    if targetStationary and not killNow and not forceExtend and not isLethalChase and not secondStackActive then
                        limit = math.min(limit, C.RAZE.HIT_RADIUS - 70)
                    end
                end
                local gamble = false
                -- Betting "on the prediction" only when this raze really decides it (kills him
                -- now / a lethal chase / extends the stack), not merely "he has low HP":
                -- otherwise the bot threw a raze at the circle edge at a standing 380 HP enemy and missed.
                local gambleWorth = isLethalChase or forceExtend or (Rk and Rk.valid and Rk.canKillNow)
                if plannedError > limit and gambleWorth then
                    -- Finish: we do not cover robustly - allow a bet on the prediction (as before)
                    local predOnly = U.GetRazeHitErrorWithDesiredFacing(bot, predLoc, data.center)
                    if predOnly <= C.RAZE.HIT_RADIUS then
                        plannedError = predOnly
                        limit = C.RAZE.HIT_RADIUS
                        aimLoc = predLoc
                        errFacing = U.GetRazeHitErrorWithCurrentFacing(bot, predLoc, data.center)
                        gamble = true
                    end
                end

                if data.label == "near" and not isLethalChase and not forceExtend then
                    local realDist = GetUnitToLocationDistance(bot, aimLoc)
                    if realDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                        plannedError = math.huge
                    end
                end

                if data.label == "near" and not mustKillNow then
                    if U.HasStackAndShouldFearNear(bot, target) then
                        plannedError = math.huge
                    end
                end

                if plannedError <= limit then
                    local score = plannedError
                    if gamble then score = score + 60 end

                    if secondStackActive and safeReplyLabel and data.label == safeReplyLabel then
                        score = score - 140
                    elseif stacks == 0 and not mustKillNow then
                        if mode == "AGGRESSIVE" then
                            -- Opening with the far band: we cast from beyond his auto attack and his
                            -- near bands; if he closes, mid meets him, if he backs off he is already hit
                            if data.label == "far" then score = score - 60 end
                            if data.label == "mid" then score = score - 40 end
                            if data.label == "near" then score = score + 10 end
                        else
                            if data.label == "mid" then score = score - 60 end
                            if data.label == "far" then score = score + 20 end
                            if data.label == "near" then score = score + 10 end
                        end
                    else
                        local distDiff = math.abs(myDist - data.center)
                        score = score - math.max(0, 80 - distDiff * 0.5)
                        if stacks >= C.FINISH.MIN_STACKS_FOR_CLOSE and data.label == "near" then
                            score = score - 80
                        end
                    end

                    if forceExtend and bootsAdvantage then
                        if data.label == "far" then score = score + 120 end
                        if data.label == "mid" then score = score - 90 end
                    elseif forceExtend and not bootsAdvantage then
                        if data.label == "mid" then score = score - 30 end
                    end

                    -- A leaving enemy with a stack is caught by the far band (he runs into it
                    -- himself), mid is second. A near band on a runner is almost a miss.
                    if enemyFleeing and stacks > 0 then
                        if data.label == "far" then score = score - 90 end
                        if data.label == "mid" then score = score - 20 end
                    end

                    if mustKillNow then
                        score = score - 200
                        local distDiff2 = math.abs(myDist - data.center)
                        if distDiff2 < 80 then score = score - 50 end
                    elseif forceExtend then
                        score = score - 150
                    elseif stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6 then
                        score = score - 110
                    elseif stacks >= 2 then
                        score = score - 45
                    end

                    if interruptRegen then score = score - 130 end
                    if enemyMissed then score = score - 55 end

                    if score < bestScore then
                        bestScore = score
                        best = { ability = ability, data = data, aimLoc = aimLoc, limit = limit, errFacing = errFacing }
                    end
                end
            end
        end
    end

    if best then
        -- The raze flies where we look: if at the current facing the circle covers both points
        -- (with a small margin) - cast immediately, otherwise turn toward the aim point.
        -- The cast threshold equals the candidate threshold (otherwise a "dead zone": after turning
        -- errFacing == plannedError in (limit-15, limit] -> TURN every tick, no cast - the bot jitters)
        if best.errFacing <= best.limit then
            return best.ability, "CAST", best.aimLoc
        end
        return best.ability, "TURN", best.aimLoc
    end

    return nil, nil, nil
end

function U.GetRazeSetupPosition(bot, target)
    if not U.CanQuery(target) then return nil end

    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local myDist = GetUnitToLocationDistance(bot, targetLoc)
    local stacks = U.GetShadowrazeDebuff(target)
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local bestCenter = nil
    local bestScore = math.huge
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)

    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
        bot:GetAbilityByName("nevermore_shadowraze1"),
    }
    local targetFleeing = (U._K and U._K.IsEnemyMovingAway(bot, target)) or false
    for _, ability in ipairs(abilities) do
        local data = U.GetRazeAbilityData(ability)
        if data and U.IsRazeAbilityCastable(bot, ability) then
            local distDiff = math.abs(myDist - data.center)
            local score = distDiff
            if stacks == 0 then
                if data.label == "mid" then score = score - 80 end
                if data.label == "far" then score = score + 30 end
                if data.label == "near" then score = score + 20 end
            else
                if data.label == "mid" then score = score - 15 end
            end
            if data.label == "near" and U.HasStackAndShouldFearNear(bot, target) then
                score = score + 9999
            end
            if bootsAdvantage then
                if data.label == "far" then score = score + 80 end
                if data.label == "mid" then score = score - 50 end
            end
            -- A leaving enemy with a stack is caught with the far band
            if targetFleeing and stacks > 0 then
                if data.label == "far" then score = score - 140 end
                if data.label == "mid" then score = score - 30 end
            end
            -- With a stack on us we only stand in a band whose copy is on his cooldown
            if secondStackActive then
                if data.label == safeReplyLabel then
                    score = score - 70
                elseif not U.IsBandSafeForMe(target, data.label, C.RAZE.CAST_POINT + 0.15) then
                    score = score + 9999
                end
            end
            if score < bestScore then
                bestScore = score
                bestCenter = data.center
            end
        end
    end

    if not bestCenter then bestCenter = C.RAZE.MID_CENTER end

    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * bestCenter
end

-- Does the enemy have a raze ready within the next horizon seconds (by the cast phase tracker) and the mana for it.
-- IsFullyCastable does not see the cooldown of enemy abilities, so we trust only the tracker;
-- if the tracker is not connected - assume there is a raze (conservative).
function U.EnemyCanUseRaze(enemy, horizon)
    if not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    if U._K then
        local n = U._K.EnemyReadyRazeCount(enemy, horizon or 1.0, true)
        return n > 0
    end
    local totalMana = enemy:GetMana() + U.GetMangoMana(enemy)
    return totalMana >= 75
end

function U.GetRetreatPositionFromEnemySF(bot, enemy)
    local botLoc = bot:GetLocation()
    local enemyLoc = enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if U.DistanceBetweenLocations(botLoc, enemyLoc) < 1 then
        away = fountain - botLoc
    end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    return botLoc + away * 680 + toFountain * 360
end

-- Should we retreat because of raze stacks on us. The decision uses the enemy's available burst
-- (cooldown tracker + mana + band reach) and absolute HP, not "by default".
-- Returns shouldRetreat, retreatLoc, reason.
function U.ShouldRetreatFromEnemyRazeStack(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    if not U.EnemyHasRaze(enemy) then return false, nil end
    local K = U._K
    if not K then
        -- Fallback without the tracker: the old behaviour
        local dist0 = GetUnitToLocationDistance(enemy, bot:GetLocation())
        local stacks0, rem0 = U.GetShadowrazeDebuff(bot)
        if stacks0 >= 2 and rem0 > C.RAZE.RETREAT_MIN_REMAIN and dist0 <= (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS) then
            return true, U.GetRetreatPositionFromEnemySF(bot, enemy), "legacy"
        end
        return false, nil
    end

    local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
    local hp = bot:GetHealth()
    local R = K._race
    if not (R and R.valid) then R = K.Race(bot, enemy, false) end

    -- 1) his available burst kills me and I cannot kill him "right now" -> leave
    if R.heCanKillSoon and not R.canKillNow then
        return true, U.GetRetreatPositionFromEnemySF(bot, enemy), "lethal burst"
    end

    -- 2) I stand deep inside his READY band: one of his razes takes a big chunk of HP and the trade
    -- is against me -> back off to the "hedge" edge of the band (not to the fountain and not past all bands).
    -- The fear conditions were tightened in FearBandPredicate (a stack on us or >= 45 % HP per raze);
    -- and we do not retreat while already at our own T1 (nowhere further to go - the tower will punish him).
    local nearOwnT1 = false
    local ownT1 = (U._W and U._W.s and U._W.s.allyT1) or nil
    if ownT1 then
        local okL, tl = pcall(ownT1.GetLocation, ownT1)
        if okL and tl and U.DistanceBetweenLocations(tl, bot:GetLocation()) <= 400 then nearOwnT1 = true end
    end
    -- The enemy's closing speed (>0 - walking at me). At equal running speed he will not catch
    -- a LEAVING bot but will catch a STANDING one: the retreat threshold and step length grow by his closing
    -- speed (previously: a 60-100 u step, the bot stopped, the enemy came right up to the band and
    -- landed a 2nd/3rd raze - "the bot was in no hurry to back off").
    local approach = U.EnemyApproachSpeed(bot, enemy)
    local band = K.EnemyReadyBandAt(enemy, dist, 1.0) or K.EnemyReadyBandAt(enemy, dist - approach * 0.7, 1.0)
    -- 2b) I have a fresh stack, he stands in his READY band and the trade is against me ->
    -- do not let him build a 2nd/3rd/4th stack: leave past the edge of his ready bands before the stack
    -- expires (6 s). Exception - a favourable trade or a guaranteed kill.
    -- A "favourable trade" only if I can really answer (mana >= 75 and a raze ready):
    -- previously a bot with 66 mana considered the trade favourable, stood still and collected 3 stacks.
    -- The "at our own T1" exception was removed for 2b - backing off behind the tower is always possible.
    local stackedFresh = false
    do
        local st, rem = U.GetShadowrazeDebuff(bot)
        stackedFresh = (st or 0) >= 1 and (rem or 0) >= 1.0
    end
    if band and stackedFresh and not R.canKillSoon and not U.IsStackTradeFavorable(bot, R) then
        local safe = K.EnemyMinSafeDistance(enemy, 1.0)
        local trigger = safe + approach * 0.7
        if safe > 0 and dist < trigger - 20 then
            local botLoc = bot:GetLocation()
            local enemyLoc = enemy:GetLocation()
            local away = botLoc - enemyLoc
            if dist < 1 then away = U.GetFountain(bot) - botLoc end
            away = away:Normalized()
            local toFountain = (U.GetFountain(bot) - botLoc):Normalized()
            local need = math.max(0, safe - dist) + 40 + approach * 1.2
            if approach > 60 and need < 300 then need = 300 end
            return true, botLoc + away * need * 0.7 + toFountain * need * 0.3, "stacked, in ready band"
        end
    end
    if band and not nearOwnT1 and U.FearBandPredicate(bot, enemy, R) then
        local safe = K.EnemyDodgeableDistance(enemy, 1.0)
        if dist < safe + approach * 0.7 - 20 then
            local botLoc = bot:GetLocation()
            local enemyLoc = enemy:GetLocation()
            local away = botLoc - enemyLoc
            if dist < 1 then away = U.GetFountain(bot) - botLoc end
            away = away:Normalized()
            local toFountain = (U.GetFountain(bot) - botLoc):Normalized()
            local need = math.max(0, safe - dist) + 40 + approach * 1.2
            return true, botLoc + away * need * 0.7 + toFountain * need * 0.3, "in ready band"
        end
    end

    return false, nil
end

-- The enemy's closing speed on me (u/s, > 0 - walking at me; 0 - standing/leaving/sideways).
function U.EnemyApproachSpeed(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return 0 end
    local okV, v = pcall(enemy.GetVelocity, enemy)
    if not okV or not v then return 0 end
    local vx, vy = v.x or 0, v.y or 0
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 60 then return 0 end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return 0 end
    local ax, ay = (botLoc.x - enLoc.x) / d, (botLoc.y - enLoc.y) / d
    local toward = vx * ax + vy * ay
    if toward <= 0 then return 0 end
    return toward
end

-- A "favourable trade with a stack on me": an edge >= 60, my HP >= his AND I can really answer
-- with a raze (mana >= 75, at least one of my razes is ready within ~2.5 s and reaches him).
function U.IsStackTradeFavorable(bot, R)
    if not (R and R.valid) then return false end
    if R.canKillSoon then return true end
    if R.edge < 60 or R.myHp < R.enHp then return false end
    if (bot:GetMana() or 0) < 75 then return false end
    if (R.myRazesSoon or 0) < 1 then return false end
    return true
end

-- The single "band fear" predicate: one of his razes >= 30% of my HP, the trade is against me,
-- and I cannot kill him back with one raze.
function U.FearBandPredicate(bot, enemy, R)
    local K = U._K
    if not K or not (R and R.valid) then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local canKillBack = myOneRaze >= enemy:GetHealth() and K.MyReadyRazeCount(bot, true) > 0
    if canKillBack then return false end
    if R.edge >= 0 then return false end
    local hp = bot:GetHealth()
    -- Without a stack on us, one of his razes is an unpleasant but not critical trade; "band fear"
    -- (backing off past the edge of his far band = ~900 from him) without a stack drove a weaker bot
    -- off the lane on any enemy step forward and caused "to the tower and back" twitching. Now fear
    -- only applies with a stack (the next raze has the bonus) or if one raze takes >= 45 % HP.
    local myStacks, myRem = U.GetShadowrazeDebuff(bot)
    local stackedMe = (myStacks or 0) >= 1 and (myRem or 0) >= 1.0
    if stackedMe then return oneRaze >= hp * 0.30 end
    return oneRaze >= hp * 0.45
end

-- The minimum distance to the enemy that our "fear" currently demands (0 = no restriction).
-- The same predicate is used by: the band retreat, approaching the enemy, the last-hit position and
-- the final position - so different handlers do not pull the bot in different directions (oscillation).
-- "Mid band fear" (dry mana against his raze / he reached level 2 first / he is
-- faster on boots) - RealThink sets the flag every tick. While it is active the minimum distance
-- to the enemy = the outer edge of his mid band: we do not enter the band for a creep PROACTIVELY instead of
-- "went for the creep -> got scared -> ran 1000 away -> came back for the creep" in a loop.
U._midFear = false
U.MID_FEAR_DIST = C.RAZE.MID_CENTER + 210 + 40

function U.GetFearMinDist(bot, enemy)
    local K = U._K
    if not K or not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local R = K._race
    local best = U._midFear and U.MID_FEAR_DIST or 0
    if not (R and R.valid) then return best end
    if R.heCanKillSoon and not R.canKillNow then return math.max(best, K.EnemyMinSafeDistance(enemy, 1.0)) end
    if U.FearBandPredicate(bot, enemy, R) then return math.max(best, K.EnemyDodgeableDistance(enemy, 1.0)) end
    return best
end

-- A short step past the edge of his mid band (instead of a ~1000 retreat toward the fountain from
-- GetRetreatPositionFromEnemySF): the step is only as long as needed, slightly toward the fountain.
function U.GetMidBandExitPosition(bot, enemy)
    local botLoc, enemyLoc = bot:GetLocation(), enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local toFountain = (fountain - botLoc):Normalized()
    local away = (dist > 1) and (botLoc - enemyLoc):Normalized() or toFountain
    local dir = (away * 0.75 + toFountain * 0.25):Normalized()
    local need = (U.MID_FEAR_DIST + 60) - dist + 40
    if need < 120 then need = 120 end
    return botLoc + dir * need
end

-- Power Treads. 0 = strength, 1 = agility, 2 = intelligence (the engine Attributes enum);
-- the in-game switch order is strength -> intelligence -> agility -> strength. We keep the state here:
-- fields on the bot handle cannot be written reliably from the bot script, so the previous
-- implementation (bot._pt_state) effectively never switched the boots.
U._pt = { stat = nil, lastSwitch = -1000 }

local PT_NEXT = { [0] = 2, [2] = 1, [1] = 0 }

local function GetPowerTreadsItem(bot)
    if not bot or not bot.FindItemSlot then return nil end
    local okS, slot = pcall(bot.FindItemSlot, bot, "item_power_treads")
    if not okS or type(slot) ~= "number" or slot < 0 or slot > 5 then return nil end
    local okI, pt = pcall(bot.GetItemInSlot, bot, slot)
    if not okI or not pt then return nil end
    local okC, ready = pcall(pt.IsFullyCastable, pt)
    if okC and ready == false then return nil end
    return pt
end

local function GetPowerTreadsStat(pt)
    if type(pt.GetPowerTreadsStat) == "function" then
        local ok, v = pcall(pt.GetPowerTreadsStat, pt)
        if ok and type(v) == "number" and v >= 0 and v <= 2 then
            U._pt.stat = v
            return v
        end
    end
    if U._pt.stat == nil then U._pt.stat = (C.TREADS and C.TREADS.STRENGTH) or 0 end
    return U._pt.stat
end

-- One switch order per SWITCH_COOLDOWN and only if the attribute really differs.
-- Returns true when the order was issued (it takes the tick - the cast/move goes on the next one).
function U.SwitchTreadsTo(bot, targetStat, opts)
    if type(targetStat) ~= "number" then return false end
    local pt = GetPowerTreadsItem(bot)
    if not pt then return false end
    local cfg = C.TREADS or {}
    opts = opts or {}
    local now = GameTime()
    local hold = opts.hold or (cfg.SWITCH_COOLDOWN or 0.35)
    if now < (U._pt.lastSwitch or -1000) + hold then return false end
    local cur = GetPowerTreadsStat(pt)
    if cur == targetStat then return false end
    -- One order = one step along the strength -> intelligence -> agility -> strength cycle. If two steps
    -- are needed but a second order cannot be spent in combat (we are about to raze) - skip the switch.
    if opts.oneUseOnly and (PT_NEXT[cur] or -1) ~= targetStat then return false end
    local ok = pcall(bot.Action_UseAbility, bot, pt)
    if not ok then return false end
    U._pt.stat = PT_NEXT[cur] or targetStat
    U._pt.lastSwitch = now
    return true
end

-- mode: "CAST" (intelligence before a raze) / "SURVIVE" (strength) / "FIGHT" (agility).
function U.UpdatePowerTreads(bot, mode, opts)
    local cfg = C.TREADS or {}
    local want
    if mode == "CAST" then
        want = cfg.INTELLIGENCE
    elseif mode == "SURVIVE" then
        want = cfg.STRENGTH
    elseif mode == "FIGHT" then
        want = cfg.AGILITY
    else
        return false
    end
    if want == nil then return false end
    -- Intelligence raises the mana CEILING (and the pool itself when switching), so the switch
    -- makes sense even at full mana - otherwise the boots would never reach intelligence by raze time.
    return U.SwitchTreadsTo(bot, want, opts)
end

function U.GetRazeSetupPositionForAbility(bot, target, centerDistance)
    if not target then return bot:GetLocation() end
    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * centerDistance
end

-- Raw raze damage: base + stacks*bonus + souls*2 (7.41f). The +30 per stack talent is already inside
-- GetSpecialValueInt("stack_bonus_damage") if the talent is learned.
function U.GetRazeRawDamage(ability, stacks, souls)
    if not ability or ability:GetLevel() == 0 then return 0 end
    local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = ability:GetSpecialValueInt("stack_bonus_damage") or 0
    local perSoul = ability:GetSpecialValueInt("damage_per_soul") or 0
    if not perSoul or perSoul <= 0 then perSoul = (C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2 end
    return baseDmg + (stacks or 0) * stackDmg + (souls or 0) * perSoul
end

function U.GetNRazeDamage(bot, target, razeCount)
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    if not target or not target:IsAlive() then return 0 end
    local stacks = U.GetShadowrazeDebuff(target) or 0
    local souls = S.GetSouls(bot)
    local totalDmg = 0
    for i = 1, (razeCount or 1) do
        local rawDmg = U.GetRazeRawDamage(q, stacks + (i - 1), souls)
        totalDmg = totalDmg + target:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
    end
    return totalDmg
end

function U.GetTwoRazeDamage(bot, target)
    return U.GetNRazeDamage(bot, target, 2)
end

function U.CanKillEnemyWithTwoRazes(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    return U.GetTwoRazeDamage(bot, enemy) >= enemy:GetHealth()
end

function U.EnemyHasTwoRazeManaThreat(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    local manaThreat = U.GetPotentialManaForRaze(enemy)
    if manaThreat >= ((C.BOOT_FEAR and C.BOOT_FEAR.TWO_RAZE_MANA_COST) or 150) then
        return true
    end
    local charges = U.GetStickCharges(enemy)
    if charges >= ((C.BOOT_FEAR and C.BOOT_FEAR.STICK_CHARGES_THREAT) or 10) then
        return true
    end
    return false
end

function U.ShouldFearBootsMidRaze(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    if U.HasBoots(bot) then return false end
    if not U.HasBoots(enemy) then return false end
    if U._K and U._K.BandSafeFromEnemy(enemy, "mid", 1.2) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemy) then return false end
    if not U.EnemyHasTwoRazeManaThreat(enemy) then return false end
    return true
end

-- The enemy raze burst on me. razeCount = nil -> as many as he really has available
-- (by the cooldown tracker + mana, a 2.5 s horizon, accounting for band reach).
function U.GetEnemyRazeBurstDamage(bot, enemy, razeCount)
    if not U.CanQuery(enemy) then return 0 end
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not eq or eq:GetLevel() == 0 then return 0 end
    if razeCount == nil then
        if U._K then
            local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
            local dmg = U._K.EnemyBurstVs(bot, enemy, dist, 2.5, false)
            return dmg
        end
        razeCount = 2
    end
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local souls = S.GetSouls(enemy)
    local totalDmg = 0
    for i = 1, razeCount do
        local rawDmg = U.GetRazeRawDamage(eq, myStacks + (i - 1), souls)
        totalDmg = totalDmg + bot:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
    end
    return totalDmg
end

function U.HasAnyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    if U.HasItem(bot, "item_flask") then return true end
    if U.HasItem(bot, "item_tango") then return true end
    return false
end

function U.IsActivelyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    return false
end

function U.IsCourierBringSalve(bot)
    local courier = GetCourier(0)
    if not courier then return false, nil end
    if not courier:IsAlive() then return false, nil end
    local hasSalve = false
    for i = 0, 8 do
        local item = courier:GetItemInSlot(i)
        if item and item:GetName() == "item_flask" then
            hasSalve = true
            break
        end
    end
    if not hasSalve then return false, nil end
    local courierLoc = courier:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, courierLoc)
    if dist <= C.EMERGENCY.COURIER_SEARCH_RANGE then
        return true, courierLoc
    end
    return false, nil
end

function U.GetEmergencyRetreatReason(bot, enemyHero)
    local hp = bot:GetHealth()
    if U.HasAnyHealing(bot) then return nil end
    -- An emergency retreat (fountain/courier) - only if the threat is NOT temporary: his available burst
    -- kills me even without stacks on me, or the stacks last a long time. Temporary stacks
    -- (expiring in a couple of seconds) are solved by leaving his bands, not by walking to the fountain.
    local threatAvail, threatBase = 0, 0
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if enemyHero and U.CanQuery(enemyHero) then
        if U._K then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            threatAvail = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false)
            threatBase = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false, 0)
        else
            threatAvail = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
            threatBase = threatAvail
        end
    end
    local isInKillRange = false
    local hpPct = hp / math.max(1, bot:GetMaxHealth())
    -- At high HP a "theoretically lethal" three-raze burst is no reason to run to the fountain:
    -- he will not land three bands in a row on a moving target while we lose the wave. An emergency retreat -
    -- only when HP is already low (<=55%) and his available burst kills us.
    if threatBase > 0 and hp <= threatBase * C.EMERGENCY.SINGLE_RAZE_FACTOR and hpPct <= 0.55 then isInKillRange = true end
    if threatAvail > 0 and hp <= threatAvail * C.EMERGENCY.SINGLE_RAZE_FACTOR and (myStacks or 0) > 0 and (myRemain or 0) > 4.0
        and hpPct <= 0.60 then
        isInKillRange = true
    end
    if hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then isInKillRange = true end
    if not isInKillRange then return nil end
    local courierHasSalve, courierLoc = U.IsCourierBringSalve(bot)
    if courierHasSalve and courierLoc then
        local dist = U.DistanceBetweenLocations(bot:GetLocation(), courierLoc)
        if dist <= C.EMERGENCY.COURIER_MEET_RANGE then
            return "COURIER", courierLoc
        end
    end
    -- To the fountain - only at genuinely low HP; in the 40-55% range we stay in the lane
    -- at a safe distance (RETREAT + "band fear"), without giving up XP and the wave.
    -- At early levels a fountain trip = a lost wave and level (40 s there and back without a TP).
    -- Below level 5 - only at <= 30% (or the absolute minimum), from level 6 - at <= 40%.
    local lvl = bot:GetLevel() or 1
    local goPct = (lvl >= 6) and 0.40 or 0.30
    if hpPct <= goPct or hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then
        -- The enemy has as few resources as we do - walking to the fountain simply hands him
        -- the lane, the XP and the wave. Keep the distance and regen.
        if U.EnemyResourcesAsWeak(bot, enemyHero, hpPct) then return nil end
        return "FOUNTAIN", nil
    end
    return nil
end

-- "The enemy has exactly as few resources as we do".
-- True when he cannot kill us with his available burst, his HP% is not above ours (within
-- the margin) and he can pay for no more razes than we can. In that situation a fountain trip is
-- a gift: he takes the wave, the XP and the lane for free.
function U.EnemyResourcesAsWeak(bot, enemy, myHpPct)
    local cfg = C.FOUNTAIN or {}
    if cfg.SYMMETRIC_ENABLE == false then return false end
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    local hpPct = myHpPct or ((bot:GetHealth() or 0) / math.max(1, bot:GetMaxHealth() or 1))
    if hpPct <= (cfg.SYMMETRIC_FLOOR_PCT or 0.12) then return false end
    if (bot:GetHealth() or 0) <= (cfg.SYMMETRIC_MIN_HP or 110) then return false end
    local K = U._K
    local R = K and K._race
    -- we can only stay on a reliable trade calculation: without it we do not know whether he kills us
    if not (R and R.valid) then return false end
    if R.heCanKillSoon then return false end
    local eHpPct = (enemy:GetHealth() or 0) / math.max(1, enemy:GetMaxHealth() or 1)
    if eHpPct > hpPct + (cfg.SYMMETRIC_HP_GAP or 0.10) then return false end
    if K.EnemyRazeBudget(enemy, true) > K.MyRazeBudget(bot, true) then return false end
    return true
end

-- The death threat from the enemy's available burst (cooldown tracker + mana + band reach).
function U.IsInEnemyRazeKillThreat(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    if U._K then
        local R = U._K._race
        if R and R.valid then
            return R.heCanKillSoon
        end
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local dmg = U._K.EnemyBurstVs(bot, enemyHero, dist, 2.5, false)
        return dmg > 0 and hp <= dmg
    end
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local threat2 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
    if threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.SINGLE_KILL_FACTOR then return true end
    if threat2 > 0 and hp <= threat2 * SAFE_DISTANCE.KILL_THREAT_FACTOR then return true end
    return false
end

-- Choose a passable endpoint beyond nearby trees. The engine finds the path;
-- passability alone is not a claim that the straight segment is traversable.
function U.GetRetreatWaypoint(bot, direction)
    local origin = bot:GetLocation()
    local side = Vector(-direction.y, direction.x, 0)
    for _, length in ipairs({900, 1200, 1500, 600}) do
        for _, offset in ipairs({0, 0.4, -0.4, 0.8, -0.8}) do
            local target = origin + (direction + side * offset):Normalized() * length
            if type(IsLocationPassable) ~= "function" or IsLocationPassable(target) then
                return target
            end
        end
    end
    return U.GetFountain(bot)
end

function U.GetSafeDistancePosition(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return nil end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if U._K then
        -- outside all his ready bands
        local safe = U._K.EnemyMinSafeDistance(enemyHero, 2.5)
        if safe > minDist then minDist = safe end
    end
    if isCritical then
        minDist = math.max(minDist, SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950)
    end
    if dist >= minDist then return nil end
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if dist < 1 then away = fountain - botLoc end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    local moveAmount = minDist - dist + 80
    -- Flee strictly AWAY from the enemy. A tilt toward the fountain is allowed only when the fountain
    -- is roughly where we are running anyway (dot > 0.2). Otherwise (the fountain is behind the enemy -
    -- we are cut off) the fountain component pulled the path TOWARD the enemy: the run came out crooked,
    -- a "to the creeps and back" zigzag.
    local dot = away.x * toFountain.x + away.y * toFountain.y
    if dot > 0.2 then
        local awayWeight = isCritical and 0.5 or 0.7
        local fountainWeight = isCritical and 0.5 or 0.3
        return botLoc + away * moveAmount * awayWeight + toFountain * moveAmount * fountainWeight
    end
    return U.GetRetreatWaypoint(bot, away)
end

function U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    if bot:GetMana() < 75 then return false, nil end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false, nil end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false, nil end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < C.FINISH.MIN_HP_PCT_FOR_CLOSE then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks < C.FINISH.MIN_STACKS_FOR_CLOSE then return false, nil end
    if rem_time <= 0.3 then return false, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false, nil end
    local baseDmg = q:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = q:GetSpecialValueInt("stack_bonus_damage") or 0
    local razeDmg = baseDmg + (stacks * stackDmg)
    local actualDmg = enemyHero:GetActualIncomingDamage(razeDmg, DAMAGE_TYPE_MAGICAL)
    local enemyHP = enemyHero:GetHealth()
    local atkDmg = bot:GetAttackDamage() or 0
    local actualAtk = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHP * 0.85 or (actualDmg + actualAtk) >= enemyHP then
        local botLoc = bot:GetLocation()
        local enemyLoc = enemyHero:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
        if dist <= C.FINISH.CLOSE_APPROACH_RANGE then
            local dir = (enemyLoc - botLoc):Normalized()
            local approachLoc = enemyLoc - dir * C.RAZE.NEAR_CENTER
            return true, approachLoc
        end
    end
    return false, nil
end

function U.ShouldForceSalve(bot)
    if bot:HasModifier("modifier_flask_healing") then return false end
    if bot:HasModifier("modifier_tango_heal") then return false end
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    if hpPct > C.FORCED_SALVE.HP_PCT_THRESHOLD then return false end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if not flask then return false end
    return true
end

U._lastAllyCreepHP = {}

function U.UpdateAllyCreepHealthTracking(allyCreeps)
    local newTracker = {}
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local key = tostring(c)
            newTracker[key] = {
                hp = c:GetHealth(),
                prevHp = (U._lastAllyCreepHP[key] and U._lastAllyCreepHP[key].hp) or c:GetHealth(),
                unit = c,
            }
        end
    end
    U._lastAllyCreepHP = newTracker
end

function U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not enemyTowers or #enemyTowers == 0 then return false end
    if not allyCreeps or #allyCreeps == 0 then return false end
    local t1Tower = nil
    for _, tower in pairs(enemyTowers) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                t1Tower = tower
                break
            end
        end
    end
    if not t1Tower then
        t1Tower = enemyTowers[1]
        if not t1Tower or not t1Tower:IsAlive() then return false end
    end
    local botDist = GetUnitToLocationDistance(bot, t1Tower:GetLocation())
    if botDist > 1000 then return false end
    local towerAggroRadius = 800
    local allyNearTower = {}
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= towerAggroRadius then
                    table.insert(allyNearTower, c)
                end
            end
        end
    end
    if #allyNearTower == 1 then
        local creep = allyNearTower[1]
        local key = tostring(creep)
        local tracked = U._lastAllyCreepHP[key]
        if tracked then
            if creep:GetHealth() < tracked.prevHp then
                if enemyHero and U.CanQuery(enemyHero) then
                    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                    local atkDmg = bot:GetAttackDamage() or 0
                    local enemyHp = enemyHero:GetHealth()
                    if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                        return false
                    end
                end
                return true
            end
        end
        if creep:GetHealth() < 200 then
            if enemyHero and U.CanQuery(enemyHero) then
                local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                local atkDmg = bot:GetAttackDamage() or 0
                local enemyHp = enemyHero:GetHealth()
                if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                    return false
                end
            end
            return true
        end
    end
    if #allyNearTower == 0 and botDist < 850 then
        return true
    end
    return false
end

U._lastGlyphTime = -math.huge

function U.IsGlyphAvailable(bot)
    local now = GameTime()
    if now < C.GLYPH.AVAILABLE_AT then return false end
    if GetGlyphCooldown and type(GetGlyphCooldown) == "function" then
        local cd = GetGlyphCooldown()
        if cd and cd > 0 then return false end
    else
        if (now - U._lastGlyphTime) < C.GLYPH.COOLDOWN then return false end
    end
    return true
end

function U.UseGlyph(bot)
    if bot.ActionImmediate_Glyph then
        bot:ActionImmediate_Glyph()
    elseif Glyph then
        Glyph()
    else
        return false
    end
    U._lastGlyphTime = GameTime()
    return true
end

function U.ShouldUseGlyphDefensive(bot, allyTowers)
    if not U.IsGlyphAvailable(bot) then return false end
    for _, tower in pairs(allyTowers or {}) do
        if U.CanQuery(tower) then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                local hp = tower:GetHealth()
                local maxHp = tower:GetMaxHealth()
                local hpPct = hp / maxHp
                if hpPct <= C.GLYPH.T1_HP_PCT_THRESHOLD or hp <= C.GLYPH.T1_HP_ABS_THRESHOLD then
                    local projs = tower:GetIncomingTrackingProjectiles()
                    local isUnderAttack = (projs and #projs > 0)
                    if not isUnderAttack then
                        local nearbyEnemies = tower:GetNearbyLaneCreeps(900, true)
                        if nearbyEnemies and #nearbyEnemies > 0 then isUnderAttack = true end
                        if not isUnderAttack then
                            local nearbyHeroes = tower:GetNearbyHeroes(900, true, BOT_MODE_NONE)
                            if nearbyHeroes and #nearbyHeroes > 0 then isUnderAttack = true end
                        end
                    end
                    if isUnderAttack then return true end
                end
            end
        end
    end
    return false
end

function U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
    local atkDmg = bot:GetAttackDamage() or 0
    local enemyHp = enemyHero:GetHealth()
    if not ((twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() >= 150) then
        return false
    end
    -- Only during an ONGOING finish: the burst available right now (ready razes + a hit) kills,
    -- and we are really attacking/aiming at him. "Two razes by formula" on an accidental entry under the tower
    -- (the tower was hitting our creep) burned the glyph without a kill attempt.
    if not (C.GLYPH and C.GLYPH.DIVE_REQUIRE_KILL_NOW == false) then
        local K = U._K
        local R = K and K._race
        if not (R and R.valid and R.canKillNow) then return false end
        local engaged = false
        local okT, tgt = pcall(bot.GetAttackTarget, bot)
        if okT and tgt == enemyHero then engaged = true end
        if not engaged and bot:IsUsingAbility() then engaged = true end
        if not engaged and U._engagedCheck and U._engagedCheck(bot, enemyHero) then engaged = true end
        if not engaged then return false end
    end
    local enemyLoc = enemyHero:GetLocation()
    local t1Tower = nil
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                if GetUnitToLocationDistance(tower, enemyLoc) <= C.GLYPH.KILL_DIVE_RANGE then
                    t1Tower = tower
                    break
                end
            end
        end
    end
    if not t1Tower then return false end
    local hasAllyCreepUnderT1 = false
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= 750 then
                hasAllyCreepUnderT1 = true
                break
            end
        end
    end
    if not hasAllyCreepUnderT1 then
        return false
    end
    local botDist = GetUnitToLocationDistance(bot, enemyLoc)
    if botDist > 1100 then return false end
    local botUnderTower = false
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) <= 880 then
            botUnderTower = true
            break
        end
    end
    if not botUnderTower then return false end
    return true
end



-- Fear the near band (do not close to near distance) if I have stacks and his NEAR raze
-- is ready (tracker) and he has the mana; his near raze must also be significant (>= 25% HP) or
-- the trade must be against me.
function U.HasStackAndShouldFearNear(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 then return false end
    if rem_time <= C.RAZE.RETREAT_MIN_REMAIN then return false end
    local K = U._K
    if K then
        if not K.EnemyRazeReady("near", 1.2) then return false end
        if K.EnemyManaBudget(enemy, true) < 75 then return false end
        local oneRaze = K.EnemyRazeDamage(bot, enemy, 1)
        local R = K._race
        local edge = (R and R.valid) and R.edge or 0
        if oneRaze < bot:GetHealth() * 0.25 and edge >= 0 then return false end
        return true
    end
    if not U.EnemyCanUseRaze(enemy) then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemy)
    if stacks == 1 and secondStackActive and hitLabel == "near" then
        return false
    end
    return true
end

function U.GetMinDistWithStack(bot, enemy)
    local fear = U.GetFearMinDist(bot, enemy)
    -- With a fresh stack (and a bad trade) the position is outside ALL his ready bands,
    -- not just outside the near one (see rule 2b in ShouldRetreatFromEnemyRazeStack)
    local K = U._K
    if K and U.CanQuery(enemy) then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local R = K._race
            local favorable = U.IsStackTradeFavorable(bot, R)
            if not favorable then
                local outOfBands = K.EnemyMinSafeDistance(enemy, 1.0)
                if outOfBands > fear then fear = outOfBands end
            end
        end
    end
    if not U.HasStackAndShouldFearNear(bot, enemy) then return fear end
    return math.max(fear, (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470)
end

function U.ClampMinDistFromEnemy(bot, enemy, loc)
    if not enemy or not U.CanQuery(enemy) then return loc end
    local minDist = U.GetMinDistWithStack(bot, enemy)
    if minDist <= 0 then return loc end
    local enemyLoc = enemy:GetLocation()
    local dist = U.DistanceBetweenLocations(loc, enemyLoc)
    if dist >= minDist then return loc end
    local dir = loc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    return enemyLoc + dir * (minDist + ((C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.RETREAT_BUFFER) or 60))
end

function U.CanOneShotEnemyHero(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local atkDmg = bot:GetAttackDamage() or 0
    local actualDmg = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHero:GetHealth() then
        return true, "ATTACK"
    end
    return false, nil
end

function U.CanKillEnemyWithOneRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + U.GetMangoMana(bot)
    if mana < 75 then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and U.IsRazeAbilityCastable(bot, ability) then
            local willHit = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
            if willHit and oneRazeDmg >= enemyHero:GetHealth() then
                return true, c.label
            end
        end
    end
    return false, nil
end

function U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + U.GetMangoMana(bot)
    if mana < 75 then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and U.IsRazeAbilityCastable(bot, ability) then
            local willHit, _, predLoc = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            if willHit then
                local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
                if oneRazeDmg >= enemyHero:GetHealth() then
                    local angleDiff = U.GetAngleDifference(bot, predLoc)
                    -- Turning is fast and the raze reaches further than a right click: the threshold is 110,
                    -- otherwise at an angle of 46+ the bot "poked" and let the enemy escape
                    if angleDiff <= 110 then
                        return true, c.label
                    end
                end
            end
        end
    end
    return false, nil
end


U.DEBUG = false


return U

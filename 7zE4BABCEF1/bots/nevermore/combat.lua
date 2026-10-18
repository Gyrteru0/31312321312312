--
-- SF vs SF combat model:
-- * enemy raze tracker (cast phase -> ready time, because GetCooldownTimeRemaining
-- does not work for enemy abilities);
-- * honest raze damage (base + stacks + 2 per soul, the talent via GetSpecialValueInt);
-- * the "race": absolute HP after the exchange, who kills whom, which enemy bands are dangerous;
-- * the chase rule (CanCatch): do not run after an enemy with equal speed.
--
-- Combat estimates use the current visible snapshot and bounded time windows.

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")

local K = {}

K.LABELS = { "near", "mid", "far" }
K.RAZE_NAMES = {
    near = "nevermore_shadowraze1",
    mid  = "nevermore_shadowraze2",
    far  = "nevermore_shadowraze3",
}

local RAZE_CD        = (C.RAZE and C.RAZE.COOLDOWN) or 9.0
local CAST_POINT     = (C.RAZE and C.RAZE.CAST_POINT) or 0.55
local HIT_RADIUS     = (C.RAZE and C.RAZE.HIT_RADIUS) or 250
local RAZE_MANA      = 75
local PER_SOUL_FALLBACK = (C.RAZE and C.RAZE.DAMAGE_PER_SOUL) or 2

local function Center(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid" then return C.RAZE.MID_CENTER end
    return C.RAZE.FAR_CENTER
end
K.Center = Center

-- Raze damage

function K.RazeRawDamage(ability, stacks, souls)
    if not ability or ability:GetLevel() == 0 then return 0 end
    local base = ability:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = ability:GetSpecialValueInt("stack_bonus_damage") or 0
    local perSoul = ability:GetSpecialValueInt("damage_per_soul") or 0
    if not perSoul or perSoul <= 0 then perSoul = PER_SOUL_FALLBACK end
    return base + (stacks or 0) * stackDmg + (souls or 0) * perSoul
end

-- Damage of N of my razes on a target (current stacks on the target, my souls, the target's magic resist).
function K.MyRazeDamage(bot, target, n, extraStacks)
    if n <= 0 or not U.CanQuery(target) then return 0 end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local souls = S.GetSouls(bot)
    local stacks = (U.GetShadowrazeDebuff(target) or 0) + (extraStacks or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls)
        total = total + target:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

-- Damage of N enemy razes on me.
function K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    if n <= 0 or not U.CanQuery(enemy) then return 0 end
    local q = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local souls = S.GetSouls(enemy)
    local stacks = stacksOverride or (U.GetShadowrazeDebuff(bot) or 0)
    local total = 0
    for i = 1, n do
        local raw = K.RazeRawDamage(q, stacks + i - 1, souls)
        total = total + bot:GetActualIncomingDamage(raw, DAMAGE_TYPE_MAGICAL)
    end
    return total
end

-- Right-click damage after the target's armour.
function K.AttackDamageVs(attacker, target)
    if not attacker or not U.CanQuery(target) then return 0 end
    local raw = attacker:GetAttackDamage() or 0
    if raw <= 0 then return 0 end
    return target:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
end

-- My razes: readiness + mana (counting mango/stick when allowConsumables)

function K.MyManaBudget(bot, allowConsumables)
    local mana = bot:GetMana() or 0
    if allowConsumables then
        mana = mana + U.GetMangoMana(bot) -- By charges
        local charges = U.GetStickCharges(bot)
        if charges > 0 then
            local stick = U.GetActiveItemByName(bot, "item_magic_wand") or U.GetActiveItemByName(bot, "item_magic_stick")
            if stick then mana = mana + charges * 15 end
        end
    end
    return mana
end

-- How many of my razes are really available (cooldown ready and enough mana).
-- Returns count, readyIgnoringMana.
function K.MyReadyRazeCount(bot, allowConsumables)
    local ready = 0
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 and ab:IsCooldownReady() then
            ready = ready + 1
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, allowConsumables) / RAZE_MANA)
    if budget < ready then return budget, ready end
    return ready, ready
end

function K.MyRazeReady(bot, label)
    local ab = bot:GetAbilityByName(K.RAZE_NAMES[label])
    return ab and ab:GetLevel() > 0 and ab:IsCooldownReady() or false
end

-- Enemy raze tracker

K._enemy = {
    key = nil,
    raze = {
        near = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        mid  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
        far  = { inPhase = false, phaseStart = -1, readyAt = 0, lastCastAt = -1 },
    },
    phaseLabel = nil,
    phaseStart = -1,
    lastAnyCastAt = -1,
    prevMyStacks = 0,
    prevMyStacksTime = -1,
}

local function ResetEnemyTracker()
    local E = K._enemy
    for i = 1, 3 do
        local st = E.raze[K.LABELS[i]]
        st.inPhase = false
        st.phaseStart = -1
        st.readyAt = 0
        st.lastCastAt = -1
    end
    E.phaseLabel = nil
    E.phaseStart = -1
    E.lastAnyCastAt = -1
end

local function EnemyKey(enemy)
    local pid = enemy.GetPlayerID and enemy:GetPlayerID()
    if pid == nil or pid < 0 then return tostring(enemy) end
    return pid
end

-- Call every tick (enemy may be nil / invisible).
function K.UpdateEnemyTracker(bot, enemy)
    local now = GameTime()
    local E = K._enemy

    if not U.CanQuery(enemy) then
        for i = 1, 3 do E.raze[K.LABELS[i]].inPhase = false end
        E.phaseLabel = nil
        return
    end

    local key = EnemyKey(enemy)
    if E.key ~= key then
        ResetEnemyTracker()
        E.key = key
    end

    E.phaseLabel = nil
    for i = 1, 3 do
        local label = K.LABELS[i]
        local st = E.raze[label]
        local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
        local inPhase = false
        if ab and ab:GetLevel() > 0 and ab:IsInAbilityPhase() then inPhase = true end

        if inPhase and not st.inPhase then
            st.phaseStart = now
        elseif st.inPhase and not inPhase then
            -- The phase ended: if it lasted almost the whole cast point - the raze was released and the cooldown started.
            local dur = now - st.phaseStart
            if dur >= CAST_POINT - 0.15 then
                st.lastCastAt = now
                st.readyAt = now + RAZE_CD - 0.05
                E.lastAnyCastAt = now
            end
        end
        st.inPhase = inPhase
        if inPhase then
            E.phaseLabel = label
            E.phaseStart = st.phaseStart
        end
    end

    -- Fallback: the stacks on us grew but we did not see a cast (the enemy razed from fog/at the edge
    -- of visibility) -> derive the band from the distance and put it on cooldown.
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local recentUpdate = E.prevMyStacksTime >= 0 and (now - E.prevMyStacksTime) < 0.5
    if recentUpdate and myStacks > E.prevMyStacks and (now - E.lastAnyCastAt) > 0.9 then
        local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
        local label = U.GetRazeLabelByDistance(dist, HIT_RADIUS + 60)
        if label then
            local st = E.raze[label]
            st.lastCastAt = now
            st.readyAt = now + RAZE_CD - 0.6
            E.lastAnyCastAt = now
        end
    end
    E.prevMyStacks = myStacks
    E.prevMyStacksTime = now
end

-- How many seconds until the enemy band is ready (0 = ready now / unknown = ready).
function K.EnemyRazeReadyIn(label)
    local st = K._enemy.raze[label]
    if not st then return 0 end
    local dt = st.readyAt - GameTime()
    if dt < 0 then return 0 end
    return dt
end

function K.EnemyRazeReady(label, horizon)
    return K.EnemyRazeReadyIn(label) <= (horizon or 0)
end

-- Is the enemy in a raze cast phase right now? -> label, elapsed, remaining
function K.EnemyPhase()
    local E = K._enemy
    if not E.phaseLabel then return nil, 0, 0 end
    local elapsed = GameTime() - E.phaseStart
    local remaining = CAST_POINT - elapsed
    if remaining < 0 then remaining = 0 end
    return E.phaseLabel, elapsed, remaining
end

-- The centre of the enemy raze circle for a given band (by his current facing).
function K.EnemyRazeCenter(enemy, label)
    local loc = enemy:GetLocation()
    local rad = math.rad(enemy:GetFacing() or 0)
    local d = Center(label)
    return Vector(loc.x + math.cos(rad) * d, loc.y + math.sin(rad) * d, loc.z)
end

function K.EnemyManaBudget(enemy, allowConsumables)
    local mana = enemy:GetMana() or 0
    if allowConsumables then
        mana = mana + U.GetMangoMana(enemy) -- By charges (2 mangoes = +200 = 2 more razes)
        local charges = U.GetStickCharges(enemy)
        if charges > 0 then mana = mana + charges * 15 end
    end
    return mana
end

-- How many enemy razes become ready within horizon seconds (limited by mana).
-- Returns count, countIgnoringMana.
function K.EnemyReadyRazeCount(enemy, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    if not U.EnemyHasRaze(enemy) then return 0, 0 end
    local n = 0
    for i = 1, 3 do
        if K.EnemyRazeReadyIn(K.LABELS[i]) <= (horizon or 0) then n = n + 1 end
    end
    local budget = math.floor(K.EnemyManaBudget(enemy, allowConsumables) / RAZE_MANA)
    if budget < n then return budget, n end
    return n, n
end

-- Can an enemy band reach me from distance dist within horizon seconds.
-- If the enemy is not faster than me - assume he can close only ~120u
-- (I retreat at the same speed), otherwise by (his speed * horizon).
local function BandCanReach(bot, enemy, label, dist, horizon, pinned)
    local reach = Center(label) + HIT_RADIUS + 25
    if dist <= reach then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local closeAllowance
    if pinned or enMS > myMS + 5 then
        closeAllowance = enMS * (horizon or 0) + 60
    else
        closeAllowance = 120
    end
    return dist <= reach + closeAllowance
end

-- The enemy burst on me from distance dist over horizon (accounting for band readiness, mana,
-- band reach and his right-click damage if he is already in attack range).
-- Returns damage, razeCount.
function K.EnemyBurstVs(bot, enemy, dist, horizon, pinned, stacksOverride)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local n = 0
    if U.EnemyHasRaze(enemy) then
        for i = 1, 3 do
            local label = K.LABELS[i]
            if K.EnemyRazeReadyIn(label) <= horizon and BandCanReach(bot, enemy, label, dist, horizon, pinned) then
                n = n + 1
            end
        end
        local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
        if budget < n then n = budget end
    end
    local dmg = K.EnemyRazeDamage(bot, enemy, n, stacksOverride)
    -- Right clicks: only if he is already close (otherwise we are backing off)
    local atkRange = (enemy:GetAttackRange() or 525) + 80
    if dist <= atkRange then
        local atk = K.AttackDamageVs(enemy, bot)
        local spa = enemy:GetSecondsPerAttack() or 1.6
        local hits = math.floor(horizon / math.max(0.6, spa))
        if hits < 1 then hits = 1 end
        if hits > 3 then hits = 3 end
        dmg = dmg + atk * hits
    end
    return dmg, n
end

-- My burst on the enemy from distance dist over horizon.
-- The first raze must be castable "from here" (the band is in reach by the same rules).
function K.MyBurstVs(bot, enemy, dist, horizon, allowConsumables)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 2.5
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local closeAllowance = 120
    if myMS > enMS + 5 then closeAllowance = (myMS - enMS) * horizon + 120 end
    local n = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.MyRazeReady(bot, label) then
            local reach = Center(label) + HIT_RADIUS + 25
            if dist <= reach + closeAllowance then n = n + 1 end
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, allowConsumables) / RAZE_MANA)
    if budget < n then n = budget end
    local dmg = K.MyRazeDamage(bot, enemy, n)
    local atkRange = (bot:GetAttackRange() or 525) + 80
    if dist <= atkRange then
        local atk = K.AttackDamageVs(bot, enemy)
        local spa = bot:GetSecondsPerAttack() or 1.6
        local hits = math.floor(horizon / math.max(0.6, spa))
        if hits < 1 then hits = 1 end
        if hits > 3 then hits = 3 end
        dmg = dmg + atk * hits
    end
    return dmg, n
end

-- "Hunt": my burst on the enemy over horizon seconds assuming I REACH the mid band
-- (all three reach from there): razes that come off cooldown within the horizon (cd <= horizon - 0.6),
-- limited by mana WITH mango; plus 1-2 right clicks. The "go finish him" decision with a large
-- HP edge when the ordinary race (razes from the current distance only) sees no kill.
function K.MyHuntBurst(bot, enemy, horizon)
    if not U.CanQuery(enemy) then return 0, 0 end
    horizon = horizon or 4.0
    local n = 0
    for i = 1, 3 do
        local ab = bot:GetAbilityByName(K.RAZE_NAMES[K.LABELS[i]])
        if ab and ab:GetLevel() > 0 then
            local cd = 0
            if ab.GetCooldownTimeRemaining then
                local ok, v = pcall(ab.GetCooldownTimeRemaining, ab)
                if ok and type(v) == "number" then cd = v end
            elseif not ab:IsCooldownReady() then
                cd = 999
            end
            if cd <= horizon - 0.6 then n = n + 1 end
        end
    end
    local budget = math.floor(K.MyManaBudget(bot, true) / RAZE_MANA)
    if budget < n then n = budget end
    local dmg = K.MyRazeDamage(bot, enemy, n)
    local spa = bot:GetSecondsPerAttack() or 1.6
    if spa <= 0 then spa = 1.6 end
    local hits = math.floor((horizon - 1.5) / math.max(0.6, spa))
    if hits < 1 then hits = 1 end
    if hits > 2 then hits = 2 end
    return dmg + K.AttackDamageVs(bot, enemy) * hits, n
end

-- Minimum safe distance to the enemy: outside all his bands that are ready within horizon.
-- 0 = no band is ready (or no mana) -> we can stand anywhere.
function K.EnemyMinSafeDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + HIT_RADIUS + 45
            if r > best then best = r end
        end
    end
    return best
end

-- "Hedge" distance: stand at the outer edge of his furthest READY band
-- (centre + 200 of the 250 radius): the cast animation (0.55 s) gives us time to leave the circle.
-- This is the compromise for a "zoned" SF: do not give up the whole wave but do not stand in the band centre.
function K.EnemyDodgeableDistance(enemy, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return 0 end
    local budget = math.floor(K.EnemyManaBudget(enemy, true) / RAZE_MANA)
    if budget <= 0 then return 0 end
    local best = 0
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            local r = Center(label) + 200
            if r > best then best = r end
        end
    end
    return best
end

-- The enemy band that is ready within horizon and that I am standing in (or nil).
function K.EnemyReadyBandAt(enemy, dist, horizon)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return nil end
    if K.EnemyManaBudget(enemy, true) < RAZE_MANA then return nil end
    for i = 1, 3 do
        local label = K.LABELS[i]
        if K.EnemyRazeReadyIn(label) <= (horizon or 0) then
            if math.abs(dist - Center(label)) <= HIT_RADIUS + 30 then return label end
        end
    end
    return nil
end

-- How many razes a unit can pay for right now (mana + consumables, 75 per raze).
function K.MyRazeBudget(bot, allowConsumables)
    return math.floor((K.MyManaBudget(bot, allowConsumables) or 0) / RAZE_MANA)
end

function K.EnemyRazeBudget(enemy, allowConsumables)
    if not U.CanQuery(enemy) then return 0 end
    return math.floor((K.EnemyManaBudget(enemy, allowConsumables) or 0) / RAZE_MANA)
end

-- Is it safe for me to stand/cast in band label.
-- At ~center(label) I am inside HIS label band, so only its copy is dangerous.
-- If his copy is on cooldown (or unlearned / no mana) he cannot answer. This is more precise
-- than the old rule "only the band he hit us with last is safe".
function K.BandSafeFromEnemy(enemy, label, marginSec)
    if not U.CanQuery(enemy) or not U.EnemyHasRaze(enemy) then return true end
    local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
    if not ab or ab:GetLevel() == 0 then return true end
    if K.EnemyManaBudget(enemy, true) < RAZE_MANA then return true end
    return K.EnemyRazeReadyIn(label) > (marginSec or 0.0)
end

-- Preserve the confirmed 2:1 lead; absolute damage advantage is not a waiver.
function K.HasRazeStackLead(bot, enemy)
    if not U.CanQuery(enemy) or not (enemy.IsHero and enemy:IsHero()) then return false end
    local mine, myRemain = U.GetShadowrazeDebuff(bot)
    local theirs, theirRemain = U.GetShadowrazeDebuff(enemy)
    return mine == 1 and theirs >= 2 and myRemain > 0.35 and theirRemain > 0.35
end

-- Count every overlapping, learned, ready band, not just the nearest centre.
function K.EnemyBandsAcross(enemy, low, high, horizon)
    if not U.CanQuery(enemy) then return 0 end
    horizon = horizon or 0.7
    local mana = K.EnemyManaBudget(enemy, true)
        + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * horizon
    local n, outer = 0, 0
    for _, label in ipairs(K.LABELS) do
        local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab:GetLevel() > 0 and K.EnemyRazeReadyIn(label) <= horizon
            and high >= Center(label) - HIT_RADIUS - 30
            and low <= Center(label) + HIT_RADIUS + 30 then
            n = n + 1
            outer = math.max(outer, Center(label) + HIT_RADIUS + 30)
        end
    end
    return math.min(n, math.floor(mana / RAZE_MANA)), mana >= RAZE_MANA and outer or 0
end

function K.StackLeadStepSafe(bot, enemy, point)
    if not K.HasRazeStackLead(bot, enemy) then return true end
    local here, e = bot:GetLocation(), enemy:GetLocation()
    local step = point - here
    local length2 = step.x * step.x + step.y * step.y
    local t = 0
    if length2 > 1 then
        t = math.max(0, math.min(1, ((e.x-here.x)*step.x + (e.y-here.y)*step.y) / length2))
    end
    local nearest = U.DistanceBetweenLocations(here + step * t, e)
    local before, after = U.DistanceBetweenLocations(here, e), U.DistanceBetweenLocations(point, e)
    if after >= before and nearest >= before - 5 then return true end -- Always permit outward escape.
    local horizon = math.min(1.5, math.sqrt(length2) / math.max(1, bot:GetCurrentMovementSpeed()) + 0.7)
    return K.EnemyBandsAcross(enemy, nearest, math.max(before, after), horizon) == 0
end

-- A short mid/far raze exchange is not a sustained right-click duel. Reuse
-- the existing damage and mana model, but bound the exchange by cast/move time.
-- Returns safe opportunity, ready own razes, enemy razes, our damage, incoming.
function K.SpellTradeWindow(bot, enemy, snapshot)
    if not U.CanQuery(enemy) then return false, 0, 0, 0, 0 end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1050 then return false, 0, 0, 0, 0 end
    local ready, desired = 0, C.RAZE.FAR_CENTER
    for _, label in ipairs({"far", "mid"}) do
        if K.MyRazeReady(bot, label) then
            ready = ready + 1
            desired = math.min(desired, Center(label))
        end
    end
    -- Only mana already usable without spending this tick on an item.
    local count = math.min(ready, math.floor(bot:GetMana() / RAZE_MANA))
    if count < 1 then return false, count, 0, 0, 0 end
    if count == 1 and K.MyRazeReady(bot, "far") then desired = C.RAZE.FAR_CENTER end
    local ms = math.max(1, bot:GetCurrentMovementSpeed() or 305)
    local reach = desired + HIT_RADIUS - 40
    if count >= 2 then desired = C.RAZE.MID_CENTER + 150; reach = desired end
    local approach = math.max(0, dist - reach) / ms
    local horizon = count * CAST_POINT + approach + 0.40
    if horizon > 3.0 or not K.CanCatch(bot, enemy, reach, horizon) then
        return false, count, 0, 0, 0
    end
    local enemyMana = K.EnemyManaBudget(enemy, true)
        + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * horizon
    local enemyReady = 0
    if U.EnemyHasRaze(enemy) then
        for _, label in ipairs(K.LABELS) do
            local ab = enemy:GetAbilityByName(K.RAZE_NAMES[label])
            if ab and ab:GetLevel() > 0 and K.EnemyRazeReadyIn(label) <= horizon then enemyReady = enemyReady + 1 end
        end
    end
    local enemyCount = math.min(enemyReady, math.floor(enemyMana / RAZE_MANA))
    if count <= enemyCount then return false, count, enemyCount, 0, 0 end
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * desired
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then
            return false, count, enemyCount, 0, 0
        end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, enemyCount)
    local enemyRange = enemy:GetAttackRange() or 525
    -- No mana is NOT no danger: include right clicks if he can reach during casts.
    if math.min(dist, desired) <= enemyRange + (enemy:GetCurrentMovementSpeed() or 305) * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
            * math.ceil(horizon / math.max(0.6, enemy:GetSecondsPerAttack() or 1.6))
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack() or 1.0))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then
                return false, count, enemyCount, 0, incoming
            end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    local damage = K.MyRazeDamage(bot, enemy, count)
    local reserve = math.max(60, K.AttackDamageVs(enemy, bot) * 0.75)
    local myStacks = U.GetShadowrazeDebuff(bot)
    local spentRanged = count >= 2 and myStacks == 0
        and K.EnemyRazeReadyIn("mid") > horizon + 0.2 and K.EnemyRazeReadyIn("far") > horizon + 0.2
    local favourable = bot:GetHealth() - incoming >= reserve
        and damage >= incoming + (spentRanged and 0 or 35)
    return favourable, count, enemyCount, damage, incoming, favourable and spentRanged
end

-- Finite cast schedule for one short reply, including regeneration and already flying attacks.
function K.ShortReplyIncoming(bot,enemy,horizon,s)
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local mana=K.EnemyManaBudget(enemy,true)+math.max(0,enemy:GetManaRegen() or 0)*horizon
    local budget=math.floor(mana/RAZE_MANA)
    local phase,_,remaining=K.EnemyPhase()
    local times={}
    for _,label in ipairs(K.LABELS) do
        local ab=enemy:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab:GetLevel()>0 then
            local gap=math.max(0,dist-Center(label)-HIT_RADIUS,Center(label)-HIT_RADIUS-dist)
            local t=math.max(K.EnemyRazeReadyIn(label),gap/math.max(1,enemy:GetCurrentMovementSpeed()))+CAST_POINT
            if phase==label then t=math.max(0,remaining or CAST_POINT);budget=budget+1 end
            times[#times+1]=t
        end
    end
    table.sort(times)
    local n,last=0,-CAST_POINT
    for _,t in ipairs(times) do
        local finish=math.max(t,last+CAST_POINT)
        if finish<=horizon and n<budget then n=n+1;last=finish end
    end
    local damage=K.EnemyRazeDamage(bot,enemy,n)
    if dist<=enemy:GetAttackRange()+enemy:GetCurrentMovementSpeed()*horizon then
        damage=damage+K.AttackDamageVs(enemy,bot)*math.ceil(horizon/math.max(0.6,enemy:GetSecondsPerAttack()))
    end
    for _,creep in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget()==bot then
            damage=damage+K.AttackDamageVs(creep,bot)*math.ceil(horizon/math.max(0.6,creep:GetSecondsPerAttack()))
        end
    end
    for _,pr in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
        if not pr.is_attack or not U.CanQuery(pr.caster) then return math.huge end
        damage=damage+K.AttackDamageVs(pr.caster,bot)
    end
    return damage
end

function K.ManaCycleWindow(bot,enemy,s)
    if not U.CanQuery(enemy) or bot:GetMana()<150 or bot:IsSilenced() or bot:IsHexed()
        or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    local times={}
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    for _,label in ipairs(K.LABELS) do
        local ab=bot:GetAbilityByName(K.RAZE_NAMES[label])
        if ab and ab:GetLevel()>0 then
            local cd=ab:GetCooldownTimeRemaining()
            if cd<=9 and math.abs(distance-Center(label))<=HIT_RADIUS-(C.RAZE.ROBUST_MARGIN or 30) then
                times[#times+1]=math.max(0,cd)
            end
        end
    end
    table.sort(times)
    local n=math.min(#times,math.floor(bot:GetMana()/RAZE_MANA))
    if n<2 then return false end
    local horizon=0
    for i=1,n do horizon=math.max(horizon,times[i])+CAST_POINT end
    horizon=horizon+0.35
    if horizon>10.5 or K.EnemyManaBudget(enemy,true)+math.max(0,enemy:GetManaRegen() or 0)*horizon>=75 then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(100,K.AttackDamageVs(enemy,bot)*1.25) then return false end
    local hits=math.max(0,math.floor((horizon-n*CAST_POINT)/math.max(0.6,bot:GetSecondsPerAttack())))
    -- Do not assume old stacks survive until the reloaded spells.
    local damage=n*K.MyRazeDamage(bot,enemy,1,-(U.GetShadowrazeDebuff(enemy) or 0))+K.AttackDamageVs(bot,enemy)*hits
    local enemyHP=enemy:GetHealth()+math.max(0,enemy:GetHealthRegen() or 0)*horizon+U.GetStickCharges(enemy)*15
    if U.HasItem(enemy,"item_faerie_fire") then enemyHP=enemyHP+85 end
    return bot:GetHealth()-incoming-(enemyHP-damage)>=60
end

-- A read-only recovery estimate for the shop. Do not call Race here: the shop
-- must not overwrite the live combat snapshot or reset the enemy cast tracker.
function K.NeedsRecoverySupport(bot, enemy)
    if not U.CanQuery(enemy) then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > 1600 then return false end
    local mine = K.MyBurstVs(bot, enemy, math.min(dist, 600), 2.5, true)
    local theirs = K.EnemyBurstVs(bot, enemy, math.min(dist, 600), 2.5, false)
    local deficit = (enemy:GetHealth() - mine) - (bot:GetHealth() - theirs)
    return deficit >= 220 and (theirs >= mine + 80 or enemy:GetHealth() >= bot:GetHealth() + 250)
end

-- The race: absolute HP, who kills whom.

K._race = {
    valid = false,
    dist = 0,
    myHp = 0, enHp = 0,
    myBurstNow = 0, myBurstSoon = 0, myRazesSoon = 0,
    enBurstNow = 0, enBurstSoon = 0, enRazesSoon = 0,
    canKillNow = false, canKillSoon = false,
    heCanKillNow = false, heCanKillSoon = false,
    edge = 0, -- (my HP after his burst) - (his HP after my burst)
    hpDiff = 0, -- my HP - his HP (absolute)
    minSafeDist = 0, -- the distance beyond which his ready bands cannot reach me
    enemyFaster = false,
    enemyBandHere = nil, -- the enemy's ready band that I am standing in
}

-- Tower damage on a hero over horizon seconds (if the hero is in its radius). T1: ~90 damage, BAT 0.9.
local function TowerDamageOn(tower, hero, horizon)
    if not tower or not U.CanQuery(hero) then return 0 end
    local okAlive, alive = pcall(tower.IsAlive, tower)
    if not okAlive or not alive then return 0 end
    local okLoc, tLoc = pcall(tower.GetLocation, tower)
    if not okLoc or not tLoc then return 0 end
    if GetUnitToLocationDistance(hero, tLoc) > 720 then return 0 end
    local raw = 90
    local okD, d = pcall(tower.GetAttackDamage, tower)
    if okD and type(d) == "number" and d > 0 then raw = d end
    local per = hero:GetActualIncomingDamage(raw, DAMAGE_TYPE_PHYSICAL)
    return per * math.floor(horizon / 0.9)
end

-- s (optional) = the world snapshot W.s: the T1 towers so their damage counts in the race.
function K.Race(bot, enemy, pinned, s)
    local R = K._race
    R.valid = false
    if not bot or not U.CanQuery(enemy) then return R end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local myHp = bot:GetHealth() or 0
    local enHp = enemy:GetHealth() or 0

    local myNow = K.MyBurstVs(bot, enemy, dist, 0.3, true)
    local mySoon, myRazesSoon = K.MyBurstVs(bot, enemy, dist, 2.5, true)
    local enNow = K.EnemyBurstVs(bot, enemy, dist, 0.3, pinned)
    local enSoon, enRazesSoon = K.EnemyBurstVs(bot, enemy, dist, 2.5, pinned)

    -- Towers: he is under my T1 - its damage is on my side; I am under his T1 - on his side.
    R.myTowerOnHim = 0
    R.hisTowerOnMe = 0
    if s then
        R.myTowerOnHim = TowerDamageOn(s.allyT1, enemy, 2.5)
        R.hisTowerOnMe = TowerDamageOn(s.enemyT1, bot, 2.5)
        mySoon = mySoon + R.myTowerOnHim
        enSoon = enSoon + R.hisTowerOnMe
    end

    -- Prolonged right-click trade: DPS and the time to kill each other with auto attacks
    local myAtk = K.AttackDamageVs(bot, enemy)
    local enAtk = K.AttackDamageVs(enemy, bot)
    local mySpa = bot:GetSecondsPerAttack() or 1.6
    local enSpa = enemy:GetSecondsPerAttack() or 1.6
    if mySpa <= 0 then mySpa = 1.6 end
    if enSpa <= 0 then enSpa = 1.6 end
    R.myDps = myAtk / mySpa
    R.enDps = enAtk / enSpa
    R.ttkMe = (R.enDps > 0) and (myHp / R.enDps) or 999
    R.ttkHim = (R.myDps > 0) and (enHp / R.myDps) or 999

    R.dist = dist
    R.myHp = myHp
    R.enHp = enHp
    R.myBurstNow = myNow
    R.myBurstSoon = mySoon
    R.myRazesSoon = myRazesSoon
    R.enBurstNow = enNow
    R.enBurstSoon = enSoon
    R.enRazesSoon = enRazesSoon
    R.canKillNow = (myNow > 0) and (myNow >= enHp)
    R.canKillSoon = (mySoon > 0) and (mySoon >= enHp)
    R.heCanKillNow = (enNow > 0) and (enNow >= myHp)
    R.heCanKillSoon = (enSoon > 0) and (enSoon >= myHp)
    R.edge = (myHp - enSoon) - (enHp - mySoon)
    R.hpDiff = myHp - enHp
    -- A 6 s trade projection: "soon" burst + auto attacks for the remaining time (absolute HP).
    local T = 6.0
    local myAfter = myHp - enSoon - R.enDps * (T - 2.5)
    local enAfter = enHp - mySoon - R.myDps * (T - 2.5)
    R.edgeLong = myAfter - enAfter
    local cfgD = C.DEFENSE or {}
    R.weaker = (R.edgeLong < -(cfgD.WEAKER_EDGE or 120))
        or (R.ttkMe < R.ttkHim * 0.6 and R.edge < 0)
    -- "Weaker in the long run": losing specifically the prolonged right-click trade (levels/souls/items/HP pool),
    -- not a temporary skew from raze cooldowns. Used where the cost of a mistake is CS (contested last hits).
    R.weakerSustained = R.ttkMe < R.ttkHim * (cfgD.SUSTAINED_TTK_RATIO or 0.8)
    R.minSafeDist = K.EnemyMinSafeDistance(enemy, 2.5)
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    R.enemyFaster = enMS > myMS + 5
    R.enemyBandHere = K.EnemyReadyBandAt(enemy, dist, 1.0)
    R.spellWindow, R.windowMyRazes, R.windowEnemyRazes, R.windowDamage, R.windowIncoming, R.cooldownWindow = K.SpellTradeWindow(bot, enemy, s)
    R.valid = true
    return R
end

-- Chasing

-- Can the distance be closed to neededDist in a reasonable time.
-- An enemy with equal/greater speed running away from us - uncatchable.
function K.CanCatch(bot, enemy, neededDist, maxTime)
    if not U.CanQuery(enemy) then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d <= neededDist + 60 then return true end
    local myMS = bot:GetCurrentMovementSpeed() or 305
    local enMS = enemy:GetCurrentMovementSpeed() or 305
    local vx, vy = 0, 0
    if enemy.GetVelocity then
        local v = enemy:GetVelocity()
        if v then vx, vy = v.x or 0, v.y or 0 end
    end
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed < 40 then
        -- Standing still: we catch him if the distance is reasonable
        return (d - neededDist) / myMS <= (maxTime or 2.5)
    end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    local awaySpeed = vx * ax + vy * ay -- >0: running away from us
    if awaySpeed > 0.4 * speed then
        local closing = myMS - awaySpeed
        if closing <= 15 then return false end
        return (d - neededDist) / closing <= (maxTime or 2.5)
    end
    -- Walking toward us / sideways
    return (d - neededDist) / (myMS + math.max(0, -awaySpeed)) <= (maxTime or 2.5)
end

-- Is the enemy moving away from us (fleeing)?
function K.IsEnemyMovingAway(bot, enemy)
    if not U.CanQuery(enemy) or not enemy.GetVelocity then return false end
    local v = enemy:GetVelocity()
    if not v then return false end
    local speed = math.sqrt((v.x or 0) ^ 2 + (v.y or 0) ^ 2)
    if speed < 60 then return false end
    local botLoc = bot:GetLocation()
    local enLoc = enemy:GetLocation()
    local d = U.DistanceBetweenLocations(botLoc, enLoc)
    if d < 1 then return false end
    local ax, ay = (enLoc.x - botLoc.x) / d, (enLoc.y - botLoc.y) / d
    return (v.x * ax + v.y * ay) > 0.5 * speed
end

-- Hook for utils (utils cannot require combat because of the cycle)
U._K = K

return K

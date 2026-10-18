
local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")
local L = require("bots/nevermore/lasthit")
local P = require("bots/nevermore/positioning")
local K = require("bots/nevermore/combat")
local W = require("bots/nevermore/world")
local LN = require("bots/nevermore/lane")
local I = require("bots/nevermore/intent")

-- Load marker: if this line is missing from the console the file did not load
-- and the stock Valve bot plays instead (look for [VScript] errors).
print("[SF-BOT] bot_nevermore.lua loaded (v2.9.16: contact-trade/last-stand/reachable-last-hits)")

U.DEBUG = false

-- All handlers live in the H table instead of being local functions: works around the
-- Lua 5.1 limit of 60 upvalues per function (otherwise the file does not compile in Dota).
local H = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}


local State = {
    hunting                   = false, -- Hunting (see H.ComputeHunt)
    attackTarget              = nil,
    attackStartTime           = 0,
    deaggroTime               = 0,
    prepTarget                = nil,
    prepTargetTime            = 0,
    lhAttackTarget            = nil,
    defensive                 = false,
    defensiveSince            = 0,
    enemyAggroCount           = 0,
    tpOrderTime               = 0,
    flyingProjectiles         = {},
    firedThisAttack           = false,
    lastAggroTime             = 0,
    aggroPullTime             = 0,
    lastItemUseTime           = 0,
    lastHarassTime            = 0,
    needsTP                   = false,
    tpOrderTime               = -100,
    -- Commitment to "finish" or "run" (prevents fight<->flee flapping)
    commitKillUntil           = 0,
    fleeUntil                 = 0,
    -- Enemy is teleporting to its T1 (TP channel visible / respawned after death)
    enemyTPIncomingUntil      = 0,
    enemyWasAlive             = true,
    aimingRaze                = nil,
    aimingTarget              = nil,
    aimingLoc                 = nil,
    aimingStartTime           = 0,
    aimingValidationRadius    = nil,
    forcedRetreatLoc          = nil,
    forcedRetreatUntil        = 0,
    -- Commitment to walk out of the enemy T1 (point + deadline)
    towerEscapeLoc            = nil,
    towerEscapeUntil          = 0,
    nearChainUntil            = 0, -- Window for the follow-up raze chain after punishing an enemy that walked up to us
    lastMoveLoc               = nil,
    lastMoveTime              = 0,
    emergencyRetreat          = nil,
    emergencyRetreatStartTime = 0,
    emergencyTPQueued         = false,
    glyphUsedForDive          = false,
    glyphDiveTime             = 0,
    lastForceSalveTime        = 0,
    enemyT1ClosestCreepDist   = nil,
    enemyT1ClosestCreepTime   = 0,
    actionTaken               = false,
    holdPos = false,
    goingToFountain           = false,
    fountainReason            = nil,
    enemyReachedLevel2First   = false,
    heroAttackTarget          = nil,
    heroAttackTime            = 0,
    _lastSalveAutoBuyTime     = 0,
    -- Tango: sticky tree choice (fixes oscillating between trees)
    tangoTree                 = nil,
    tangoCastAt = 0,
    tangoFails = 0,
    tangoTreeLoc              = nil,
    tangoChosenAt             = 0,
    tangoBestDist             = math.huge,
    tangoBadTree              = nil,
    tangoBadTreeTime          = 0,
    -- Dodging the enemy raze
    dodgeLoc                  = nil,
    dodgeUntil                = 0,
    -- Intent and context
    intent                    = "FARM",
    lastIntentPrint           = 0,
    siegeWaitUntil            = 0,
}

-- Context for the intent FSM (reused, no per-tick allocation)
local IntentCtx = {
    enemy = false, race = nil, myHpPct = 1, myRazes = 0, healing = false,
    enemyDist = 99999, enemyDistToWave = 99999, enemyAbsent = false,
    enemyUnderHisTower = false, canCatch = true, underEnemyTower = false,
}

-- Hook for utils (glyph for a dive): "we are really committing" = aiming a raze / hit a hero <= 1 s ago
U._State = State -- Test hook: State access from the tooling
U._engagedCheck = function(bot, enemy)
    if State.aimingRaze then return true end
    if (GameTime() - (State.heroAttackTime or -10)) <= 1.0 then return true end
    return false
end

-- force=true: micro-steps (turning for a raze, dodging) must not be swallowed by deduplication.
function H.SmartMove(bot, loc, threshold, force, stackAbility)
    if not loc then return false end
    if State.actionTaken then return false end
    local enemy = H._enemyHeroNear
    if enemy and not State.forcedRetreatLoc and not State.survivalLoc and not State.towerEscapeLoc
        and not K.StackLeadStepSafe(bot, enemy, loc)
        and not H.StackLeadThirdRazeOK(bot, enemy, stackAbility, loc, W.s) then return false end
    threshold = threshold or 60
    local now = GameTime()
    local last = State.lastMoveLoc
    if force then
        if last and (now - State.lastMoveTime) < 0.1 and U.DistanceBetweenLocations(last, loc) <= 4 then
            State.actionTaken = true
            return true
        end
    elseif last and U.DistanceBetweenLocations(last, loc) <= threshold and (now - State.lastMoveTime) < 0.6 then
        -- A move order to this point was already issued recently: treat it as in progress (actionTaken),
        -- otherwise the next handler overrides it and everything
        -- reverses on the next tick - the classic oscillation between two points.
        State.actionTaken = true
        return true
    end
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    bot:Action_MoveToLocation(loc)
    State.actionTaken = true
    return true
end

function H.ClearMoveCache()
    State.lastMoveLoc = nil
    State.lastMoveTime = 0
end

function H.ClearRazeState()
    State.shortCombatCast = nil
    State.aimingRaze = nil
    State.aimingTarget = nil
    State.aimingLoc = nil
    State.aimingStartTime = 0
    State.aimingValidationRadius = nil
    State.aimingFollowup = nil
end

function H.StartRazeCast(ability, target, loc, validationRadius)
    State.aimingFollowup = nil
    State.lastRazeOrderTime = GameTime()
    if target and target.IsHero and target:IsHero() and U.CanQuery(target) then
        local age = U.GetRecentEnemyRazeHitAge(target)
        if age <= C.RAZE.MIRROR_INSTANT_SEC then
            State.mirrorAnsweredEnemy = target
            State.mirrorAnsweredHit = GameTime() - age
        end
        local data = U.GetRazeAbilityData(ability)
        local chain = State.razeFollowup
        if chain and chain.enemy == target and GameTime() <= chain.untilTime then
            State.aimingFollowup = chain
            State.razeFollowup = nil -- The second cast consumes, never renews, this plan.
        elseif data and (data.label == "far" or data.label == "mid") then
            State.razeFollowup = {
                enemy = target, label = data.label == "far" and "mid" or "far",
                opened = GameTime(), untilTime = GameTime() + 2.5,
                stacks = U.GetShadowrazeDebuff(target),
            }
        end
    end
    State.aimingRaze = ability
    State.aimingTarget = target
    State.aimingLoc = loc
    State.aimingStartTime = GameTime()
    State.aimingValidationRadius = validationRadius or C.RAZE.HIT_RADIUS
    State.actionTaken = true
end

function H.HandleActiveRazeValidation(bot)
    if not State.aimingRaze then return false end
    local now = GameTime()
    if bot:IsUsingAbility() or bot:IsChanneling() then
        if not U.CanQuery(State.aimingTarget) then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local elapsed = now - State.aimingStartTime
        -- Do not cancel a completed cast just because the target moves during backswing.
        if elapsed >= C.RAZE.CAST_POINT and not State.aimingRaze:IsInAbilityPhase() then
            H.ClearRazeState()
            return false
        end
        local remaining = math.max(0, C.RAZE.CAST_POINT - elapsed)

        local data = U.GetRazeAbilityData(State.aimingRaze)
        if not data then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
            return true
        end

        local predicted = U.PredictPosition(State.aimingTarget, remaining + (C.RAZE.LAND_LEAD or 0.08))
        local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
        local limit = math.min(State.aimingValidationRadius or C.RAZE.HIT_RADIUS, C.RAZE.HIT_RADIUS) - 10

        if error > limit then
            State.mirrorAnsweredHit = nil -- A cancelled cast has not answered the hit.
            State.razeFollowup = State.aimingFollowup
            bot:Action_ClearActions(true)
            H.ClearRazeState()
            H.ClearMoveCache()
        end
        return true
    end

    if now > State.aimingStartTime + 1.0 then
        H.ClearRazeState()
    end

    return false
end

function H.SafeClearActions(bot)
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    bot:Action_ClearActions(true)
    H.ClearMoveCache()
    return true
end

-- Power Treads. Intelligence before a raze and shortly after it (bigger mana pool + regen),
-- strength while surviving, agility while attacking. Only called where the switch order
-- cannot override something important: idle tick, first retreat tick, pre-cast tick.
function H.ManageTreads(bot, mode)
    if not U.HasItem(bot, "item_power_treads") then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.TREADS or {}
    local opts = nil
    if mode == "CAST" then
        -- Do not delay the raze with a second order: switch only when one use is enough
        opts = { oneUseOnly = true }
    elseif mode == nil then
        local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        if hpPct < (cfg.SURVIVE_HP_PCT or 0.30) or State.intent == I.RETREAT or State.emergencyRetreat then
            mode = "SURVIVE"
        elseif bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK then
            mode = "FIGHT"
            opts = { hold = cfg.MODE_HOLD or 1.0 }
        else
            -- Idle: stay on intelligence (mana pool and regen) so we are on it when a raze comes
            mode = "CAST"
            opts = { hold = cfg.MODE_HOLD or 1.0 }
        end
    end
    return U.UpdatePowerTreads(bot, mode, opts)
end

function H.BeginForcedRetreat(bot, loc, duration)
    if not loc then return false end
    local now = GameTime()
    -- A repeated order to the same point is NOT re-issued via ClearActions. Previously every call
    -- did ClearActions + Move: the order was cancelled on the very tick it was issued, the hero never
    -- started moving - which looked like "the bot jitters in place" (under the enemy tower).
    local same = State.forcedRetreatLoc ~= nil
        and U.DistanceBetweenLocations(State.forcedRetreatLoc, loc) <= 120
        and now < (State.forcedRetreatUntil or 0)
    State.forcedRetreatLoc = loc
    State.forcedRetreatUntil = math.max(State.forcedRetreatUntil or 0, now + (duration or 0.75))
    -- Clean flee: while retreating we do not turn to the enemy and do not answer
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 1.5)
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    State.actionTaken = true
    if not same then
        -- While leaving, switch Power Treads to strength (+HP): the order takes this tick,
        -- the step starts on the next one (0.05 s)
        if H.ManageTreads(bot, "SURVIVE") then return true end
        H.SafeClearActions(bot)
    end
    bot:Action_MoveToLocation(loc)
    return true
end

function H.ClearForcedRetreat()
    State.forcedRetreatLoc = nil
    State.forcedRetreatUntil = 0
end

-- Commitment to walk out of the enemy tower (see HandleEnemyTowerSafety)
function H.ClearTowerEscape()
    State.towerEscapeLoc = nil
    State.towerEscapeUntil = 0
end

function H.CastOrTurnRaze(bot, ability, actionType, aimLoc, target)
    if State.combatPolicyActive == true and target and target.IsHero and target:IsHero()
        and not State.heroCombatAllowed then return false end
    if not ability or (target and not U.CanQuery(target)) then return false end
    if target and State.towerChaseBlockedEnemy == target then return false end
    if target and K.HasRazeStackLead(bot, target) then
        local distance = GetUnitToLocationDistance(bot, target:GetLocation())
        if K.EnemyBandsAcross(target, distance, distance, 0.7) > 0
            and not H.StackLeadThirdRazeOK(bot, target, ability, bot:GetLocation(), W.s) then return false end
    end
    if State.actionTaken then return false end
    -- Every path that decided "CAST" goes through the facing check (see H.RazeFacingOK); otherwise TURN
    if actionType == "CAST" and aimLoc and not H.RazeFacingOK(bot, aimLoc) then
        actionType = "TURN"
    end

    local data = U.GetRazeAbilityData(ability)
    if data and target and U.CanQuery(target) then
        -- Check the band against both the current and the predicted position (aimLoc): the raze lands
        -- 0.55 s later and an approaching enemy changes band in that time. Previously only
        -- the current position was checked and casts at an approaching enemy were dropped.
        local distNow = GetUnitToLocationDistance(bot, target:GetLocation())
        local errNow = math.abs(distNow - data.center)
        local errPred = errNow
        if aimLoc then
            errPred = math.abs(GetUnitToLocationDistance(bot, aimLoc) - data.center)
        end
        if math.min(errNow, errPred) > C.RAZE.STRICT_RADIUS + 25 then
            return false
        end
    end

    if actionType == "TURN" then
        -- Guard against an endless turn: turning 180 degrees takes ~0.1 s,
        -- so TURNing for over 0.45 s means something does not add up (target on the circle edge etc.);
        -- then TURN razes are blocked for 1 s and control goes back to the rest of the logic.
        local now = GameTime()
        if now < (State.razeTurnBlockUntil or 0) then return false end
        if (now - (State.lastTurnTick or -10)) > 0.25 then State.turnSince = now end
        State.lastTurnTick = now
        if (now - (State.turnSince or now)) > 0.45 then
            State.razeTurnBlockUntil = now + 1.0
            State.turnSince = now
            return false
        end
        local botLoc = bot:GetLocation()
        local turnLoc = aimLoc or (target and target:GetLocation()) or botLoc
        local dist = U.DistanceBetweenLocations(botLoc, turnLoc)
        local stepLoc = turnLoc
        -- Turn step 40 u (was 12): too short an order could be executed by the engine without
        -- turning the hero fully; 40 u = ~0.13 s of walking and the cast on the next tick stops it
        local step = (C.RAZE.TURN_STEP or 40)
        if dist > step + 10 then
            local dir = (turnLoc - botLoc):Normalized()
            stepLoc = botLoc + dir * step
        end
        return H.SmartMove(bot, stepLoc, 20, true, ability)
    elseif actionType == "CAST" then
        -- Every caller, including mirror/finish shortcuts, must cover the landing point.
        if data and target and U.CanQuery(target) then
            local landing = U.PredictPosition(target, C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08))
            if U.GetRazeHitErrorWithCurrentFacing(bot, landing, data.center) > C.RAZE.HIT_RADIUS - 10 then
                return false
            end
        end
        -- Before a raze switch Power Treads to intelligence (bigger mana pool -> more mana
        -- left after the cast). The order takes this tick, the cast follows on the next one.
        if H.ManageTreads(bot, "CAST") then
            State.actionTaken = true
            return true
        end
        bot:Action_UseAbility(ability)
        H.StartRazeCast(ability, target, aimLoc, C.RAZE.HIT_RADIUS)
        H.ClearMoveCache()
        return true
    end

    return false
end

-- Single facing check before the cast. An untargeted raze flies where the hero is LOOKING at
-- the start of the cast; "the circle covers the enemy at the current facing" (errFacing <= 220) allowed
-- a cast with an error of up to ~18 degrees on the far band - and any step by the enemy meant a miss
-- ("the bot turned slightly left/right and missed"). Now CAST only if the angle between
-- the look direction and the aim point <= MAX_ANGLE_TO_CAST; otherwise TURN (0.03-0.1 s).
function H.RazeFacingOK(bot, aimLoc)
    if not aimLoc then return true end
    local maxAng = (C.RAZE.MAX_ANGLE_TO_CAST or 6)
    return U.GetAngleDifference(bot, aimLoc) <= maxAng
end



function H.GetRazeAbilityByLabel(bot, label)
    if label == "near" then return bot:GetAbilityByName("nevermore_shadowraze1") end
    if label == "mid"  then return bot:GetAbilityByName("nevermore_shadowraze2") end
    if label == "far"  then return bot:GetAbilityByName("nevermore_shadowraze3") end
    return nil
end

-- Robust: CAST if at the current facing the circle covers the enemy both now and
-- after the cast time; TURN toward the aim point if it covers after turning; otherwise nil.
function H.GetRazeActionType(bot, ability, target)
    if not ability or not target or not U.CanQuery(target) then return nil, nil end
    local data = U.GetRazeAbilityData(ability)
    if not data then return nil, nil end
    local errAim, errFacing, aim = U.RobustRazeErrors(bot, target, data.center, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - (C.RAZE.ROBUST_MARGIN or 30)
    -- The cast threshold equals the candidate threshold. Different thresholds (CAST <= limit-15, TURN <= limit) created
    -- a dead zone: after turning, errFacing == errAim in (limit-15, limit] -> the cast never
    -- goed through while TURN was issued every tick (12 u step) -> the bot jittered in place forever.
    -- CAST = the circle covers AND the hero faces the aim point (angle <= MAX_ANGLE_TO_CAST);
    -- covers only after turning -> TURN
    if errFacing <= limit and H.RazeFacingOK(bot, aim) then return "CAST", aim end
    if errAim <= limit then return "TURN", aim end
    return nil, aim
end

function H.GetStickLikeItem(bot)
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and (not wand.GetCurrentCharges or wand:GetCurrentCharges() > 0) then return wand end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and (not stick.GetCurrentCharges or stick:GetCurrentCharges() > 0) then return stick end
    return nil
end

function H.GetPotentialCombatMana(bot)
    local mana = bot:GetMana() or 0
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and wand.GetCurrentCharges then
        mana = mana + (wand:GetCurrentCharges() or 0) * 15
    end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and stick.GetCurrentCharges then
        mana = mana + (stick:GetCurrentCharges() or 0) * 15
    end
    mana = mana + U.GetMangoMana(bot) -- By charges
    return mana
end

function H.TryUseBurstManaItem(bot, allowMango)
    local item = H.GetStickLikeItem(bot)
    if not item and allowMango then
        item = U.GetActiveItemByName(bot, "item_enchanted_mango")
    end
    if not item then return false end
    bot:Action_UseAbility(item)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

function H.IsInHeroAttackAnimation(bot)
    if not State.heroAttackTarget then return false end
    if not State.heroAttackTarget:IsAlive() then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local target = bot:GetAttackTarget()
    if target ~= State.heroAttackTarget then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local elapsed = GameTime() - State.heroAttackTime
    local bat = bot:GetSecondsPerAttack() or 1.7
    if elapsed < bat + 0.1 then
        return true
    end
    State.heroAttackTarget = nil
    State.heroAttackTime = 0
    return false
end

function H.IsSameAttackTarget(bot, target)
    return bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK and bot:GetAttackTarget() == target
end

function H.IssueHeroAttack(bot, enemyHero)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.towerChaseBlockedEnemy == enemyHero then return false end
    local distance = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if K.HasRazeStackLead(bot, enemyHero) then
        if K.EnemyBandsAcross(enemyHero, distance, distance, 0.7) > 0 then return false end
        local stop = enemyHero:GetLocation() + (bot:GetLocation()-enemyHero:GetLocation()):Normalized()
            * math.min(distance, bot:GetAttackRange())
        if not K.StackLeadStepSafe(bot, enemyHero, stop) then return false end
    end
    local sameTarget = H.IsSameAttackTarget(bot, enemyHero)
    if not sameTarget then
        bot:Action_AttackUnit(enemyHero, true)
        H.ClearMoveCache()
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    elseif State.attackTarget ~= enemyHero then
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    State.heroAttackTarget = enemyHero
    State.heroAttackTime = GameTime()
    return true
end

-- The attack animation detector uses the ANIMATION (GetAnimActivity/GetAnimCycle), not the order time:
-- the attack order is issued 0-1 s before the real swing (the hero is still walking/turning),
-- so an order-time lock expired before the actual swing and the next
-- handler (creep aggro drop, last hit, raze turn, positioning) cancelled the attack a fraction
-- of a second before the attack point. Called every tick before decisions are made.
function H.UpdateAttackActivity(bot)
    local now = GameTime()
    local act, cyc = nil, nil
    if bot.GetAnimActivity then
        local ok, a = pcall(bot.GetAnimActivity, bot)
        if ok and type(a) == "number" then act = a end
    end
    if act == nil then
        State.atkAnimAvailable = false
        State.atkAnimSince = nil
        return
    end
    if bot.GetAnimCycle then
        local ok, c = pcall(bot.GetAnimCycle, bot)
        if ok and type(c) == "number" then cyc = c end
    end
    State.atkAnimAvailable = true
    local A1 = _G.ACTIVITY_ATTACK or 1503
    local A2 = _G.ACTIVITY_ATTACK2 or 1504
    local A3 = _G.ACTIVITY_ATTACK_EVENT or 1505
    local isAtk = (act == A1 or act == A2 or act == A3)
    if isAtk then
        local restarted = cyc and State.atkAnimCycle and (cyc < State.atkAnimCycle - 0.05)
        if not State.atkAnimSince or restarted then State.atkAnimSince = now end
    else
        State.atkAnimSince = nil
    end
    State.atkAnimCycle = cyc
end

-- Is a right-click swing at the enemy hero in progress (attack point not reached yet)?
function H.IsHeroWindupNow(bot, enemyHero)
    if not enemyHero then return false end
    local okT, target = pcall(bot.GetAttackTarget, bot)
    if not okT or target ~= enemyHero then return false end
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK then return false end
    local ap = bot:GetAttackPoint() or 0.5
    if State.atkAnimAvailable then
        if not State.atkAnimSince then return false end
        return (GameTime() - State.atkAnimSince) < (ap + 0.03)
    end
    return H.IsHeroAttackWindupLocked(bot)
end

-- "Let the attack land": while a swing at the hero is in progress, no non-emergency handler issues
-- orders (70-90 damage in 0.3-0.5 s beats all of them). Exceptions: his burst right now
-- is lethal, the enemy tower is hitting us, emergency retreat. (Raze dodging runs earlier and already handled it.)
function H.ShouldHoldForHeroWindup(bot, s, enemyHero, race)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not H.IsHeroWindupNow(bot, enemyHero) then return false end
    if State.emergencyRetreat then return false end
    if race and race.valid and race.heCanKillNow then return false end
    local t1 = s and s.enemyT1
    if t1 and t1.GetAttackTarget and (not t1.CanBeSeen or t1:CanBeSeen()) then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then return false end
    end
    if bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(0.5) then return false end
    return true
end

function H.IsHeroAttackWindupLocked(bot)
    local target = bot:GetAttackTarget()
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or not target or not target:IsAlive() then
        return false
    end
    if not (target.IsHero and target:IsHero()) then
        return false
    end
    if State.attackTarget ~= target then
        State.attackTarget = target
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    local elapsed = GameTime() - (State.attackStartTime or 0)
    local ap = bot:GetAttackPoint() or 0
    return elapsed < (ap + 0.06)
end

-- "Shield" under the tower: a live (non-siege) allied creep inside the tower radius that is CLOSER to the
-- tower than refLoc (the bot by default), with the tower not currently hitting us. The old check
-- ("any creep within 760 of the tower") missed the case where the creeps walked off after the enemy
-- while the bot stayed the tower's closest target.
function H._hasTankCreepUnderTower(tower, allyCreeps, refLoc)
    if not tower or not tower:IsAlive() then return false end
    local bot = GetBot()
    local tgt = tower.GetAttackTarget and tower:GetAttackTarget()
    if bot and tgt == bot then return false end
    -- "Burn" after leaving the tower: it was hitting US just now - do not trust the shield
    -- (last hits/approaches only from outside its radius until the burn expires)
    if H.TowerBurnActive and H.TowerBurnActive() then return false end
    local ref = refLoc or (bot and bot:GetLocation())
    local count = LN.TowerShieldCount(tower, allyCreeps, ref)
    return count >= 1
end

-- A creep tank under the tower does not justify going in when the enemy hero is nearby and we are weaker
-- (he is at full HP, we are not): in that trade under the tower we simply die while wandering between points.
function H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc)
    if H._hasTankCreepUnderTower(tower, allyCreeps, targetLoc) then
        local eh = H._enemyHeroNear and H._enemyHeroNear
        if eh and U.CanQuery(eh) then
            local d = GetUnitToLocationDistance(eh, targetLoc)
            if d <= 900 then
                local myHp, enHp = bot:GetHealth(), eh:GetHealth()
                if myHp < enHp - 100 or (bot:GetHealth() / math.max(1, bot:GetMaxHealth())) < 0.50 then
                    return false
                end
            end
        end
        return true
    end
    return false
end

function H.GetSafeApproach(bot, targetLoc, enemyTowers, allyCreeps)
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 830 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 885
                end
            end
        end
    end
    return targetLoc
end

function H.GetSafeApproachLoose(bot, targetLoc, enemyTowers, allyCreeps)
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 740 then
                if not H._TowerApproachAllowed(bot, tower, allyCreeps, targetLoc) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 815
                end
            end
        end
    end
    return targetLoc
end

-- Single entry point for ANY approach toward the enemy hero:
-- 1) do not chase a fleeing enemy with equal/greater speed (pointless, we lose creeps);
-- 2) leash at his T1: do not enter the tower radius without a creep shield;
-- 3) the usual point correction relative to the tower.
-- Can we close to distance dAfter without entering our own "band fear" range?
function H.ApproachIntoBandOK(bot, enemyHero, dAfter)
    if State.intent == I.RETREAT then return false end
    local R = K._race
    local killing = (R and R.valid and R.canKillSoon) or State.hunting -- Hunting = finishing
    -- With a fresh stack on us, closing into the near band (< 470 = his right click + near
    -- raze with the stack bonus) is forbidden except to finish; with 2+ stacks we do not close at all.
    -- Previously only "band fear" was checked (it did not trigger without a stack when edge >= 0), so the mirror /
    -- stack finish walked a stacked bot right up to the enemy.
    if not killing then
        local st, rem = U.GetShadowrazeDebuff(bot)
        if (st or 0) >= 1 and (rem or 0) >= 1.0 then
            local nearFear = (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470
            if dAfter < nearFear then return false end
            if st >= 2 then return false end
        end
    end
    -- Single minimum distance (band fear + the "with a stack, stay out of his ready bands" rule)
    local fearMin = U.GetMinDistWithStack(bot, enemyHero)
    if fearMin <= 0 then return true end
    return dAfter >= fearMin - 20
end

function H.ApproachEnemyPoint(bot, enemyHero, loc, threshold, enemyTowers, allyCreeps, allowDive, stackAbility)
    if State.combatPolicyActive == true and enemyHero and not State.heroCombatAllowed then return false end
    if not loc then return false end
    if State.actionTaken then return false end
    if State.towerChaseBlockedEnemy == enemyHero and enemyHero then return false end
    local third = stackAbility and H.StackLeadThirdRazeOK(bot, enemyHero, stackAbility, loc, W.s)
    if enemyHero and not K.StackLeadStepSafe(bot, enemyHero, loc) and not third then return false end
    if allowDive and H.TowerBurnActive() then allowDive = false end -- No dives after leaving the T1
    if enemyHero and U.CanQuery(enemyHero) then
        local botLoc = bot:GetLocation()
        local enLoc = enemyHero:GetLocation()
        local dNow = U.DistanceBetweenLocations(botLoc, enLoc)
        local dAfter = U.DistanceBetweenLocations(loc, enLoc)
        if dAfter < dNow - 60 then
            -- Closing in: does it make sense?
            if not K.CanCatch(bot, enemyHero, dAfter, 2.0) then return false end
            -- Do not enter his READY band if our own fear triggers there too
            -- (ShouldRetreatFromEnemyRazeStack): otherwise we get an "approach - get scared - back off" loop.
            if not allowDive and not third and not H.ApproachIntoBandOK(bot, enemyHero, dAfter) then return false end
        end
        local t1 = W.s.enemyT1
        if t1 and not allowDive then
            local okLoc, tLoc = pcall(t1.GetLocation, t1)
            if okLoc and tLoc then
                local leash = (C.TOWER and C.TOWER.CHASE_LEASH) or 820
                if U.DistanceBetweenLocations(tLoc, loc) < leash and LN.TowerDanger(bot, t1, allyCreeps, loc) >= 2 then
                    return false
                end
                -- Do not chase the enemy BEHIND his T1. The leash above only checked the radius, so
                -- a point on the far side of the tower passed the check - and walking back would mean
                -- crossing its attack radius (hence the freezes under the tower).
                if LN.IsBeyondTower(bot, t1, loc) then return false end
            end
        end
    end
    loc = H.GetSafeApproachLoose(bot, loc, enemyTowers or {}, allyCreeps or {})
    if U.DistanceBetweenLocations(bot:GetLocation(), loc) <= (threshold or 35) then return false end
    return H.SmartMove(bot, loc, threshold or 35, false, stackAbility)
end

function H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    local enemy = H._enemyHeroNear
    if enemy and K.HasRazeStackLead(bot, enemy) then
        local walk = math.max(0, U.DistanceBetweenLocations(botLoc, targetLoc) - bot:GetAttackRange())
        local stop = botLoc + (targetLoc - botLoc):Normalized() * walk
        if not K.StackLeadStepSafe(bot, enemy, stop) then return false end
    end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 420 then return false end
                if GetUnitToLocationDistance(tower, botLoc) < 860 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToHarass(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            -- A right click on a hero inside the tower radius draws the tower onto us REGARDLESS of
            -- creeps (the tower aggros on hero attacks) - so we always stay outside its radius
            -- (+30 for the step toward the target). A creep shield only relaxes the requirement on the target position.
            if GetUnitToLocationDistance(tower, botLoc) < 790 then return false end
            if not H._hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 320 then return false end
            end
        end
    end
    return true
end

function H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local towerToEnemy = GetUnitToLocationDistance(tower, enemyHero:GetLocation())
            if towerToEnemy <= 850 then
                if H._hasTankCreepUnderTower(tower, allyCreeps) then
                    return true
                end
                if GetUnitToLocationDistance(bot, tower:GetLocation()) > 810 then
                    return true
                end
                return false
            end
        end
    end
    return true
end

function H.GetEnemyT1Tower(enemyTowers)
    for _, tower in pairs(enemyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                return tower
            end
        end
    end
    return nil
end

-- Bot near its own T1 (within radius of the tower)
function H.IsNearOwnT1(bot, radius)
    local s = W.s
    local t1 = s and s.allyT1
    if not t1 then return false end
    local okL, tl = pcall(t1.GetLocation, t1)
    if not okL or not tl then return false end
    return GetUnitToLocationDistance(bot, tl) <= (radius or 400)
end

function H.IsBotUnderEnemyT1(bot, enemyTowers)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 then return false, nil end
    if GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880 then
        return true, t1
    end
    return false, t1
end

function H.HasRazeResource(bot)
    return H.GetPotentialCombatMana(bot) >= 75
end

function H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.TowerBurnActive() then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if bot:GetLevel() < 5 then return false end
    if not H.HasRazeResource(bot) then return false end
    local enemyCanPunish = U.EnemyCanUseRaze(enemyHero)
    local atkActual = enemyHero:GetActualIncomingDamage(bot:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    local enemyVeryLow = enemyHero:GetHealth() <= (oneRaze + atkActual * 2.0) or enemyHero:GetHealth() <= (twoRaze + atkActual)
    if not enemyCanPunish then return true end
    if enemyVeryLow then return true end
    return false
end

function H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if not H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    U.UseGlyph(bot)
    State.actionTaken = true
    return true
end

function H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, mode)
    local safeLoc = P.GetLasthitPosition(bot, enemyCreeps or {}, allyCreeps or {}, nil, mode or "PASSIVE")
    local fountain = P.GetFountain(bot)
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if t1 and t1:IsAlive() then
        local dir = (fountain - t1:GetLocation()):Normalized()
        local extra = 150
        safeLoc = t1:GetLocation() + dir * (850 + C.T1_SAFETY.RETREAT_BUFFER + extra)
    end
    return safeLoc
end

-- Single defence against the enemy T1 (instead of the "aggro a creep + back off" trick, which every tick
-- alternated with the retreat executor and caused twitching under the tower until the shield creeps died).
-- 1) the tower targets us / hit us recently -> leave its radius immediately;
-- 2) inside the tower radius (<= 720) without a creep shield -> leave;
-- 3) inside the tower radius "for the hero" (chasing, attacking the hero, aiming a raze) for longer
-- than DIVE_MAX_TIME in a row -> leave.
-- Exception (items 1 and 3): a guaranteed finish right now (one right click within attack
-- range / one raze) - within the time budget and with HP >= 40 % and >= 3 tower shots.
-- Pushing/last hitting under a shield is not time limited (its safety is TowerDanger/IsSafeToAttack).
-- After leaving there is a burn towerBurnUntil: BURN_SEC with no dives, risky commits or T1 attacks.
function H.HandleEnemyTowerSafety(bot, s, enemyHero)
    local t1 = s.enemyT1
    if not t1 then State.t1EnterTime = nil H.ClearTowerEscape() return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then State.t1EnterTime = nil H.ClearTowerEscape() return false end
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okL or not tLoc then return false end
    local cfg = C.TOWER or {}
    local d = GetUnitToLocationDistance(bot, tLoc)
    local now = GameTime()

    -- The tower is nearly down - do not leave it, finish it (breaking the T1 wins the game)
    if LN.IsTowerFinishable(bot, t1) then
        State.t1EnterTime = nil
        H.ClearTowerEscape()
        return false
    end

    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    -- Active commitment to walk out of the tower. While we are inside the radius there are no other
    -- orders: their alternation with the escape is what caused the jitter under fire.
    if (State.towerEscapeUntil or 0) > now and State.towerEscapeLoc then
        if d > (cfg.ESCAPE_RADIUS or 900) then
            H.ClearTowerEscape()
        else
            -- Same order, same point: SmartMove does not re-issue it every tick
            H.SmartMove(bot, State.towerEscapeLoc, 60)
            State.actionTaken = true
            return true
        end
    elseif (State.towerEscapeUntil or 0) > 0 then
        H.ClearTowerEscape()
    end

    local inRange = d <= ((cfg.ATTACK_RANGE or 700) + 20)
    if not inRange then State.t1EnterTime = nil end
    if d > (cfg.ESCAPE_RADIUS or 900) then return false end
    if State.actionTaken then return false end
    local onMe = false
    if t1.GetAttackTarget and (not t1.CanBeSeen or t1:CanBeSeen()) then
        local okT, tgt = pcall(t1.GetAttackTarget, t1)
        if okT and tgt == bot then onMe = true end
    end
    if not onMe and bot.WasRecentlyDamagedByTower and bot:WasRecentlyDamagedByTower(1.0) then onMe = true end
    local reason = nil
    if onMe then
        reason = "tower on me"
    elseif inRange then
        if not State.t1EnterTime then State.t1EnterTime = now end
        local shield = LN.TowerShieldCount(t1, s.allyCreeps, bot:GetLocation())
        if shield == 0 then
            reason = "no shield"
        else
            local cur = bot:GetAttackTarget()
            local heroEngaged = State.aimingRaze and true or false
            if not heroEngaged and cur ~= t1 and (now - (State.heroAttackTime or -10)) <= 1.5 then heroEngaged = true end
            if not heroEngaged and cur and U.CanQuery(cur) and cur.IsHero and cur:IsHero() then heroEngaged = true end
            if heroEngaged and (now - State.t1EnterTime) > (cfg.DIVE_MAX_TIME or 1.0) then
                reason = "dive budget"
            end
        end
    end
    -- The enemy hero is hitting us under his tower (raze/clicks) and we are not finishing him -
    -- leave immediately instead of wandering between points inside the tower radius
    if not reason and inRange and enemyHero and U.CanQuery(enemyHero) and bot.WasRecentlyDamagedByHero then
        if bot:WasRecentlyDamagedByHero(enemyHero, 1.5) then
            local killing = U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero)
            local committed = GameTime() < (State.commitKillUntil or 0)
            if not killing and not committed then
                reason = "hero hits me under T1"
            end
        end
    end
    if not reason then return false end
    -- Exception: a guaranteed finish right now, within the budget and with an HP margin.
    -- When the tower is ALREADY hitting us we stay only for a single right click that
    -- finishes it. A raze with a turn under its shots was exactly that jitter in place.
    if reason ~= "no shield" and enemyHero and U.CanQuery(enemyHero) then
        local hp = bot:GetHealth()
        local maxHp = math.max(1, bot:GetMaxHealth())
        local okD, tDmg = pcall(t1.GetAttackDamage, t1)
        if not okD or type(tDmg) ~= "number" or tDmg <= 0 then tDmg = 100 end
        local hpOk = hp >= maxHp * 0.40 and hp >= tDmg * 3
        local within = (now - (State.t1EnterTime or now)) <= (cfg.DIVE_MAX_TIME or 1.0)
        if hpOk and within then
            local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if U.CanOneShotEnemyHero(bot, enemyHero) and dist <= bot:GetAttackRange() + 60 then
                return false
            end
            if not onMe and U.CanQuickTurnKillWithRaze(bot, enemyHero) then
                return false
            end
        end
    end
    -- Leaving the tower again shortly after -> a longer burn (no walking back and forth)
    local burn = cfg.BURN_SEC or 2.5
    if (now - (State.lastTowerEscapeAt or -100)) < (cfg.REPEAT_WINDOW or 10) then burn = cfg.BURN_REPEAT_SEC or 6.0 end
    State.lastTowerEscapeAt = now
    State.towerBurnUntil = now + burn
    State.t1EnterTime = nil
    -- The escape is a hard commitment: the point is fixed and we walk to it until we are outside the radius
    local escape = LN.TowerEscapePoint(bot, t1)
    State.towerEscapeLoc = escape
    State.towerEscapeUntil = now + (cfg.ESCAPE_COMMIT_SEC or 3.0)
    H.BeginForcedRetreat(bot, escape, 0.9)
    if U.DEBUG then print(string.format("[SF-BOT] tower escape (%s) d=%.0f", reason, d)) end
    return true
end

-- The tower burn is active (we had to leave the T1 recently)
function H.TowerBurnActive()
    return GameTime() < (State.towerBurnUntil or 0)
end

-- A few of my hits are left on the enemy T1 - hit it no matter what:
-- in 1v1 breaking the T1 is a win. The HP threshold is held by LN.IsTowerFinishable (HP >= the number
-- of hits needed converted into its shots); a lethal hero finish still outranks the tower.
function H.HandleEnemyTowerFinish(bot, s, enemyHero)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local t1 = s.enemyT1
    if not t1 or not LN.IsTowerFinishable(bot, t1) then return false end
    local okL, tLoc = pcall(t1.GetLocation, t1)
    if not okL or not tLoc then return false end
    if GetUnitToLocationDistance(bot, tLoc) > ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        if U.CanOneShotEnemyHero(bot, enemyHero) or U.CanQuickTurnKillWithRaze(bot, enemyHero) then
            return false
        end
    end
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= t1 then
        bot:Action_AttackUnit(t1, true)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

function H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps)
    if not ability or not enemyHero or not U.CanQuery(enemyHero) then return false end
    local t1 = H.GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    if H._hasTankCreepUnderTower(t1, allyCreeps) then return false end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local enemyNearTower = GetUnitToLocationDistance(t1, enemyHero:GetLocation()) <= 900
    if not enemyNearTower then return false end
    local botUnderT1 = GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880
    local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, data.center)
    local setupUnderT1 = setupPos and U.DistanceBetweenLocations(setupPos, t1:GetLocation()) < 900
    if botUnderT1 or setupUnderT1 then
        return true
    end
    return false
end

function H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana()<75 or not U.IsRazeAbilityCastable(bot,H.GetRazeAbilityByLabel(bot,"mid")) then return false end
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or hitLabel ~= "mid" then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local minHold = C.RAZE.NEAR_CENTER + 110
    local maxHold = C.RAZE.FAR_CENTER - 110
    local desired = C.RAZE.MID_CENTER
    if dist >= minHold and dist <= maxHold then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    return H.SmartMove(bot, holdLoc, 35)
end

function H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil, nil, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return false, nil, nil, nil end
    local nearRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local atkRaw = bot:GetAttackDamage() or 0
    local atkActual = enemyHero:GetActualIncomingDamage(atkRaw, DAMAGE_TYPE_PHYSICAL)
    if atkActual <= 0 then return false, nil, nil, nil end
    local hpAfterRaze = enemyHero:GetHealth() - nearRazeDmg
    if hpAfterRaze <= 0 then return false, nearRazeDmg, atkActual, 0 end
    local attacksNeeded = math.ceil(hpAfterRaze / atkActual)
    if attacksNeeded >= 1 and attacksNeeded <= 2 then
        return true, nearRazeDmg, atkActual, attacksNeeded
    end
    return false, nearRazeDmg, atkActual, attacksNeeded
end

function H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not H.HasRazeResource(bot) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        return false
    end
    local canFinish, _, _, attacksNeeded = H.GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not canFinish then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not canOneShot then return false end
    if not H.IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps) and not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        H.IssueHeroAttack(bot, enemyHero)
        return true
    end
    if dist <= attackRange + 260 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 220)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.GetPotentialCombatMana(bot) < 150 then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    if not q or q:GetLevel() == 0 then return false end

    local stacks = U.GetShadowrazeDebuff(enemyHero)
    if stacks ~= 0 then return false end

    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    if twoRaze < enemyHero:GetHealth() then return false end
    if oneRaze >= enemyHero:GetHealth() then return false end

    local candidates = {
        { label = "mid",  ability = w, center = C.RAZE.MID_CENTER  },
        { label = "far",  ability = e, center = C.RAZE.FAR_CENTER  },
        { label = "near", ability = q, center = C.RAZE.NEAR_CENTER },
    }

    for _, c in ipairs(candidates) do
        if c.ability and U.IsRazeAbilityCastable(bot, c.ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, c.ability, enemyTowers, allyCreeps) then
            local actionType, aimLoc = H.GetRazeActionType(bot, c.ability, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, c.ability, actionType, aimLoc, enemyHero) then
                return true
            end
        end
    end

    local opener = nil
    if w and U.IsRazeAbilityCastable(bot, w) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, w, enemyTowers, allyCreeps) then
        opener = { ability = w, center = C.RAZE.MID_CENTER, label = "mid" }
    elseif e and U.IsRazeAbilityCastable(bot, e) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, e, enemyTowers, allyCreeps) then
        opener = { ability = e, center = C.RAZE.FAR_CENTER, label = "far" }
    elseif q and U.IsRazeAbilityCastable(bot, q) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        opener = { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" }
    end

    if opener then
        local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, opener.center)
        if setupPos then
            local currentDist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if math.abs(currentDist - opener.center) > 90 then
                if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps) then
                    return true
                end
            end
        end
    end

    return false
end

function H.TryRazeEnemy(bot, enemyHero, current_mode, enemyTowers, allyCreeps, isLethalChase, forceExtend)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end

    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, current_mode, isLethalChase or false, forceExtend or false)
    if ability then
        local data = U.GetRazeAbilityData(ability)
        local predDist = GetUnitToLocationDistance(bot, aimLoc or enemyHero:GetLocation())
        local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
        if data and data.label == "near" and predDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and data.label == "near" and underT1 and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and (data.label == "mid" or data.label == "far") and H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
            ability, actionType, aimLoc = nil, nil, nil
        end
    end

    if H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then return true end

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local followUp = stacks > 0 and rem_time >= (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2)
    if (forceExtend or (stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6) or isLethalChase or followUp) and bot:GetMana() >= 75 then
        local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
        -- Do not close in for a finishing raze into the NEAR band (200 from him) - that is his
        -- right-click range and his near raze; finish from mid/far or do not finish at all
        if setupPos and followUp and not isLethalChase and not forceExtend then
            local pred = U.PredictPosition(enemyHero, 0.35) or enemyHero:GetLocation()
            if U.DistanceBetweenLocations(setupPos, pred) <= C.RAZE.NEAR_CENTER + 10 then setupPos = nil end
        end
        if setupPos then
            -- Approaching his T1 for a raze is allowed while the tower is busy with a creep (a raze gives no aggro)
            -- and his burst cannot kill us; not below 50% HP.
            local allowDive = isLethalChase
            if not allowDive and (followUp or forceExtend) then
                local R = K._race
                local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
                if hpPct >= 0.5 and not (R and R.valid and R.heCanKillSoon) and H.TowerLockedOnCreep(W.s.enemyT1) then
                    allowDive = true
                end
            end
            -- If the safe boundary (tower) cuts off most of the approach, the raze position is
            -- unreachable: do not stamp at the boundary, give the tick to siege/last hits (not for finishing).
            local reachable = true
            if not isLethalChase then
                local clamped = H.GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
                if clamped and U.DistanceBetweenLocations(clamped, setupPos) > 200 then reachable = false end
            end
            if reachable and H.ApproachEnemyPoint(bot, enemyHero, setupPos, 35, enemyTowers, allyCreeps, allowDive) then
                return true
            end
        end
    end

    return false
end

function H.StackLeadThirdRazeOK(bot, enemy, ability, point, snapshot)
    if not ability or not K.HasRazeStackLead(bot, enemy) then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) then return false end
    local stacks, remain = U.GetShadowrazeDebuff(enemy)
    if stacks ~= 2 or not U.IsRazeAbilityCastable(bot, ability) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data or data.label == "near" then return false end
    local race = K._race
    if not race or not race.valid or race.heCanKillSoon then return false end
    local horizon = U.DistanceBetweenLocations(bot:GetLocation(), point) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > 1.25 or remain <= horizon + 0.1 then return false end
    local predicted = U.PredictPosition(enemy, horizon)
    local d = U.DistanceBetweenLocations(point, enemy:GetLocation())
    local dp = U.DistanceBetweenLocations(point, predicted)
    if math.max(math.abs(d-data.center), math.abs(dp-data.center)) > C.RAZE.HIT_RADIUS - 40 then return false end
    local before = GetUnitToLocationDistance(bot, enemy:GetLocation())
    local beforePred = GetUnitToLocationDistance(bot, predicted)
    local replies = K.EnemyBandsAcross(enemy, math.min(d, dp, before, beforePred), math.max(d, dp, before, beforePred), horizon)
    if replies > 1 then return false end -- Do not turn 2:1 into a possible 3:3.
    local snap = snapshot or {}
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 900
            or U.DistanceBetweenLocations(point, tower:GetLocation()) < 900) then return false end
    end
    local incoming = K.EnemyRazeDamage(bot, enemy, replies)
    if math.min(d, dp) <= enemy:GetAttackRange() + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot) * math.ceil(horizon / math.max(0.6, enemy:GetSecondsPerAttack()))
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot) * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack()))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return false end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    return bot:GetHealth() - incoming >= math.max(110, K.AttackDamageVs(enemy, bot))
end

function H.HandleStackLead(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not K.HasRazeStackLead(bot, enemy) or State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    for _, label in ipairs({"far", "mid"}) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if H.StackLeadThirdRazeOK(bot, enemy, ab, bot:GetLocation(), snapshot) then
            local action, aim = H.GetRazeActionType(bot, ab, enemy)
            if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
        end
        if ab and U.IsRazeAbilityCastable(bot, ab) and distance > K.Center(label) + 150 then
            local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * (K.Center(label)+150)
            if H.StackLeadThirdRazeOK(bot, enemy, ab, point, snapshot)
                and H.ApproachEnemyPoint(bot, enemy, point, 25, snapshot.enemyTowers, snapshot.allyCreeps, false, ab) then return true end
        end
    end
    if K.EnemyBandsAcross(enemy, distance, distance, 0.7) > 0 then
        local _, outer = K.EnemyBandsAcross(enemy, 0, 2000, 1.0)
        local safe = math.max(distance + 120, outer + 60)
        local point = enemy:GetLocation() + (bot:GetLocation()-enemy:GetLocation()):Normalized() * safe
        point = H.GetSafeApproach(bot, point, snapshot.enemyTowers, snapshot.allyCreeps)
        H.ClearRazeState()
        return H.BeginForcedRetreat(bot, point, 0.45)
    end
    return false
end

-- A confirmed first hit may be followed by ONE other ranged raze, even at
-- equal resources. This is not permission to initiate against an equal opponent.
function H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    local chain = State.razeFollowup
    if not chain or chain.enemy ~= enemy or not U.CanQuery(enemy) then return nil end
    local now = GameTime()
    if now > chain.untilTime or now < chain.opened + C.RAZE.CAST_POINT then return nil end
    if not race or not race.valid or race.heCanKillSoon then return nil end
    local stacks, remaining = U.GetShadowrazeDebuff(enemy)
    if stacks <= chain.stacks then return nil end -- No blind chase after a miss.
    local ab = H.GetRazeAbilityByLabel(bot, chain.label)
    if not U.IsRazeAbilityCastable(bot, ab) then return nil end
    local center = U.GetRazeCenterByLabel(chain.label)
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist < 350 or dist > 1000 then return nil end
    local reach = center + C.RAZE.STRICT_RADIUS - 30
    local horizon = math.max(0, dist - reach) / math.max(1, bot:GetCurrentMovementSpeed())
        + C.RAZE.CAST_POINT + (C.RAZE.LAND_LEAD or 0.08) + 0.1
    if horizon > chain.untilTime - now or remaining <= horizon + 0.1
        or not K.CanCatch(bot, enemy, reach, horizon) then return nil end
    local snap = snapshot or W.s or {}
    local goal = enemy:GetLocation() + (bot:GetLocation() - enemy:GetLocation()):Normalized() * center
    for _, tower in pairs(snap.enemyTowers or {}) do
        if tower and tower:IsAlive() and (GetUnitToLocationDistance(bot, tower:GetLocation()) < 800
            or U.DistanceBetweenLocations(goal, tower:GetLocation()) < 800) then return nil end
    end
    local incoming, count = K.EnemyBurstVs(bot, enemy, math.min(dist, center), horizon, false)
    local enemyRange = (enemy:GetAttackRange() or 525) + 80
    if math.min(dist, center) > enemyRange
        and math.min(dist, center) <= enemyRange + enemy:GetCurrentMovementSpeed() * horizon then
        incoming = incoming + K.AttackDamageVs(enemy, bot)
    end
    local regen = math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0)
    local extra = math.floor((K.EnemyManaBudget(enemy, true) + regen * horizon) / 75)
        - math.floor(K.EnemyManaBudget(enemy, true) / 75)
    if extra > 0 then
        incoming = incoming + K.EnemyRazeDamage(bot, enemy, math.min(3, count + extra))
            - K.EnemyRazeDamage(bot, enemy, count)
    end
    for _, creep in pairs(snap.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then
            incoming = incoming + K.AttackDamageVs(creep, bot)
                * math.ceil(horizon / math.max(0.6, creep:GetSecondsPerAttack()))
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if not projectile.is_attack or not U.CanQuery(projectile.caster) then return nil end
            incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
        end
    end
    if bot:GetHealth() - incoming < math.max(110, K.AttackDamageVs(enemy, bot)) then return nil end
    if incoming > K.MyRazeDamage(bot, enemy, 1) + math.max(80, bot:GetHealth() - enemy:GetHealth()) then return nil end
    return ab, center
end

function H.HandlePendingRazeFollowup(bot, enemy, race, snapshot)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local ab, center = H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
    if not ab then return false end
    local action, aim = H.GetRazeActionType(bot, ab, enemy)
    if action and H.CastOrTurnRaze(bot, ab, action, aim, enemy) then return true end
    local predicted = U.PredictPosition(enemy, 0.3)
    local desired = center == C.RAZE.MID_CENTER and center + 150 or center
    local setup = predicted + (bot:GetLocation() - predicted):Normalized() * desired
    if not setup then return false end
    for _, tower in pairs(snapshot.enemyTowers or {}) do
        if tower and tower:IsAlive() and U.DistanceBetweenLocations(setup, tower:GetLocation()) < 800 then return false end
    end
    return H.ApproachEnemyPoint(bot, enemy, setup, 25, snapshot.enemyTowers or {}, snapshot.allyCreeps or {})
end

function H.EnemyStackNeedsImmediateExtension(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.6 then return false end
    -- Do not run to extend a stack on an enemy we cannot reach before it expires (previously
    -- a pointless jog after an enemy that left): the far raze must be reachable in the remaining stack time.
    if not K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS - 60, math.max(0.3, rem_time - C.RAZE.CAST_POINT)) then
        return false
    end
    -- Mana/defence discipline: extending a stack also costs 75 mana. Allowed when
    -- (a) it is a finish, or (b) normal mana-based harass is allowed and we are not defending, or
    -- (c) the stack is already >= 2 (two razes invested), the race is not against us and >= 75 mana remains.
    local R = K._race
    local killing = R and R.valid and R.canKillSoon
    if killing then return true end
    -- A clear advantage in the trade (edge >= 100, he cannot kill us right away) - extend the stack
    -- even if we are formally "defending"/reserving mana: our raze advantage has to pay off
    if R and R.valid and R.edge >= 100 and not R.heCanKillNow and (bot:GetMana() - 75) >= 75 then return true end
    if State.defensive and not H.HasTradeSupport(R) then return false end
    if H.HarassManaOK(bot, R) then return true end
    if stacks >= 2 and R and R.valid and R.edge >= 0 and (bot:GetMana() - 75) >= 75 then return true end
    return false
end

function H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not H.EnemyStackNeedsImmediateExtension(bot, enemyHero) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return true end
    if State.actionTaken then return false end

    State.prepTarget = nil
    State.attackTarget = nil
    State.attackStartTime = 0
    State.firedThisAttack = false
    State.aggroPullTime = 0
    State.deaggroTime = 0

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local isLethal = U.GetTwoRazeDamage(bot, enemyHero) >= enemyHero:GetHealth() * 0.90
    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, "AGGRESSIVE", isLethal, true)
    if ability and actionType then
        local data = U.GetRazeAbilityData(ability)
        if data and data.label == "near" and actionType == "TURN" then
            local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                ability = nil
                actionType = nil
            end
        end
        if ability and actionType and H.CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then
            return true
        end
    end

    local shouldCloseIn, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if shouldCloseIn and closePos then
        if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
            return true
        end
    end

    local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
    if setupPos then
        if H.ApproachEnemyPoint(bot, enemyHero, setupPos, 45, enemyTowers, allyCreeps) then
            return true
        end
    end

    local desiredCenter = C.RAZE.MID_CENTER
    local enemyLoc = enemyHero:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = nil
    if dist > desiredCenter + 60 then
        local dir = (enemyLoc - botLoc):Normalized()
        desired = botLoc + dir * math.min(dist - desiredCenter, 380)
    elseif dist < desiredCenter - 100 then
        local dir = (botLoc - enemyLoc):Normalized()
        desired = enemyLoc + dir * desiredCenter
    else
        return false
    end
    if H.ApproachEnemyPoint(bot, enemyHero, desired, 45, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.LevelUpAbilities(bot)
    local order = (C.SKILL and C.SKILL.ORDER) or {}
    local lvl = bot:GetLevel()
    -- Count how many times each ability should be learned by the current level
    -- and learn what is missing (self-healing if a level was skipped).
    -- A level entry is an ability name OR a list: talents cost no points, so at
    -- 10/15/20/25 the talent is taken together with the next point (into "+2 all attributes").
    local want = {}
    for i = 1, lvl do
        local entry = order[i]
        if type(entry) == "table" then
            for _, name in ipairs(entry) do want[name] = (want[name] or 0) + 1 end
        elseif type(entry) == "string" then
            want[entry] = (want[entry] or 0) + 1
        end
    end
    for name, cnt in pairs(want) do
        if not (C.SKILL and C.SKILL.ALLOW_FRENZY == false and name == "nevermore_frenzy") then
            -- A talent is learned without points: do not bail out early on GetAbilityPoints() == 0,
            -- otherwise the point taken first went into attributes and the talent stayed unlearned
            local isTalent = string.find(name, "special_bonus", 1, true) ~= nil
            if isTalent or bot:GetAbilityPoints() > 0 then
                local okA, ab = pcall(bot.GetAbilityByName, bot, name)
                if okA and ab and ab.GetLevel and ab:GetLevel() < cnt then
                    if not ab.CanAbilityBeUpgraded or ab:CanAbilityBeUpgraded() then
                        bot:ActionImmediate_LevelAbility(name)
                        return
                    end
                end
            end
        end
    end
end

function H.IsInDangerForRegen(bot, heroDist)
    heroDist = heroDist or 850
    local heroes = bot:GetNearbyHeroes(heroDist, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return true end
    local creeps = bot:GetNearbyLaneCreeps(600, true)
    if creeps and #creeps > 0 then return true end
    local projs = bot:GetIncomingTrackingProjectiles()
    if projs and #projs > 0 then return true end
    return false
end

function H.HasEnemyProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = true
            if caster.GetTeam then
                isEnemy = caster:GetTeam() ~= bot:GetTeam()
            end
            if isEnemy then
                return true, p
            end
        end
    end
    return false, nil
end

function H.GetSalveSafeRetreatLocation(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local botLoc = bot:GetLocation()
    local safeDistance = (C.REGEN and C.REGEN.FLASK_SAFE_DISTANCE) or (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 200) or 1150
    if enemyHero and U.CanQuery(enemyHero) then
        local enemyLoc = enemyHero:GetLocation()
        local dir = fountain - enemyLoc
        if U.DistanceBetweenLocations(fountain, enemyLoc) < 1 then
            dir = fountain - botLoc
        end
        dir = dir:Normalized()
        return enemyLoc + dir * safeDistance
    end
    local dir = fountain - botLoc
    if U.DistanceBetweenLocations(fountain, botLoc) < 1 then
        return fountain
    end
    dir = dir:Normalized()
    return botLoc + dir * 450
end

function H.HandleActiveSalveSafety(bot, enemyHero)
    if not bot:HasModifier("modifier_flask_healing") then
        return false
    end
    local safeDistance = (C.REGEN and C.REGEN.FLASK_SAFE_DISTANCE) or (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 200) or 1150
    local incomingProjectile = H.HasEnemyProjectileIncoming(bot)
    local tooCloseToEnemy = false
    if enemyHero and U.CanQuery(enemyHero) then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dist < safeDistance then
            tooCloseToEnemy = true
        end
    end
    if incomingProjectile or tooCloseToEnemy then
        local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return true
    end
    State.actionTaken = true
    return true
end

-- Safety condition: he has no time to turn around, catch up and land a second stack on us.
-- Finishing a creep right after the enemy hero's projectile. His projectile is in flight,
-- and after it lands the creep falls into my finish threshold -> hit now so my attack lands
-- right after his (the window between his hit and the creep dying).
function H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local now = GameTime()
    if now < (State.snipeCooldown or 0) then return false end
    if State.prepTarget then return false end
    local myPoint = bot:GetAttackPoint() or 0.5
    for _, c in pairs(enemyCreeps or {}) do
        if c and U.CanQuery(c) and c:IsAlive() then
            local okP, projs = pcall(function() return c:GetIncomingTrackingProjectiles() end)
            if okP and type(projs) == "table" then
                for _, pr in pairs(projs) do
                    if pr.is_attack and pr.caster == enemyHero then
                        local speed = 1200
                        local okS, sp = pcall(function() return enemyHero:GetAttackProjectileSpeed() end)
                        if okS and type(sp) == "number" and sp > 0 then speed = sp end
                        local eta = 0.3
                        if pr.location then
                            eta = U.DistanceBetweenLocations(pr.location, c:GetLocation()) / speed
                        end
                        if eta <= 0.7 then
                            local myDmg = U.SFDamageRange(bot, c).min
                            local ctx = U.GetTargetPredictionContext(c, { enemyHero })
                            local hpAfter = U.PredictHPWithContext(ctx, c, eta + 0.05, "avg")
                            -- his hit does not kill the creep but makes it mine
                            if hpAfter > 0 and hpAfter <= myDmg * 0.97 then
                                local travel = 0.2
                                local okPS, psp = pcall(function() return bot:GetAttackProjectileSpeed() end)
                                if okPS and type(psp) == "number" and psp > 0 then
                                    travel = U.DistanceBetweenLocations(bot:GetLocation(), c:GetLocation()) / psp
                                end
                                local impact = myPoint + travel + 0.03
                                -- my attack lands AFTER his projectile and inside the window before the creep dies
                                if impact >= eta - 0.06 and impact <= eta + 1.1 then
                                    if H.IsSafeToAttack(bot, c:GetLocation(), enemyTowers, allyCreeps) then
                                        State.prepTarget = c
                                        State.prepTargetTime = now
                                        State.snipeCooldown = now + 0.3
                                        if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK
                                            or bot:GetAttackTarget() ~= c then
                                            bot:Action_AttackUnit(c, true)
                                            H.ClearMoveCache()
                                        end
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- At the end of an already-started dry duel, take the remaining swings instead of wasting them walking.
function H.HandleDryLastStand(bot,enemy,s)
    if State.actionTaken or bot:GetHealth()>bot:GetMaxHealth()*0.40 or not U.CanQuery(enemy) or enemy:GetAttackTarget()~=bot or bot:IsUsingAbility() or bot:IsChanneling()
        or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) or State.towerEscapeLoc then return false end
    local now=GameTime()
    local involved=bot:GetAttackTarget()==enemy
        or (State.heroAttackTarget==enemy and now-(State.heroAttackTime or -100)<2)
        or (State.heroCombatEnemy==enemy and now<(State.heroCombatUntil or 0))
    if not involved or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if K.MyManaBudget(bot,true)+math.max(0,(bot.GetManaRegen and bot:GetManaRegen()) or 0)*0.8>=75
        or K.EnemyManaBudget(enemy,true)+math.max(0,(enemy.GetManaRegen and enemy:GetManaRegen()) or 0)*0.8>=75 then return false end
    local damage=bot:GetActualIncomingDamage(enemy:GetAttackDamage()+math.max(3,(enemy.GetBaseDamageVariance and enemy:GetBaseDamageVariance()) or 0),DAMAGE_TYPE_PHYSICAL)
    local committed=State.lastStandEnemy==enemy and now<(State.lastStandUntil or 0)
    if damage<=0 or (not committed and (bot:GetHealth()>damage*2
        or enemy:GetHealth()>math.max(enemy:GetMaxHealth()*0.40,K.AttackDamageVs(bot,enemy)*3))) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    -- Explicit last-stand exception: only this dry, in-range case may cancel a prior hero retreat.
    H.ClearForcedRetreat();State.survivalLoc=nil;State.survivalUntil=0;State.fleeUntil=0
    State.dodgeLoc=nil;State.dodgeUntil=0;State.goingToFountain=false;State.fountainReason=nil
    State.towerChaseBlockedEnemy=nil;State.heroCombatAllowed=true
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastStandEnemy=enemy;State.lastStandUntil=now+1.0
    State.actionTaken=true;State.lastCombatStage="dry-last-stand"
    return true
end

-- After an exchange, a hero already in attack range gets an actionable answer, not a spacing tour.
function H.HandleContactTrade(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or enemy:GetAttackTarget()~=bot then return false end
    local ours,ourTime=U.GetShadowrazeDebuff(bot)
    local theirs,theirTime=U.GetShadowrazeDebuff(enemy)
    if ours<2 or theirs<2 or ourTime<=0.2 or theirTime<=0.2 then return false end
    local distance=GetUnitToLocationDistance(bot,enemy:GetLocation())
    if distance>bot:GetAttackRange() then return false end
    if H.HandleGuaranteedRazeKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {})
        or H.HandleGuaranteedAttackKill(bot,enemy,s.enemyTowers or {},s.allyCreeps or {}) then
        State.actionTaken=true;State.lastCombatStage="contact-trade-finish"
        return true
    end
    local horizon=(bot:GetAttackPoint() or 0.5)+distance/math.max(1,bot:GetAttackProjectileSpeed())+0.15
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(40,K.AttackDamageVs(enemy,bot)*0.5) then
        local point=U.GetSafeDistancePosition(bot,enemy)
            or U.GetRetreatWaypoint(bot,(bot:GetLocation()-enemy:GetLocation()):Normalized())
        State.lastCombatStage="contact-trade-retreat"
        return H.BeginForcedRetreat(bot,point,2.0)
    end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast=State.aimingRaze==ab
                State.actionTaken=true;State.lastCombatStage="contact-trade-raze"
                return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.heroCombatEnemy=enemy;State.heroCombatUntil=GameTime()+1.25
    State.actionTaken=true;State.lastCombatStage="contact-trade-attack"
    return true
end

-- A survival retreat is separate from tactical spacing. No turn, mirror or chase
-- may steal its order, even when an enemy raze happens to be on cooldown.
-- Low HP alone must not cancel a winning, already-started dry right-click duel.
-- This is not permission to turn back during a retreat or to chase a fleeing hero.
function H.HandleWinningDryDuel(bot, enemy, snapshot)
    local now = GameTime()
    if not enemy or not U.CanQuery(enemy) then return false end
    if State.forcedRetreatLoc or State.survivalLoc
        or now < (State.fleeUntil or 0) or State.goingToFountain then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() or (bot.IsDisarmed and bot:IsDisarmed()) then return false end
    if bot:GetHealth() / math.max(1, bot:GetMaxHealth()) > 0.45 then return false end
    local continuing = bot:GetAttackTarget() == enemy
        or (State.heroAttackTarget == enemy and now - (State.heroAttackTime or -100) < 0.35)
    if not continuing or enemy:GetAttackTarget() ~= bot then return false end
    local dist = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if dist > bot:GetAttackRange() or U.GetAngleDifference(bot, enemy:GetLocation()) > 25 then return false end
    -- Avoid projecting a clean duel while tower/creep damage is also incoming.
    for _, tower in pairs((snapshot and snapshot.enemyTowers) or {}) do
        if tower and tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < 900 then return false end
    end
    for _, creep in pairs((snapshot and snapshot.enemyCreeps) or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    local hp = bot:GetHealth()
    local enDamage = bot:GetActualIncomingDamage((enemy:GetAttackDamage() or 0)
        + math.max(3, enemy:GetBaseDamageVariance() or 0), DAMAGE_TYPE_PHYSICAL)
    local myDamage = U.SFDamageRange(bot, enemy).min
    if myDamage <= 0 or enDamage <= 0 then return false end
    -- Compare impact events, not "enemy hits NOW" versus our entire fresh windup.
    local function impacts(attacker, target, damage, own)
        local events = {}
        local period = math.max(0.1, attacker:GetSecondsPerAttack() or 1.7)
        local speed = math.max(1,attacker:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED)
        for _, projectile in pairs((target.GetIncomingTrackingProjectiles and target:GetIncomingTrackingProjectiles()) or {}) do
            if not projectile.is_attack or projectile.caster ~= attacker then return nil end
            if projectile.location then
                events[#events+1] = {time=U.DistanceBetweenLocations(projectile.location,target:GetLocation())/speed, damage=damage}
            elseif not own then
                events[#events+1] = {time=0,damage=damage}
            end
        end
        local last = attacker:GetLastAttackTime() or -100
        local travel = dist/speed
        local first
        if last > 0 and now-last <= period+0.1 then
            first = math.max(0,last+period-now) + travel
        else
            first = own and ((attacker:GetAttackPoint() or 0.5)+travel) or 0
        end
        first = math.max(0,first+(own and 0.04 or -0.08))
        for i=0,5 do events[#events+1]={time=first+i*period,damage=damage} end
        table.sort(events,function(x,y) return x.time<y.time end)
        return events
    end
    local outgoing = impacts(bot,enemy,myDamage,true)
    local incoming = impacts(enemy,bot,enDamage,false)
    if not outgoing or not incoming then return false end
    local function lethalAt(events,health)
        for _,e in ipairs(events) do
            health=health-e.damage
            if health<=0 then return e.time end
        end
        return math.huge
    end
    local enemyHp = enemy:GetHealth()+U.GetStickCharges(enemy)*15
        + math.max(0,enemy:GetHealthRegen() or 0)*4
    if U.HasItem(enemy,"item_faerie_fire") then enemyHp=enemyHp+85 end
    local killAt = lethalAt(outgoing,enemyHp)
    local dieAt = lethalAt(incoming,hp)
    if killAt>4 or killAt+0.06>=dieAt then return false end
    -- Include mango/wand charges and mana regenerated before our killing hit.
    if K.MyManaBudget(bot, true) + math.max(0, bot:GetManaRegen() or 0) * killAt >= 75
        or K.EnemyManaBudget(enemy, true) + math.max(0, enemy:GetManaRegen() or 0) * killAt >= 75 then return false end
    if not H.IssueHeroAttack(bot, enemy) then return false end
    State.lastCombatStage = "timed-dry-finish"
    State.actionTaken = true
    return true
end

function H.CanTakeShortCombatAction(bot,enemy,s)
    if not U.CanQuery(enemy) or State.actionTaken or State.goingToFountain
        or State.forcedRetreatLoc or State.survivalLoc or GameTime()<(State.fleeUntil or 0)
        or bot:IsUsingAbility() or bot:IsChanneling() or bot:IsStunned() then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    if State.towerChaseBlockedEnemy==enemy then
        if H.TowerChaseBlocked(bot,s) then return false end
        State.towerChaseBlockedEnemy=nil
    end
    return true
end

-- Keep a safe answer through its cast point, while still validating aim and new threats.
function H.HandleShortCombatCast(bot,enemy,s)
    if not State.shortCombatCast or not State.aimingRaze or State.aimingTarget~=enemy
        or not U.CanQuery(enemy) or not bot:IsUsingAbility() or State.forcedRetreatLoc
        or State.survivalLoc or State.goingToFountain or GameTime()<(State.fleeUntil or 0) then return false end
    for _,tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot,tower:GetLocation())<900 then return false end
    end
    local remaining=math.max(0,C.RAZE.CAST_POINT-(GameTime()-State.aimingStartTime))
    if bot:GetHealth()-K.ShortReplyIncoming(bot,enemy,remaining+0.15,s)<math.max(60,K.AttackDamageVs(enemy,bot)) then return false end
    if H.HandleActiveRazeValidation(bot) then
        State.lastCombatStage="short-cast-validation"
        State.actionTaken=true
        return true
    end
    return false
end

-- A short stationary answer is not the same decision as tanking a 2.5-second combo.
function H.HandleSafeRazeReply(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local age=U.GetRecentEnemyRazeHitAge(enemy)
    local castAge=GameTime()-((K._enemy and K._enemy.lastAnyCastAt) or -100)
    local phase=K.EnemyPhase()
    local phaseThreat=phase and GetUnitToLocationDistance(bot,K.EnemyRazeCenter(enemy,phase))<=C.RAZE.HIT_RADIUS+20
    if not phaseThreat and age>0.8 and (castAge>1.0 or not H.IsEnemyPressuring(bot,enemy)) then return false end
    if K.HasRazeStackLead(bot,enemy) then return false end -- The bounded third-spell rule owns this case.
    local hitTime=GameTime()-age
    if not phaseThreat and age<=0.8 and State.mirrorAnsweredEnemy==enemy and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit-hitTime)<0.001 then return false end
    if GetUnitToLocationDistance(bot,enemy:GetLocation())<=bot:GetAttackRange()
        and U.SFDamageRange(bot,enemy).min>=enemy:GetHealth() then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,C.RAZE.CAST_POINT+0.3,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    for _,label in ipairs({(phaseThreat and phase) or U.GetRecentEnemyRazeHitLabel(enemy) or "far","far","mid","near"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.dodgeLoc=nil; State.dodgeUntil=0
                if State.shortCombatCast and label=="mid" and State.razeFollowup then State.razeFollowup.reply=true end
                State.lastCombatStage="safe-short-reply"
                State.actionTaken=true
                return true
            end
        end
    end
    return false
end

-- A confirmed middle reply owns one short far follow-up before generic stack spacing.
function H.HandleReplyFarFollowup(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) or bot:GetMana()<75 then return false end
    local chain=State.razeFollowup
    if not chain or not chain.reply or chain.enemy~=enemy or chain.label~="far"
        or GameTime()>chain.untilTime or GameTime()<chain.opened+C.RAZE.CAST_POINT then return false end
    local stacks,remaining=U.GetShadowrazeDebuff(enemy)
    if stacks<=chain.stacks or K.HasRazeStackLead(bot,enemy) then return false end
    local ab=H.GetRazeAbilityByLabel(bot,"far")
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemy)
    local point=bot:GetLocation()
    local dist=GetUnitToLocationDistance(bot,enemy:GetLocation())
    local move=0
    if not action then
        local desired=C.RAZE.FAR_CENTER-150
        if dist>=desired or desired-dist>160 then return false end
        move=desired-dist
        point=enemy:GetLocation()+(bot:GetLocation()-enemy:GetLocation()):Normalized()*desired
    end
    local horizon=C.RAZE.CAST_POINT+0.3+move/math.max(1,bot:GetCurrentMovementSpeed())
    if remaining<horizon+0.1 or GameTime()+horizon>chain.untilTime then return false end
    local incoming=K.ShortReplyIncoming(bot,enemy,horizon,s)
    if bot:GetHealth()-incoming<math.max(80,K.AttackDamageVs(enemy,bot)) then return false end
    if action then
        if not H.CastOrTurnRaze(bot,ab,action,aim,enemy) then return false end
        State.shortCombatCast=State.aimingRaze==ab
    else
        if not H.ApproachEnemyPoint(bot,enemy,point,25,s.enemyTowers or {},s.allyCreeps or {}) then return false end
    end
    State.dodgeLoc=nil;State.dodgeUntil=0
    State.lastCombatStage="reply-far-followup";State.actionTaken=true
    return true
end

-- Continue an existing close fight through one funded cooldown cycle; never initiate at parity.
function H.HandleManaCycleContinuation(bot,enemy,s)
    if not H.CanTakeShortCombatAction(bot,enemy,s) then return false end
    if enemy:GetAttackTarget()~=bot or GetUnitToLocationDistance(bot,enemy:GetLocation())>bot:GetAttackRange() then return false end
    if not H.IsRazeFollowUp(bot,enemy) and not (State.heroCombatEnemy==enemy and GameTime()<State.heroCombatUntil) then return false end
    if not K.ManaCycleWindow(bot,enemy,s) then return false end
    for _,label in ipairs({"near","mid","far"}) do
        local ab=H.GetRazeAbilityByLabel(bot,label)
        if U.IsRazeAbilityCastable(bot,ab) then
            local action,aim=H.GetRazeActionType(bot,ab,enemy)
            if action and H.CastOrTurnRaze(bot,ab,action,aim,enemy) then
                State.shortCombatCast = State.aimingRaze==ab
                State.lastCombatStage="mana-cycle-raze";State.actionTaken=true;return true
            end
        end
    end
    if not H.IssueHeroAttack(bot,enemy) then return false end
    State.lastCombatStage="mana-cycle-attack"
    State.actionTaken=true
    return true
end

function H.HandleSurvivalRetreat(bot, enemy, race)
    local now = GameTime()
    local visible = enemy and U.CanQuery(enemy)
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local danger = visible and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 1300
        and hpPct <= 0.45
        and enemy:GetHealth() / math.max(1, enemy:GetMaxHealth()) > hpPct + 0.12
    -- Hysteresis: regen or a momentary range change must not reopen combat.
    local active = State.survivalLoc ~= nil and now < (State.survivalUntil or 0)
    if active and visible and hpPct < 0.55
        and GetUnitToLocationDistance(bot, enemy:GetLocation()) < 1600 then danger = true end
    -- Never start a HP%-only escape before consulting the current resource race.
    -- An existing retreat still completes its commitment: no instant about-face.
    local favourable = visible and race and race.valid and not race.heCanKillSoon
        and (race.spellWindow or H.GetPendingRazeFollowup(bot, enemy, race)
            or (race.edge >= 0 and bot:GetHealth() >= enemy:GetHealth()))
    if favourable then danger = false end
    if danger then State.survivalUntil = now + 3.0 end
    if now >= (State.survivalUntil or 0) then
        State.survivalLoc = nil
        return false
    end
    if not State.survivalLoc then
        local fountain = P.GetFountain(bot)
        local loc = bot:GetLocation()
        local home = (fountain - loc):Normalized()
        local away = visible and (loc - enemy:GetLocation()):Normalized() or home
        -- A distant destination lets MoveToLocation route around trees instead of
        -- repeatedly ordering a short step into the same obstacle.
        if away.x * home.x + away.y * home.y > 0.2 then
            State.survivalLoc = U.GetRetreatWaypoint(bot, home)
        else
            State.survivalLoc = U.GetRetreatWaypoint(bot, away)
        end
        bot:Action_ClearActions(true)
        H.ClearRazeState()
        H.ClearForcedRetreat()
        H.ClearMoveCache()
        State.commitKillUntil = 0
        State.nearChainUntil = 0
        State.dodgeLoc = nil
    end
    if GetUnitToLocationDistance(bot, State.survivalLoc) < 150 then
        if not danger then
            State.survivalUntil = 0
            State.survivalLoc = nil
            return false
        end
        State.survivalLoc = U.GetRetreatWaypoint(bot,
            (bot:GetLocation() - enemy:GetLocation()):Normalized())
    end
    State.fleeUntil = math.max(State.fleeUntil or 0, now + 1.5)
    -- Do not force the pathfinder to rebuild a long route every 0.6 seconds.
    local moving = bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO
    if moving and State.survivalOrderLoc == State.survivalLoc
        and now - (State.survivalOrderTime or -100) < 2.0 then
        State.actionTaken = true
        return true
    end
    State.survivalOrderLoc = State.survivalLoc
    State.survivalOrderTime = now
    return H.SmartMove(bot, State.survivalLoc, 60)
end


function H.HandleEnemyNearRazeCounter(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- Clean flee - no turning toward the enemy
    if GameTime() < (State.fleeUntil or 0) and GameTime() >= (State.commitKillUntil or 0) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q_enemy = enemyHero:GetAbilityByName("nevermore_shadowraze1")
    if not q_enemy or not q_enemy:IsInAbilityPhase() then return false end

    local enemyLoc = enemyHero:GetLocation()
    local enemyFacing = enemyHero:GetFacing()
    local rad = math.rad(enemyFacing)
    local forward = Vector(math.cos(rad), math.sin(rad), 0)
    local center = enemyLoc + forward * C.RAZE.NEAR_CENTER
    if U.DistanceBetweenLocations(center, bot:GetLocation()) > C.RAZE.HIT_RADIUS then
        return false
    end

    local q_bot = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q_bot or not U.IsRazeAbilityCastable(bot, q_bot) then return false end

    local botPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local myError = U.GetRazeHitErrorWithDesiredFacing(bot, botPred, C.RAZE.NEAR_CENTER)
    if myError <= C.RAZE.HIT_RADIUS + 30 then
        local actionType = "TURN"
        if U.GetAngleDifference(bot, botPred) <= C.RAZE.MAX_ANGLE_TO_CAST then
            actionType = "CAST"
        end
        if H.CastOrTurnRaze(bot, q_bot, actionType, botPred, enemyHero) then
            return true
        end
    end

    return false
end

function H.GetPotentialRecallHpPct(bot)
    local hp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local bonus = 0
    if bot:HasModifier("modifier_flask_healing") then
        bonus = bonus + 390
    elseif U.HasItem(bot, "item_flask") then
        bonus = bonus + 390
    end
    return math.min(maxHp, hp + bonus) / maxHp
end


-- A confirmed kill is a safe reset opportunity, not a reason to remain resource-starved.
function H.HandlePostKillReset(bot, snapshot)
    local kills = snapshot and snapshot.myKills
    if type(kills) == "number" then
        local previous = State.postKillCount
        State.postKillCount = kills
        if previous ~= nil and kills > previous then
            local hp = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
            if hp <= 0.40 or bot:GetMana() < 75 then
                bot:Action_ClearActions(true)
                H.ClearRazeState()
                H.ClearForcedRetreat()
                H.ClearTowerEscape()
                H.ClearMoveCache()
                State.survivalLoc = nil
                State.survivalUntil = 0
                State.emergencyRetreat = nil
                State.commitKillUntil = 0
                State.nearChainUntil = 0
                State.prepTarget = nil
                State.dodgeLoc = nil
                State.needsTP = false -- Only request TP after reaching and healing at the fountain.
                State.goingToFountain = true
                State.fountainReason = "POST_KILL"
            end
        end
    end
    if State.goingToFountain and State.fountainReason == "POST_KILL" then
        if H.HandleFountainRecall(bot) then return true end
        if State.needsTP then return H.HandleReturnTP(bot) end
    end
    return false
end

function H.ShouldGoToFountain(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    if potentialHpPct < hpCritical then
        -- The enemy has exactly as few resources as we do - walking to the fountain simply hands
        -- him the lane and the wave. Keep the distance and regen.
        local enemyHero = W.s.enemy
        if enemyHero and U.EnemyResourcesAsWeak(bot, enemyHero, nil) then return false, nil end
        return true, "HP"
    end
    return false, nil
end

function H.ShouldAbortFountainRecall(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct >= hpCritical then
        return true
    end
    local potentialHpPct = H.GetPotentialRecallHpPct(bot)
    return potentialHpPct >= hpCritical
end

function H.IsAtFountain(bot)
    local fountain = P.GetFountain(bot)
    local radius = (C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500
    return GetUnitToLocationDistance(bot, fountain) <= radius
end

function H.IsFountainFullyRestored(bot)
    local hp = bot:GetHealth()
    local maxHp = bot:GetMaxHealth()
    local mana = bot:GetMana()
    local maxMana = bot:GetMaxMana()
    local hpPct = hp / maxHp
    local manaPct = (maxMana > 0) and (mana / maxMana) or 1.0
    local waitHpPct = (C.FOUNTAIN and C.FOUNTAIN.WAIT_FULL_HP_PCT) or 0.98
    local waitManaPct = (C.FOUNTAIN and C.FOUNTAIN.WAIT_FULL_MANA_PCT) or 0.98
    return hpPct >= waitHpPct and manaPct >= waitManaPct
end

function H.HandleFountainRecall(bot)
    if State.goingToFountain then
        if not bot:IsAlive() then
            State.goingToFountain = false
            State.fountainReason = nil
            return false
        end
        if not H.IsAtFountain(bot) and State.fountainReason ~= "EMERGENCY" and State.fountainReason ~= "POST_KILL" and H.ShouldAbortFountainRecall(bot) then
            State.goingToFountain = false
            State.fountainReason = nil
            H.ClearMoveCache()
            return false
        end
        if H.IsAtFountain(bot) then
            if H.IsFountainFullyRestored(bot) then
                State.goingToFountain = false
                State.fountainReason = nil
                State.needsTP = true
                return false
            else
                State.actionTaken = true
                return true
            end
        else
            local fountain = P.GetFountain(bot)
            H.SmartMove(bot, fountain, 80)
            State.actionTaken = true
            return true
        end
    end

    if State.emergencyRetreat then return false end
    if bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal") then return false end
    if H.IsInDangerForRegen(bot, 900) then return false end
    local should, reason = H.ShouldGoToFountain(bot)
    if should then
        State.goingToFountain = true
        State.fountainReason = reason
        H.ClearForcedRetreat()
        local fountain = P.GetFountain(bot)
        H.SmartMove(bot, fountain, 80)
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleReturnTP(bot)
    local t1 = P.GetT1Close(bot)
    local fountain = P.GetFountain(bot)
    local farFromT1 = GetUnitToLocationDistance(bot, t1) > C.TP.RETURN_DISTANCE_FROM_T1
    local nearFount = GetUnitToLocationDistance(bot, fountain) < (C.TP.FOUNTAIN_RADIUS or 400)
    -- Do not spend the starting scroll on a "TP to lane" in the first 20 s (we walk),
    -- afterwards needsTP (death/fountain) and the fountain return take over
    if not (State.needsTP or (nearFount and farFromT1 and GameTime() > 20)) then return false end
    if not H.IsFountainFullyRestored(bot) then
        State.actionTaken = true
        return true
    end
    local tp = U.GetTPScroll(bot)
    if not tp then
        -- The dedicated TP slot (15/16) can be invisible to GetItemInSlot. Before
        -- BUYING a new scroll (the hero already has one!) try moving it into slot 0.
        local step = State.tpSwapStep or 0
        if step < 2 and GameTime() - (State.tpSwapAt or -100) > 0.5 then
            State.tpSwapStep = step + 1
            State.tpSwapAt = GameTime()
            pcall(function() bot:ActionImmediate_SwapItems(15 + step, 0) end)
            State.actionTaken = true
            return true
        end
        if bot:GetGold() >= 100 and GameTime() - (State.tpBuyTime or -100) > 2.0 then
            bot:ActionImmediate_PurchaseItem("item_tpscroll")
            State.tpBuyTime = GameTime()
            return true
        end
        if GameTime() - (State.tpBuyTime or -100) <= 2.0 then return true end
        State.needsTP = false
        return false
    end
    State.tpSwapStep = 0
    -- A TP order is already issued: do not re-issue (re-issuing resets the teleport channel)
    if GameTime() - (State.tpOrderTime or -100) < 4.5 then
        State.actionTaken = true
        return true
    end
    local castOk, castable = pcall(function() return tp:IsFullyCastable() end)
    if castOk and castable then
        bot:Action_UseAbilityOnLocation(tp, t1)
        State.tpOrderTime = GameTime()
        State.needsTP = false
        State.actionTaken = true
        return true
    end
    -- Scroll on cooldown: wait up to 10 s, then walk
    local cdOk, cd = pcall(tp.GetCooldownTimeRemaining, tp)
    if cdOk and type(cd) == "number" and cd > 0 and cd <= 10 then
        State.actionTaken = true
        return true
    end
    State.needsTP = false
    return false
end

-- Defensive stance "I am weaker" (with hysteresis). The criterion is K.Race: a 6 s trade projection
-- (burst + right clicks + HP pool + towers), not just razes. While defending: do not answer his
-- right clicks without creep/tower support, do not harass, do not contest last hits,
-- stand behind our creeps (PASSIVE position), heal earlier.
function H.UpdateDefensive(bot, s, race)
    local now = s.now or GameTime()
    local cfg = C.DEFENSE or {}
    if not race or not race.valid then
        if not s.enemyAlive then State.defensive = false end
        return State.defensive
    end
    if race.spellWindow and not race.heCanKillSoon then
        State.defensive = false
        return false
    end
    if not State.defensive then
        if race.weaker then
            State.defensive = true
            State.defensiveSince = now
        end
    else
        local held = now - (State.defensiveSince or 0)
        if not race.weaker and race.edgeLong > -(cfg.EXIT_EDGE or 40) and held >= (cfg.MIN_HOLD_SEC or 2.0) then
            State.defensive = false
        end
    end
    return State.defensive
end

-- Support in the fight: my creeps are hitting him / he is under my tower.
function H.HasTradeSupport(race)
    local cfg = C.DEFENSE or {}
    if (State.enemyAggroCount or 0) >= (cfg.SUPPORT_CREEPS or 2) then return true end
    if race and race.valid and (race.myTowerOnHim or 0) > 0 then return true end
    return false
end

-- Can we spend 75 mana on a harass raze (not CS, not a finish): the reserve depends on the level.
-- followUp = the enemy has a fresh stack and is still in reach: the second/third raze finishes the stack
-- (+35/50/65/80 bonus per stack, he cannot answer) - the mana reserve does not apply.
function H.HarassManaOK(bot, race, followUp)
    local mana = H.GetPotentialCombatMana(bot)
    if mana < 75 then return false end
    if race and race.valid and race.canKillSoon then return true end
    if State.hunting then return true end -- Hunting: mana for 1 raze (+mango) is enough
    local cfg = C.MANA or {}
    local lvl = bot:GetLevel() or 1
    if followUp then
        -- At L1-L2 the "raze + stack finish" chain is limited by a 130 reserve (otherwise with
        -- fixed aiming the bot threw 3 razes in a row and sat at 66 mana for a minute)
        -- Exception - the enemy walked up close and took a near raze: finish with a chain
        -- of up to 3 razes (near -> mid -> far at the runner), no mana reserve.
        if GameTime() < (State.nearChainUntil or 0) then return true end
        local keep = cfg.FOLLOWUP_KEEP or 60
        if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then keep = cfg.FOLLOWUP_KEEP_L2 or 130 end
        return (mana - 75) >= keep
    end
    local reserve = cfg.RESERVE_FOR_PRESSURE or 75
    if lvl <= (cfg.EARLY_LEVEL_L2 or 2) then
        reserve = cfg.EARLY_RESERVE_L2 or 150
    elseif lvl <= (cfg.EARLY_LEVEL_L4 or 4) then
        reserve = cfg.EARLY_RESERVE_L4 or 112
    end
    return (mana - 75) >= reserve
end

-- "Stack finish": the enemy has a fresh raze stack (remaining >= FOLLOWUP_MIN_REMAIN) and is within
-- band reach (accounting for his movement during the cast).
function H.IsRazeFollowUp(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    local stacks, rem = U.GetShadowrazeDebuff(enemyHero)
    if (stacks or 0) <= 0 then return false end
    if (rem or 0) < (C.RAZE.FOLLOWUP_MIN_REMAIN or 1.2) then return false end
    local pred = U.PredictPosition(enemyHero, C.RAZE.PREDICT_DELAY)
    local d = GetUnitToLocationDistance(bot, pred or enemyHero:GetLocation())
    return d <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 60
end

-- The enemy T1 is "busy" with a creep: its current target is not a hero, is alive, with HP for >= 2 shots.
-- The tower does not switch to a hero while the target is alive and nobody right-clicks the hero (a raze gives no aggro).
function H.TowerLockedOnCreep(t1)
    if not t1 then return false end
    local okA, alive = pcall(t1.IsAlive, t1)
    if not okA or not alive then return false end
    if t1.CanBeSeen and not t1:CanBeSeen() then return false end
    local okT, tgt = pcall(t1.GetAttackTarget, t1)
    if not okT or not tgt or not U.CanQuery(tgt) then return false end
    if tgt.IsHero and tgt:IsHero() then return false end
    local okD, dmg = pcall(t1.GetAttackDamage, t1)
    if not okD or type(dmg) ~= "number" or dmg <= 0 then dmg = 100 end
    return (tgt:GetHealth() or 0) >= dmg * 2
end


-- Convert a clear lane lead into ranged pressure, without requiring a prior
-- enemy miss or an already-open raze stack. Never bypass retreat or tower safety.
function H.HasLanePressureAdvantage(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid then return false end
    if race.heCanKillSoon then return false end
    if race.spellWindow then return true end
    if race.edge < 0 then return false end
    local hp, enemyHp = bot:GetHealth(), enemy:GetHealth()
    local myHit, enemyHit = K.AttackDamageVs(bot, enemy), K.AttackDamageVs(enemy, bot)
    local levelLead = bot:GetLevel() > enemy:GetLevel()
    local soulLead = S.GetSouls(bot) - S.GetSouls(enemy)
    -- Absolute resources and the projected trade, never a percentage of our own pool.
    local healthLead = hp - enemyHp >= math.max(100, enemyHit * 1.5)
    local laneLead = levelLead and soulLead >= 4 and hp >= enemyHp
    local attackLead = myHit >= enemyHit * 1.20 and hp >= enemyHp and myHit > 0
    return healthLead or laneLead or attackLead

end

-- Observe incoming pressure independently of farm targets and attack intent.
function H.IsEnemyPressuring(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if enemy:GetAttackTarget() == bot then return true end
    local label = K.EnemyPhase()
    if label then
        local center = K.EnemyRazeCenter(enemy, label)
        if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then return true end
    end
    if bot.WasRecentlyDamagedByHero and bot:WasRecentlyDamagedByHero(enemy, 2.0) then return true end
    if bot.WasRecentlyDamagedByPlayer and enemy.GetPlayerID then
        local id = enemy:GetPlayerID()
        if id and id >= 0 and bot:WasRecentlyDamagedByPlayer(id, 2.0) then return true end
    end
    if U.GetRecentEnemyRazeHitAge(enemy) <= 2.0 then return true end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.caster == enemy then return true end
        end
    end
    return false
end

function H.TowerChaseBlocked(bot, snapshot)
    local enemy, tower = snapshot.enemy, snapshot.enemyT1
    if not U.CanQuery(enemy) or not tower or not tower:IsAlive() then return false end
    if GetUnitToLocationDistance(enemy, tower:GetLocation()) > 820 then return false end
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), snapshot.enemyTowers, snapshot.allyCreeps) then return false end
    if GetUnitToLocationDistance(bot, tower:GetLocation()) >= 900 then
        if State.aimingTarget == enemy and State.aimingRaze and bot:IsUsingAbility() then return false end
        for _, label in ipairs(K.LABELS) do
            local ab = H.GetRazeAbilityByLabel(bot, label)
            if U.IsRazeAbilityCastable(bot, ab) and not H.IsTowerDiveRazeUnsafe(bot, enemy, ab, snapshot.enemyTowers, snapshot.allyCreeps) then
                local action = H.GetRazeActionType(bot, ab, enemy)
                if action then return false end
            end
        end
    end
    return true
end

function H.UpdateTowerChase(bot, snapshot)
    local enemy = snapshot.enemy
    if not H.TowerChaseBlocked(bot, snapshot) then
        State.towerChaseBlockedEnemy = nil
        return false
    end
    local wasChasing = bot:GetAttackTarget() == enemy
        or (State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)
            and bot:GetCurrentActionType() == BOT_ACTION_TYPE_MOVE_TO)
    State.towerChaseBlockedEnemy = enemy
    State.heroCombatAllowed = false
    State.heroCombatEnemy = nil
    State.heroCombatUntil = 0
    State.commitKillUntil = 0
    State.razeFollowup = nil
    if GetUnitToLocationDistance(bot, snapshot.enemyT1:GetLocation()) < 900
        or H.IsEnemyPressuring(bot, enemy) then
        return H.BeginForcedRetreat(bot, LN.TowerEscapePoint(bot, snapshot.enemyT1), 0.6)
    end
    if wasChasing then H.SafeClearActions(bot) end
    return false -- Outside danger: release the tick to lane work, not another chase.
end

-- One combat pipeline for both initiation and retaliation. Its caller owns the
-- tick: farm/prehit state is never consulted and cannot suppress a combat stage.
function H.RunCombatPriority(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not enemy or not U.CanQuery(enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    local towers, allies = snapshot.enemyTowers or {}, snapshot.allyCreeps or {}
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.aggroPullTime = 0
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local function stage(name, ...)
        if H[name](...) then
            State.lastCombatStage = name
            State.actionTaken = true
            return true
        end
        return false
    end
    if stage("HandleEnemyTowerSafety", bot, snapshot, enemy) then return true end
    if stage("HandleEmergencyConsumables", bot, race) then return true end
    if stage("HandleGuaranteedRazeKill", bot, enemy, towers, allies) then return true end
    if stage("HandleGuaranteedAttackKill", bot, enemy, towers, allies) then return true end
    if stage("HandleEnemyRazeDodge", bot, enemy) then return true end
    if race and race.valid and race.heCanKillSoon and not race.canKillNow then
        local point = U.GetSafeDistancePosition(bot, enemy)
            or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
        State.lastCombatStage = "lethal-threat-retreat"
        State.commitKillUntil = 0
        return H.BeginForcedRetreat(bot, point, 1.0)
    end
    if State.aimingRaze and stage("HandleActiveRazeValidation", bot) then return true end
    if bot:IsUsingAbility() or bot:IsChanneling() then
        State.lastCombatStage = "finish-current-cast"
        State.actionTaken = true
        return true
    end
    if stage("HandleStackLead", bot, snapshot, race) then return true end
    -- Preserve a HERO swing, never a creep swing. Safety and lethal finishes above
    -- may interrupt it; ordinary movement/pressure below may not.
    if stage("ShouldHoldForHeroWindup", bot, snapshot, enemy, race) then return true end
    if stage("HandleInstantMirrorRaze", bot, enemy, race, snapshot) then return true end
    if stage("HandlePendingRazeFollowup", bot, enemy, race, snapshot) then return true end
    if race and race.spellWindow then
        if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    end
    if H.CanContinueDryRazeChain(bot, enemy, race) then
        if H.TryRazeEnemy(bot, enemy, "AGGRESSIVE", towers, allies, false, false) then return true end
    end
    if stage("HandleEnemyNearRazeCounter", bot, enemy) then return true end
    if stage("ForceExtendEnemyStack", bot, enemy, towers, allies) then return true end
    if stage("HandleNearRazeReplyPressure", bot, enemy, towers, allies) then return true end
    if race and race.valid and race.canKillSoon then
        if stage("HandleLethalTwoRazeSequence", bot, enemy, towers, allies) then return true end
        if stage("HandleNearRazeFinish", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleImmediateNearRazePunish", bot, enemy, "AGGRESSIVE", towers, allies) then return true end
    if stage("HandleCloseEnemyPunish", bot, enemy, towers, allies) then return true end
    if stage("HandleMirrorRazeTrade", bot, enemy, towers, allies, allies, snapshot.enemyCreeps or {}) then return true end
    if stage("HandleCloseAttackFinish", bot, enemy, towers, allies) then return true end
    local stacked, band = U.IsSecondStackDangerActive(bot, enemy)
    if stacked and band == "mid" and not (race and race.spellWindow) then
        if stage("HandleMidStackSpacing", bot, enemy, towers, allies) then return true end
    end
    if stage("HandleRetaliationAttack", bot, enemy, towers, allies) then return true end
    -- Generic attacks/approach are deliberately LAST, not an early return that
    -- makes every specialised combo handler unreachable.
    if stage("HandleAdvantageRazePressure", bot, enemy, race, towers, allies, nil) then return true end
    local point = U.GetSafeDistancePosition(bot, enemy)
        or U.GetRetreatWaypoint(bot, (bot:GetLocation() - enemy:GetLocation()):Normalized())
    State.lastCombatStage = "no-safe-action-retreat"
    return H.BeginForcedRetreat(bot, point, 0.8)
end

function H.HandleIncomingHeroPressure(bot, snapshot, race)
    local enemy = snapshot.enemy
    if not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.UpdateTowerChase(bot, snapshot) then return true end
    if State.towerChaseBlockedEnemy == enemy then return false end
    State.prepTarget = nil
    State.lhAttackTarget = nil
    State.heroCombatEnemy = enemy
    State.heroCombatUntil = GameTime() + 1.25
    local valid = race and race.valid
    if valid and race.canKillNow then
        if H.HandleGuaranteedRazeKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
        if H.HandleGuaranteedAttackKill(bot, enemy, snapshot.enemyTowers or {}, snapshot.allyCreeps or {}) then return true end
    end
    local losing = not valid or (race.heCanKillSoon and not race.canKillNow)
        or (valid and race.weakerSustained and not race.spellWindow
            and not race.canKillSoon and not H.GetPendingRazeFollowup(bot, enemy, race, snapshot)
            and bot:GetHealth() + 120 < enemy:GetHealth())
    if losing then
        State.commitKillUntil = 0
        H.ClearRazeState()
        local loc = U.GetSafeDistancePosition(bot, enemy)
        if not loc then
            local away = (bot:GetLocation() - enemy:GetLocation()):Normalized()
            loc = U.GetRetreatWaypoint(bot, away)
        end
        H.BeginForcedRetreat(bot, loc, 1.0)
        return true
    end
    -- Both response and initiative use the same specialist-first pipeline.
    local previous = State.intent
    State.intent = I.TRADE
    local acted = H.RunCombatPriority(bot, snapshot, race)
    State.intent = previous
    return acted

end

-- Combat owns the tick once selected. Creeps are not a reason to ignore an
-- attacker, but retreat, lethal damage and tower safety still take precedence.
function H.CanContinueDryRazeChain(bot, enemy, race)
    if not race or not race.valid or race.heCanKillSoon or not U.CanQuery(enemy) then return false end
    if K.EnemyManaBudget(enemy, true) + math.max(0, enemy.GetManaRegen and enemy:GetManaRegen() or 0) * 0.7 >= 75 then return false end
    if not H.IsRazeFollowUp(bot, enemy) then return false end
    for _, label in ipairs(K.LABELS) do
        local ab = H.GetRazeAbilityByLabel(bot, label)
        if U.IsRazeAbilityCastable(bot, ab) and H.GetRazeActionType(bot, ab, enemy) then return true end
    end
    return false
end

function H.ShouldEngageHero(bot, enemy, race)
    if not enemy or not U.CanQuery(enemy) or not race or not race.valid or race.heCanKillSoon then return false end
    if State.towerChaseBlockedEnemy == enemy or H.TowerChaseBlocked(bot, W.s) then return false end
    if GetUnitToLocationDistance(bot, enemy:GetLocation()) > 1150 then return false end
    if H.CanContinueDryRazeChain(bot, enemy, race) then return true end
    if K.HasRazeStackLead(bot, enemy) and not H.IsEnemyPressuring(bot, enemy) then return false end
    if H.GetPendingRazeFollowup(bot, enemy, race) then return true end
    if H.HasLanePressureAdvantage(bot, enemy, race) then return true end
    if H.IsEnemyPressuring(bot, enemy) then return true end
    return State.heroCombatEnemy == enemy and GameTime() < (State.heroCombatUntil or 0)

end

-- Once our last-hit swing has started, a rival projectile is NOT grounds to
-- surrender it. Timing uncertainty can reverse arrival order at short distances.
function H.ShouldCancelCommittedLastHit(predictedHP, threshold, buffer, remaining, window)
    return predictedHP > threshold + buffer and remaining > 0.01 and remaining <= window
end

function H.HandleAdvantageRazePressure(bot, enemy, race, towers, allies, nextLastHit)
    if not H.ShouldEngageHero(bot, enemy, race) then return false end
    if State.actionTaken or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc then return false end
    if State.intent == I.RETREAT or GameTime() < (State.fleeUntil or 0) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    -- A chosen hero fight may interrupt even a creep last-hit windup.
    local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
    if distance > 1150 then return false end
    local setupAbility, setupCenter
    local followUp = H.IsRazeFollowUp(bot, enemy)
    local spellBudget = bot:GetMana() >= 150 or (bot:GetMana() >= 75
        and ((race.enRazesSoon or 0) == 0 or followUp or race.canKillSoon
            or H.IsEnemyPressuring(bot, enemy)))
    for _, label in ipairs({"far", "mid", "near"}) do
        local ability = H.GetRazeAbilityByLabel(bot, label)
        if spellBudget and ability and U.IsRazeAbilityCastable(bot, ability) then
            local center = label == "far" and C.RAZE.FAR_CENTER or (label == "mid" and C.RAZE.MID_CENTER or C.RAZE.NEAR_CENTER)
            if not setupAbility and label ~= "near" then setupAbility, setupCenter = ability, center end
            if not H.IsTowerDiveRazeUnsafe(bot, enemy, ability, towers, allies) then
                local action, aim = H.GetRazeActionType(bot, ability, enemy)
                if action and H.CastOrTurnRaze(bot, ability, action, aim, enemy) then return true end
            end
        end
    end
    -- A lead also means right-click pressure, not waiting for spell mana/cooldowns.
    if distance <= bot:GetAttackRange() and H.IsSafeToHarass(bot, enemy:GetLocation(), towers, allies) then
        if H.IssueHeroAttack(bot, enemy) then
            State.actionTaken = true
            return true
        end
    end
    if not setupAbility then setupCenter = bot:GetAttackRange() - 30 end
    -- Walk only a short step toward a ready mid/far band, never into near-raze range.
    if setupCenter and distance > setupCenter + 10 then
        local here = bot:GetLocation()
        local step = math.min(220, distance - setupCenter)
        local point = here + (enemy:GetLocation() - here):Normalized() * step
        return H.ApproachEnemyPoint(bot, enemy, point, 35, towers, allies, false)
    end
    return false
end

function H.EarlyRazePolicyBlocks(bot, enemyHero)
    local cfg = C.RAZE or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local razeLvl = (q and q:GetLevel()) or 0
    if razeLvl >= (cfg.AGGRO_MIN_RAZE_LEVEL or 2) then return false end
    if not U.CanQuery(enemyHero) then return true end
    -- Mirror / answer: he cast a raze (hit or missed) in the last MIRROR_WINDOW s
    local E = K._enemy
    if E and E.lastAnyCastAt and (GameTime() - E.lastAnyCastAt) <= (cfg.MIRROR_WINDOW or 2.5) then return false end
    if U.HasEnemyMissedRazeRecently() then return false end
    -- He walked up close: the near band starts a chain of up to 3 razes
    local pred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT) or enemyHero:GetLocation()
    local d = GetUnitToLocationDistance(bot, pred)
    local dNow = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if math.min(d, dNow) <= (cfg.EARLY_CHAIN_DIST or 360) then return false end
    -- An open chain window (he already took a near raze and is leaving)
    if GameTime() < (State.nearChainUntil or 0) then return false end
    return true
end

function H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false, current_mode end
    if not U.CanQuery(enemyHero) then return false, current_mode end
    local intent = State.intent
    if intent == I.RETREAT then return false, current_mode end
    -- Mana reserve: pressure with razes only if mana for one more remains after the cast
    -- (except when the enemy cannot answer or we kill him).
    local R = K._race
    local killing = R and R.valid and (R.canKillSoon or State.hunting) -- Hunting = finishing
    local followUp = H.IsRazeFollowUp(bot, enemyHero)
    -- "Free pressure": the enemy has NO raze available (cooldown or mana) and we are
    -- ahead in the trade - raze without a mana reserve. The old reserve (112-150) kept the bot
    -- on right clicks only even though the enemy could not answer with a raze ("I have 1 coil, he has 0 - hit!").
    local freePressure = R and R.valid and (R.enRazesSoon or 0) == 0 and R.edge >= 0
        and bot:GetMana() >= 75
    -- Mana: reserve by level (at level 1-2 a "harmless" enemy is no reason to go to zero: mana is needed
    -- for last hits and the answer, and he will just regen the 64 damage). Finishing a stack - no reserve.
    if not killing and not freePressure and not H.HarassManaOK(bot, R, followUp) then
        return false, current_mode
    end
    -- Raze policy with 1 point (hero L1-L2): do NOT start a trade from range - he regens/eats a mango
    -- for the 85 damage while 75 mana (a quarter of the pool) is lost. Raze only: (a) as a mirror/answer
    -- to his cast, (b) when he walked up close himself (near->mid->far chain),
    -- (c) finishing a stack / killing. From 2 raze points (usually L3) aggression is as before.
    if not killing and not followUp and H.EarlyRazePolicyBlocks(bot, enemyHero) then
        return false, current_mode
    end
    -- Defence: raze him only with support (creeps/tower hitting him), to finish, or
    -- finishing a stack on a LEAVING enemy (he cannot answer, the stack is free)
    if State.defensive and not killing and not H.HasTradeSupport(R) then
        if not (followUp and K.IsEnemyMovingAway(bot, enemyHero)) then
            return false, current_mode
        end
    end
    if followUp then return true, "AGGRESSIVE" end
    if intent == I.ALLIN or intent == I.TRADE or intent == I.ZONE then return true, "AGGRESSIVE" end
    if intent == I.PUSH and R and R.valid and R.edge >= 0 then return true, "AGGRESSIVE" end
    if current_mode == "NEUTRAL" or current_mode == "AGGRESSIVE" then return true, current_mode end
    if bot:GetLevel() > 1 and U.HasEnemyMissedRazeRecently() and H.GetPotentialCombatMana(bot) >= 75 then
        return true, "AGGRESSIVE"
    end
    if aggroCount > 1 or H.GetPotentialCombatMana(bot) < 75 then return false, current_mode end
    local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
    local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
    local bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemyHero, "item_bracer")
    if levelDiff > 0 or soulDiff >= 6 or bracerDiff > 0 then return true, "NEUTRAL" end
    return false, current_mode
end

function H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps)
    if State.combatPolicyActive == true and not State.heroCombatAllowed then return false end
    if not U.CanQuery(enemyHero) then return false end
    if State.defensive and not H.HasTradeSupport(K._race) then return false end
    local interruptRegen = U.IsEnemyHighValueRegen(enemyHero)
    local enemyMissed = U.HasEnemyMissedRazeRecently() and bot:GetLevel() > 1
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local attackRange = bot:GetAttackRange() + 60
    if dist > attackRange then return false end
    local minDistStack = U.GetMinDistWithStack(bot, enemyHero)
    if minDistStack > 0 and dist < minDistStack then return false end
    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
        if interruptRegen then
            for _, tower in pairs(enemyTowers or {}) do
                if tower:IsAlive() and GetUnitToLocationDistance(tower, bot:GetLocation()) < 720 then
                    return false
                end
            end
        else
            return false
        end
    end
    if interruptRegen then
        return (bot:GetHealth() / bot:GetMaxHealth()) >= 0.30
    end
    local maxAggro = enemyMissed and 2 or 1
    if aggroCount > maxAggro then return false end
    if (bot:GetHealth() / bot:GetMaxHealth()) < C.HARASS.MIN_HP_PCT then return false end
    if current_mode == "PASSIVE" and not enemyMissed then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemyHero:GetHealth() / enemyHero:GetMaxHealth()
        if (myHpPct - eHpPct) < -0.15 then
            local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
            local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
            if levelDiff <= 0 and soulDiff < 6 then return false end
        end
    end
    return true
end

function H.GetEnemyApproachDistance(enemyMissed)
    return enemyMissed and C.HARASS.APPROACH_DISTANCE_MISS or C.HARASS.APPROACH_DISTANCE
end

function H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.8 then return false end
    return true
end

function H.IsDryVsEnemyRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local myHasResource = H.GetPotentialCombatMana(bot) >= 75
    if myHasResource then return false end
    local enemyHasResource = enemyHero:GetMana() >= 75 or U.HasItem(enemyHero, "item_enchanted_mango") or U.HasItem(enemyHero, "item_magic_wand") or U.HasItem(enemyHero, "item_magic_stick")
    if not enemyHasResource then return false end
    return true
end

-- "Raze parity". The trade is roughly even (level, items) but he has mana for two
-- razes and we have one. Until we save as much, do not close into mid-band distance:
-- otherwise he catches us with the second raze and we have nothing to mirror with.
function H.IsManaBudgetDisadvantage(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local cfg = C.MANA or {}
    if cfg.PARITY_ENABLE == false then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local enBudget = K.EnemyRazeBudget(enemyHero, true)
    if enBudget < (cfg.PARITY_MIN_ENEMY or 2) then return false end
    local myBudget = K.MyRazeBudget(bot, true)
    if enBudget - myBudget < (cfg.PARITY_GAP or 1) then return false end
    -- A clear advantage in the trade - no fear: our edge has to be converted
    local R = K._race
    if R and R.valid and (R.edge >= 100 or R.canKillSoon) then return false end
    -- "Roughly equal": level and items
    if math.abs((bot:GetLevel() or 1) - (enemyHero:GetLevel() or 1)) > (cfg.PARITY_LEVEL_DIFF or 1) then
        return false
    end
    if math.abs(U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemyHero)) > (cfg.PARITY_ITEM_DIFF or 0.35) then
        return false
    end
    return true
end

function H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    -- Harass raze - with the level-based mana reserve (like any pressure)
    if not H.HarassManaOK(bot, K._race) then return false end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end

    local heroPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
    }

    for _, creep in pairs(enemyCreeps or {}) do
        if creep and creep:IsAlive() then
            local name = creep:GetUnitName() or ""
            if name:find("ranged") then
                local creepPred = U.PredictPosition(creep, C.RAZE.CAST_POINT)
                if U.DistanceBetweenLocations(creepPred, heroPred) <= 180 then
                    local ctx = U.GetTargetPredictionContext(creep, allyAttackers)
                    local predHp = U.PredictHPWithContext(ctx, creep, C.RAZE.CAST_POINT + 0.07)
                    for _, ability in ipairs(abilities) do
                        if ability and U.IsRazeAbilityCastable(bot, ability) and not H.IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
                            local data = U.GetRazeAbilityData(ability)
                            local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
                            local actualCreepDmg = creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL)
                            local midPoint = Vector(
                                (creepPred.x + heroPred.x) * 0.5,
                                (creepPred.y + heroPred.y) * 0.5,
                                (creepPred.z + heroPred.z) * 0.5
                            )
                            local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, midPoint, data.center)
                            -- This is a "2 in 1" raze (creep + hero): the hero must be covered robustly
                            -- (now and after the cast), otherwise it is just 75 mana for one creep while the band
                            -- goes on cooldown right as he arrives
                            local heroErrAim = U.RobustRazeErrors(bot, enemyHero, data.center, C.RAZE.CAST_POINT)
                            local heroCovered = heroErrAim <= (C.RAZE.HIT_RADIUS - 60)
                            if predHp > 0 and predHp <= actualCreepDmg + 12 and plannedError <= C.RAZE.HIT_RADIUS and heroCovered then
                                local actionType = "TURN"
                                if U.GetAngleDifference(bot, midPoint) <= C.RAZE.MAX_ANGLE_TO_CAST then
                                    actionType = "CAST"
                                end
                                if H.CastOrTurnRaze(bot, ability, actionType, midPoint, enemyHero) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

-- Emergency consumables BEFORE retreats/salves: wand/faerie when nearly dead,
-- mango for a finish (the raze decides the fight). They used to be in HandleItemsAndConsumables
-- at the end of the tick - while retreating the tick ended earlier and the faerie "was not pressed before death".
function H.HandleEmergencyConsumables(bot, race, snapshot)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GameTime() < (State.lastItemUseTime or 0) + 0.3 then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local commitKill = GameTime() < (State.commitKillUntil or 0)
    local heLethalSoon = race and race.valid and race.heCanKillSoon or false
    local enemy = snapshot and snapshot.enemy or (W.s and W.s.enemy)
    local incoming, threatened = 0, false
    if U.CanQuery(enemy) then
        local distance = GetUnitToLocationDistance(bot, enemy:GetLocation())
        threatened = H.IsEnemyPressuring(bot, enemy)
            or (bot:GetAttackTarget() == enemy and distance <= enemy:GetAttackRange() + 100)
        if threatened and distance <= enemy:GetAttackRange() + 100 then
            incoming = K.AttackDamageVs(enemy, bot) * 2 + 25
        end
        local label = K.EnemyPhase()
        if label then
            local center = K.EnemyRazeCenter(enemy, label)
            if center and GetUnitToLocationDistance(bot, center) <= C.RAZE.HIT_RADIUS + 30 then
                incoming = incoming + K.EnemyRazeDamage(bot, enemy, 1)
                threatened = true
            end
        end
    end
    if bot.GetIncomingTrackingProjectiles then
        for _, projectile in pairs(bot:GetIncomingTrackingProjectiles() or {}) do
            if projectile.is_attack and U.CanQuery(projectile.caster) then
                incoming = incoming + K.AttackDamageVs(projectile.caster, bot)
                threatened = true
            end
        end
    end
    local urgent = threatened and bot:GetHealth() <= incoming
    if hpPct < 0.10 then
        local stickItem = H.GetStickLikeItem(bot)
        if stickItem then
            bot:Action_UseAbility(stickItem)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    if hpPct < 0.20 or urgent or (heLethalSoon and hpPct < 0.35) or (commitKill and hpPct < 0.40) then
        local faerie = U.GetActiveItemByName(bot, "item_faerie_fire")
        if faerie then
            bot:Action_UseAbility(faerie)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end
    -- Mango for the finish: let the raze decide the fight right now
    if commitKill and bot:GetMana() < 75 and (bot:GetMana() + U.GetMangoMana(bot)) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    return false
end

-- Plant only when healing is needed; identify the new tree, never an old nearby one.
function H.HandleBranchTango(bot,tango)
    if State.branchTangoDone then return false end
    local now=GameTime()
    local plan=State.branchTango
    if plan then
        local best,bestDistance=nil,math.huge
        for _,tree in pairs(bot:GetNearbyTrees(350) or {}) do
            local distance=U.DistanceBetweenLocations(GetTreeLocation(tree),plan.location)
            if not plan.before[tree] and distance<80 and distance<bestDistance then best=tree;bestDistance=distance end
        end
        if best then
            bot:Action_UseAbilityOnTree(tango,best)
            State.tangoTree=best;State.tangoTreeLoc=GetTreeLocation(best)
            State.tangoChosenAt=now;State.tangoProgressAt=now;State.tangoBestDist=math.huge
            State.tangoCastAt=now;State.lastItemUseTime=now
            State.branchTangoDone=true;State.branchTango=nil;State.branchTangoSwapUntil=nil;State.actionTaken=true
            return true
        end
        if now-plan.time<1.5 then State.actionTaken=true;return true end
        State.branchTango=nil
        State.branchTangoDone=true -- Failed/removed tree: do not stall healing forever.
        return false
    end
    local slot=bot:FindItemSlot("item_branches")
    if slot<0 or slot>8 then return false end
    if slot>=6 then
        local target,priority=nil,math.huge
        for i=0,5 do
            local it=bot:GetItemInSlot(i)
            if not it then target=i;break end
            local name=it:GetName()
            local value=(C.ITEM_PRIORITY or {})[name] or 0
            if name~="item_tango" and value<priority then target=i;priority=value end
        end
        if target~=nil then
            bot:ActionImmediate_SwapItems(slot,target)
            State.branchTangoSwapUntil=now+7
            State.actionTaken=true
            return true
        end
        return false,true
    end
    local branch=bot:GetItemInSlot(slot)
    if not branch or not branch:IsFullyCastable() then return false,true end
    local angle=math.rad(bot:GetFacing())
    local point=bot:GetLocation()+Vector(math.cos(angle),math.sin(angle),0)*100
    if type(IsLocationPassable)=="function" and not IsLocationPassable(point) then return false end
    local before={}
    for _,tree in pairs(bot:GetNearbyTrees(350) or {}) do before[tree]=true end
    State.branchTango={location=point,before=before,time=now}
    bot:Action_UseAbilityOnLocation(branch,point)
    H.ClearMoveCache();State.actionTaken=true
    return true
end

function H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero)
    if GameTime()>=(State.branchTangoSwapUntil or -math.huge) then U.ManageInventorySlots(bot) end
    -- An eat-tree order was issued: hold position until modifier_tango_heal appears (up to 1 s)
    if State.tangoCastAt > 0 and (GameTime() - State.tangoCastAt) < 1.0 then
        if bot:HasModifier("modifier_tango_heal") then
            H.ClearTangoState()
            State.tangoFails = 0
        else
            State.actionTaken = true
            return true
        end
    end
    if GameTime() < State.lastItemUseTime + 0.3 then return false end
    if H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then return false end

    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    -- (Wand/faerie moved to HandleEmergencyConsumables - the start of the tick)
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end

    local isHighValueBeingAttacked = false
    for _, c in pairs(enemyCreeps or {}) do
        if c:IsAlive() then
            local name = c:GetUnitName() or ""
            if name:find("ranged") or name:find("flagbearer") or name:find("siege") then
                if (c:GetHealth() / c:GetMaxHealth()) < 0.50 then
                    isHighValueBeingAttacked = true
                    break
                end
                for _, atk in pairs(allyAttackers or {}) do
                    if atk:IsAlive() and atk:GetAttackTarget() == c then
                        isHighValueBeingAttacked = true
                        break
                    end
                end
                if isHighValueBeingAttacked then break end
            end
        end
    end

    local tcfg = C.TANGO or {}
    local missingHp = bot:GetMaxHealth() - bot:GetHealth()
    local wantTango = hpPct < (tcfg.USE_HP_PCT or 0.80) and missingHp >= (tcfg.MIN_MISSING_HP or 100)
    -- In an active fight (TRADE/ALLIN) do not walk to trees while HP is above 60%; in ZONE eat below 60%
    local intent = State.intent
    if (intent == "TRADE" or intent == "ALLIN") and hpPct >= 0.60 then wantTango = false end
    if intent == "ZONE" and hpPct >= 0.60 then wantTango = false end
    if intent == "RETREAT" then wantTango = false end
    -- A "valuable creep under attack" delays the tango only at HP >= 50%
    if hpPct < 0.50 then isHighValueBeingAttacked = false end
    if bot:HasModifier("modifier_tango_heal") then
        H.ClearTangoState()
        wantTango = false
    end

    if wantTango and not isHighValueBeingAttacked then
        local tango = U.GetActiveItemByName(bot, "item_tango")
        if tango then
            local now = GameTime()
            -- An eat-tree order was already issued: wait for modifier_tango_heal without leaving the tree.
            -- Otherwise the next handler walks the bot away and the eat order is cancelled (loop).
            if State.tangoCastAt > 0 and (now - State.tangoCastAt) < 1.0 then
                State.actionTaken = true
                return true
            end
            if State.tangoCastAt > 0 then
                -- The order did not work within 1 s: try again, after two failures use another tree
                State.tangoFails = (State.tangoFails or 0) + 1
                State.tangoCastAt = 0
                if State.tangoFails >= 2 then
                    State.tangoBadTree = State.tangoTree
                    State.tangoBadTreeTime = now
                    State.tangoFails = 0
                    H.ClearTangoState()
                end
            end
            local branchAction,waitingForBranch=H.HandleBranchTango(bot,tango)
            if branchAction then return true end
            if waitingForBranch then return false end
            local tree, treeLoc = H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
            if tree and treeLoc then
                local distToTree = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
                if distToTree > 165 then
                    H.SmartMove(bot, treeLoc, 40)
                    return true
                end
                bot:Action_UseAbilityOnTree(tango, tree)
                State.branchTangoDone=true
                State.lastItemUseTime = now
                State.tangoCastAt = now
                State.actionTaken = true
                return true
            end
        end
    elseif not wantTango then
        H.ClearTangoState()
    end

    return false
end

function H.ProcessTelemetry(bot)
    local now = GameTime()
    for i = #State.flyingProjectiles, 1, -1 do
        local proj = State.flyingProjectiles[i]
        if now > proj.impactTime + 0.15 then
            table.remove(State.flyingProjectiles, i)
        end
    end
end

function H.HandleEmergencyRetreat(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()

    if enemyHero and U.CanQuery(enemyHero) then
        local canOneShot, oneShotMethod = U.CanOneShotEnemyHero(bot, enemyHero)
        local canRazeKill, razeLabel = U.CanKillEnemyWithOneRaze(bot, enemyHero)
        if canOneShot then
            return false
        end
        if canRazeKill then
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct >= returnHpPct then
        if H.IsAtFountain(bot) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            State.goingToFountain = true
            State.fountainReason = "HP"
        else
            -- HP recovered on the way (regen/tango/salve): the emergency retreat is over. Otherwise
            -- "FOUNTAIN" would stay in State and on the next HP dip below 50% would force
            -- a fountain run (committedFountain) for no real reason.
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            H.ClearForcedRetreat()
        end
        return false
    end

    local committedFountain = State.emergencyRetreat == "FOUNTAIN"
        and State.emergencyRetreatStartTime > 0
        and (GameTime() - State.emergencyRetreatStartTime) >= 5.0
        and distToFountain > ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500)

    if committedFountain then
        H.BeginForcedRetreat(bot, fountain, 1.0)
        return true
    end

    local reason, extraLoc = U.GetEmergencyRetreatReason(bot, enemyHero)
    if not reason then
        if State.emergencyRetreat then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
        end
        return false
    end

    if reason == "COURIER" and extraLoc then
        State.emergencyRetreat = "COURIER"
        State.emergencyRetreatStartTime = 0
        local botLoc = bot:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, extraLoc)
        if dist > 150 then
            local toFountain = (fountain - botLoc):Normalized()
            local toCourier = (extraLoc - botLoc):Normalized()
            local blended = (toCourier * 0.8 + toFountain * 0.2):Normalized()
            H.SmartMove(bot, botLoc + blended * math.min(dist, 400), 60)
        end
        State.actionTaken = true
        return true
    end

    if State.emergencyRetreat ~= "FOUNTAIN" then
        State.emergencyRetreatStartTime = GameTime()
    end
    State.emergencyRetreat = "FOUNTAIN"

    if distToFountain < ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500) then
        State.emergencyRetreat = nil
        State.goingToFountain = true
        State.fountainReason = "EMERGENCY"
        State.actionTaken = true
        return true
    end

    H.BeginForcedRetreat(bot, fountain, 1.0)
    return true
end

function H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if U.ShouldUseGlyphDefensive(bot, allyTowers) then
        U.UseGlyph(bot)
        State.actionTaken = true
        return true
    end
    if U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then
        U.UseGlyph(bot)
        State.glyphUsedForDive = true
        State.glyphDiveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

function H.HandleForcedSalve(bot)
    if not U.ShouldForceSalve(bot) then return false end
    if GameTime() < State.lastForceSalveTime + 1.0 then return false end
    local nearbyEnemyHeroes = bot:GetNearbyHeroes(700, true, BOT_MODE_NONE)
    if nearbyEnemyHeroes and #nearbyEnemyHeroes > 0 then
        local fountain = P.GetFountain(bot)
        local botLoc = bot:GetLocation()
        H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 400, 60)
        State.actionTaken = true
        return true
    end
    local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(500, true) or {}
    for _, c in pairs(nearbyEnemyCreeps) do
        if U.CanQuery(c) and c:GetAttackTarget() == bot then -- Creep in fog -> do not query
            local fountain = P.GetFountain(bot)
            local botLoc = bot:GetLocation()
            H.SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 350, 60)
            State.actionTaken = true
            return true
        end
    end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if flask then
        if H.HasEnemyProjectileIncoming(bot) then
            local safeLoc = H.GetSalveSafeRetreatLocation(bot, nil)
            H.BeginForcedRetreat(bot, safeLoc, 0.65)
            return true
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastForceSalveTime = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

-- Purchases have one owner: item_purchase_nevermore.lua.

function H.HandleSafeDistanceFromEnemy(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if canOneShot then
        H.IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        return true
    end
    local canQuickRazeKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
        local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
        if ability then
            local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, predLoc)
            local actionType = angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, ability, actionType, predLoc, enemyHero) then
                return true
            end
        end
    end
    if not U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = isCritical and (SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950) or SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if dist < minDist then
        local duration = isCritical and 1.20 or 0.80
        H.BeginForcedRetreat(bot, safeLoc, duration)
        return true
    end
    return false
end

function H.HandleDryManaMidRazeAvoidance(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not H.IsDryVsEnemyRaze(bot, enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if State.actionTaken then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midDangerRadius = math.max(C.RAZE.STRICT_RADIUS, 210)
    if math.abs(dist - C.RAZE.MID_CENTER) > midDangerRadius then return false end
    -- Short step past the band edge (previously ~1000 toward the fountain -> back for a creep -> scared again)
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero)
    H.BeginForcedRetreat(bot, retreatLoc, 0.75)
    return true
end

function H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_DISTANCE) or 215
    local minDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MIN_DISTANCE) or 150
    local maxDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MAX_DISTANCE) or 250
    local tol = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_TOLERANCE) or 25
    if dist >= minDist and dist <= maxDist then
        H.SafeClearActions(bot)
        bot:Action_MoveToLocation(botLoc)
        State.lastMoveLoc = botLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    -- With a stack on us do NOT close on the enemy (near band = his right click + near raze
    -- with the bonus); "keep the answer distance" only if already adjacent (back off to 215)
    if dist > maxDist then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = H.GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    H.SmartMove(bot, holdLoc, tol)
    State.actionTaken = true
    return true
end

function H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not secondStackActive or hitLabel ~= "near" then return false end
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if myStacks ~= 1 or myRemain <= C.RAZE.RETREAT_MIN_REMAIN then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local actionType = U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.0)
    end

    if enemyIsHittingUs then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local attackRange = bot:GetAttackRange() + 60
        if dist <= attackRange then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end

    return H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
end

function H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreepsData, enemyCreepsData)
    if not U.CanQuery(enemyHero) or State.towerChaseBlockedEnemy==enemyHero or State.actionTaken then return false end
    local active,label=U.IsSecondStackDangerActive(bot,enemyHero)
    if not active or not label then return false end
    local ab=H.GetRazeAbilityByLabel(bot,label)
    if not U.IsRazeAbilityCastable(bot,ab) then return false end
    local action,aim=H.GetRazeActionType(bot,ab,enemyHero)
    if action then return H.CastOrTurnRaze(bot,ab,action,aim,enemyHero) end
    -- A real in-range attacker must not get free hits while we reposition for a different band.
    if enemyHero:GetAttackTarget()==bot and GetUnitToLocationDistance(bot,enemyHero:GetLocation())<=bot:GetAttackRange() then return false end
    local setup=U.GetRazeSetupPositionForAbility(bot,enemyHero,U.GetRazeCenterByLabel(label))
    return setup and H.ApproachEnemyPoint(bot,enemyHero,setup,35,enemyTowers,allyCreeps) or false
end

-- Instant mirror. His raze just landed on us (<= MIRROR_INSTANT_SEC): he stands
-- in the same band on our side (symmetry) - answer immediately with the same band (his copy is on a 9 s cd)
-- or with any band that covers robustly. Previously the answer came after the stack-exit rule and the
-- finish block, i.e. 0.5-1 s later when the enemy had already moved ("mirrors slowly").
-- Without closing: cast/turn in place only. No mirror if: his burst is lethal now; less than
-- MIRROR_MIN_HP_LEFT would remain after his next raze; we are under his T1 without a creep shield.
H._mirrorOrder = { nil, nil, nil }
function H.HandleInstantMirrorRaze(bot, enemyHero, race, s)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    -- While fleeing we MAY answer (an instant reply to his raze that hit us) -
    -- this is a deliberate "turn, cast, run again", not twitching (as it was before v2.6)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local age = U.GetRecentEnemyRazeHitAge(enemyHero)
    if age > ((C.RAZE and C.RAZE.MIRROR_INSTANT_SEC) or 0.7) then return false end
    -- Deduplicate the enemy HIT, not all our casts for 1.2 seconds.
    local hitTime = GameTime() - age
    if State.mirrorAnsweredEnemy == enemyHero and State.mirrorAnsweredHit
        and math.abs(State.mirrorAnsweredHit - hitTime) < 0.001 then return false end
    if H.GetPotentialCombatMana(bot) < 75 then return false end
    local canKillNow = race and race.valid and race.canKillNow
    if race and race.valid and race.heCanKillNow and not canKillNow then return false end
    local oneRaze = K.EnemyRazeDamage(bot, enemyHero, 1)
    if not canKillNow and (bot:GetHealth() - oneRaze) < ((C.RAZE and C.RAZE.MIRROR_MIN_HP_LEFT) or 110) then
        return false
    end
    local underT1 = H.IsBotUnderEnemyT1(bot, s and s.enemyTowers or {})
    if underT1 and not H.TowerLockedOnCreep(s and s.enemyT1) then return false end
    if bot:GetMana() < 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
        return false
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemyHero)
    local order = H._mirrorOrder
    local n = 0
    if hitLabel then n = n + 1; order[n] = hitLabel end
    for i = 1, 3 do
        if K.LABELS[i] ~= hitLabel then n = n + 1; order[n] = K.LABELS[i] end
    end
    for i = 1, n do
        local ab = H.GetRazeAbilityByLabel(bot, order[i])
        if ab and U.IsRazeAbilityCastable(bot, ab) then
            local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
            if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                if U.DEBUG then print(string.format("[SF-BOT] instant mirror %s (%s) age=%.2f", order[i], actionType, age)) end
                return true
            end
        end
    end
    return false
end

function H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false end
    local shouldClose, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not shouldClose or not closePos then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local canQuickRazeKill, _ = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
    elseif U.IsInEnemyRazeKillThreat(bot, enemyHero) then
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            -- Via the shared CastOrTurnRaze (facing check + turn step, not walking to the enemy)
            local actionType = H.RazeFacingOK(bot, predicted) and "CAST" or "TURN"
            if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    if H.ApproachEnemyPoint(bot, enemyHero, closePos, 35, enemyTowers, allyCreeps) then
        return true
    end
    return false
end

function H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and H.GetPotentialCombatMana(bot) >= 75 then
        if H.TryUseBurstManaItem(bot, true) then return true end
    end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false end
    -- The mana reserve for the near punish was removed (v2.3 gated it with a 130 reserve: at 141 mana the bot
    -- silently stood in the near band and took stacks). The enemy walked up close - that is the best moment
    -- for a trade: a near raze now, mid/far at the runner. Only 75 mana is needed.
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and safeReplyLabel ~= "near" then return false end
    -- Robust - the near circle must cover the enemy both now and after the cast time
    -- (an enemy leaving the near band is not "punished" with a raze into thin air)
    -- A margin of >= 100 u from the near circle edge: an enemy standing at the edge (380-450) gets out of
    -- the circle during the cast as soon as he starts moving; such a target is hit by the mid raze (via GetBestRaze).
    if K.IsEnemyMovingAway(bot, enemyHero) then return false end
    local errAim, errFacing, predicted = U.RobustRazeErrors(bot, enemyHero, C.RAZE.NEAR_CENTER, C.RAZE.CAST_POINT)
    local limit = C.RAZE.HIT_RADIUS - 100
    if errAim > limit then return false end
    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then return false end
    if H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
        if oneRaze < enemyHero:GetHealth() then return false end
    end
    local actionType = "TURN"
    if errFacing <= limit then -- Same threshold as the candidate (no TURN dead zone)
        actionType = "CAST"
    end
    if H.CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
        if actionType == "CAST" then
            -- Chain window: for the next ~5 s the stack-finishing razes go without a mana reserve
            State.nearChainUntil = GameTime() + ((C.RAZE and C.RAZE.NEAR_CHAIN_WINDOW) or 5.0)
        end
        return true
    end
    return false
end

-- The enemy walked up close - punishing him beats waiting for the last hit. Previously at this moment
-- the last-hit block ran (is_free_to_prehit = false) and the bot silently stood by the creep while being hit.
-- Try the near raze first; if it does not cover, finish for sure with mid/far
-- and extend the stack (he is already in reach, too late for him to leave).
function H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps)
    if enemyHero and State.towerChaseBlockedEnemy == enemyHero then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.RAZE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist > (cfg.PUNISH_CLOSE_RANGE or 520) then return false end
    if H.GetPotentialCombatMana(bot) < (cfg.PUNISH_MIN_POT_MANA or 150) then return false end
    local R = K._race
    local weWin = R and R.valid and (R.canKillSoon or R.edge > 0)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not weWin and not U.CanOneShotEnemyHero(bot, enemyHero) then
        return false
    end
    if bot:GetMana() < 75 and H.TryUseBurstManaItem(bot, true) then return true end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and H.IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then return false end

    if H.HandleImmediateNearRazePunish(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps) then
        return true
    end

    -- Near does not cover - hit with mid/far and extend the stack
    State.nearChainUntil = math.max(State.nearChainUntil or 0, GameTime() + (cfg.NEAR_CHAIN_WINDOW or 5.0))
    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, true) then
        return true
    end
    return false
end

function H.HandleBootDisadvantageMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if not U.ShouldFearBootsMidRaze(bot, enemyHero) then return false end
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = (C.BOOT_FEAR and C.BOOT_FEAR.MID_RAZE_RADIUS) or 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, (C.BOOT_FEAR and C.BOOT_FEAR.RETREAT_DURATION) or 0.95)
    return true
end

-- Is any "mid band fear" active (same conditions as the three handlers below,
-- without the distance check). The U._midFear flag makes the minimum enemy distance proactive.
function H.MidRazeFearActive(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) or not U.EnemyHasRaze(enemyHero) then return false end
    -- Do not back off past our own T1: the tower will punish him and retreating behind it loses the lane
    if H.IsNearOwnT1(bot, 400) then return false end
    if State.enemyReachedLevel2First and bot:GetLevel() < 2 then return true end
    if H.IsDryVsEnemyRaze(bot, enemyHero) then return true end
    if H.IsManaBudgetDisadvantage(bot, enemyHero) then return true end
    if U.ShouldFearBootsMidRaze(bot, enemyHero) and not U.IsInEnemyRazeKillThreat(bot, enemyHero)
        and not U.CanKillEnemyWithTwoRazes(bot, enemyHero) then
        return true
    end
    return false
end

function H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero)
    if U.CanQuery(enemyHero) and K.BandSafeFromEnemy(enemyHero, "mid", 1.2) then return false end
    if not State.enemyReachedLevel2First then return false end
    if H.IsNearOwnT1(bot, 400) then return false end -- Do not retreat past our own T1
    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
        return false
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetMidBandExitPosition(bot, enemyHero) -- Short step past the band edge
    H.BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

function H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    if H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    -- The tower is nearly down - stay under it and finish it
    if LN.IsTowerFinishable(bot, t1) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    local closestDist = math.huge
    local closestCreep = nil
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                local d = GetUnitToLocationDistance(t1, c:GetLocation())
                if d < closestDist then
                    closestDist = d
                    closestCreep = c
                end
            end
        end
    end
    local prevDist = State.enemyT1ClosestCreepDist
    State.enemyT1ClosestCreepDist = (closestCreep and closestDist) or nil
    State.enemyT1ClosestCreepTime = GameTime()
    local driftStart = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_START) or 620
    local driftHard = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_HARD) or 700
    local driftDelta = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_DELTA) or 22
    local shouldRetreat = false
    if not closestCreep then
        shouldRetreat = true
    elseif closestDist >= driftHard then
        shouldRetreat = true
    elseif prevDist and closestDist >= driftStart and closestDist > (prevDist + driftDelta) then
        shouldRetreat = true
    end
    if not shouldRetreat then return false end
    if H.TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps) then return true end
    local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
    H.BeginForcedRetreat(bot, safeLoc, 0.90)
    return true
end

function H.HandleGuaranteedAttackKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- Hitting a hero inside his T1 radius draws the tower onto us: only with an HP margin
    -- (>= 40 % and >= 3 tower shots) and not right after leaving the tower
    local underT1 = H.IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 then
        local hp = bot:GetHealth()
        if H.TowerBurnActive() or hp < bot:GetMaxHealth() * 0.40 or hp < 300 then return false end
    end
    if dist <= attackRange then
        H.IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        State.commitKillUntil = GameTime() + 2.5
        return true
    end
    if dist <= attackRange + 300 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 250)
        if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 35, enemyTowers, allyCreeps) then
            return true
        end
    end
    return false
end

function H.HandleGuaranteedRazeKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not canKill then return false end
    -- Do not cancel the swing of an attack that kills him anyway
    if H.IsHeroAttackWindupLocked(bot) then
        local oneShot = U.CanOneShotEnemyHero(bot, enemyHero)
        if oneShot then return false end
    end
    local ability = H.GetRazeAbilityByLabel(bot, razeLabel)
    if ability then
        local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
        local angleDiff = U.GetAngleDifference(bot, predLoc)
        if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
            bot:Action_UseAbility(ability)
            H.StartRazeCast(ability, enemyHero, predLoc, C.RAZE.HIT_RADIUS)
            H.ClearMoveCache()
            -- "Finish" commitment: for the next seconds we do not run or twitch
            State.commitKillUntil = GameTime() + 2.5
            return true
        else
            local botLoc = bot:GetLocation()
            local dir = (predLoc - botLoc):Normalized()
            local stepLoc = botLoc + dir * math.min(15, U.DistanceBetweenLocations(botLoc, predLoc))
            H.SmartMove(bot, stepLoc, 15)
            State.commitKillUntil = GameTime() + 2.5
            return true
        end
    end
    return false
end

function H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.5)
    end

    if not enemyIsHittingUs then return false end

    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local R = K._race

    -- I am weaker (level/souls/items/HP): the right-click trade is lost beforehand. Do not answer
    -- without support (my creeps/tower hitting him) - leave his attack radius toward our own
    -- creeps/tower. Chasing us while attacking, he loses distance (each attack = 0.5 s standing still)
    -- and his attack on a hero draws aggro from my creeps.
    if State.defensive and not H.HasTradeSupport(R) and not (R and R.valid and R.canKillSoon) then
        local enRange = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.KITE_PAD) or 140)
        if dist <= enRange then
            local botLoc = bot:GetLocation()
            local eLoc = enemyHero:GetLocation()
            local away = botLoc - eLoc
            if dist < 1 then away = P.GetT1Close(bot) - botLoc end
            away = away:Normalized()
            local toHome = (P.GetT1Close(bot) - botLoc):Normalized()
            local need = (enRange - dist) + 80
            local target = botLoc + (away * 0.6 + toHome * 0.4):Normalized() * need
            target = H.GetSafeApproach(bot, target, enemyTowers, allyCreeps)
            H.SmartMove(bot, target, 60)
            State.actionTaken = true
            return true
        end
        return false
    end

    if dist > bot:GetAttackRange() + 50 then return false end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < 0.25 then return false end

    if not H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then return false end

    H.IssueHeroAttack(bot, enemyHero)
    State.lastHarassTime = GameTime()
    State.lastAggroTime = GameTime()
    State.aggroPullTime = GameTime() + 0.25
    return true
end


-- Raze dodging (any band), sticky tango, zoning, pushing, intents

-- Dodge: the enemy is in a raze cast phase and we are inside his circle -> leave the circle directly
-- (pathfinding movement) if we make it in time; otherwise counter-raze (trade) if his raze is not lethal.
function H.HandleEnemyRazeDodge(bot, enemyHero)
    local now = GameTime()
    local label, elapsed, remaining = K.EnemyPhase()
    local race = K._race
    if U.CanQuery(enemyHero) and race and race.valid and race.spellWindow
        and (race.windowMyRazes or 0) >= 2 and (race.windowEnemyRazes or 0) <= 1
        and not race.heCanKillSoon and (not label or K.EnemyRazeDamage(bot, enemyHero, 1) < bot:GetHealth()-60)
        and not K.HasRazeStackLead(bot, enemyHero)
        and not State.forcedRetreatLoc and not State.survivalLoc and now >= (State.fleeUntil or 0) then
        State.dodgeLoc = nil
        State.dodgeUntil = 0
        return false
    end
    if State.dodgeLoc and now < State.dodgeUntil then
        -- While dodging we keep watching his cast: he may CANCEL the raze
        -- (we left the circle) and immediately cast another band - previously we blindly ran for 0.6 s toward
        -- the old point and took a new raze at point blank ("dodges slowly").
        local E = K._enemy
        local newCast = label and (label ~= State.dodgeLabel
            or math.abs((E.phaseStart or -1) - (State.dodgePhaseStart or -2)) > 0.01)
        local cancelled = (not label) and (now - (State.dodgePhaseStart or -10)) < (C.RAZE.CAST_POINT - 0.05)
        if newCast then
            State.dodgeLoc = nil -- Re-evaluated below
        elseif cancelled then
            State.dodgeLoc = nil
            State.dodgeUntil = 0
            return false
        else
            bot:Action_MoveToLocation(State.dodgeLoc)
            State.lastMoveLoc = State.dodgeLoc
            State.lastMoveTime = now
            State.actionTaken = true
            return true
        end
    end
    State.dodgeLoc = nil
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not label then return false end
    local center = K.EnemyRazeCenter(enemyHero, label)
    local botLoc = bot:GetLocation()
    local dFromCenter = U.DistanceBetweenLocations(botLoc, center)
    local R = C.RAZE.HIT_RADIUS
    if dFromCenter > R + 40 then return false end

    local dmg = K.EnemyRazeDamage(bot, enemyHero, 1)
    local myHp = bot:GetHealth()
    local lethal = dmg >= myHp
    local ms = bot:GetCurrentMovementSpeed() or 305
    local selfCasting = bot:IsUsingAbility() or bot:IsChanneling() or (State.aimingRaze ~= nil)

    local dir
    if dFromCenter < 1 then
        dir = (botLoc - enemyHero:GetLocation()):Normalized()
    else
        dir = (botLoc - center):Normalized()
    end
    -- Margin past the circle edge 45 u (was 70): the raze hits a unit's position within radius 250, the extra
    -- 25 u of margin made dodging "impossible" where it just barely fit (near raze)
    local escapeLoc = center + dir * (R + 45)
    local need = (R + 45) - dFromCenter
    -- Honest dodge time: minus the turn (0.03 * angle(rad) / 0.9: 180 degrees ~0.105 s)
    -- and the order delay. A failed dodge = we took the raze AND did not answer; when in doubt, answering is better.
    local turnAng = U.GetAngleDifference(bot, escapeLoc)
    local turnTime = 0.03 * math.rad(turnAng) / 0.9
    local canEscape = ((remaining - turnTime - 0.03) * ms * 0.95) >= need

    if canEscape and (not selfCasting or lethal) then
        if selfCasting then
            bot:Action_ClearActions(true)
            H.ClearRazeState()
        end
        State.dodgeLoc = escapeLoc
        State.dodgeUntil = now + remaining + 0.08
        State.dodgeLabel = label
        State.dodgePhaseStart = K._enemy.phaseStart
        bot:Action_MoveToLocation(escapeLoc)
        State.lastMoveLoc = escapeLoc
        State.lastMoveTime = now
        State.actionTaken = true
        return true
    end

    -- Cannot outrun it: answer with a raze (any band that hits) if his raze does not kill us
    -- But NOT during a clean flee - while fleeing we flee (turning = extra hits/coils)
    if not selfCasting and not lethal and bot:GetMana() >= 75
        and not (now < (State.fleeUntil or 0) and now >= (State.commitKillUntil or 0)) then
        for i = 1, 3 do
            local ab = H.GetRazeAbilityByLabel(bot, K.LABELS[i])
            if ab and U.IsRazeAbilityCastable(bot, ab) then
                local actionType, aimLoc = H.GetRazeActionType(bot, ab, enemyHero)
                if actionType and H.CastOrTurnRaze(bot, ab, actionType, aimLoc, enemyHero) then
                    return true
                end
            end
        end
    end
    return false
end

-- Sticky tango tree: pick once and keep it (COMMIT_TIME) until eaten / it became
-- dangerous / we got stuck. Filters: far from the enemy tower, not closer to the enemy, same height level.
function H.GetStickyTangoTree(bot, enemyHero, enemyTowers)
    local now = GameTime()
    local cfg = C.TANGO or {}
    local botLoc = bot:GetLocation()
    local enemyLoc = (enemyHero and U.CanQuery(enemyHero)) and enemyHero:GetLocation() or nil

    if State.tangoTree and State.tangoTreeLoc then
        local age = now - State.tangoChosenAt
        local d = U.DistanceBetweenLocations(botLoc, State.tangoTreeLoc)
        if d < State.tangoBestDist - 15 then
            State.tangoBestDist = d
            State.tangoProgressAt = now
        end
        local stuck = d > 165 and (now - (State.tangoProgressAt or State.tangoChosenAt)) > (cfg.STUCK_TIME or 4.0)
        local unsafe = enemyLoc and U.DistanceBetweenLocations(State.tangoTreeLoc, enemyLoc) < ((cfg.ENEMY_MIN_DIST or 650) - 150)
        if age <= (cfg.COMMIT_TIME or 8.0) and not stuck and not unsafe then
            return State.tangoTree, State.tangoTreeLoc
        end
        if stuck then
            State.tangoBadTree = State.tangoTree
            State.tangoBadTreeTime = now
        end
        State.tangoTree = nil
        State.tangoTreeLoc = nil
    end

    local trees = bot:GetNearbyTrees(cfg.SEARCH_RADIUS or 900)
    if not trees or #trees == 0 then return nil, nil end
    local myH = nil
    if type(GetHeightLevel) == "function" then myH = GetHeightLevel(botLoc) end
    local fountain = P.GetFountain(bot)

    local best, bestLoc, bestScore = nil, nil, math.huge
    for pass = 1, 2 do
        for _, tree in ipairs(trees) do
            local bad = (State.tangoBadTree == tree) and (now - State.tangoBadTreeTime) < 20
            if not bad then
                local loc = GetTreeLocation(tree)
                local ok = true
                for _, tower in pairs(enemyTowers or {}) do
                    if tower:IsAlive() and GetUnitToLocationDistance(tower, loc) < (cfg.TOWER_MIN_DIST or 1125) then
                        ok = false
                        break
                    end
                end
                if ok and enemyLoc and U.DistanceBetweenLocations(loc, enemyLoc) < (cfg.ENEMY_MIN_DIST or 650) then ok = false end
                if ok and pass == 1 and myH and GetHeightLevel(loc) ~= myH then ok = false end
                if ok then
                    local score = U.DistanceBetweenLocations(botLoc, loc)
                    score = score + U.DistanceBetweenLocations(fountain, loc) * 0.10
                    if enemyLoc then
                        score = score - math.min(400, U.DistanceBetweenLocations(loc, enemyLoc)) * 0.25
                    end
                    if score < bestScore then
                        bestScore, best, bestLoc = score, tree, loc
                    end
                end
            end
        end
        if best then break end
    end
    if best then
        State.tangoTree = best
        State.tangoTreeLoc = bestLoc
        State.tangoChosenAt = now
        State.tangoBestDist = math.huge
        State.tangoProgressAt = now
    end
    return best, bestLoc
end

function H.ClearTangoState()
    State.tangoTree = nil
    State.tangoTreeLoc = nil
    State.tangoCastAt = 0
end

-- Context + the intent FSM. Returns the intent.
-- "Hunt" (complaint: +400 HP against a low-HP enemy and the bot farms). Go for the kill when:
-- raze >= 2 points, absolute HP edge >= HUNT_HP_EDGE, my HP >= HUNT_MIN_HP_PCT, he is not under
-- his T1, his burst on me from mid range is not dangerous (HUNT_SAFETY_HP margin), my burst over
-- HUNT_HORIZON with an approach into the mid band (razes that come off cooldown; mana WITH mango;
-- 1-2 right clicks) covers his HP, and he is catchable. Hysteresis: while hunting the thresholds are softer.
function H.ComputeHunt(bot, s, race, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) or not race or not race.valid then return false end
    -- He is TPing back to his T1 (fresh, full) - do not fly in
    if (State.enemyTPIncomingUntil or 0) > s.now then return false end
    local cfg = C.INTENT or {}
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() < 2 then return false end
    local was = State.hunting and true or false
    local edgeNeed = (cfg.HUNT_HP_EDGE or 250) - (was and 60 or 0)
    if race.hpDiff < edgeNeed then return false end
    local myHp = race.myHp
    if (myHp / math.max(1, bot:GetMaxHealth())) < ((cfg.HUNT_MIN_HP_PCT or 0.40) - (was and 0.05 or 0)) then return false end
    if race.dist > ((cfg.HUNT_MAX_DIST or 1100) + (was and 150 or 0)) then return false end
    if race.heCanKillSoon then return false end
    local t1 = s and s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 760 then
            return false
        end
    end
    local dmg, n = K.MyHuntBurst(bot, enemyHero, cfg.HUNT_HORIZON or 4.0)
    if dmg < race.enHp + (was and -20 or 10) then return false end
    -- His answer during my finish: as many razes as I need (no more than his
    -- ready ones by cooldown/mana with mango), against my current stacks; right clicks are not counted - he is casting.
    -- His full 2.5 s burst (3 razes = ~970) is irrelevant here: he dies before the third.
    local hisReady = K.EnemyReadyRazeCount(enemyHero, 1.5, true)
    local hisN = math.min(math.max(n, 1), hisReady)
    local enBurst = K.EnemyRazeDamage(bot, enemyHero, hisN)
    if enBurst >= myHp - (cfg.HUNT_SAFETY_HP or 80) then return false end
    if not K.CanCatch(bot, enemyHero, C.RAZE.MID_CENTER + 200, 2.5) then return false end
    return true
end

function H.UpdateIntent(bot, s, race)
    local ctx = IntentCtx
    local enemyHero = s.enemy
    ctx.enemy = enemyHero ~= nil
    ctx.race = race
    ctx.myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    ctx.myRazes = K.MyReadyRazeCount(bot, true)
    ctx.healing = U.IsActivelyHealing(bot)
    ctx.enemyDist = s.enemyDist
    ctx.enemyAbsent = W.EnemyAbsent((C.INTENT and C.INTENT.ENEMY_ABSENT_SEC) or 5.0)
    -- A live enemy disappeared near the lane (highground/trees/fog) - most likely he is
    -- lurking, not gone. Do not count him as "absent" before 12 s.
    if ctx.enemyAbsent and s.enemyAlive and s.enemyLastLoc and s.enemyAbsentFor < 12.0 then
        if U.DistanceBetweenLocations(s.enemyLastLoc, bot:GetLocation()) < 1400 then
            ctx.enemyAbsent = false
        end
    end
    ctx.enemyDistToWave = enemyHero and LN.EnemyDistToAllyWave(enemyHero, s.allyCreeps) or 99999
    ctx.enemyUnderHisTower = false
    ctx.underEnemyTower = false
    local t1 = s.enemyT1
    if t1 then
        local okLoc, tLoc = pcall(t1.GetLocation, t1)
        if okLoc and tLoc then
            if enemyHero then
                ctx.enemyUnderHisTower = U.DistanceBetweenLocations(tLoc, enemyHero:GetLocation()) <= 720
            end
            ctx.underEnemyTower = LN.TowerDanger(bot, t1, s.allyCreeps, nil) >= 2
        end
    end
    ctx.canCatch = enemyHero and K.CanCatch(bot, enemyHero, C.RAZE.FAR_CENTER, 2.0) or false
    ctx.defensive = State.defensive and not H.HasTradeSupport(race)
    -- He is TPing to his T1 (channel visible / respawned after death)
    ctx.enemyTPIncoming = (State.enemyTPIncomingUntil or 0) > s.now
    ctx.enemyT1Dist = 99999
    if t1 then
        local okT1, t1Loc = pcall(t1.GetLocation, t1)
        if okT1 and t1Loc then
            ctx.enemyT1Dist = U.DistanceBetweenLocations(bot:GetLocation(), t1Loc)
        end
    end
    ctx.towerChaseBlocked = enemyHero ~= nil and State.towerChaseBlockedEnemy == enemyHero
    ctx.hunt = not ctx.towerChaseBlocked and H.ComputeHunt(bot, s, race, enemyHero)
    State.hunting = ctx.hunt
    local intent = I.Update(ctx, s.now)
    State.intent = intent
    if U.DEBUG and (s.now - State.lastIntentPrint) > 2.0 then
        State.lastIntentPrint = s.now
        print(string.format("[SF-BOT] intent=%s (%s) edge=%.0f myB=%.0f enB=%.0f dist=%.0f",
            intent, I.reason, race.valid and race.edge or 0, race.valid and race.myBurstSoon or 0,
            race.valid and race.enBurstSoon or 0, s.enemyDist))
    end
    return intent
end

-- Retreat under the RETREAT intent: get outside the enemy's ready bands toward our own T1.
-- If we are already far enough, do nothing (farming under the tower takes over).
function H.ExecuteRetreat(bot, enemyHero, race)
    -- We took the finish commitment - do not run
    if GameTime() < (State.commitKillUntil or 0) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local hp = bot:GetHealth()
    local critical = race.valid and race.enBurstNow >= hp
    H.BeginForcedRetreat(bot, safeLoc, critical and 1.0 or 0.6)
    return true
end

-- Zoning: stand between the enemy and our wave at HOLD_DIST (outside his near band), right-click him
-- when he is in attack range; do not leave the wave; do not stand in his READY bands.
function H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local cfg = C.ZONE or {}
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    -- 0) if he is in a band I can cast and mana allows - the raze (pressure) outranks positioning
    local canPressure = H.ShouldTryRazePressure(bot, enemyHero, "AGGRESSIVE", 0)
    if canPressure and dist <= C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS then
        if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return true end
    end
    local hold = cfg.HOLD_DIST or 520
    -- Do not stand in his ready band: push the distance past its edge
    local minSafe = race.valid and race.minSafeDist or 0
    if minSafe > hold then hold = minSafe end
    -- A right click if he is in range and it does not walk us into his ready band
    local attackRange = bot:GetAttackRange() + (cfg.ATTACK_RANGE_PAD or 40)
    if dist <= attackRange and dist >= minSafe - 30 then
        if H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) and not H.IsHeroAttackWindupLocked(bot) then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end
    local pos = LN.ZonePosition(bot, enemyHero, allyCreeps, hold, cfg.MAX_FROM_WAVE or 520)
    if not pos then return false end
    -- If the position requires closing on a fleeing enemy - do not run after him
    local dAfter = U.DistanceBetweenLocations(pos, enemyHero:GetLocation())
    if dAfter < dist - 60 and not K.CanCatch(bot, enemyHero, dAfter, 1.5) then
        return false
    end
    pos = H.GetSafeApproachLoose(bot, pos, enemyTowers or {}, allyCreeps or {})
    if GetUnitToLocationDistance(bot, pos) > 70 then
        return H.SmartMove(bot, pos, 45)
    end
    -- In place: hold the position (final positioning must not pull the bot away) but
    -- hand control over further on - items/regens must still run.
    State.holdPos = true
    return false
end

function H.HandleIncomingTeleport(bot, s)
    if bot:IsChanneling() then return false end
    local weak = bot:GetHealth() < bot:GetMaxHealth() * 0.55 or bot:GetMana() < 75
    if not weak then return false end
    local radius = C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 100
    for _, tp in pairs(s.incomingEnemyTPs or {}) do
        local distance = GetUnitToLocationDistance(bot, tp.location)
        if distance < radius then
            local away = bot:GetLocation() - tp.location
            if distance < 1 then away = P.GetFountain(bot) - tp.location end
            local point = tp.location + away:Normalized() * (radius + 80)
            point = H.GetSafeApproach(bot, point, s.enemyTowers, s.allyCreeps)
            if U.DistanceBetweenLocations(point, tp.location) < radius then
                point = tp.location + (P.GetFountain(bot)-tp.location):Normalized() * (radius+150)
                point = H.GetSafeApproach(bot, point, s.enemyTowers, s.allyCreeps)
            end
            if U.DistanceBetweenLocations(point, tp.location) < radius then
                local dir = away:Normalized()
                for _, side in ipairs({Vector(-dir.y,dir.x,0),Vector(dir.y,-dir.x,0),-dir}) do
                    local candidate = H.GetSafeApproach(bot, tp.location+side*(radius+150), s.enemyTowers, s.allyCreeps)
                    if U.DistanceBetweenLocations(candidate,tp.location) >= radius then point=candidate;break end
                end
            end
            State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, GameTime()+tp.time_remaining+0.5)
            H.ClearRazeState()
            State.commitKillUntil = 0
            return H.BeginForcedRetreat(bot, point, 0.5)
        end
    end
    return false
end

function H.HandleSeekAlliedWave(bot, s, race)
    State.waveScoutPoint = nil
    if #(s.allyCreeps or {}) > 0 then State.lastAlliedWaveSeen = GameTime(); return false end
    if GameTime() - (State.lastAlliedWaveSeen or -100) < 1.0 then return false end
    if State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc
        or GameTime() < (State.fleeUntil or 0) or bot:IsUsingAbility() or bot:IsChanneling()
        or U.IsActivelyHealing(bot) or bot:GetHealth() < bot:GetMaxHealth()*0.55 then return false end
    if (State.branchTango and GameTime()-State.branchTango.time<1.5)
        or State.needsTP or (GameTime()>20 and H.IsAtFountain(bot))
        or U.GetActiveItemByName(bot,"item_ward_observer")
        or (State.tangoTree and U.GetActiveItemByName(bot,"item_tango")) then return false end
    local scout = P.GetT1Close(bot, 500)
    for _, tp in pairs(s.incomingEnemyTPs or {}) do
        if GetUnitToLocationDistance(bot, tp.location) < 1300 or U.DistanceBetweenLocations(scout, tp.location) < 1300 then return false end
    end
    if s.enemyT1 and s.enemyT1:IsAlive() and GetUnitToLocationDistance(bot, s.enemyT1:GetLocation()) < 900 then return false end
    local point = scout
    if U.CanQuery(s.enemy) then
        if GetUnitToLocationDistance(s.enemy, point) < 1100 or GetUnitToLocationDistance(bot, s.enemy:GetLocation()) < 1100
            or (race and race.valid and race.heCanKillSoon) then return false end
    elseif s.enemyAlive and s.enemyLastLoc and (s.enemyAbsentFor or 0) < 5
        and U.DistanceBetweenLocations(point, s.enemyLastLoc) < 1200 then return false end
    if bot.GetIncomingTrackingProjectiles and #(bot:GetIncomingTrackingProjectiles() or {}) > 0 then return false end
    for _, creep in pairs(s.enemyCreeps or {}) do
        if U.CanQuery(creep) and creep:GetAttackTarget() == bot then return false end
    end
    for _, tower in pairs(s.enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(tower, point) < 900 then return false end
    end
    State.waveScoutPoint = point
    if GetUnitToLocationDistance(bot, point) > 45 then return H.SmartMove(bot, point, 30) end
    State.holdPos = true
    return false
end

function H.LaneEnemyAbsent(s)
    if s.enemyAlive == false then return true end
    if U.CanQuery(s.enemy) then return (s.enemyDist or 0) > 1800 and LN.EnemyDistToAllyWave(s.enemy, s.allyCreeps) > 1600 end
    local unseen = s.enemyAbsentFor or 0
    if unseen < 5 then return false end
    if unseen < 12 and s.enemyLastLoc and s.bot
        and U.DistanceBetweenLocations(s.enemyLastLoc, s.bot:GetLocation()) < 1400 then return false end
    return true
end

function H.PriorityPushAllowed(bot, s, race)
    if State.branchTango and GameTime()-State.branchTango.time<1.5 then return false end
    if State.needsTP or State.goingToFountain or State.forcedRetreatLoc or State.survivalLoc or GameTime() < (State.fleeUntil or 0)
        or bot:GetHealth() < bot:GetMaxHealth()*0.5 or U.IsActivelyHealing(bot) then return false end
    local teleports = s.incomingEnemyTPs or {}
    if #teleports == 0 and GameTime() < (State.enemyTPIncomingUntil or 0) then return false end
    for _, tp in pairs(teleports) do
        if GetUnitToLocationDistance(bot, tp.location) < 1800
            or (s.enemyT1 and GetUnitToLocationDistance(s.enemyT1, tp.location) < 1200) then return false end
    end
    if U.CanQuery(s.enemy) then
        local distance = GetUnitToLocationDistance(bot, s.enemy:GetLocation())
        if H.IsEnemyPressuring(bot, s.enemy) and distance < 1400 then return false end
        if K.HasRazeStackLead(bot,s.enemy) and K.EnemyBandsAcross(s.enemy,distance,distance,0.7)>0 then return false end
    end
    if H.LaneEnemyAbsent(s) then return true end
    return race and race.valid and not race.heCanKillSoon and race.edge >= (C.INTENT.PUSH_EDGE or 260)
        and s.enemyT1 ~= nil and GetUnitToLocationDistance(bot,s.enemyT1:GetLocation()) <= (C.PUSH.T1_ATTACK_RANGE or 900)
end

function H.HandleSiegeGlyph(bot, s, race)
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph") or not H.PriorityPushAllowed(bot, s, race)
        or not U.IsGlyphAvailable(bot) or GetUnitToLocationDistance(bot, tower:GetLocation()) > 900 then return false end
    if U.ShouldUseGlyphDefensive(bot, s.allyTowers) then return U.UseGlyph(bot) end
    local tank = tower:GetAttackTarget()
    if not U.CanQuery(tank) or tank == bot or (tank.IsHero and tank:IsHero())
        or tank:HasModifier("modifier_fountain_glyph") then return false end
    local allied = false
    for _, c in pairs(s.allyCreeps or {}) do if c == tank then allied = true; break end end
    if not allied or GetUnitToLocationDistance(tank, tower:GetLocation()) > 740 then return false end
    local hit = tank:GetActualIncomingDamage(tower:GetAttackDamage(), DAMAGE_TYPE_PHYSICAL)
    local imminent = tank:GetHealth() <= hit*1.35
    for _, projectile in pairs(tank:GetIncomingTrackingProjectiles() or {}) do
        if projectile.caster == tower and projectile.is_attack and tank:GetHealth() <= hit*2 then imminent = true end
    end
    if not imminent then return false end
    return U.UseGlyph(bot)
end

function H.HandleSiegeTower(bot, race, s)
    local tower = s.enemyT1
    if not U.CanQuery(tower) or tower:HasModifier("modifier_fountain_glyph") then return false end
    local distance = GetUnitToLocationDistance(bot, tower:GetLocation())
    if distance > (C.PUSH.T1_ATTACK_RANGE or 900) then return false end
    local finish = LN.IsTowerFinishable(bot, tower)
    if not finish then
        if bot:GetHealth() < bot:GetMaxHealth()*0.5 or H.TowerBurnActive() or tower:GetAttackTarget() == bot then return false end
        local point = tower:GetLocation() + (bot:GetLocation()-tower:GetLocation()):Normalized() * math.max(100,bot:GetAttackRange()-25)
        if U.CanQuery(s.enemy) and not K.StackLeadStepSafe(bot,s.enemy,point) then return false end
        if not LN.CanHitTower(bot, tower, s.allyCreeps, 1)
            or LN.TowerShieldCount(tower, s.allyCreeps, point) < 1 then return false end
        if U.CanQuery(s.enemy) and (not race.valid or race.heCanKillSoon or H.IsEnemyPressuring(bot,s.enemy)
            or (race.edge < (C.INTENT.PUSH_EDGE or 260) and not LN.EnemyBusyWithWave(bot,s.enemy)
                and GetUnitToLocationDistance(bot,s.enemy:GetLocation()) <= 950)) then return false end
    end
    State.prepTarget = nil; State.lhAttackTarget = nil
    if bot:GetAttackTarget() ~= tower or bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK then
        bot:Action_AttackUnit(tower, false)
        H.ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

function H.HandlePriorityPush(bot, s, race)
    if State.actionTaken or bot:IsUsingAbility() or bot:IsChanneling() or not H.PriorityPushAllowed(bot,s,race) then return false end
    if H.HandleSiegeGlyph(bot,s,race) then State.actionTaken=true;return true end
    if H.HandleEnemyTowerSafety(bot,s,s.enemy) then return true end
    if H.HandleSiegeTower(bot,race,s) then return true end
    if not H.LaneEnemyAbsent(s) then return false end
    -- Only a real siege displaces last hits/denies; ordinary wave push fills their gaps.
    local enemyAttackers = U.MergeLists(s.enemyCreeps,s.enemyTowers)
    local allyAttackers = U.MergeLists(s.allyCreeps,s.allyTowers)
    local target, deny = L.GetBestTarget(bot,s.enemyCreeps,s.allyCreeps,enemyAttackers,allyAttackers,false)
    if target and U.GetTimeToKillable(bot,target,deny and enemyAttackers or allyAttackers) <= 1.2 then return false end
    if not LN.BestPushCreep(bot,s.enemyCreeps,(C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700,s.allyCreeps) then return false end
    State.prepTarget=nil;State.lhAttackTarget=nil
    return H.ExecutePush(bot,s.enemy,race,s,true)
end

function H.ExecutePush(bot, enemyHero, race, s, priority)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local enemyCreeps, allyCreeps, enemyTowers = s.enemyCreeps, s.allyCreeps, s.enemyTowers
    local t1 = s.enemyT1
    local myHpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    local now = GameTime()

    if priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 1) enemy creeps nearby -> hit the "fat" ones (low HP is the last-hit zone, do not push-hit there)
    local pushCreep = LN.BestPushCreep(bot, enemyCreeps, (C.PUSH and C.PUSH.PUSH_ATTACK_RANGE) or 700, allyCreeps)
    -- The current push target dropped into the last-hit zone: stop attacking it continuously
    if not priority and bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK then
        local cur = bot:GetAttackTarget()
        if cur and U.CanQuery(cur) and not (cur.IsHero and cur:IsHero()) and not (cur.IsTower and cur:IsTower())
            and State.lhAttackTarget ~= cur and (cur:GetHealth() or 0) <= LN.PushHpFloor(bot, cur, allyCreeps) then
            if pushCreep == cur then pushCreep = nil end
            if not pushCreep then
                bot:Action_ClearActions(false)
                H.ClearMoveCache()
                State.actionTaken = true
                return true
            end
        end
    end
    if pushCreep then
        if H.IsSafeToAttack(bot, pushCreep:GetLocation(), enemyTowers, allyCreeps) then
            if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= pushCreep then
                bot:Action_AttackUnit(pushCreep, false)
                H.ClearMoveCache()
            end
            State.actionTaken = true
            return true
        end
    end

    if not priority and H.HandleSiegeTower(bot, race, s) then return true end

    -- 4) move forward with the wave (behind the front creep) if there are creeps
    local front = LN.FrontAllyCreep(bot, allyCreeps)
    if front then
        local fountain = P.GetFountain(bot)
        local dir = (fountain - front:GetLocation()):Normalized()
        local pos = front:GetLocation() + dir * 300
        pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
        -- "Moving with the wave" never walks under the T1: without a tower hit (item 2) there is nothing
        -- to do inside its radius (the creeps die - the tower switches to us). Stay >= 800.
        if t1 and t1:IsAlive() then
            local okTL, tl = pcall(t1.GetLocation, t1)
            if okTL and tl then
                local keep = ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) + 20
                if U.DistanceBetweenLocations(pos, tl) < keep then
                    pos = tl + (pos - tl):Normalized() * keep
                end
            end
        end
        if GetUnitToLocationDistance(bot, pos) > 120 then
            return H.SmartMove(bot, pos, 60)
        end
        State.holdPos = true -- In place behind the wave: do not let the final positioning pull us back
        return false
    end
    return false
end

function H.RealThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    State.actionTaken = false
    State.combatPolicyActive = false
    State.holdPos = false
    U.BeginPredictionFrame()

    -- World snapshot + the enemy raze tracker (every tick, before any decision)
    local s = W.Update(bot)
    K.UpdateEnemyTracker(bot, s.enemy)
    H._enemyHeroNear = s.enemy -- GetSafeApproach accounts for the enemy when going under the tower
    -- The hit/miss tracker for his razes - before decisions (the instant mirror reads it)
    if s.enemy then U.UpdateEnemyRazeMissTracker(bot, s.enemy) end

    -- A visible channel/respawn gives a conservative arrival warning only when
    -- no actual visible landing point is available. It is not a known destination.
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemy and U.IsEnemyTPChanneling(s.enemy) then
        State.enemyTPIncomingUntil = s.now + 3.0
    end
    if #(s.incomingEnemyTPs or {}) == 0 and s.enemyAlive and State.enemyWasAlive == false then
        State.enemyTPIncomingUntil = math.max(State.enemyTPIncomingUntil or 0, s.now + 6.0)
    end
    State.enemyWasAlive = s.enemyAlive

    -- A TP channel is running - no orders (any order cancels the teleport to the T1)
    if bot:IsChanneling() then
        State.actionTaken = true
        return
    end

    if H.HandleEmergencyConsumables(bot, nil, s) then return end
    if H.HandleIncomingTeleport(bot, s) then return end
    if H.HandlePostKillReset(bot, s) then return end
    if H.HandleWinningDryDuel(bot, s.enemy, s) then return end
    if H.HandleDryLastStand(bot,s.enemy,s) then return end
    H.LevelUpAbilities(bot)
    local earlyRace = K.Race(bot, s.enemy, false, s)
    if H.HandleShortCombatCast(bot,s.enemy,s) then return end
    if H.HandleSafeRazeReply(bot,s.enemy,s) then return end
    if H.HandleReplyFarFollowup(bot,s.enemy,s) then return end
    if H.HandleManaCycleContinuation(bot,s.enemy,s) then return end
    if H.HandleContactTrade(bot,s.enemy,s) then return end

    -- A committed retreat owns the tick, not just the movement phase.
    -- No mirror, turn-to-kill, dodge counterattack or creep attack may replace it.
    if State.forcedRetreatLoc and GameTime() < (State.forcedRetreatUntil or 0) then
        H.SmartMove(bot, State.forcedRetreatLoc, 60)
        return
    elseif State.forcedRetreatLoc then
        H.ClearForcedRetreat()
    end

    if H.HandleSurvivalRetreat(bot, s.enemy, earlyRace) then return end
    if H.HandleSeekAlliedWave(bot, s, earlyRace) then return end
    if H.HandlePriorityPush(bot, s, earlyRace) then return end
    if H.UpdateTowerChase(bot, s) then return end
    if H.HandleStackLead(bot, s, earlyRace) then return end
    H.UpdateDefensive(bot, s, earlyRace)
    State.enemyAggroCount = 0
    for _, creep in pairs(s.allyCreeps or {}) do
        if s.enemy and U.CanQuery(creep) and creep:GetAttackTarget() == s.enemy then
            State.enemyAggroCount = State.enemyAggroCount + 1
        end
    end
    State.combatPolicyActive = true
    State.heroCombatAllowed = State.towerChaseBlockedEnemy ~= s.enemy
        and (H.ShouldEngageHero(bot, s.enemy, earlyRace)
            or H.IsEnemyPressuring(bot, s.enemy)
            or (earlyRace.valid and earlyRace.canKillNow))
    if H.HandleIncomingHeroPressure(bot, s, earlyRace) then return end
    if State.heroCombatAllowed and not State.goingToFountain
        and GameTime() >= (State.fleeUntil or 0) then
        local previous = State.intent
        State.intent = I.TRADE
        local acted = H.RunCombatPriority(bot, s, earlyRace)
        State.intent = previous
        if acted then return end
    end

    if H.HandleActiveRazeValidation(bot) then return end

    -- A guaranteed finish comes before dodging and everything else: if we can kill
    -- him with a raze/click right now - kill immediately, do not postpone it for seconds
    if s.enemy then
        if H.HandleGuaranteedRazeKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
        if H.HandleGuaranteedAttackKill(bot, s.enemy, s.enemyTowers, s.allyCreeps) then return end
    end

    -- Dodging the enemy raze outranks even our own cast (if the raze is lethal)
    if H.HandleEnemyRazeDodge(bot, s.enemy) then return end

    if bot:IsUsingAbility() then return end

    H.ProcessTelemetry(bot)

    -- Power Treads are handled by H.ManageTreads - on an idle tick (end of RealThink),
    -- on the first retreat tick (strength) and on the tick before a raze cast (intelligence). The old call
    -- here issued a switch order EVERY tick and overrode the combat orders.

    local enemyHero = s.enemy

    -- The race (absolute HP, razes available to both sides) and the intent for the tick
    local race = earlyRace
    local intent = H.UpdateIntent(bot, s, race)

    -- A swing at the hero is in progress - let it land (see ShouldHoldForHeroWindup)
    H.UpdateAttackActivity(bot)
    if enemyHero and H.ShouldHoldForHeroWindup(bot, s, enemyHero, race) then
        State.actionTaken = true
        return
    end

    -- Emergency consumables (faerie/wand/mango for a finish) - right after the swing,
    -- before salves and retreats
    if H.HandleEmergencyConsumables(bot, race) then return end

    if H.HandleActiveSalveSafety(bot, enemyHero) then return end
    if H.HandleEnemyNearRazeCounter(bot, enemyHero) then return end
    if enemyHero and H.HandleInstantMirrorRaze(bot, enemyHero, race, s) then return end

    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
    end
    if enemyHero and U.CanQuery(enemyHero) and U.EnemyHasRaze(enemyHero) then
        if bot:GetLevel() < 2 and enemyHero:GetLevel() >= 2 then
            State.enemyReachedLevel2First = true
        end
    end

    -- (Guaranteed finishes moved up - before dodging and the swing)
    if H.HandleReturnTP(bot) then return end

    -- Defence against the enemy T1 - before everything else
    if H.HandleEnemyTowerSafety(bot, s, enemyHero) then return end

    -- The enemy T1 is nearly down - finish it before any retreat or last hit
    if H.HandleEnemyTowerFinish(bot, s, enemyHero) then return end

    if H.HandleEmergencyRetreat(bot, enemyHero) then return end

    -- RETREAT intent: get out of the enemy's ready bands (his available burst is lethal)
    if intent == I.RETREAT and enemyHero then
        if H.ExecuteRetreat(bot, enemyHero, race) then return end
    end

    if H.HandleForcedSalve(bot) then return end
    if H.HandleFountainRecall(bot) then return end

    -- The intent is still RETREAT but we are already at a safe distance (ExecuteRetreat
    -- returned false). Previously control fell through to last hits/prehit - those turned
    -- the bot toward the creep pack, the enemy caught up, run again - a crooked zigzag instead of leaving.
    -- Keep a clean step straight away from the enemy while he is near.
    if intent == I.RETREAT and enemyHero and U.CanQuery(enemyHero) and not State.actionTaken then
        local bLoc, eLoc = bot:GetLocation(), enemyHero:GetLocation()
        local d = U.DistanceBetweenLocations(bLoc, eLoc)
        if d < 1100 and d >= 1 then
            H.SmartMove(bot, bLoc + (bLoc - eLoc):Normalized() * 160, 60)
            return
        end
    end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local mpPct = bot:GetMana() / bot:GetMaxMana()
    local flask = U.GetActiveItemByName(bot, "item_flask")
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    local hasMango = U.HasItem(bot, "item_enchanted_mango")
    local isHealing = bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_clarity_potion")
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50

    if bot:HasModifier("modifier_clarity_potion") and not bot:HasModifier("modifier_flask_healing") and myHpPct >= returnHpPct then
        isHealing = false
        H.ClearForcedRetreat()
    end

    local needsFlask = (myHpPct < 0.5 and flask and not isHealing)
    local needsClarity = (mpPct < 0.4 and clarity and not isHealing and not hasMango)

    if isHealing or needsFlask or needsClarity then
        local fountain = P.GetFountain(bot)
        local dangerRange = 850
        if enemyHero and enemyHero:GetUnitName() == "npc_dota_hero_nevermore" then
            if bot:HasModifier("modifier_flask_healing") or needsFlask then
                dangerRange = C.REGEN.FLASK_SAFE_DISTANCE or 1150
            else
                dangerRange = C.REGEN.ENEMY_SAFE_DISTANCE or 1100
            end
        end
        if H.IsInDangerForRegen(bot, dangerRange) then
            local moveLoc = P.GetT1Close(bot)
            if enemyHero then
                local dir = (fountain - enemyHero:GetLocation()):Normalized()
                moveLoc = enemyHero:GetLocation() + dir * dangerRange
            end
            H.BeginForcedRetreat(bot, moveLoc, 0.85)
            return
        end
        if needsFlask and GameTime() > State.lastItemUseTime + 0.3 then
            if H.HasEnemyProjectileIncoming(bot) then
                local safeLoc = H.GetSalveSafeRetreatLocation(bot, enemyHero)
                H.BeginForcedRetreat(bot, safeLoc, 0.65)
                return
            end
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return
        elseif needsClarity and GameTime() > State.lastItemUseTime + 0.3 then
            bot:Action_UseAbilityOnEntity(clarity, bot)
            State.lastItemUseTime = GameTime()
            return
        elseif isHealing then
            -- Lists from the world snapshot (filtered through CanQuery - no creeps in fog)
            local enemyCreepsNearby = s.enemyCreeps or {}
            local allyCreepsNearby = s.allyCreeps or {}
            if #allyCreepsNearby == 0 then
                local targetPos = P.GetT1Close(bot)
                if GetUnitToLocationDistance(bot, targetPos) > 45 then
                    H.SmartMove(bot, targetPos, 60)
                end
            elseif bot:HasModifier("modifier_flask_healing") then
                local safeLoc = P.GetLasthitPosition(bot, enemyCreepsNearby, allyCreepsNearby, nil, "PASSIVE")
                if enemyHero and U.CanQuery(enemyHero) then
                    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
                    if distToEnemy < dangerRange then
                        local dir = (fountain - enemyHero:GetLocation()):Normalized()
                        safeLoc = enemyHero:GetLocation() + dir * dangerRange
                    end
                end
                if not H.IsInDangerForRegen(bot, dangerRange) then
                    H.SmartMove(bot, safeLoc, 60)
                end
            end
            if State.actionTaken or #allyCreepsNearby == 0 or bot:HasModifier("modifier_flask_healing") then return end
        end
    end

    local enemyCreeps = s.enemyCreeps
    local allyCreeps = s.allyCreeps
    local enemyTowers = s.enemyTowers
    local allyTowers = s.allyTowers
    local enemyAttackers = U.MergeLists(enemyCreeps, enemyTowers)
    local allyAttackers = U.MergeLists(allyCreeps, allyTowers)
    -- The enemy hero also hits creeps (finishes his own = deny, finishes mine). His attack
    -- is accounted for in the target HP forecast (GetAttackTarget() == target): the "safe" last-hit window
    -- closes with his attack -> hit earlier/immediately instead of waiting for a moment he takes.
    if enemyHero and U.CanQuery(enemyHero) then
        table.insert(enemyAttackers, enemyHero)
        table.insert(allyAttackers, enemyHero)
    end
    local enemyNearWave = enemyHero ~= nil and s.enemyDist <= 1300

    U.UpdateAllyCreepHealthTracking(allyCreeps)


    local current_mode = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if State.defensive then current_mode = "PASSIVE" end
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local enemyMissedAggro = enemyMissed and bot:GetLevel() > 1
    if bot:GetLevel() <= 1 and enemyMissed and current_mode == "AGGRESSIVE" then
        current_mode = "NEUTRAL"
    end

    if H.HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then return end
    if H.HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps) then return end

    local inKillThreat = U.IsInEnemyRazeKillThreat(bot, enemyHero)
    local secondStackActive, secondStackLabel = false, nil
    if enemyHero then
        secondStackActive, secondStackLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    end

    if enemyHero and secondStackActive and secondStackLabel == "near" then
        if H.HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if inKillThreat then
        if H.HandleSafeDistanceFromEnemy(bot, enemyHero) then return end
    end

    U._midFear = (enemyHero ~= nil) and H.MidRazeFearActive(bot, enemyHero) or false
    if enemyHero and H.HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero) then return end
    if enemyHero and H.HandleDryManaMidRazeAvoidance(bot, enemyHero) then return end

    -- Stacks on us: the decision is based on the enemy's available burst and absolute HP (not "2 stacks = run").
    -- If his razes are on cooldown / out of mana / the band is out of reach - keep pressing.
    if enemyHero then
        local shouldFear, fearLoc = U.ShouldRetreatFromEnemyRazeStack(bot, enemyHero)
        if shouldFear and fearLoc then
            H.BeginForcedRetreat(bot, fearLoc, 0.80)
            return
        end
    end

    if enemyHero and H.HandleBootDisadvantageMidRazeFear(bot, enemyHero) then return end

    local mustRetreatFromT1Soon = U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not mustRetreatFromT1Soon and s.enemyT1 then
        -- The shield is gone (creeps ran off after the enemy / died) and we are still inside the tower radius
        local okLoc, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okLoc and tLoc and U.DistanceBetweenLocations(tLoc, bot:GetLocation()) <= ((C.TOWER and C.TOWER.SAFE_RADIUS) or 780) then
            if LN.TowerDanger(bot, s.enemyT1, allyCreeps, nil) >= 2 then
                mustRetreatFromT1Soon = true
            end
        end
    end
    if mustRetreatFromT1Soon and not H.ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
        and not (s.enemyT1 and LN.IsTowerFinishable(bot, s.enemyT1)) then
        -- Do NOT spend the glyph just to get out of the tower (an accidental entry into the T1 radius without a finish
        -- burned the glyph for 5 minutes) - just walk out
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    if enemyHero and not inKillThreat then
        if H.HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and H.GetPotentialCombatMana(bot) >= 150 and not inKillThreat then
        local q = bot:GetAbilityByName("nevermore_shadowraze1")
        if q and q:GetLevel() > 0 then
            local dmg2 = U.GetTwoRazeDamage(bot, enemyHero)
            local lethal = dmg2 >= enemyHero:GetHealth()
            local Rr = K._race
            if Rr and Rr.valid then
                -- Only razes that are REALLY available (cooldowns/mana), not "two razes by formula"
                lethal = Rr.canKillSoon
            end
            if intent == I.RETREAT then lethal = false end
            if lethal then
                local myBoots = U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")
                local eBoots = U.HasItem(enemyHero, "item_boots") or U.HasItem(enemyHero, "item_power_treads")
                local canChase = myBoots and not eBoots
                local chaseTargetLoc = enemyHero:GetLocation()
                local isSafeChase = true
                for _, tower in pairs(enemyTowers) do
                    if tower:IsAlive() then
                        local name = tower:GetUnitName() or ""
                        if name:find("tower2") or name:find("tower3") or name:find("tower4") then
                            if GetUnitToLocationDistance(tower, chaseTargetLoc) < 850 then
                                isSafeChase = false
                                break
                            end
                        end
                    end
                end
                local glyphActive = State.glyphUsedForDive and (GameTime() - State.glyphDiveTime) < 5.0
                local normalSafe = (H.GetSafeApproachLoose(bot, chaseTargetLoc, enemyTowers, allyCreeps) == chaseTargetLoc)
                -- His T1 is busy with our creep (>= 2 shots), HP >= 50%, his burst is not lethal:
                -- razes under the tower give no aggro - the finish is allowed
                local towerLockedSafe = isSafeChase and H.TowerLockedOnCreep(s.enemyT1)
                    and myHpPct >= 0.5 and not (Rr and Rr.valid and Rr.heCanKillSoon)
                    and not H.TowerBurnActive()
                if (canChase and isSafeChase) or normalSafe or glyphActive or towerLockedSafe then
                    if H.HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, true, false) then
                        return
                    end
                end
            end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreeps, enemyCreeps) then return end
    end

    if enemyHero and not inKillThreat and secondStackActive then
        if secondStackLabel == "mid" then
            if H.HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        elseif secondStackLabel == "near" then
            if H.HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        end
    end

    if enemyHero and not inKillThreat then
        if H.HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if H.ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    local ward = U.GetActiveItemByName(bot, "item_ward_observer")
    if ward and not H.ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then
        local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        local distToWard = GetUnitToLocationDistance(bot, wardLoc)
        if distToWard > 450 then
            H.SmartMove(bot, wardLoc, 60)
        else
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            H.ClearMoveCache()
        end
        return
    end

    local aggroCount = 0
    local closeCreepsCount = 0
    local hasRangedAggro = false
    local is_taking_damage = bot:WasRecentlyDamagedByCreep(1.5)
    -- How many of MY creeps are hitting the enemy hero (support in the trade)
    local enemyAggroCount = 0
    if enemyHero and U.CanQuery(enemyHero) then
        for _, c in pairs(allyCreeps) do
            if U.CanQuery(c) and c:GetAttackTarget() == enemyHero then enemyAggroCount = enemyAggroCount + 1 end
        end
    end
    State.enemyAggroCount = enemyAggroCount
    for _, c in pairs(enemyCreeps) do
        if c:IsAlive() then
            if U.CanQuery(c) and c:GetAttackTarget() == bot then
                aggroCount = aggroCount + 1
                local name = c:GetUnitName() or ""
                if name:find("ranged") or name:find("siege") then hasRangedAggro = true end
            end
            if GetUnitToLocationDistance(bot, c:GetLocation()) < 350 then
                closeCreepsCount = closeCreepsCount + 1
            end
        end
    end

    if U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero) then
        local safeLoc = H.GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        H.BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    local is_under_my_tower = false
    for _, t in pairs(allyTowers) do
        if GetUnitToLocationDistance(bot, t:GetLocation()) < 850 then
            is_under_my_tower = true
            break
        end
    end

    if GameTime() > State.deaggroTime then
        local should_deaggro = false
        if allyCreeps and #allyCreeps > 0 then
            -- Drop aggro only when the creeps are REALLY hitting us (>= 2 creeps, or 1 + damage, or
            -- a ranged + damage). The old condition "2 enemy creeps closer than 350" triggered on any
            -- last hit near the wave: CLEAR + "attack own creep" + a 400 back-off every 1.2 s ->
            -- lost last hits and twitching toward the tower.
            if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) or (hasRangedAggro and is_taking_damage) then
                should_deaggro = true
            end
        else
            if is_under_my_tower and bot:GetHealth() > 300 then
                if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) then
                    should_deaggro = true
                end
            else
                if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) or hasRangedAggro then
                    should_deaggro = true
                end
            end
        end
        if should_deaggro then
            bot:Action_ClearActions(false)
            H.ClearMoveCache()
            State.heroAttackTarget = nil
            State.heroAttackTime = 0
            local fountain = P.GetFountain(bot)
            if allyCreeps and #allyCreeps > 0 then
                local closestAlly = allyCreeps[1]
                local minDist2 = 9999
                for _, c in pairs(allyCreeps) do
                    local d = GetUnitToLocationDistance(bot, c:GetLocation())
                    if d < minDist2 then
                        minDist2 = d
                        closestAlly = c
                    end
                end
                local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 400
                bot:ActionQueue_AttackUnit(closestAlly, true)
                bot:ActionQueue_MoveToLocation(safe_pos)
                State.deaggroTime = GameTime() + 1.2
            else
                local kite_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 300
                bot:Action_MoveToLocation(kite_pos)
                State.deaggroTime = GameTime() + 0.6
            end
            return
        end
    end

    if GameTime() < State.aggroPullTime then
        if H.IsHeroAttackWindupLocked(bot) then return end
        if H.IsInHeroAttackAnimation(bot) then return end
        H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
        return
    end

    local bestTarget, isDeny = L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers, enemyNearWave)
    -- Do not take a last hit that requires entering his ready band in a bad trade:
    -- otherwise it is an endless "approach for the creep - get scared - back off", and every approach is his raze on us.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) then
        local fearMin = U.GetFearMinDist(bot, enemyHero)
        if fearMin > 0 then
            local eLoc = enemyHero:GetLocation()
            local cLoc = bestTarget:GetLocation()
            local botD = U.DistanceBetweenLocations(bot:GetLocation(), eLoc)
            local inRangeNow = GetUnitToLocationDistance(bot, cLoc) <= bot:GetAttackRange() + 20
            local creepD = U.DistanceBetweenLocations(cLoc, eLoc)
            if not (inRangeNow and botD >= fearMin - 40) and creepD < fearMin - bot:GetAttackRange() + 40 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Do not walk for a creep into a point where his available burst (ready bands + right clicks)
    -- kills me: otherwise "approached for the creep -> became lethal -> RETREAT for 1 s -> came back"
    -- in a loop every 2-3 s (twitching). Take only what is reachable from a non-lethal distance.
    if bestTarget and enemyHero and U.CanQuery(enemyHero) and race.valid and not race.canKillNow then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        local atkD = U.DistanceBetweenLocations(atkPos, eLoc)
        local curD = U.DistanceBetweenLocations(bLoc, eLoc)
        if atkD < curD - 30 then
            local burst = K.EnemyBurstVs(bot, enemyHero, atkD, 2.5, false)
            if burst >= bot:GetHealth() - 20 then
                bestTarget, isDeny = nil, false
            end
        end
    end
    -- Defence (clearly weaker, no creep/tower support): do not enter his attack
    -- radius for a last hit - every entry is 1-2 of his hits (70+ per hit with 20 souls and bracers), a creep
    -- is not worth that. Take only what is reachable from outside his radius, or while he is busy with the wave.
    local myHpPctNow = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if bestTarget and enemyHero and State.defensive and race.valid and race.weakerSustained
        and U.CanQuery(enemyHero) and not H.HasTradeSupport(race) then
        local eLoc = enemyHero:GetLocation()
        local cLoc = bestTarget:GetLocation()
        local bLoc = bot:GetLocation()
        local myRange = bot:GetAttackRange()
        local hisReach = (enemyHero:GetAttackRange() or 525) + ((C.DEFENSE and C.DEFENSE.CONTEST_PAD) or 80)
        local atkPos = bLoc
        if U.DistanceBetweenLocations(bLoc, cLoc) > myRange - 20 then
            atkPos = cLoc + (bLoc - cLoc):Normalized() * (myRange - 30)
        end
        -- Skip a creep only if it is really pressuring us (hitting us / hit us in the last
        -- 3 s) or we are low with his raze ready. Merely "standing by the wave" is no reason to give up
        -- all the farm: previously a weaker bot with that rule took not a single creep.
        local pressing = false
        if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then pressing = true end
        if not pressing and bot.WasRecentlyDamagedByHero then
            pressing = bot:WasRecentlyDamagedByHero(enemyHero, 3.0) and true or false
        end
        if not pressing and myHpPctNow <= 0.45 and (race.enRazesSoon or 0) >= 1 then
            pressing = true
        end
        if pressing and U.DistanceBetweenLocations(atkPos, eLoc) <= hisReach and not LN.EnemyBusyWithWave(bot, enemyHero) then
            bestTarget, isDeny = nil, false
        end
    end
    local bestTargetTime = 999
    if bestTarget then
        bestTargetTime = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
    end
    local lasthitImminent = bestTarget ~= nil and bestTargetTime >= 0 and bestTargetTime <= 1.2

    local am_i_tanking_too_much = false
    if not allyCreeps or #allyCreeps == 0 then
        if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) then am_i_tanking_too_much = true end
    else
        if aggroCount >= 3 or (aggroCount >= 2 and bot:GetHealth() < 400) then am_i_tanking_too_much = true end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then
        if aggroCount <= 1 then am_i_tanking_too_much = false end
    end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            local fountain = P.GetFountain(bot)
            local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 250
            H.SmartMove(bot, safe_pos, 60)
            return
        end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then am_i_tanking_too_much = false end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            H.SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        if H.HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and U.IsEnemyHighValueRegen(enemyHero) then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if bot:GetMana() >= 75 and distToEnemy <= 1100 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
        local attackRange = bot:GetAttackRange() + 60
        if distToEnemy <= attackRange then
            if myHpPct > 0.30 and H.IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
                H.IssueHeroAttack(bot, enemyHero)
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return
            end
        elseif distToEnemy <= C.HARASS.INTERRUPT_APPROACH and myHpPct > 0.40 and H.GetPotentialCombatMana(bot) >= 75 then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local approachLoc = botLoc + dir * math.min(distToEnemy - attackRange + 50, 400)
            approachLoc = U.ClampMinDistFromEnemy(bot, enemyHero, approachLoc)
            if H.ApproachEnemyPoint(bot, enemyHero, approachLoc, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
        -- Extending 2 stacks is a combo continuation: allowed with a favourable trade or by the mana reserve
        local extendOk = (race.valid and race.edge >= 0 and bot:GetMana() >= 75) or H.HarassManaOK(bot, race)
        if eStacks >= 2 and eRem <= C.RAZE.EXTEND_AT + 0.6 and extendOk and not State.defensive then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and enemyMissedAggro
        and H.HarassManaOK(bot, race) and not State.defensive then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if distToEnemy <= 950 then
            if H.TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    -- ZONE: keep the enemy away from our wave (if no last hit is available right now)
    if intent == I.ZONE and enemyHero and not lasthitImminent and not am_i_tanking_too_much and not inKillThreat then
        if H.ExecuteZoning(bot, enemyHero, race, allyCreeps, enemyTowers) then return end
    end

    if H.HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero) then return end

    -- prepTarget (the creep for a "pre-hit") was NEVER reset (except by ForceExtend):
    -- after the first pre-hit, harass, push and the pre-hit itself were disabled forever while the dead handle
    -- was queried every tick. Reset when: the target is dead/invisible, the hit landed, or > 2.5 s passed.
    if State.prepTarget then
        local pt = State.prepTarget
        local age = GameTime() - (State.prepTargetTime or 0)
        if not U.CanQuery(pt) or age > 2.5
            or (bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK and age > 0.6) then
            State.prepTarget = nil
            State.prepTargetTime = 0
        end
    end

    -- The enemy projectile is already flying at the creep, his hit is not enough to finish it, and after
    -- it lands the creep becomes mine - send our attack RIGHT AFTER his projectile.
    if H.HandleProjectileSnipe(bot, enemyCreeps, enemyHero, enemyTowers, allyCreeps) then return end

    local is_free_to_prehit = true
    if bestTarget then
        local t_killable = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
        if t_killable < (bot:GetSecondsPerAttack() + 0.3) then is_free_to_prehit = false end
    end

    local prehit_target = nil
    if is_free_to_prehit and not State.prepTarget and not am_i_tanking_too_much then
        local attack_cd = bot:GetSecondsPerAttack()
        for _, c in pairs(enemyCreeps) do
            if U.CanQuery(c) then
                local in_tower_range = false
                for _, t in pairs(allyTowers) do
                    if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                        in_tower_range = true
                        break
                    end
                end
                -- "HP shaping": the pre-hit is allowed outside our own tower too if the enemy cannot
                -- punish it (far from the creep / busy with the wave / no ready razes) and we are not under his T1.
                local prehit_ok = in_tower_range
                if not prehit_ok and (C.LASTHIT.PREHIT_ANYWHERE ~= false) and not inKillThreat and not State.defensive then
                    local eFar = true
                    if enemyHero and U.CanQuery(enemyHero) then
                        local dce = U.DistanceBetweenLocations(c:GetLocation(), enemyHero:GetLocation())
                        local R = K._race
                        eFar = dce > 850 or LN.EnemyBusyWithWave(bot, enemyHero) or (R and R.valid and R.enRazesSoon == 0)
                    end
                    local underEnemyTower = false
                    for _, t in pairs(enemyTowers) do
                        if t:IsAlive() and GetUnitToLocationDistance(t, c:GetLocation()) < 800 then underEnemyTower = true break end
                    end
                    prehit_ok = eFar and not underEnemyTower
                end
                if prehit_ok then
                    local myDmg = U.SFDamageRange(bot, c).min
                    local hp = c:GetHealth()
                    if hp > (myDmg * 1.5) then
                        local ctx_normal = U.GetTargetPredictionContext(c, allyAttackers)
                        if not U.HasLasthitWindow(ctx_normal, c, myDmg, 0) then
                            local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                            if U.HasLasthitWindow(ctx_prehit, c, myDmg, attack_cd) then
                                prehit_target = c
                                break
                            end
                        end
                    end
                end
            end
        end

        if not prehit_target then
            for _, c in pairs(allyCreeps) do
                if c:IsAlive() and (c:GetHealth() / c:GetMaxHealth()) < 0.5 then
                    local in_enemy_tower_range = false
                    for _, t in pairs(enemyTowers) do
                        if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                            in_enemy_tower_range = true
                            break
                        end
                    end
                    if in_enemy_tower_range then
                        local eSF = enemyHero
                        local eDmg = eSF and U.CanQuery(eSF) and eSF:GetAttackDamage() or U.SFDamageRange(bot, c).min
                        local myDmg = U.SFDamageRange(bot, c).min
                        local hp = c:GetHealth()
                        if hp > myDmg then
                            local ctx_normal = U.GetTargetPredictionContext(c, enemyAttackers)
                            if U.HasLasthitWindow(ctx_normal, c, eDmg, 0) then
                                local ctx_prehit = U.WithHypotheticalDamage(ctx_normal, myDmg)
                                if not U.HasLasthitWindow(ctx_prehit, c, eDmg, 0) then
                                    prehit_target = c
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if prehit_target then
            local tower_proj_flying = false
            local projs = prehit_target:GetIncomingTrackingProjectiles()
            if projs then
                for _, p in pairs(projs) do
                    if p.is_attack and p.caster and p.caster:IsTower() then
                        tower_proj_flying = true
                        break
                    end
                end
            end
            if not tower_proj_flying then
                State.prepTarget = prehit_target
                State.prepTargetTime = GameTime()
                if H.IsSafeToAttack(bot, prehit_target:GetLocation(), enemyTowers, allyCreeps) then
                    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= prehit_target then
                        -- ONE attack (previously a continuous attack: the second hit cut the creep into the zone
                        -- where our own creeps finished it)
                        bot:Action_AttackUnit(prehit_target, true)
                        H.ClearMoveCache()
                    end
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, bot:GetLocation(), enemyTowers, allyCreeps), 60)
                end
                return
            end
        end
    end

    -- Finishing a stack on the enemy does not wait for the 1.9 s "free window" before a last hit: the cast is 0.55 s,
    -- we only yield to a last hit that must be taken within the next 0.7 s.
    -- A stack-finishing raze outranks a last hit when the last hit is not "right now" (<= 0.45 s):
    -- a raze on a stacked hero (~120-160 damage + stack extension) is worth more than one creep
    local followUpNow = enemyHero and H.IsRazeFollowUp(bot, enemyHero) and (bestTargetTime < 0 or bestTargetTime > 0.45)
    -- Hunting (State.hunting) outranks the last hit and is not blocked by a stack on us (his burst on us
    -- was already checked in ComputeHunt with the stack taken into account)
    local hunting = (State.hunting and enemyHero ~= nil) or false
    -- The enemy walked up close and we have mana for two razes - the trade beats waiting for the
    -- last hit (previously is_free_to_prehit = false here and the bot silently stood by the creep)
    local punishWindow = enemyHero ~= nil
        and (s.enemyDist <= ((C.RAZE and C.RAZE.PUNISH_CLOSE_RANGE) or 520))
        and H.GetPotentialCombatMana(bot) >= ((C.RAZE and C.RAZE.PUNISH_MIN_POT_MANA) or 150)
    local allowHarass = (is_free_to_prehit or enemyMissedAggro or followUpNow or hunting or punishWindow) and not State.prepTarget and not inKillThreat and (not secondStackActive or hunting or punishWindow)
    -- "Stack finish only" window (a last hit in 0.45-1.9 s): only razes are allowed (0.55 s cast),
    -- while a right click on the hero (0.5 s swing + 1.6 s cooldown) would cost the last hit.
    local razeOnlyWindow = followUpNow and not (is_free_to_prehit or enemyMissedAggro or hunting)
    -- No aggression under RETREAT; under FARM - no closing on the enemy (only if he came to us)
    if intent == I.RETREAT then allowHarass = false end
    local allowApproach = (intent == I.TRADE or intent == I.ALLIN)
    
    if H.HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps) then return end

    if allowHarass and enemyHero then
        local canRazePressure, razeMode = H.ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
        if canRazePressure then
            if H.TryRazeEnemy(bot, enemyHero, razeMode, enemyTowers, allyCreeps, false, false) then return end
        end
        if razeOnlyWindow then
            -- The stack finish did not work (no coverage/mana) - go back to the last hit
        elseif H.ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps) then
            H.IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return
        end

        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local approachThreshold = H.GetEnemyApproachDistance(enemyMissedAggro)
        local minHpPct = enemyMissedAggro and C.HARASS.MIN_HP_PCT_MISS or C.HARASS.MIN_HP_PCT
        local effectiveMode = enemyMissedAggro and "AGGRESSIVE" or current_mode
        if hunting then
            approachThreshold = (C.INTENT and C.INTENT.HUNT_MAX_DIST or 1100) + 150
            minHpPct = (C.INTENT and C.INTENT.HUNT_MIN_HP_PCT) or 0.40
            effectiveMode = "AGGRESSIVE"
        end
        if allowApproach and not razeOnlyWindow
            and (effectiveMode == "AGGRESSIVE" or (effectiveMode == "NEUTRAL" and enemyMissedAggro))
            and aggroCount <= 1
            and myHpPct >= minHpPct
            and dist > bot:GetAttackRange() + 50
            and dist < approachThreshold then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local stepIn = math.min(dist - bot:GetAttackRange() + 30, 350)
            local rawApproach = botLoc + dir * stepIn
            local futureDist = U.DistanceBetweenLocations(rawApproach, enemyHero:GetLocation())
            if U.ShouldFearBootsMidRaze(bot, enemyHero) and math.abs(futureDist - C.RAZE.MID_CENTER) <= 220 then
                return
            end
            local rawApproachClamped = U.ClampMinDistFromEnemy(bot, enemyHero, rawApproach)
            -- If "fear" pushed the point beyond the current position it is no longer an approach
            -- but a retreat: do not walk (otherwise the bot backed off endlessly from an advancing enemy)
            if U.DistanceBetweenLocations(rawApproachClamped, enemyHero:GetLocation()) >= dist - 20 then
                return
            end
            if H.ApproachEnemyPoint(bot, enemyHero, rawApproachClamped, 60, enemyTowers, allyCreeps) then
                return
            end
        end
    end

    local isAttacking = bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK
    local target = bot:GetAttackTarget()
    -- The target went into fog/died: it must not be queried (otherwise "[Developer] ... cannot be seen" every tick)
    if isAttacking and target and not U.CanQuery(target) then
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
        isAttacking = false
        target = nil
    end
    local lhFallThrough = false
    if isAttacking and target and State.lhAttackTarget==target and not (target.IsHero and target:IsHero()) then
        local last=bot:GetLastAttackTime() or -100
        local released=false
        if State.attackTarget==target and State.attackStartTime>0
            and last>State.attackStartTime+0.01 and last<=GameTime() then
            for _,projectile in pairs(target:GetIncomingTrackingProjectiles() or {}) do
                if projectile.is_attack and projectile.caster==bot then released=true;break end
            end
        end
        local waitingForCooldown=bestTarget and bestTarget~=target and last>0
            and last<State.attackStartTime
            and last+bot:GetSecondsPerAttack()-GameTime()>(bot:GetAttackPoint() or 0.5)+0.08
        if released or waitingForCooldown then
            State.lhAttackTarget=nil;State.prepTarget=nil;State.attackTarget=nil
            State.attackStartTime=0;State.firedThisAttack=false
            lhFallThrough=true
        end
    end
    if isAttacking and target and not lhFallThrough then
        if State.attackTarget ~= target then
            State.attackTarget = target
            State.attackStartTime = GameTime()
            State.firedThisAttack = false
        end
        if State.prepTarget == target then return end
        local targetIsHero = target.IsHero and target:IsHero()
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        if targetIsHero then return end
        -- The attack is not a "last hit" (push/clearing the wave): the cancel logic does not apply to it - previously
        -- it cancelled EVERY such attack 0.08 s before the attack point (the creep was "too alive") and the bot
        -- twitched endlessly without dealing damage. If a real last hit ripens meanwhile - yield to it.
        if State.lhAttackTarget ~= target then
            if target == bestTarget then
                -- A continuous (push) attack on a creep that became a last-hit candidate:
                -- if it is killable right now - let the attack land; otherwise stop attacking,
                -- the last-hit logic below takes over the timing
                if bestTargetTime <= 0.05 then return end
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
                isAttacking = false
                target = nil
                lhFallThrough = true
            elseif bestTarget and bestTargetTime >= 0 and bestTargetTime <= (bot:GetSecondsPerAttack() + 0.4) then
                lhFallThrough = true
            else
                return
            end
        end
    end
    if isAttacking and target and not lhFallThrough then
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        local dist = GetUnitToLocationDistance(bot, target:GetLocation())
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local impact_time = remaining_windup + (dist / projSpeed)
        local isAlly = (target:GetTeam() == bot:GetTeam())
        local attackers = isAlly and enemyAttackers or allyAttackers
        local ctx = U.GetTargetPredictionContext(target, attackers)
        local predHP = U.PredictHPWithContext(ctx, target, impact_time, "avg")
        local atkCount = 0
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then atkCount = atkCount + 1 end
        end
        local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
        local kill_threshold = dmg - safety_margin
        local dmgRange = U.SFDamageRange(bot, target)
        local commit_threshold = math.max(kill_threshold, dmgRange.avg)
        local commit_buffer = C.LASTHIT.COMMIT_HP_BUFFER or 8
        local cancel_window = C.LASTHIT.CANCEL_WINDOW or math.max(0.03, math.min(0.08, ap * 0.20))
        local shouldCancel = H.ShouldCancelCommittedLastHit(predHP, commit_threshold, commit_buffer, remaining_windup, cancel_window)
        if shouldCancel then
            if remaining_windup > 0.01 and remaining_windup <= cancel_window then
                bot:Action_ClearActions(true)
                H.ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
            end
            return
        else
            if remaining_windup <= 0.05 and not State.firedThisAttack then
                State.firedThisAttack = true
            end
            return
        end
    else
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
    end

    -- The enemy walked up close - punish him without waiting for a last-hit window
    if enemyHero and not am_i_tanking_too_much and not State.prepTarget then
        if H.HandleCloseEnemyPunish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if bestTarget then
        local targetLoc = bestTarget:GetLocation()
        local botLoc = bot:GetLocation()
        local dist = GetUnitToLocationDistance(bot, targetLoc)
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local ap = bot:GetAttackPoint()
        local ms = bot:GetCurrentMovementSpeed() or 305
        local earliest_t_attack,current_t_attack=U.GetAttackImpactWindow(bot,bestTarget)
        local DESIRED_ATK_RANGE = 450
        local time_to_walk = math.max(0, dist - DESIRED_ATK_RANGE) / ms
        local ranged_t_attack = ap + (DESIRED_ATK_RANGE / projSpeed) + C.LASTHIT.NET_LATENCY
        local attackers = isDeny and enemyAttackers or allyAttackers
        local t_killable, t_window_end = U.GetTimeToKillable(bot, bestTarget, attackers)
        -- My hit must land AFTER the creep becomes killable (with the IMPACT_LEAD margin
        -- for jitter), and BEFORE our own creeps finish it. Previously a hit was allowed
        -- 0.05 s BEFORE the threshold -> systematic "hit too early, the creep survived".
        if t_killable < 0 then
            -- No window: our own creeps kill it first. If it is nearly killable - hit now (a chance).
            local hpNow = bestTarget:GetHealth()
            local dr = U.SFDamageRange(bot, bestTarget)
            if hpNow <= dr.avg + 4 and not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                    return
                end
            end
            t_killable = 999
        end
        if (time_to_walk + ranged_t_attack + 0.1) < t_killable then
            if dist > DESIRED_ATK_RANGE then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * DESIRED_ATK_RANGE, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            else
                if isAttacking then
                    bot:Action_ClearActions(true)
                    H.ClearMoveCache()
                end
            end
            return
        elseif U.LastHitImpactFits(earliest_t_attack, current_t_attack, t_killable, t_window_end) then
            if not (isAttacking and target == bestTarget) then
                if H.IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    State.lhAttackTarget = bestTarget
                    State.attackTarget = bestTarget
                    State.attackStartTime = GameTime()
                    State.firedThisAttack = false
                    H.ClearMoveCache()
                else
                    H.SmartMove(bot, H.GetSafeApproach(bot, botLoc, enemyTowers, allyCreeps), 60)
                end
            end
            return
        else
            if dist > 500 then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = H.GetSafeApproach(bot, targetLoc + dir * 480, enemyTowers, allyCreeps)
                H.SmartMove(bot, moveTarget, 60)
            end
            return
        end
    end

    -- PUSH: push the wave / hit the T1 under a shield (last hits have higher priority - we get here
    -- only when no last hit is imminent)
    -- Siege as a fallback plan: the intent is aggressive (ALLIN/ZONE/TRADE) but the enemy hides
    -- under his T1 and is unreachable while our edge is large and the wave is at the tower - hit the tower/creeps
    -- under a shield instead of standing around. (ExecutePush checks the shield, HP and enemy threat itself.)
    local siegeFallback = false
    if intent ~= I.PUSH and intent ~= I.RETREAT and intent ~= I.FARM and not State.defensive
        and race.valid and s.enemyT1 and myHpPct >= ((C.INTENT and C.INTENT.PUSH_MIN_HP_PCT) or 0.55)
        and race.edge >= ((C.INTENT and C.INTENT.PUSH_EDGE) or 260) and not race.heCanKillSoon then
        local okTL, tLoc = pcall(s.enemyT1.GetLocation, s.enemyT1)
        if okTL and tLoc and GetUnitToLocationDistance(bot, tLoc) <= ((C.PUSH and C.PUSH.T1_ATTACK_RANGE) or 900) then
            siegeFallback = true
        end
    end
    if (intent == I.PUSH or siegeFallback) and not State.prepTarget and not am_i_tanking_too_much then
        if H.ExecutePush(bot, enemyHero, race, s) then return end
    end

    -- No creeps: walk to the lane (to the centre if far; otherwise to our own T1)
    local hasCreeps = (#allyCreeps > 0) or (#enemyCreeps > 0)
    -- Time hysteresis - creep lists are taken within 1200 of the bot, and when moving past
    -- that boundary "no creeps -> walk to the T1 (closer to the wave) -> creeps again -> back off"
    -- twitched 20 times a second. "No creeps" = not seen for >= 1.5 s.
    local nowC = GameTime()
    if hasCreeps then State.lastCreepsSeenTime = nowC end
    if not hasCreeps and (nowC - (State.lastCreepsSeenTime or -1e9)) < 1.5 then hasCreeps = true end
    if not hasCreeps and not U.IsActivelyHealing(bot) then
        -- No creeps (early game / the wave died): wait at our own T1 (the T1_CLOSE point).
        -- One target without "centre/T1" thresholds (they twitched at the 1500-from-centre boundary);
        -- the "between the T1 and the centre" point was removed - for Dire it landed in the river.
        local targetPos = State.waveScoutPoint or P.GetT1Close(bot)
        -- Do not route through the enemy T1 radius
        targetPos = H.GetSafeApproach(bot, targetPos, enemyTowers, allyCreeps)
        if GetUnitToLocationDistance(bot, targetPos) > 45 then
            H.SmartMove(bot, targetPos, 80)
        end
        return
    end

    if State.holdPos then return end

    local pos = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode)
    if enemyHero and U.CanQuery(enemyHero) then
        pos = U.ClampMinDistFromEnemy(bot, enemyHero, pos) -- Do not enter his band under "fear"
    end
    pos = H.GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
    if GetUnitToLocationDistance(bot, pos) > 100 then
        H.SmartMove(bot, pos, 60)
    end

    -- The tick stayed free - switch the Power Treads for the current task
    if not State.actionTaken then
        H.ManageTreads(bot, nil)
    end
end

function Think()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then
        State.heroCombatEnemy = nil
        State.heroCombatUntil = 0
        State.survivalUntil = 0
        State.survivalLoc = nil
        State.needsTP = true
        State.emergencyRetreat = nil
        State.emergencyRetreatStartTime = 0
        State.emergencyTPQueued = false
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        State.goingToFountain = false
        State.fountainReason = nil
        State.enemyReachedLevel2First = false
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        H.ClearForcedRetreat()
        H.ClearTowerEscape()
        H.ClearRazeState()
        H.ClearMoveCache()
        H.ClearTangoState()
        State.dodgeLoc = nil
        State.dodgeUntil = 0
        State.intent = "FARM"
        I.Reset()
        return
    end

    local now = GameTime()
    if now - (State.lastThinkTick or -100) < 0.03 then return end
    State.lastThinkTick = now
    local success, err = pcall(H.RealThink)
    if not success and now - (State.lastErrorLog or -100) >= 1.0 then
        State.lastErrorLog = now
        print("[SF-BOT CRITICAL ERROR] " .. tostring(err))
    end
end

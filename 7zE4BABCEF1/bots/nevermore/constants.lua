
local C = {}

C.HERO = {
    PROJECTILE_SPEED = 1200,
    DAMAGE_HALF_RANGE = 3, -- SF 7.41f: base damage 16-22 -> half-spread 3 (see U.SFDamageRange)
}

C.LASTHIT = {
    NET_LATENCY       = 0.05,
    DENY_HP_THRESHOLD = 0.50,
    CANCEL_WINDOW     = 0.08,
    COMMIT_HP_BUFFER  = 8,
    -- Contested creep (an enemy hero within its attack radius): creep hits that are not determined
    -- are counted at the middle of the cycle (not the worst case) - otherwise a bot with MORE damage hit the creep
    -- at the same moment as the weaker enemy and lost it to the deny.
    CONTEST_SLACK     = 0.45,
    CONTEST_RANGE_PAD = 150,
}

C.RAZE = {
    NEAR_CENTER         = 200,
    -- Raze policy with 1 point (L1-L2): start only point blank / as a mirror / as a finish
    AGGRO_MIN_RAZE_LEVEL = 2, -- from this raze level (2 points, usually hero L3) - aggression without limits
    EARLY_CHAIN_DIST     = 360, -- enemy closer -> a chain can be started (near -> mid -> far)
    MIRROR_WINDOW        = 2.5, -- s: after his cast we answer with ours (mirror)
    NEAR_CHAIN_WINDOW    = 5.0, -- s: after the near punish, finishing razes go without a mana reserve
    MID_CENTER          = 450,
    FAR_CENTER          = 700,
    HIT_RADIUS          = 250,
    STRICT_RADIUS       = 190,
    CAST_POINT          = 0.55,
    PREDICT_DELAY       = 0.62,
    EXTEND_AT           = 3.05,
    HARASS_MARGIN    = 90, -- A harass raze only with a robust error <= 250-90=160 (a reacting enemy at the edge leaves the circle)
    MAX_ANGLE_TO_CAST   = 6, -- Cast only when facing the aim point (was 8 and was not checked in the main path)
    TURN_STEP           = 40, -- The "turn" step (u): shorter and the engine may not turn the hero
    MIRROR_INSTANT_SEC  = 0.7, -- His raze hit us no later than this - an instant answer with the same/any band
    MIRROR_MIN_HP_LEFT  = 110, -- No less HP may remain after his next raze
    -- The raze lands slightly after the cast ends (animation + projectile): the hit check
    -- takes three points (now / middle of the cast / landing) instead of two.
    LAND_LEAD           = 0.08,
    ENEMY_THREAT_RANGE  = 930,
    RETREAT_MIN_REMAIN  = 0.35,
    MISS_DETECT_WINDOW  = 0.75,
    MISS_ADVANTAGE_TIME = 6.0,
    -- Robust aiming - the raze circle must cover the enemy both at the current and the predicted
    -- point (in case he "stops" / "starts walking"); the margin from the circle edge:
    ROBUST_MARGIN       = 30,
    -- Stack finish: the second/third raze immediately while the enemy is in reach (no waiting for EXTEND_AT),
    -- if he has a fresh stack with a remaining time of at least:
    FOLLOWUP_MIN_REMAIN = 1.2,
    -- Punishing an enemy that walked up close beats waiting for the last hit
    PUNISH_CLOSE_RANGE   = 520,
    PUNISH_MIN_POT_MANA  = 150, -- Mana for two razes (near + finishing)
}

C.HARASS = {
    BASE_COOLDOWN          = 0.0,
    MISS_BONUS_COOLDOWN    = 0.0,
    APPROACH_DISTANCE      = 800,
    APPROACH_DISTANCE_MISS = 1100,
    MIN_HP_PCT             = 0.45,
    MIN_HP_PCT_MISS        = 0.35,
    INTERRUPT_APPROACH     = 1300,
}

-- 7.41f (npc_dota_hero_nevermore.txt): necromastery_damage_per_soul = 1, +0.8 every 6 hero levels
C.NECROMASTERY = {
    BASE_DMG_PER_SOUL         = 1.0,
    DMG_PER_SOUL_PER_6_LEVELS = 0.8,
    MAX_SOULS                 = 20,
}

C.TP = {
    RETURN_DISTANCE_FROM_T1 = 3200,
    FOUNTAIN_RADIUS         = 400,
    RETURN_HP_PCT           = 0.50,
}

C.POSITIONS = {
    MID_LANE_CENTER      = Vector(503.58, -1010.36, 1124.97),
    MIDLANE_CENTER       = Vector(503.58, -1010.36, 1124.97),
    MID_FOUNTAIN_RADIANT = Vector(-6848, -6336, 384),
    MID_FOUNTAIN_DIRE    = Vector(6656, 6080, 384),
    RADIANT_T1           = Vector(-1544.00, -2008.00, 1144.05),
    RADIANT_T1_CLOSE     = Vector(-1395.18, -1859.83, 1144.00), -- ~210 from the T1 along the lane (was ~460)
    RADIANT_FLANK_TOP    = Vector(-1417.84, -1061.84, 1123.81),
    RADIANT_FLANK_BOT    = Vector(-591.38, -1812.09, 1138.51),
    WARD_RADIANT         = Vector(-304.583435, -1010.216370, 128.000000),
    DIRE_T1              = Vector(521.28, 48.31, 1146.80),
    DIRE_T1_CLOSE        = Vector(372.46, -99.86, 1146.00), -- ~210 from the T1 along the lane (was ~370)
    DIRE_FLANK_TOP       = Vector(-425.08, -37.47, 1123.98),
    DIRE_FLANK_BOT       = Vector(423.34, -847.56, 1117.69),
    WARD_DIRE            = Vector(-514.736816, 293.893494, 128.000000),
}

C.ITEM_PRIORITY = {
    ["item_kaya"]              = 100,
    ["item_dragon_lance"]      = 90,
    ["item_power_treads"]      = 80,
    ["item_boots"]             = 76,
    ["item_staff_of_wizardry"] = 75,
    ["item_blade_of_alacrity"] = 74,
    ["item_belt_of_strength"]  = 73,
    ["item_robe"]              = 72,
    ["item_bracer"]            = 70,
    ["item_magic_wand"]        = 60,
    ["item_magic_stick"]       = 50,
    ["item_circlet"]           = 40,
    ["item_gauntlets"]         = 35,
    ["item_faerie_fire"]       = 30,
    ["item_enchanted_mango"]   = 25,
    ["item_flask"]             = 20,
    ["item_tango"]             = 15,
    ["item_branches"]          = 10,
    ["item_ward_observer"]     = 5,
}

C.EMERGENCY = {
    RAZE_KILL_FACTOR     = 1.15,
    SINGLE_RAZE_FACTOR   = 1.05,
    MIN_HP_ABSOLUTE      = 180,
    COURIER_SEARCH_RANGE = 3000,
    COURIER_MEET_RANGE   = 1500,
}

C.GLYPH = {
    AVAILABLE_AT        = 180,
    COOLDOWN            = 300,
    T1_HP_PCT_THRESHOLD = 0.15,
    T1_HP_ABS_THRESHOLD = 400,
    KILL_DIVE_RANGE     = 900,
    -- The glyph "for a dive" only during an ongoing finish (the burst right now kills, we are attacking/aiming)
    DIVE_REQUIRE_KILL_NOW = true,
}

C.T1_SAFETY = {
    LAST_CREEP_HP_LOSS_CHECK = true,
    RETREAT_BUFFER           = 250,
    CREEP_DRIFT_START        = 620,
    CREEP_DRIFT_HARD         = 700,
    CREEP_DRIFT_DELTA        = 22,
}

C.FORCED_SALVE = {
    HP_PCT_THRESHOLD = 0.50,
}


C.SAFE_DISTANCE = {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

C.FINISH = {
    MIN_STACKS_FOR_CLOSE = 2,
    CLOSE_APPROACH_RANGE = 600,
    MIN_HP_PCT_FOR_CLOSE = 0.30,
}

C.BOOT_FEAR = {
    MID_RAZE_RADIUS       = 220,
    RETREAT_DURATION      = 0.95,
    RETREAT_DISTANCE_BONUS = 140,
    TWO_RAZE_MANA_COST    = 150,
    STICK_CHARGES_THREAT  = 10,
}

C.NEAR_REPLY = {
    WAIT_AFTER_HIT   = 1.0,
    HOLD_DISTANCE    = 215,
    HOLD_MIN_DISTANCE = 150,
    HOLD_MAX_DISTANCE = 250,
    HOLD_TOLERANCE    = 25,
}

C.FORCE_EXTEND = {
    PREFER_MID_WITH_BOOTS = true,
    FAR_DOWNGRADE_TO_MID  = true,
    FAR_CANCEL_TOLERANCE  = 60,
}

C.PUSH = {
    PUSH_ATTACK_RANGE     = 700,
    T1_ATTACK_RANGE       = 900,
    MIN_CREEPS_TO_TANK    = 2,
    MIN_HP_PCT_TO_PUSH    = 0.50,
    TOWER_SAFE_CREEP_HP   = 200,
    -- The tower is nearly down - finish it despite the shield/HP/burn (breaking the T1 wins)
    TOWER_FINISH_HITS     = 3,
    TOWER_FINISH_MIN_HP   = 0.22,
}

C.REGEN = {
    ENEMY_SAFE_DISTANCE = 1100,
    FLASK_SAFE_DISTANCE = 1150,
}

C.FOUNTAIN = {
    GO_HP_CRITICAL_PCT  = 0.15,
    GO_HP_WITH_MANA_PCT = 0.0,
    GO_MANA_WITH_HP_PCT = 0.0,
    STICK_CHARGES_ENOUGH = 10,
    WAIT_FULL_HP_PCT    = 0.98,
    WAIT_FULL_MANA_PCT  = 0.98,
    AT_FOUNTAIN_RADIUS  = 500,
    -- The enemy has exactly as few resources as we do - walking to the fountain simply hands
    -- the lane. Do not leave, keep the distance and regen. Exception - very low HP.
    SYMMETRIC_ENABLE    = true,
    SYMMETRIC_HP_GAP    = 0.10, -- his HP% is not above ours + this much (or lower)
    SYMMETRIC_FLOOR_PCT = 0.12, -- below this HP we leave regardless
    SYMMETRIC_MIN_HP    = 110, -- absolute floor (below MIN_HP_ABSOLUTE the rule would be dead)
}

C.STACK_NEAR_FEAR = {
    MIN_DISTANCE   = 470,
    RETREAT_BUFFER = 60,
}

-- World / combat / intents (world.lua, combat.lua, lane.lua, intent.lua)
C.RAZE.COOLDOWN                     = 9.0 -- 7.41f: all three razes
C.RAZE.DAMAGE_PER_SOUL              = 2 -- +2 raze damage per soul
C.RAZE.SINGLE_TRADE_LEVEL_TOLERANCE = 1
C.RAZE.SECOND_STACK_AVOID_RADIUS    = 190

C.LASTHIT.ALLY_DPS_FACTOR = 0.70 -- Only the fallback averaged model (attackers without data)
C.LASTHIT.IMPACT_LEAD = 0.025 -- Aim just after the opening, not before the allied hit.
C.LASTHIT.PREHIT_ANYWHERE = false -- "HP shaping" with a pre-hit outside our own tower (experiment: it worsened CS in the harness)

-- Skill build (without Feast of Souls / nevermore_frenzy - the lobby rules forbid it entirely).
-- Index = hero level; the value is an ability name or a list of names (talents cost no points,
-- so at 10/15/20/25 the talent is taken TOGETHER with the next point).
-- Talents 7.41f: 10 = +30 damage per raze stack (special_bonus_unique_nevermore_7),
-- 15 = -1.5 armour from Presence (_3), 20 = +5 souls (_1), 25 = razes proc attacks (_raze_procsattacks).
-- Raze and the passive are maxed by level 8, so from level 9 every point goes into "+2 all attributes"
-- (attribute_bonus, 7 levels max).
C.SKILL = {
    ALLOW_FRENZY = false,
    ORDER = {
        [1]  = "nevermore_shadowraze1",
        [2]  = "nevermore_dark_lord",
        [3]  = "nevermore_shadowraze1",
        [4]  = "nevermore_dark_lord",
        [5]  = "nevermore_shadowraze1",
        [6]  = "nevermore_dark_lord",
        [7]  = "nevermore_shadowraze1",
        [8]  = "nevermore_dark_lord",
        [9]  = "attribute_bonus",
        [10] = { "special_bonus_unique_nevermore_7", "attribute_bonus" },
        [11] = "attribute_bonus",
        [12] = "attribute_bonus",
        [13] = "attribute_bonus",
        [14] = "attribute_bonus",
        [15] = { "special_bonus_unique_nevermore_3", "attribute_bonus" },
        [20] = "special_bonus_unique_nevermore_1",
        [25] = "special_bonus_unique_nevermore_raze_procsattacks",
    },
}

-- Power Treads: 0 = strength, 1 = agility, 2 = intelligence (the engine Attributes enum).
-- In-game switch order: strength -> intelligence -> agility -> strength.
C.TREADS = {
    STRENGTH        = 0,
    AGILITY         = 1,
    INTELLIGENCE    = 2,
    SWITCH_COOLDOWN = 0.35, -- emergency switch (strength while surviving) - no more often than this
    MODE_HOLD       = 1.0, -- the normal mode (agility while attacking / intelligence while idle) is held for this long
    SURVIVE_HP_PCT  = 0.30, -- below this HP we stay on strength
}

C.TOWER = {
    ATTACK_RANGE      = 700, -- T1 attack range
    SAFE_RADIUS       = 780, -- the radius inside which we consider ourselves "under the tower"
    CHASE_LEASH       = 820, -- do not chase to a point closer than this to the enemy T1 without a creep shield
    MIN_SHIELD_TO_HIT = 2, -- minimum own creeps under the tower to hit the T1
    DIVE_MAX_TIME     = 1.0, -- Maximum time in a row inside the T1 radius "for the hero" (chasing/razing him)
    BURN_SEC          = 2.5, -- After leaving the T1, this many seconds with no dives and no tower attacks
    BURN_REPEAT_SEC   = 6.0, -- Leaving the T1 again within REPEAT_WINDOW s -> a longer burn
    REPEAT_WINDOW     = 10,
    -- Leaving the enemy T1 is a hard commitment (no other orders
    -- until we are out), otherwise the handlers overrode each other and the bot "jittered" in place.
    ESCAPE_RADIUS     = 900, -- we leave past this radius from the tower
    ESCAPE_MIN_STEP   = 240, -- the escape order must take us at least this far
    ESCAPE_COMMIT_SEC = 3.0, -- maximum time for a single escape commitment
}

C.INTENT = {
    ENEMY_ABSENT_SEC = 5.0, -- the enemy is dead / unseen for longer -> PUSH
    PUSH_EDGE        = 260, -- burst (absolute HP) advantage for PUSH with a live enemy
    ZONE_EDGE        = 70, -- advantage for ZONE
    TRADE_EDGE       = -30, -- allowed deficit for TRADE
    LOW_HP_PCT       = 0.22,
    PUSH_MIN_HP_PCT  = 0.55,
    PUSH_KEEP_HP_PCT = 0.45,
    ZONE_WAVE_DIST   = 900, -- the enemy is closer than this to the wave -> there is someone to zone
    -- "Hunt": a large absolute HP edge and the enemy is killable by my burst within
    -- HUNT_HORIZON (razes that will be ready + mango/stick + 1 hit) -> ALLIN even at low mana
    HUNT_HP_EDGE     = 250, -- my HP - his HP no less than
    HUNT_MIN_HP_PCT  = 0.40,
    HUNT_HORIZON     = 4.0, -- s: razes with a cooldown remaining of no more than this count as available
    HUNT_MAX_DIST    = 1100,
    HUNT_SAFETY_HP   = 80, -- his burst from mid-band distance must leave me >= this
}

C.ZONE = {
    HOLD_DIST        = 520, -- Stay at right-click distance, no closer than minSafeDist
    MAX_FROM_WAVE    = 520, -- do not move further from the wave than this for zoning
    ATTACK_RANGE_PAD = 40,
}

C.TANGO = {
    USE_HP_PCT     = 0.80, -- eat the tango earlier (user request): already below 80% HP
    MIN_MISSING_HP = 100, -- the tango heals 112 over 16 s: do not spend it for less than 100 missing HP
    SEARCH_RADIUS  = 900,
    COMMIT_TIME    = 8.0, -- Stay with the chosen tree (protects against hopping between trees)
    STUCK_TIME     = 4.0, -- no progress toward the tree -> blacklist the tree for 20 s
    ENEMY_MIN_DIST = 650,
    TOWER_MIN_DIST = 1125,
}

C.MANA = {
    RESERVE_FOR_PRESSURE = 75, -- pressure with razes only if mana for one more remains after the cast
    -- Early levels: a harass raze (not a finish, not a last hit) only if AFTER the cast there is
    -- a reserve for last hits/answers. At level 1-2 (291 mana, ~0.9/s regen) - one harass raze,
    -- then only CS/answers/finishes; otherwise the bot goes to zero while the enemy regens in peace.
    EARLY_RESERVE_L2 = 150,
    EARLY_RESERVE_L4 = 112,
    EARLY_LEVEL_L2   = 2,
    EARLY_LEVEL_L4   = 4,
    -- Finishing a stack (the enemy has a fresh stack and is still in reach): no reserve needed -
    -- the first 75 mana is already spent, the second/third raze hits with the stack bonus. We keep only:
    FOLLOWUP_KEEP    = 60,
    FOLLOWUP_KEEP_L2 = 130, -- At L1-L2 leave >= 130 after a stack-finishing raze (a chain of <= 2 razes)
    -- "Raze parity". The trade is roughly even (level/items) but he has mana
    -- for N razes and we have N-1: do not close into mid-band distance until we save
    -- as much - otherwise he catches us with the second raze and we cannot mirror.
    PARITY_ENABLE    = true,
    PARITY_MIN_ENEMY = 2, -- his budget (mana + consumables) must give no less than this
    PARITY_GAP       = 1, -- and exceed ours by this much
    PARITY_LEVEL_DIFF = 1, -- "Roughly equal": the level difference is no more than
    PARITY_ITEM_DIFF  = 0.35, -- "Roughly equal": the item power difference is no more than
}

-- Defensive stance "I am weaker": auto attacks + burst + both HP pools (see K.Race).
C.DEFENSE = {
    WEAKER_EDGE      = 120, -- the 6 s trade projection is worse by this much absolute HP -> I am weaker
    EXIT_EDGE        = 40, -- leaving defence: the projection is better than -40 (hysteresis)
    MIN_HOLD_SEC     = 2.0,
    KITE_PAD         = 140, -- back off past his attack radius + this much
    SUPPORT_CREEPS   = 2, -- this many of my creeps hit him -> we may answer even while defending
    CONTEST_PAD      = 80, -- defence: do not take a last hit if the hit position is within his attack radius + this
    SUSTAINED_TTK_RATIO = 0.8, -- "Weaker in the long run": he kills me with right clicks faster than I kill him, by 1/0.8 times
}

-- Consumable purchases from combat code (not the build!): no "out of stock" spam and no breaking the build.
C.CONSUMABLE_BUY = {
    RECOVERY_BUDGET     = 200, -- additional recovery gold per window when badly behind
    RECOVERY_WINDOW     = 180,
    RECOVERY_COOLDOWN   = 45,
    RECOVERY_RESERVE    = 50,
}

return C

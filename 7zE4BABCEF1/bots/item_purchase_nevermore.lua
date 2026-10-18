-- scripts/vscripts/bots/item_purchase_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local K = require("bots/nevermore/combat")

local PurchaseTable = {
    "item_ward_observer",
    "item_tango",
    "item_branches",
    "item_circlet",
    "item_circlet",
    "item_enchanted_mango",
    "item_faerie_fire",

    "item_gauntlets", "item_recipe_bracer",
    "item_gauntlets", "item_recipe_bracer",

    "item_magic_stick",

    "item_boots",
    "item_gloves",
    "item_boots_of_elves",

    "item_blade_of_alacrity", "item_belt_of_strength", "item_recipe_dragon_lance",

    "item_staff_of_wizardry", "item_robe", "item_recipe_kaya"
}

-- Per-bot purchase state (keyed by player ID)
local BotPurchaseState = {}


-- Gets or creates the purchase state for a specific bot
local function GetBotState(bot)
    local pid = bot:GetPlayerID()
    if pid == nil or pid < 0 then
        return nil
    end

    if not BotPurchaseState[pid] then
        BotPurchaseState[pid] = {
            currentItemIndex = 1,
            lastSalveBuyTime = -1000,
            extraMango = 0, extraSalve = 0,
            recoveryWindowAt = -1000, recoverySpent = 0, lastRecoveryBuy = -1000,
            lastShopAttempt = -1000,
            bought5MinWard = false,
            lastCourierCallTime = -1000,
        }
    end

    return BotPurchaseState[pid]
end

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local state = GetBotState(bot)
    if not state then return end
    if GameTime() - state.lastShopAttempt < 1.0 then return end
    state.lastShopAttempt = GameTime()
    local gold = bot:GetGold()

    -- 0. WARD AT 4:30 (270 seconds)
    if DotaTime() >= 270 and not state.bought5MinWard then
        bot:ActionImmediate_PurchaseItem("item_ward_observer")
        state.bought5MinWard = true
    end

    -- Inventory + stash + personal courier: do not duplicate an item in delivery.
    local function owns(name)
        for i = 0, 16 do
            local it = bot:GetItemInSlot(i)
            if it and it:GetName() == name then return true end
        end
        for i = 0, GetNumCouriers() - 1 do
            local courier = GetCourier(i)
            if courier and not courier:IsNull() and courier:GetPlayerID() == bot:GetPlayerID() then
                for slot = 0, 8 do
                    local it = courier:GetItemInSlot(slot)
                    if it and it:GetName() == name then return true end
                end
            end
        end
        return false
    end
    -- Temporary recovery budget when a VISIBLE opponent clearly wins the lane.
    -- This is separate from ordinary replenishment, not an unlimited exemption.
    local now = GameTime()
    local cfg = C.CONSUMABLE_BUY or {}
    if now - state.recoveryWindowAt >= (cfg.RECOVERY_WINDOW or 180) then
        state.recoveryWindowAt = now
        state.recoverySpent = 0
    end
    local recoveryBought = false
    if DotaTime() > 0 and now - state.lastRecoveryBuy >= (cfg.RECOVERY_COOLDOWN or 45)
        and now - state.lastSalveBuyTime >= (cfg.RECOVERY_COOLDOWN or 45)
        and not bot:HasModifier("modifier_fountain_aura_buff") then
        local strongerEnemy = nil
        for _, enemy in pairs(bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE) or {}) do
            if U.CanQuery(enemy) and enemy:GetUnitName() == "npc_dota_hero_nevermore"
                and K.NeedsRecoverySupport(bot, enemy) then strongerEnemy = enemy; break end
        end
        if strongerEnemy then
            local name
            local missingHP = bot:GetMaxHealth() - bot:GetHealth()
            if missingHP >= 250 and not bot:HasModifier("modifier_flask_healing") and not owns("item_flask") then
                name = "item_flask"
            elseif K.MyManaBudget(bot, true) < 150 and bot:GetMaxMana() - bot:GetMana() >= 100
                and bot:GetHealth() > math.max(110, K.AttackDamageVs(strongerEnemy, bot) * 1.5)
                and not owns("item_enchanted_mango") then
                name = "item_enchanted_mango"
            end
            if name then
                local cost = GetItemCost(name)
                local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount(name) > 0
                if inStock and state.recoverySpent + cost <= (cfg.RECOVERY_BUDGET or 200)
                    and gold >= cost + (cfg.RECOVERY_RESERVE or 50) then
                    local result = bot:ActionImmediate_PurchaseItem(name)
                    if result == (PURCHASE_ITEM_SUCCESS or 0) then
                        recoveryBought = true
                        state.recoverySpent = state.recoverySpent + cost
                        state.lastRecoveryBuy = now
                        state.lastSalveBuyTime = now
                        if name == "item_flask" then state.extraSalve = state.extraSalve + 1
                        else state.extraMango = state.extraMango + 1 end
                    end
                    gold = bot:GetGold()
                end
            end
        end
    end

    -- Main build has priority, especially both bracers. Advance only on success.
    local nextItem = PurchaseTable[state.currentItemIndex]
    if nextItem and gold >= GetItemCost(nextItem) then
        local result = bot:ActionImmediate_PurchaseItem(nextItem)
        if result == (PURCHASE_ITEM_SUCCESS or 0) then
            state.currentItemIndex = state.currentItemIndex + 1
        end
        gold = bot:GetGold()
    end

    local early = state.currentItemIndex <= 11 -- both bracers not yet ordered
    local interval = early and 120 or 90
    if not recoveryBought and DotaTime() > 0 and GameTime() - state.lastSalveBuyTime >= interval
        and not bot:HasModifier("modifier_fountain_aura_buff") then
        local hp = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
        local name
        if hp < 0.35 and not bot:HasModifier("modifier_flask_healing")
            and (not early or state.extraSalve < 1) then
            name = "item_flask"
        elseif bot:GetMana() < 75 and hp >= 0.50 and (not early or state.extraMango < 1) then
            name = "item_enchanted_mango"
        end
        local nextBuild = PurchaseTable[state.currentItemIndex]
        local reserve = math.max(210, nextBuild and GetItemCost(nextBuild) or 0)
        if name and not owns(name) and gold >= GetItemCost(name) + reserve then
            local inStock = type(GetItemStockCount) ~= "function" or GetItemStockCount(name) > 0
            if inStock then
                local result = bot:ActionImmediate_PurchaseItem(name)
                if result == (PURCHASE_ITEM_SUCCESS or 0) then
                    state.lastSalveBuyTime = GameTime()
                    if name == "item_flask" then state.extraSalve = state.extraSalve + 1
                    else state.extraMango = state.extraMango + 1 end
                end
            end
        end
    end

    -- 3. SMART COURIER (strictly personal)
    if GameTime() - state.lastCourierCallTime > 1.0 then

        local pid = bot:GetPlayerID()
        if pid < 0 then return end

        local numCouriers = GetNumCouriers()
        local myCourier = nil

        for i = 0, numCouriers - 1 do
            local c = GetCourier(i)
            if c and not c:IsNull() then
                if c:GetPlayerID() == pid then
                    myCourier = c
                    break
                end
            end
        end

        if myCourier and not myCourier:IsNull() then
            local state_c = GetCourierState(myCourier)

            if state_c == COURIER_STATE_IDLE or state_c == COURIER_STATE_AT_BASE then

                local stashItemsCount = 0
                local onlyWardInStash = true

                for i = 9, 14 do
                    local item = bot:GetItemInSlot(i)
                    if item then
                        stashItemsCount = stashItemsCount + 1
                        if item:GetName() ~= "item_ward_observer" then
                            onlyWardInStash = false
                        end
                    end
                end

                if stashItemsCount > 0 and not (stashItemsCount == 1 and onlyWardInStash) then
                    bot:ActionImmediate_Courier(myCourier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
                    state.lastCourierCallTime = GameTime()
                end
            end
        end
    end
end

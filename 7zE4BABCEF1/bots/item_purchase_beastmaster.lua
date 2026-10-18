-- scripts/vscripts/bots/item_purchase_beastmaster.lua

-- Strict purchase queue: 6 rings of protection for armor
local PurchaseTable = {
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection",
    "item_ring_of_protection"
}

local currentItemIndex = 1

function ItemPurchaseThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    local gold = bot:GetGold()

    -- 1. BUY RINGS
    if currentItemIndex <= #PurchaseTable then
        local nextItem = PurchaseTable[currentItemIndex]
        if gold >= GetItemCost(nextItem) then
            bot:ActionImmediate_PurchaseItem(nextItem)
            currentItemIndex = currentItemIndex + 1
        end
    end

    -- 2. PERSONAL COURIER
    -- In Dota, couriers are indexed 0-4 per team.
    -- We need to figure out which slot this Beastmaster occupies so we grab HIS courier.
    local myPlayerId = bot:GetPlayerID()
    local teamPlayers = GetTeamPlayers(GetTeam())
    local myCourierIndex = 0

    for index, id in pairs(teamPlayers) do
        if id == myPlayerId then
            myCourierIndex = index - 1 -- Lua tables are 1-based, Dota API is 0-based
            break
        end
    end

    local courier = GetCourier(myCourierIndex)
    if courier then
        local state = GetCourierState(courier)
        -- If the bot has a ring sitting in stash and his personal courier is idle
        if bot:GetStashValue() > 0 and (state == COURIER_STATE_IDLE or state == COURIER_STATE_AT_BASE) then
            bot:ActionImmediate_Courier(courier, COURIER_ACTION_TAKE_AND_TRANSFER_ITEMS)
        end
    end
end

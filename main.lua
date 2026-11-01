-- BondForge - Craft • Profit • Progress
-- Version 0.2.0
-- Experimental mouse dragging with directional buttons as fallback.
-- Keeps animated progress bar and pulsing goal celebration.
-- Fix: ui.Text components now receive the documented RuneScape font.
-- HTTP is optional; users can grant access via Plugin Hub > Manage > Permissions.
-- Manual price inputs and production tracking remain available without HTTP.

local KEY = "mgc_auto_v01_" -- Separate data from the stable offline edition.
local INV = config.Inv.INV
local FULL_HEIGHT, COMPACT_HEIGHT = 905, 210
local WINDOW_WIDTH = 540
local compact = (PersistentDB:GetInt(KEY .. "compact") or 0) == 1
local accent = PersistentDB:GetInt(KEY .. "accent") or 1
if accent < 1 or accent > 3 then accent = 1 end
local opacity = PersistentDB:GetInt(KEY .. "opacity") or 1
if opacity < 1 or opacity > 3 then opacity = 1 end
-- Session metrics reset on plugin reload or Reset Session. Lifetime progress is separate.
local sessionSeconds, sessionProduced, sessionProfit = 0, 0, 0
local pendingItems = math.max(0, PersistentDB:GetInt(KEY .. "pendingItems") or 0)
local REVIEW_THRESHOLD = 100 -- Large backpack gains require user confirmation; never silently discard them.
local bestRate = PersistentDB:GetInt(KEY .. "bestRate") or 0
local trendBaselineRate, trendBaselineAt = nil, nil
local trendText = "Collecting data"
local todayProfit = PersistentDB:GetInt(KEY .. "todayProfit") or 0
local todayItems = PersistentDB:GetInt(KEY .. "todayItems") or 0
local todayDay = PersistentDB:GetString(KEY .. "todayDay") or ""
-- Date support is optional; never use an unverified day as a calendar date.
local function currentDay()
    if type(os) ~= "table" or type(os.date) ~= "function" then return nil end
    local ok, result = pcall(os.date, "%Y-%m-%d")
    if ok and type(result) == "string" and result:match("^%d%d%d%d%-%d%d%-%d%d$") then return result end
    return nil
end
local function syncDay()
    local day = currentDay()
    if day and day ~= todayDay then
        todayDay, todayProfit, todayItems = day, 0, 0
        PersistentDB:SetString(KEY .. "todayDay", todayDay)
        PersistentDB:SetInt(KEY .. "todayProfit", 0)
        PersistentDB:SetInt(KEY .. "todayItems", 0)
    end
    return day
end
syncDay()
local details = {}
local function detail(c)
    details[#details + 1] = c
    return c
end
local function panelHeight()
    return compact and COMPACT_HEIGHT or FULL_HEIGHT
end

local state = {
    bondPrice = PersistentDB:GetInt(KEY .. "bondPrice") or 0,
    itemPrice = PersistentDB:GetInt(KEY .. "itemPrice") or 0,
    materialCost = PersistentDB:GetInt(KEY .. "materialCost") or 0,
    itemId = PersistentDB:GetInt(KEY .. "itemId") or 0,
    itemName = PersistentDB:GetString(KEY .. "itemName") or "",
    produced = PersistentDB:GetInt(KEY .. "produced") or 0,
    earnedGP = PersistentDB:GetInt(KEY .. "earnedGP") or 0,
    target = 0,
    profit = 0,
    previousCount = nil,
    complete = false,
    displayProgress = 0,
    targetProgress = 0,
    celebrationActive = false,
    celebrationTime = 0
}

-- One-time migration from the older produced * current-profit estimate.
-- Keep the migrated amount fixed as market prices change afterward.
if (PersistentDB:GetInt(KEY .. "earnedMigrationV2") or 0) ~= 1 then
    -- Existing installs stored only item counts; use last saved prices once.
    local legacyProfit = math.max(0, math.floor(state.itemPrice * 0.98) - state.materialCost)
    state.earnedGP = state.produced * legacyProfit
    PersistentDB:SetInt(KEY .. "earnedGP", state.earnedGP)
    PersistentDB:SetInt(KEY .. "earnedMigrationV2", 1)
end
local function savePending()
    PersistentDB:SetInt(KEY .. "pendingItems", pendingItems)
end
local function progressPct()
    return state.bondPrice > 0 and math.min(100, state.earnedGP / state.bondPrice * 100) or 0
end
local function goalReached()
    return state.bondPrice > 0 and state.profit > 0 and state.earnedGP >= state.bondPrice
end
local function save()
    PersistentDB:SetInt(KEY .. "bondPrice", state.bondPrice)
    PersistentDB:SetInt(KEY .. "itemPrice", state.itemPrice)
    PersistentDB:SetInt(KEY .. "materialCost", state.materialCost)
    PersistentDB:SetInt(KEY .. "itemId", state.itemId)
    PersistentDB:SetString(KEY .. "itemName", state.itemName)
    PersistentDB:SetInt(KEY .. "produced", state.produced)
    PersistentDB:SetInt(KEY .. "earnedGP", math.floor(state.earnedGP))
end

local function fmt(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    while true do
        local out, count = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        s = out
        if count == 0 then break end
    end
    return s
end

local function quantity(field)
    return math.max(0, math.floor(tonumber(field.contentQuantity) or 0))
end

local gameWindow = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
local panel = ui.GroupBox.new(gameWindow)
panel.stylesheetID = id.StyleSheet.DEFAULT
panel:SetHeaderLayout(0, 0, 0, 0, 0)
panel:SetSize(WINDOW_WIDTH, panelHeight())
local savedX = PersistentDB:GetInt(KEY .. "windowX")
local savedY = PersistentDB:GetInt(KEY .. "windowY")
if savedX ~= nil and savedY ~= nil then
    panel:SetPos(savedX, savedY)
else
    -- Use absolute coordinates, not fractional anchors. Anchored positioning
    -- causes the client layout system to snap the GroupBox back after dragging.
    local startX = math.max(0, math.floor((gameWindow.width - WINDOW_WIDTH) / 2))
    panel:SetPos(startX, 100)
end

local function textLine(content, x, y, w, h, isDetail)
    local t = ui.Text.new(panel)
    t:SetPos(x, y)
    t:SetSize(w, h)
    t.content = content
    t.font = id.Font.MUSEO_SANS_15PT_REGULAR
    t.colour = Vector4.new(0.95, 0.92, 0.86, 1.0)
    if isDetail then detail(t) end
    return t
end

-- Reliable manual window positioning: avoid the client's drag-and-drop
-- overlay, which does not reposition this custom GroupBox.
local titleBar = textLine("BONDFORGE  |  CRAFT - PROFIT - PROGRESS", 12, 8, 315, 24)
-- Consume clicks on the draggable title instead of passing them to the world.
titleBar.clickthrough = false
-- Experimental direct mouse movement. Unlike dragConfig, this moves the
-- actual GroupBox, not the engine's temporary drag-and-drop overlay.
-- ONHOLD is only sent while the title is held; release clears the gesture.
local dragging = false
local previousMouseX, previousMouseY = nil, nil
local function beginDrag()
    if not Mouse.IsAvailable() then return end
    previousMouseX, previousMouseY = Mouse.GetX(), Mouse.GetY()
    dragging = previousMouseX ~= nil and previousMouseY ~= nil
    return true
end
local function dragHeld()
    if not dragging then
        beginDrag()
        return true
    end
    local mx, my = Mouse.GetX(), Mouse.GetY()
    if mx == nil or my == nil then return end
    local dx, dy = mx - previousMouseX, my - previousMouseY
    if dx ~= 0 or dy ~= 0 then
        local nx = math.max(0, math.min(math.max(0, gameWindow.width - WINDOW_WIDTH), panel.x + dx))
        local ny = math.max(0, math.min(math.max(0, gameWindow.height - panelHeight()), panel.y + dy))
        panel:SetPos(nx, ny)
    end
    previousMouseX, previousMouseY = mx, my
    return true
end
local function endDrag()
    if dragging then
        PersistentDB:SetInt(KEY .. "windowX", panel.x)
        PersistentDB:SetInt(KEY .. "windowY", panel.y)
    end
    dragging = false
    previousMouseX, previousMouseY = nil, nil
    return true
end
titleBar:Subscribe(ui.Hook.ONCLICK, "MGC_DragBegin", beginDrag)
titleBar:Subscribe(ui.Hook.ONHOLD, "MGC_DragHold", dragHeld)
titleBar:Subscribe(ui.Hook.ONRELEASE, "MGC_DragRelease", endDrag)

local positionStep = 40
local function movePanel(dx, dy)
    local newX = math.max(0, math.min(math.max(0, gameWindow.width - WINDOW_WIDTH), panel.x + dx))
    local newY = math.max(0, math.min(math.max(0, gameWindow.height - panelHeight()), panel.y + dy))
    panel:SetPos(newX, newY)
    PersistentDB:SetInt(KEY .. "windowX", newX)
    PersistentDB:SetInt(KEY .. "windowY", newY)
end
local function positionButton(label, x, dx, dy)
    local b = ui.Button.new(panel)
    b:SetPos(x, 3)
    b:SetSize(42, 29)
    b.label = label
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        movePanel(dx, dy)
    end)
end
positionButton("Left", 335, -positionStep, 0)
positionButton("Right", 380, positionStep, 0)
positionButton("Up", 425, 0, -positionStep)
positionButton("Down", 470, 0, positionStep)

textLine("Bond price (GP)", 12, 40, 245, 18, true)
local bondInput = ui.InputField.new(panel)
detail(bondInput)
bondInput.stylesheetID = id.StyleSheet.DEFAULT
bondInput.content = tostring(state.bondPrice)
bondInput.emptyText = "Bond price in GP"
bondInput:SetSize(245, 29)
bondInput:SetPos(12, 62)
bondInput:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.QUANTITY, 14)

textLine("Product name", 280, 40, 245, 18, true)
local nameInput = ui.InputField.new(panel)
detail(nameInput)
nameInput.stylesheetID = id.StyleSheet.DEFAULT
nameInput.content = state.itemName
nameInput.emptyText = "e.g. Rune platebody"
nameInput:SetSize(245, 29)
nameInput:SetPos(280, 62)
nameInput:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.NONE, 80)

textLine("Selling price per item (GP)", 12, 104, 245, 18, true)
local priceInput = ui.InputField.new(panel)
detail(priceInput)
priceInput.stylesheetID = id.StyleSheet.DEFAULT
priceInput.content = tostring(state.itemPrice)
priceInput.emptyText = "Selling price"
priceInput:SetSize(245, 29)
priceInput:SetPos(12, 126)
priceInput:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.QUANTITY, 14)

textLine("Material cost per item (GP)", 280, 104, 245, 18, true)
local costInput = ui.InputField.new(panel)
detail(costInput)
costInput.stylesheetID = id.StyleSheet.DEFAULT
costInput.content = tostring(state.materialCost)
costInput.emptyText = "Material cost"
costInput:SetSize(245, 29)
costInput:SetPos(280, 126)
costInput:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.QUANTITY, 14)

textLine("Tracked product item ID", 12, 168, 245, 18, true)
local idInput = ui.InputField.new(panel)
detail(idInput)
idInput.stylesheetID = id.StyleSheet.DEFAULT
idInput.content = tostring(state.itemId)
idInput.emptyText = "Item ID"
idInput:SetSize(245, 29)
idInput:SetPos(12, 190)
idInput:Setup(ui.TextContentVisibilityMode.VISIBLE, ui.InputFieldFilterMode.QUANTITY, 12)

local status = textLine("Scan backpack, choose an item, then fetch its GE guide price.", 12, 258, 510, 25, true)
local priceInfo = textLine("Prices: waiting for automatic refresh", 12, 289, 510, 22, true)
local bondOut = textLine("Bond: --", 12, 325, 510, 20, true)
local netOut = textLine("Net sale proceeds: --", 12, 349, 510, 20, true)
local profitOut = textLine("Profit per item: --", 12, 373, 510, 20, true)
local targetOut = textLine("Items required: --", 12, 397, 510, 20, true)
local producedOut = textLine("Cumulative produced: " .. fmt(state.produced), 12, 421, 510, 20, true)
local remainingOut = textLine("Remaining: --", 12, 445, 510, 20, true)
local progressOut = textLine("Progress: 0%", 12, 469, 510, 20, true)
-- Proper graphical progress bar: dark track, animated fill, and outline.
local progressTrack = ui.Rectangle.new(panel)
detail(progressTrack)
progressTrack:SetPos(12, 497)
progressTrack:SetSize(510, 18)
progressTrack.colour = Vector4.new(0.10, 0.09, 0.08, 1.0)
progressTrack.fill = true

local progressFill = ui.Rectangle.new(panel)
detail(progressFill)
progressFill:SetPos(13, 498)
progressFill:SetSize(0, 16)
progressFill.colour = Vector4.new(0.22, 0.68, 0.34, 1.0)
progressFill.fill = true

local progressOutline = ui.Rectangle.new(panel)
detail(progressOutline)
progressOutline:SetPos(12, 497)
progressOutline:SetSize(510, 18)
progressOutline.colour = Vector4.new(0.72, 0.66, 0.52, 1.0)
progressOutline.fill = false
progressOutline.outlineThickness = 1

local celebrationOut = textLine("Next milestone: --", 12, 525, 510, 28, true)
-- Visible milestone ticks are passive decorations, not draggable controls.
local milestoneTicks = {}
for _, percent in ipairs({25, 50, 75}) do
    local tick = ui.Rectangle.new(panel)
    detail(tick)
    tick:SetPos(12 + math.floor(510 * percent / 100), 497)
    tick:SetSize(2, 18)
    tick.fill = true
    tick.colour = Vector4.new(0.92, 0.88, 0.72, 1.0)
    milestoneTicks[#milestoneTicks + 1] = tick
end

local rateOut = textLine("Session rate: collecting data...", 12, 553, 510, 20, true)
local noteOut = textLine("Offline estimates | Session stats reset on reload", 12, 575, 510, 20, true)
local statsTitle = textLine("PRODUCTION STATISTICS", 12, 603, 510, 22, true)
local statsSession = textLine("Session: 0 items | 0 GP profit", 12, 629, 510, 20, true)
local statsAverage = textLine("Average: -- GP/hour | -- items/hour", 12, 653, 510, 20, true)
local statsToday = textLine("Today: --", 12, 677, 510, 20, true)
local statsBest = textLine("Best observed GP/hour: --", 12, 701, 510, 20, true)
local statsHint = textLine("Estimated profit, not verified sales | Reset Session below", 12, 727, 510, 20, true)

local function refresh()
    local net = math.floor(state.itemPrice * 0.98)
    local remaining = state.profit > 0 and math.ceil(math.max(0, state.bondPrice - state.earnedGP) / state.profit) or 0
    local pct = progressPct()
    bondOut.content = "Bond: " .. (state.bondPrice > 0 and fmt(state.bondPrice) .. " GP" or "--")
    netOut.content = "Net sale proceeds (2% fee estimate): " .. (state.itemPrice > 0 and fmt(net) .. " GP" or "--")
    profitOut.content = "Profit per item: " .. (state.itemPrice > 0 and fmt(state.profit) .. " GP" or "--")
    targetOut.content = "Additional items needed: " .. (state.target > 0 and fmt(remaining) or "--")
    producedOut.content = "Cumulative produced: " .. fmt(state.produced)
    local earned = state.earnedGP
    local gpLeft = math.max(0, state.bondPrice - earned)
    remainingOut.content = state.target > 0 and ("Earned: " .. fmt(earned) .. " GP | Left: " .. fmt(gpLeft) .. " GP") or "Earned / remaining GP: --"
    progressOut.content = string.format("BOND PROGRESS  %.1f%%  |  %s more items needed", pct, state.target > 0 and fmt(remaining) or "--")
    if not state.celebrationActive then
        if state.target <= 0 then
            celebrationOut.content = "Next milestone: set a valid Bond goal"
        elseif pct >= 100 then
            celebrationOut.content = "All milestones reached!"
        else
            local nextMark = pct < 25 and 25 or (pct < 50 and 50 or (pct < 75 and 75 or 100))
            local milestoneGP = math.ceil(state.bondPrice * nextMark / 100)
            celebrationOut.content = "Next milestone: " .. nextMark .. "% | " .. fmt(math.max(0, milestoneGP - earned)) .. " GP to go"
        end
    end
    state.targetProgress = pct / 100
    if state.targetProgress <= 0 then
        state.displayProgress = 0
        progressFill:SetSize(0, 16)
    end
end

local function showGoalCelebration()
    celebrationOut.content = "*** GOAL COMPLETE! YOU HAVE REACHED YOUR BOND TARGET! ***"
    status.content = "Congratulations! Your Bond profit goal has been reached."
    state.celebrationActive = true
    state.celebrationTime = 0
    progressFill.colour = Vector4.new(1.0, 0.72, 0.12, 1.0)
    print("*** MEMBERSHIP GOAL COMPLETE! BOND TARGET REACHED! ***")
    log("BondForge: Bond goal completed.")
end

local function calculate()
    state.bondPrice = quantity(bondInput)
    state.itemPrice = quantity(priceInput)
    state.materialCost = quantity(costInput)
    state.itemName = nameInput.content or ""
    state.itemId = quantity(idInput)

    local net = math.floor(state.itemPrice * 0.98)
    state.profit = net - state.materialCost

    if state.bondPrice <= 0 then
        state.target = 0
        status.content = "Please enter a Bond price greater than zero."
    elseif state.itemPrice <= 0 then
        state.target = 0
        status.content = "Please enter a selling price greater than zero."
    elseif state.profit <= 0 then
        state.target = 0
        status.content = "No positive profit after the estimated GE fee. Check your costs."
    else
        state.target = math.ceil(state.bondPrice / state.profit)
        state.complete = goalReached()
        if state.complete then
            showGoalCelebration()
        else
            state.celebrationActive = false
            celebrationOut.content = ""
            celebrationOut.colour = Vector4.new(0.95, 0.92, 0.86, 1.0)
            titleBar.colour = Vector4.new(0.95, 0.92, 0.86, 1.0)
            progressFill.colour = Vector4.new(0.22, 0.68, 0.34, 1.0)
            status.content = "Goal calculated successfully."
        end
    end

    save()
    refresh()
    log("BondForge: Calculate Goal pressed.")
end

local function addButton(label, x, y, w, callback)
    local b = ui.Button.new(panel)
    b:SetPos(x, y)
    b:SetSize(w, 28)
    b.label = label
    b.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    b:Subscribe(ui.Hook.ONBUTTONPRESSED, function(btn)
        local ok, err = pcall(callback)
        if not ok then
            status.content = "Plugin error: " .. tostring(err)
            log("BondForge button error: " .. tostring(err))
        end
    end)
    detail(b)
    return b
end

-- Backpack discovery: read visible inventory slots, never guess item IDs.
local foundItems, foundIndex = {}, 0
-- Silent refresh is safe to call from the inventory event and startup.
-- Preserve the selection index by item ID so new backpack items do not
-- unexpectedly change which product Select next chooses.
local function scanBackpack(silent)
    local inv = Inventory.Find(INV)
    if not inv or not inv.isValid then
        if not silent then status.content = "Backpack unavailable. Open your inventory and retry." end
        return false
    end
    local oldID = foundItems[foundIndex] and foundItems[foundIndex].id
    local items, seen = {}, {}
    for _, slot in ipairs(inv:GetSlots() or {}) do
        local obj = slot and slot.obj
        if obj and obj.id and obj.id > 0 and not seen[obj.id] then
            seen[obj.id] = true
            items[#items + 1] = {id = obj.id, name = obj.name or ("Item " .. obj.id)}
        end
    end
    table.sort(items, function(a,b) return a.name < b.name end)
    foundItems, foundIndex = items, 0
    for i, item in ipairs(items) do
        if item.id == oldID then foundIndex = i end
        -- Restore saved product name if it was missing in persistent storage.
        if item.id == state.itemId and (state.itemName == "" or state.itemName:match("^Item %d+$")) then
            state.itemName = item.name
            nameInput.content = item.name
            save()
        end
    end
    if not silent then
        status.content = tostring(#foundItems) .. " unique backpack items found. Select Next to choose."
    end
    return true
end
local function chooseNext()
    if #foundItems == 0 then scanBackpack() end
    if #foundItems == 0 then return end
    foundIndex = (foundIndex % #foundItems) + 1
    local item = foundItems[foundIndex]
    -- A new tracked item starts a fresh progress count to prevent mixing products.
    if state.itemId ~= item.id then
        state.produced = 0
        state.earnedGP = 0
        pendingItems = 0
        savePending()
        PersistentDB:SetInt(KEY .. "milestoneReached", 0)
        state.previousCount = nil
        state.complete = false
        state.celebrationActive = false
        sessionProduced, sessionProfit, sessionSeconds = 0, 0, 0
    end
    nameInput.content = item.name
    idInput.content = tostring(item.id)
    state.itemId, state.itemName = item.id, item.name
    local inv = Inventory.Find(INV)
    state.previousCount = inv and inv.isValid and inv:GetTotal(item.id) or nil
    priceInput.content = "0"
    state.itemPrice = 0
    itemPriceSource, itemUpdateAge = "Not updated", nil
    save()
    status.content = "Selected " .. item.name .. " (" .. item.id .. "). Fetch price or enter manually."
end
-- Recompute silently when an automatic price arrives, without resetting production.
local function recalculateFromPrices()
    state.bondPrice = quantity(bondInput)
    state.itemPrice = quantity(priceInput)
    state.materialCost = quantity(costInput)
    state.itemId = quantity(idInput)
    state.itemName = nameInput.content or ""
    state.profit = math.floor(state.itemPrice * 0.98) - state.materialCost
    if state.bondPrice > 0 and state.itemPrice > 0 and state.profit > 0 then
        state.target = math.ceil(state.bondPrice / state.profit)
    else
        state.target = 0
    end
    local reached = goalReached()
    if reached and not state.complete then
        state.complete = true
        showGoalCelebration()
    elseif not reached then
        state.complete = false
        state.celebrationActive = false
        celebrationOut.content = ""
    end
    save()
    refresh()
end

local refreshElapsed = 0
local startupRefresh = 0
local autoStarted = false
local itemPriceSource, bondPriceSource = "Not updated", "Not updated"
local itemUpdateAge, bondUpdateAge = nil, nil
local bondRequestPending = false
local autoItemRequestedID = 0
local autoPermissionNotice = false
local function updatePriceInfo()
    local function age(t)
        if not t then return "--" end
        if t < 60 then return tostring(math.floor(t)) .. "s ago" end
        return tostring(math.floor(t / 60)) .. "m ago"
    end
    priceInfo.content = "Item: " .. itemPriceSource .. " (" .. age(itemUpdateAge) .. ") | Bond: " .. bondPriceSource .. " (" .. age(bondUpdateAge) .. ")"
end

local priceRequestPending = false
local function diagnosticValue(value)
    if value == nil then return "nil" end
    local valueText = tostring(value)
    if #valueText > 70 then return valueText:sub(1, 67) .. "..." end
    return valueText
end
-- Official GE catalogue returns human-readable prices such as "12.3k" and "1.2m".
local function parseGEPrice(value)
    if type(value) == "number" then return math.floor(value) end
    if type(value) ~= "string" then return nil end
    local clean = value:lower():gsub(",", ""):gsub("%s+", "")
    local number, suffix = clean:match("^(%d+%.?%d*)([kmb]?)$")
    if not number then return nil end
    local multipliers = { k = 1000, m = 1000000, b = 1000000000 }
    return math.floor(tonumber(number) * (multipliers[suffix] or 1) + 0.5)
end
local function officialPrice(data)
    -- Only parse the 'current' price, not daily or 30/90/180-day change fields.
    local value = data:match('"current"%s*:%s*{.-"price"%s*:%s*"([^"]+)"')
    if not value then value = data:match('"current"%s*:%s*{.-"price"%s*:%s*(%d+)') end
    return parseGEPrice(value)
end
local function wikiPrice(data, itemID)
    local value = data:match('"' .. tostring(itemID) .. '"%s*:%s*(%d+)')
    return parseGEPrice(value)
end
local function fetchGuidePrice()
    local itemID = quantity(idInput)
    if itemID <= 0 then status.content = "Select a backpack item first."; return end
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        status.content = "Auto GE pricing needs HTTP access. Enable it in Plugin Hub > Manage > Permissions; manual prices still work."
        return
    end
    if priceRequestPending then status.content = "Price request already running."; return end
    priceRequestPending = true
    autoItemRequestedID = itemID
    local failures = {}
    local function fail(source, message)
        failures[#failures + 1] = source .. ": " .. message
    end
    local function finishFailure()
        priceRequestPending = false
        status.content = table.concat(failures, " | ") .. " | Enter manual price."
    end
    local function applyPrice(price, source)
        priceRequestPending = false
        if quantity(idInput) ~= itemID then
            status.content = "Selected item changed. Fetch price again."
            return
        end
        priceInput.content = tostring(price)
        itemPriceSource, itemUpdateAge = source, 0
        recalculateFromPrices()
        updatePriceInfo()
        status.content = source .. " GE guide: " .. fmt(price) .. " GP (goal recalculated)."
    end
    local function attempt(source, host, path, parser, onFailure)
        local ok, err = pcall(function()
            local req = HTTPRequest.new(host, path)
            req:Get(function(request)
                local handled, callbackError = pcall(function()
                    if not request then
                        fail(source, "no HTTP response")
                        onFailure()
                        return
                    end
                    local code = tonumber(request.responseCode)
                    if not request.successful or code ~= 200 then
                        fail(source, "HTTP " .. diagnosticValue(request.responseCode)
                            .. " timeout=" .. diagnosticValue(request.timedOut)
                            .. " error=" .. diagnosticValue(request.errorCode))
                        onFailure()
                        return
                    end
                    local data = request.data
                    if type(data) ~= "string" then
                        fail(source, "HTTP 200 data=" .. type(data))
                        onFailure()
                        return
                    end
                    local price = parser(data)
                    if not price or price <= 0 then
                        fail(source, "HTTP 200 price missing (bytes=" .. tostring(#data) .. ")")
                        onFailure()
                        return
                    end
                    applyPrice(price, source)
                end)
                if not handled then
                    fail(source, "callback " .. diagnosticValue(callbackError))
                    onFailure()
                end
            end)
        end)
        if not ok then
            fail(source, "request " .. diagnosticValue(err))
            onFailure()
        end
    end
    local function tryWiki()
        status.content = "Official GE unavailable; trying Wiki..."
        attempt("Wiki", Plugin.urls.wiki,
            "/w/Module:GEPricesByIDs/data.json?action=raw",
            function(data) return wikiPrice(data, itemID) end,
            finishFailure)
    end
    status.content = "Fetching official RuneScape GE guide price..."
    attempt("Official GE", Plugin.urls.officialGE,
        "/m=itemdb_rs/api/catalogue/detail.json?item=" .. tostring(itemID),
        officialPrice, tryWiki)
end
-- RuneScape Bond item ID (tradeable Bond). Official catalogue first; no Wiki dependency.
local BOND_ITEM_ID = 29492
local function fetchBondPrice()
    if bondRequestPending or not Plugin.HasPermission(PluginPermissions.httpAccess) then return end
    bondRequestPending = true
    bondPriceSource = "Fetching..."
    updatePriceInfo()
    local ok, err = pcall(function()
        local req = HTTPRequest.new(Plugin.urls.officialGE,
            "/m=itemdb_rs/api/catalogue/detail.json?item=" .. tostring(BOND_ITEM_ID))
        req:Get(function(response)
            bondRequestPending = false
            local handled, callbackError = pcall(function()
                local code = response and tonumber(response.responseCode)
                if response and response.successful and code == 200 and type(response.data) == "string" then
                    local price = officialPrice(response.data)
                    if price and price > 0 then
                        bondInput.content = tostring(price)
                        bondPriceSource, bondUpdateAge = "Official GE", 0
                        recalculateFromPrices()
                        updatePriceInfo()
                        return
                    end
                end
                bondPriceSource = "HTTP " .. diagnosticValue(code or "no response")
                log("Bond official GE response: " .. bondPriceSource)
                updatePriceInfo()
            end)
            if not handled then
                bondPriceSource = "Parse error"
                updatePriceInfo()
                log("Bond price callback: " .. tostring(callbackError))
            end
        end)
    end)
    if not ok then
        bondRequestPending = false
        bondPriceSource = "Request error"
        updatePriceInfo()
        log("Bond price request: " .. tostring(err))
    end
end
local function fetchAllPrices()
    if not Plugin.HasPermission(PluginPermissions.httpAccess) then
        if not autoPermissionNotice then
            status.content = "Auto prices off: enable HTTP in Plugin Hub > Manage > Permissions, or enter prices manually."
            autoPermissionNotice = true
        end
        return false
    end
    autoPermissionNotice = false
    fetchBondPrice()
    local itemID = quantity(idInput)
    if itemID > 0 and not priceRequestPending then
        autoItemRequestedID = itemID
        fetchGuidePrice()
    end
    return true
end

addButton("Scan backpack", 280, 190, 110, function() scanBackpack(false) end)
addButton("Select next", 396, 190, 125, chooseNext)
addButton("Fetch GE price", 280, 216, 150, fetchGuidePrice)

addButton("Calculate Goal", 12, 763, 150, calculate)

addButton("Set Inventory Baseline", 175, 763, 175, function()
    local inv = Inventory.Find(INV)
    if inv and inv.isValid and state.itemId > 0 then
        state.previousCount = inv:GetTotal(state.itemId)
        status.content = "Inventory baseline set. New positive increases will count."
    else
        status.content = "Cannot set baseline. Enter a valid item ID first."
    end
end)

-- Forward declaration: Reset Progress callback is registered before the label is created.
local updatePendingLabel

addButton("Reset Progress", 365, 763, 160, function()
    state.produced = 0
    state.earnedGP = 0
    pendingItems = 0
    savePending()
    updatePendingLabel()
    PersistentDB:SetInt(KEY .. "milestoneReached", 0)
    state.complete = false
    state.previousCount = nil
    state.celebrationActive = false
    celebrationOut.content = ""
    celebrationOut.colour = Vector4.new(0.95, 0.92, 0.86, 1.0)
    titleBar.colour = Vector4.new(0.95, 0.92, 0.86, 1.0)
    progressFill.colour = Vector4.new(0.22, 0.68, 0.34, 1.0)
    status.content = "Progress reset. Set a new inventory baseline."
    save()
    refresh()
end)

-- Reset only the session, leaving lifetime Bond progress and daily totals intact.
addButton("Reset Session", 12, 801, 155, function()
    sessionSeconds, sessionProduced, sessionProfit = 0, 0, 0
    trendBaselineRate, trendBaselineAt, trendText = nil, nil, "Collecting data"
    status.content = "Session statistics reset; Bond progress and today's profit preserved."
end)

-- Review large inventory increases: backpack changes alone cannot identify bank withdrawals.
-- Keep the observed amount pending until the player explicitly counts or ignores it.
local pendingLabel = textLine("Large batch review: none pending", 12, 839, 255, 20, true)
local function creditProduction(delta)
    if delta <= 0 then return end
    state.produced = state.produced + delta
    state.earnedGP = state.earnedGP + delta * math.max(0, state.profit)
    sessionProduced = sessionProduced + delta
    local earned = delta * math.max(0, state.profit)
    sessionProfit = sessionProfit + earned
    if syncDay() then
        todayProfit = todayProfit + earned
        todayItems = todayItems + delta
        PersistentDB:SetInt(KEY .. "todayProfit", math.floor(todayProfit))
        PersistentDB:SetInt(KEY .. "todayItems", todayItems)
    end
    save()
    refresh()
    if state.target > 0 then
        local currentPct = progressPct()
        local highest = PersistentDB:GetInt(KEY .. "milestoneReached") or 0
        local newlyReached = 0
        for _, mark in ipairs({25, 50, 75}) do
            if currentPct >= mark and mark > highest then newlyReached = mark end
        end
        if newlyReached > 0 then
            PersistentDB:SetInt(KEY .. "milestoneReached", newlyReached)
            status.content = "Milestone reached: " .. newlyReached .. "% of your Bond goal!"
            celebrationOut.content = "*** " .. newlyReached .. "% BOND MILESTONE REACHED! ***"
        end
    end
    if not state.complete and goalReached() then
        state.complete = true
        showGoalCelebration()
    end
end
updatePendingLabel = function()
    pendingLabel.content = pendingItems > 0 and ("Review " .. fmt(pendingItems) .. " items:") or "Large batch review: none pending"
end
addButton("Count batch", 278, 835, 115, function()
    if pendingItems > 0 then
        local count = pendingItems
        pendingItems = 0
        savePending()
        creditProduction(count)
        status.content = "Counted " .. fmt(count) .. " reviewed items as production."
        updatePendingLabel()
    end
end)
addButton("Ignore batch", 402, 835, 123, function()
    if pendingItems > 0 then
        status.content = "Ignored " .. fmt(pendingItems) .. " items (e.g. bank withdrawal)."
        pendingItems = 0
        savePending()
        updatePendingLabel()
    end
end)

-- Compact HUD: progress, remaining profit, hourly rate and smart ETA.
local miniItem = textLine("Tracked: --", 12, 40, 510, 20)
local miniGoal = textLine("Bond: --", 12, 62, 510, 20)
local miniRemaining = textLine("Remaining profit: --", 12, 84, 510, 20)
local miniRate = textLine("GP/hour: --", 12, 106, 510, 20)
local miniEta = textLine("Bond ETA: waiting for production data", 12, 128, 510, 20)
local miniTrack = ui.Rectangle.new(panel)
miniTrack:SetPos(12, 153)
miniTrack:SetSize(510, 16)
miniTrack.fill = true
miniTrack.colour = Vector4.new(0.10, 0.09, 0.08, 1)
local miniFill = ui.Rectangle.new(panel)
miniFill:SetPos(13, 154)
miniFill:SetSize(0, 14)
miniFill.fill = true
local miniHint = textLine("", 12, 180, 385, 20)
local miniComponents = {miniItem, miniGoal, miniRemaining, miniRate, miniEta, miniTrack, miniFill, miniHint}

local themes = {
    Vector4.new(0.22, 0.68, 0.34, 1), -- green
    Vector4.new(0.90, 0.65, 0.16, 1), -- gold
    Vector4.new(0.28, 0.58, 0.92, 1)  -- blue
}
local function applyAppearance()
    panel.alpha = ({1.0, 0.90, 0.78})[opacity]
    if not state.celebrationActive then
        progressFill.colour = themes[accent]
    end
    miniFill.colour = themes[accent]
end
local function applyMode()
    panel:SetSize(WINDOW_WIDTH, panelHeight())
    for _, c in ipairs(details) do c.hidden = compact end
    for _, c in ipairs(miniComponents) do c.hidden = not compact end
    local maxX = math.max(0, gameWindow.width - WINDOW_WIDTH)
    local maxY = math.max(0, gameWindow.height - panelHeight())
    local nx, ny = math.max(0, math.min(maxX, panel.x)), math.max(0, math.min(maxY, panel.y))
    panel:SetPos(nx, ny)
    PersistentDB:SetInt(KEY .. "windowX", nx)
    PersistentDB:SetInt(KEY .. "windowY", ny)
end
local modeButton = ui.Button.new(panel)
modeButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
modeButton:SetPos(175, 801)
modeButton:SetSize(110, 28)
modeButton:Subscribe(ui.Hook.ONBUTTONPRESSED, "MGC_ToggleCompact", function()
    compact = not compact
    PersistentDB:SetInt(KEY .. "compact", compact and 1 or 0)
    applyMode()
end)
-- Always-accessible expand button in compact mode.
local expandButton = ui.Button.new(panel)
expandButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
expandButton:SetPos(416, 176)
expandButton:SetSize(108, 27)
expandButton.label = "Expand"
expandButton:Subscribe(ui.Hook.ONBUTTONPRESSED, "MGC_Expand", function()
    compact = false
    PersistentDB:SetInt(KEY .. "compact", 0)
    applyMode()
end)
miniHint:SetPos(12, 180)
miniHint:SetSize(385, 20)
local themeButton = ui.Button.new(panel)
themeButton:SetPos(294, 801)
themeButton:SetSize(110, 28)
themeButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
themeButton:Subscribe(ui.Hook.ONBUTTONPRESSED, "MGC_Theme", function()
    accent = accent % 3 + 1
    PersistentDB:SetInt(KEY .. "accent", accent)
    applyAppearance()
    themeButton.label = "Accent: " .. ({"Green", "Gold", "Blue"})[accent]
end)
local opacityButton = ui.Button.new(panel)
opacityButton:SetPos(412, 801)
opacityButton:SetSize(113, 28)
opacityButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
opacityButton:Subscribe(ui.Hook.ONBUTTONPRESSED, "MGC_Opacity", function()
    opacity = opacity % 3 + 1
    PersistentDB:SetInt(KEY .. "opacity", opacity)
    applyAppearance()
    opacityButton.label = "Opacity: " .. ({"100%", "90%", "78%"})[opacity]
end)
local function refreshModeButtons()
    modeButton.label = "Compact mode"
    themeButton.label = "Accent: " .. ({"Green", "Gold", "Blue"})[accent]
    opacityButton.label = "Opacity: " .. ({"100%", "90%", "78%"})[opacity]
    modeButton.hidden = compact
    themeButton.hidden = compact
    opacityButton.hidden = compact
    expandButton.hidden = not compact
end
local originalApplyMode = applyMode
applyMode = function()
    originalApplyMode()
    refreshModeButtons()
end
applyAppearance()
applyMode()

local function trackedCount()
    if state.itemId <= 0 then return nil end
    local inv = Inventory.Find(INV)
    if not inv or not inv.isValid then return nil end
    return inv:GetTotal(state.itemId)
end

local function onInventoryUpdated(event)
    if event.inv ~= INV then return end
    scanBackpack(true)
    if state.itemId <= 0 then return end
    local current = trackedCount()
    if current == nil then return end

    if state.previousCount == nil then
        state.previousCount = current
        return
    end

    local delta = current - state.previousCount
    state.previousCount = current
    if delta > 0 then
        if delta >= REVIEW_THRESHOLD or pendingItems > 0 then
            pendingItems = pendingItems + delta
            savePending()
            updatePendingLabel()
            status.content = "Inventory +" .. fmt(delta) .. ": review pending batch (count or ignore)."
        else
            creditProduction(delta)
        end
    end
end

Event.InventoryUpdated.Subscribe("MembershipGoalAuto_InventoryUpdated", onInventoryUpdated)

-- ETA helpers. A local clock time is optional; never require os APIs to load.
local function etaDuration(seconds)
    if seconds <= 0 then return "Goal reached" end
    local mins = math.ceil(seconds / 60)
    local hours = math.floor(mins / 60)
    local minutes = mins % 60
    if hours >= 24 then
        return tostring(math.floor(hours / 24)) .. "d " .. tostring(hours % 24) .. "h"
    end
    if hours > 0 then return tostring(hours) .. "h " .. tostring(minutes) .. "m" end
    return tostring(minutes) .. "m"
end
local function clockAt(seconds)
    if type(os) ~= "table" or type(os.time) ~= "function" or type(os.date) ~= "function" then return nil end
    local ok, result = pcall(function() return os.date("%I:%M %p", os.time() + math.ceil(seconds)) end)
    if ok and type(result) == "string" then return result end
    return nil
end

-- Draw event smoothly animates the fill width and pulses the completion message.
Event.Draw.Subscribe("MembershipGoalAuto_Draw", function(drawEvent)
    local dt = math.max(0, math.min(1, drawEvent.timeDeltaSecs or 0.016))
    refreshElapsed = refreshElapsed + dt
    startupRefresh = startupRefresh + dt
    if itemUpdateAge then itemUpdateAge = itemUpdateAge + dt end
    if bondUpdateAge then bondUpdateAge = bondUpdateAge + dt end
    -- Initial fetch retries after HTTP permission is granted, rather than
    -- permanently marking startup complete while access is disabled.
    if not autoStarted and startupRefresh >= 2 then
        if fetchAllPrices() then
            autoStarted = true
            refreshElapsed = 0
        else
            startupRefresh = 0
        end
    elseif autoStarted and refreshElapsed >= 300 then
        refreshElapsed = 0
        fetchAllPrices()
    end
    -- The initial refresh can run before a backpack item has been selected.
    -- Fetch immediately when the selected ID changes (also covers saved IDs).
    local selectedID = quantity(idInput)
    if autoStarted and selectedID > 0 and selectedID ~= autoItemRequestedID
        and Plugin.HasPermission(PluginPermissions.httpAccess) and not priceRequestPending then
        autoItemRequestedID = selectedID
        fetchGuidePrice()
    end
    -- Keep manual changes to costs / prices reflected in the goal without a button.
    local newBond, newItem, newCost = quantity(bondInput), quantity(priceInput), quantity(costInput)
    if newBond ~= state.bondPrice or newItem ~= state.itemPrice or newCost ~= state.materialCost then
        recalculateFromPrices()
    end
    updatePriceInfo()
    sessionSeconds = sessionSeconds + dt
    local rate = sessionSeconds >= 120 and math.floor(sessionProfit * 3600 / sessionSeconds) or nil
    local itemsRate = sessionSeconds >= 120 and math.floor(sessionProduced * 3600 / sessionSeconds) or nil
    if rate and rate > bestRate then
        bestRate = rate
        PersistentDB:SetInt(KEY .. "bestRate", bestRate)
    end
    -- Compare the current cumulative rate to a snapshot at least 60 seconds old.
    -- This is a rough trend, not a forecast guarantee.
    if rate and rate > 0 then
        if trendBaselineRate == nil then
            trendBaselineRate, trendBaselineAt = rate, sessionSeconds
            trendText = "Gathering trend"
        elseif sessionSeconds - trendBaselineAt >= 60 then
            if rate > trendBaselineRate * 1.05 then
                trendText = "Improving"
            elseif rate < trendBaselineRate * 0.95 then
                trendText = "Slowing"
            else
                trendText = "Steady"
            end
            trendBaselineRate, trendBaselineAt = rate, sessionSeconds
        end
    end
    local dateAvailable = syncDay()
    statsSession.content = "Session: " .. fmt(sessionProduced) .. " items | " .. fmt(sessionProfit) .. " GP profit"
    statsAverage.content = "Average: " .. (rate and fmt(rate) or "--") .. " GP/hour | " .. (itemsRate and fmt(itemsRate) or "--") .. " items/hour"
    statsToday.content = dateAvailable and ("Today (" .. dateAvailable .. "): " .. fmt(todayItems) .. " items | " .. fmt(todayProfit) .. " GP | Bond " .. string.format("%.1f%%", state.bondPrice > 0 and math.min(100, todayProfit / state.bondPrice * 100) or 0)) or "Today: unavailable (date API unsupported)"
    statsBest.content = "Best observed GP/hour: " .. (bestRate > 0 and fmt(bestRate) or "--")
    local remainingGp = math.max(0, state.bondPrice - state.earnedGP)
    local hasGoal = state.target > 0
    local etaSeconds = (hasGoal and rate and rate > 0) and remainingGp * 3600 / rate or nil
    local etaLabel, completion = "Waiting for GP/hour", nil
    if not hasGoal then
        etaLabel = "Set a valid Bond goal"
    elseif remainingGp <= 0 then
        etaLabel = "Goal reached"
    elseif etaSeconds then
        etaLabel = etaDuration(etaSeconds)
        completion = clockAt(etaSeconds)
    end
    local rateText = rate and (fmt(rate) .. " GP/h") or "warming up (120s)"
    local completionText = completion and (" | Finish ~" .. completion) or ""
    rateOut.content = "Rate: " .. rateText .. " | ETA: " .. etaLabel .. completionText
    miniRate.content = "GP/hour: " .. rateText .. " | Trend: " .. trendText
    miniEta.content = "Bond ETA: " .. etaLabel .. completionText
    local pct = progressPct()
    miniItem.content = "Tracked: " .. (state.itemName ~= "" and state.itemName or "Select an item") .. " | " .. fmt(state.produced) .. " produced"
    miniGoal.content = string.format("Bond progress: %.1f%%  |  %s GP earned", pct, fmt(state.earnedGP))
    miniRemaining.content = "GP remaining: " .. (hasGoal and (fmt(remainingGp) .. " GP") or "--")
    miniHint.content = pendingItems > 0 and ("Review " .. fmt(pendingItems) .. " items in full view") or (hasGoal and ("Next: " .. (pct < 25 and "25%" or (pct < 50 and "50%" or (pct < 75 and "75%" or "100%")))) or "")
    local difference = state.targetProgress - state.displayProgress
    if math.abs(difference) > 0.001 then
        state.displayProgress = state.displayProgress + difference * math.min(1, dt * 7)
    else
        state.displayProgress = state.targetProgress
    end

    local fillWidth = math.floor(508 * state.displayProgress + 0.5)
    progressFill:SetSize(fillWidth, 16)
    miniFill:SetSize(fillWidth, 14)

    if not state.celebrationActive then
        progressFill.colour = themes[accent]
    end
    if state.celebrationActive then
        state.celebrationTime = state.celebrationTime + dt
        local pulse = 0.5 + 0.5 * math.sin(state.celebrationTime * 8)
        celebrationOut.colour = Vector4.new(1.0, 0.65 + 0.30 * pulse, 0.12, 1.0)
        titleBar.colour = Vector4.new(1.0, 0.78 + 0.20 * pulse, 0.35, 1.0)
        progressFill.colour = Vector4.new(1.0, 0.55 + 0.40 * pulse, 0.08, 1.0)
    end
end)

scanBackpack(true)
state.previousCount = trackedCount()
updatePendingLabel()
refresh()

function PluginShutdown()
    save()
    savePending()
    PersistentDB:SetInt(KEY .. "bestRate", bestRate)
    PersistentDB:SetInt(KEY .. "todayProfit", math.floor(todayProfit))
    PersistentDB:SetInt(KEY .. "todayItems", todayItems)
    Event.InventoryUpdated.Unsubscribe("MembershipGoalAuto_InventoryUpdated")
    Event.Draw.Unsubscribe("MembershipGoalAuto_Draw")
end

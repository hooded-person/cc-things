local h = fs.open("players.log", "a")

function log(str)
    local time = os.date("!%d/%m/%y %T")
    local out = ("[%s] %s"):format(time, str)
    h.write(out .. "\n")
    h.flush()

    local oldColor = term.getTextColor()
    term.setTextColor(colors.gray)
    write(("[%s] "):format(time))
    term.setTextColor(oldColor)

    print(str)
end

local detector = peripheral.find("playerDetector")
local chatbox = peripheral.find("chatBox")

if detector == nil then
    term.setTextColor(colors.red)
    print("Could not find player detector")
    term.setTextColor(colors.white)
    if fs.exists("/startup.lua") then
        print("Auto-restarting in 5 seconds")
        sleep(5)
        os.reboot()
    else
        return
    end
end
if chatbox == nil then
    term.setTextColor(colors.gray)
    print("No chatbox connected, connect a chatbox to send messages to incoming players")
    term.setTextColor(colors.white)
end

-- START CONFIGURATION
local subscribed = "HoodedKingGreen" -- "unkown_zen"
local excluded = { "unkown_zen", }
local hate = { "HoodedKingGreen" }

local layers = {
    {
        vector.new(1359, 92, -1140),
        vector.new(1324, 97, -1172),
        name = "First Layer",
        relayName = "redstone_relay_12",
        relaySide = "top"
    },
    {
        vector.new(1360, 92, -1140),
        vector.new(1324, 87, -1172),
        name = "Second Layer",
        relayName = "redstone_relay_14",
    },
    {
        vector.new(1360, 86, -1140),
        vector.new(1338, 60, -1162),
        name = "Third Layer",
        relayName = "redstone_relay_13",
    },
}
local toastTitle = "Zen's base entered"
local enterToast = "You entered the '%s' of unkown_zen's base."
local enterToastHated = "You entered the '%s' of unkown_zen's base. Please leave the premises."
-- END CONFIGURATION

local players = {}
local playersPerLayer = {}

local function toCheckMap(table)
    local map = {}
    for _, v in ipairs(table) do
        map[v] = true
    end
    return map
end

local excludedMap = toCheckMap(excluded)
local hateMap = toCheckMap(hate)

function handlePlayerEnter(player, layer)
    players[player] = layer.id

    if hateMap[player] then
        term.setTextColor(colors.orange)
    end
    log(("Player '%s' entered %s"):format(player, layer.name))
    term.setTextColor(colors.white)

    if excludedMap[player] then
        return
    end

    if chatbox ~= nil then
        if hateMap[player] then
            chatbox.sendToastToPlayer(enterToastHated:format(layer.name), toastTitle, player, "KGsec", "{}")
        else
            chatbox.sendToastToPlayer(enterToast:format(layer.name), toastTitle, player, "KGsec", "{}")
        end

        sleep(1) -- account for cooldown

        local msg = {
            { text = ("Player '%s' entered %s."):format(player, layer.name), color = hateMap[player] and "gold" or "white" },
        }
        chatbox.sendFormattedMessageToPlayer(
            textutils.serialiseJSON(msg),
            subscribed,
            "KGsec", "{}"
        )
    end

    if layer.relayName then
        if not layer.relay then
            layer.relay = peripheral.wrap(layer.relayName)
        end
        local side = layer.relaySide or "front"
        layer.relay.setOutput(side, true)
        sleep()
        layer.relay.setOutput(side, false)
    end
end

function handlePlayerLeave(player, layer)
    if players[player] == layer.id then players[player] = nil end

    log(("Player '%s' left %s"):format(player, layer.name))
end

function handleLayer(id, layer)
    local detected = detector.getPlayersInCoords(layer[1], layer[2])
    playersPerLayer[id] = toCheckMap(detected)
    while true do
        local detected = detector.getPlayersInCoords(layer[1], layer[2])
        local detectedMap = toCheckMap(detected)

        -- detect players entering
        for _, player in ipairs(detected) do
            if not playersPerLayer[id][player] then
                handlePlayerEnter(player, layer)
            end
        end

        -- detect players leaving
        for player, _ in pairs(playersPerLayer[id]) do
            if not detectedMap[player] then
                handlePlayerLeave(player, layer)
            end
        end

        playersPerLayer[id] = detectedMap
    end
end

local callers = {}

for id, layer in ipairs(layers) do
    layer.id = id
    if layer.relayName then layer.relay = peripheral.wrap(layer.relayName) end
    table.insert(callers, function() handleLayer(id, layer) end)
end

parallel.waitForAny(table.unpack(callers))

print("Something went wrong")
if fs.exist("/startup.lua") then
    print("Auto-restarting in 5 seconds")
    sleep(5)
    os.reboot()
end

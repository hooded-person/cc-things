-- Daemon: A basic script runner that runs scripts from a specific folder
-- Has a UI to oversee all running processes and view their output windows
-- Requires Taskmaster by JackMacWindows: https://gist.github.com/MCJack123/1678fb2c240052f1480b07e9053d4537
-- Made by kinggreen
-- Licensed under the MIT license

local loop = require "taskmaster" ()
local defaultEventBlacklist = { "key", "key_up", "char", "paste", "mouse_click", "mouse_up", "mouse_scroll", "mouse_drag" }
loop:setEventBlacklist(defaultEventBlacklist)

-- CONFIG
local base_dir = "/programs"
local data_dir = "/data"
local confirmKillTimeout = 1
-- keep alive
local config = {
    keep_alive = {
        max_retries = 5, ---@field max_retries number The amount of retries that will be attempted in `retry_timespan` seconds. Set to -1 to auto-restart infinitly.
        retry_timespan = 5 * 60, ---@field retry_timespan number The maximum amount of seconds that can be between the `max_retries` ago fail and current time
        retry_delay = 1, ---@field retry_delay number The amount of seconds to wait before restarting the process
    },
}
-- CONFIG VALIDATION
if config.keep_alive.retry_delay * config.keep_alive.max_retries > config.keep_alive.retry_timespan then
    error(("Due to retry_delay (%d), processes can never fail %d times in %d seconds"):format(
        config.keep_alive.retry_delay, config.keep_alive.max_retries, config.keep_alive.retry_timespan
    ))
end
-- END CONFIG

---@class Process
---@field name string Name of the process
---@field entrypoint string Absolute path to the main file of this process
---@field data_folder string Absolute path to the data folder of this process
---@field task Task The taskmaster Task that this process is running in.
---@field confirmKill boolean Wether killing this process requires confirmation
---@field lastKillClick? number Epoch miliseconds (utc) when the kill button was last pressed
---@field fails number[] Rolling window of the last `config.keep_alive.max_retries` fails epoch seconds. Index 1 is the newest.
---@field dead boolean Wether the program has failed to many times (`config.keep_alive.max_retries`) within the configured timespan (`config.keep_alive.retry_timespan`)


---@type Process[]
local processes = {}

local parentTerm = term.current()
local width, height = parentTerm.getSize()

-- Daemon functionality

local function copyTable(source, settings, destination)
    settings    = settings or {}
    destination = destination or {}

    for k, v in pairs(source) do
        local excluded = false
        if type(settings.exclude) == "function" then
            excluded = settings.exclude(k)
        elseif type(settings.exclude) == "table" then
            excluded = settings.exclude[k]
        end

        if not excluded and destination[k] == nil or settings.override == true then
            destination[k] = v
        end
    end

    return destination
end

local function deepCopyInto(source, destination)
    for k, v in pairs(source) do
        if type(v) == "table" then
            destination[k] = type(destination[k]) == "table" and destination[k] or {}
            deepCopyInto(v, destination[k])
        else
            destination[k] = v
        end
    end
end

local function keepAlive(process, func)
    process.fails = {}
    process.dead = false
    return function()
        while not process.dead do
            func()
            local now = os.epoch("utc") / 1000
            table.insert(process.fails, 1, now)
            if config.keep_alive.max_retries ~= -1 and #process.fails >= config.keep_alive.max_retries and now - process.fails[config.keep_alive.max_retries] < config.keep_alive.retry_timespan then
                process.dead = true
                local oldTerm = term.current()
                term.redirect(process.win)
                local oldColor = term.getTextColor()
                term.setTextColor(colors.red)
                print(("Process failed %d times in %d seconds. Stopping auto-restart"):format(
                    config.keep_alive.max_retries,
                    now - process.fails[config.keep_alive.max_retries]
                ))
                term.setTextColor(oldColor)
                term.redirect(oldTerm)
            else
                local oldTerm = term.current()
                term.redirect(process.win)
                local oldColor = term.getTextColor()
                term.setTextColor(colors.red)
                print(("Auto restarting in %d second(s)"):format(config.keep_alive.retry_delay))
                term.setTextColor(oldColor)
                term.redirect(oldTerm)
            end
            if #process.fails > config.keep_alive.max_retries then
                table.remove(process.fails)
            end
        end
    end
end

local function addProcess(name, func, options)
    options = options or {}
    local process = {
        name = name,
        entrypoint = tostring(func),
        data_folder = "/" .. fs.combine(data_dir, name),
        confirmKill = false,
        hooks = {},
    }
    processes[name] = process

    process.shared = copyTable(process)

    process.win = window.create(parentTerm, 1, 2, width, height - 1, false)

    process.task = loop:addTask(
        keepAlive(process, function()
            term.redirect(process.win)
            func()
            term.redirect(parentTerm)
        end)
    )
    if options.eventBlacklist ~= nil then
        process.task:setEventBlacklist(options.eventBlacklist)
    end
    if options.confirmKill ~= nil then
        process.confirmKill = options.confirmKill
    end
    if type(options.hooks) == "table" then
        deepCopyInto(options.hooks, process.hooks) -- prevent hook modification after registration
    end

    return true, process
end

local function addProcessFile(name, entrypoint)
    if not fs.exists(entrypoint) then
        return false, "Entrypoint does not exist"
    elseif fs.isDir(entrypoint) then
        return false, "Entrypoint is not a file"
    end
    if type(name) ~= "string" then
        return false, "Name must be a string"
    end

    local process = {
        name = name,
        entrypoint = entrypoint,
        data_folder = "/" .. fs.combine(data_dir, name),
    }
    processes[name] = process

    process.shared = copyTable(process)

    process.win = window.create(parentTerm, 1, 2, width, height - 1, false)

    process.task = loop:addTask(
        keepAlive(process, function()
            term.redirect(process.win)
            shell.execute(entrypoint, textutils.serialise(process.shared, { compact = true }))
            term.redirect(parentTerm)
        end)
    )

    return true, process
end

local h = fs.open("/" .. fs.combine(base_dir, "daemons.lon"), "r")
if not h then
    error("'daemons.lon' definition file does not exist")
end
local serialised = h.readAll()
h.close()
local daemons = textutils.unserialise(serialised)
if daemons == nil then
    error("'daemons.lon' definition file is not a valid lua table")
end

for index, data in pairs(daemons) do
    local name = index
    local entrypoint = data
    if type(data) == "table" then
        entrypoint = data.entrypoint
    end

    if fs.exists("/" .. fs.combine(base_dir, entrypoint)) then
        entrypoint = "/" .. fs.combine(base_dir, entrypoint)
    end

    if type(name) == "number" then
        name = data.name
            :lower()
            :gsub(" ", "_")
    end

    local ok, err = addProcessFile(name, entrypoint)
    if not ok then
        print(tostring(index) .. ":" .. err)
    end
end

-- daemon UI task
local processListWin = window.create(parentTerm, 1, 2, width, height - 1)

local processList = {}

local function updateProcessList()
    local oldTerm = term.current()
    term.redirect(processListWin)

    local w, h = processListWin.getSize()

    processListWin.setVisible(false)
    term.clear()

    local y = 1
    for name, process in pairs(processes) do
        processList[y] = name
        term.setCursorPos(1, y)

        term.setTextColor(process.dead and colors.red or colors.white)
        write(name)

        term.setCursorPos(w - 8, y)
        local now = os.epoch("utc") / 1000
        if process.confirmKill and not (process.lastKillClick ~= nil and now - process.lastKillClick < confirmKillTimeout) then
            term.blit("View Kill", "44440eeee", "fffffffff")
        else
            term.blit("View Kill", "444400000", "fffffeeee")
        end

        y = y + 1
    end
    for i = y, #processList do
        processList[i] = nil
    end

    processListWin.setVisible(true)


    term.redirect(oldTerm)
end

local function drawMainBar(name, showExitBtn)
    local oldTerm = term.current()
    term.redirect(parentTerm)
    local oldTextColor = term.getTextColor()
    local oldBackgroundColor = term.getBackgroundColor()

    local w, h = term.getSize()

    term.setCursorPos(1, 1)
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
    term.write(name .. (" "):rep(w - #name))

    if showExitBtn then
        term.setCursorPos(w - 3, 1)
        term.setBackgroundColor(colors.red)
        write("Exit")
    end

    term.setTextColor(oldTextColor)
    term.setBackgroundColor(oldBackgroundColor)
    term.redirect(oldTerm)
end

local function updateOpenedWindow(nameOld, nameNew)
    if nameOld ~= nil and processes[nameOld] and processes[nameOld].win then
        processes[nameOld].win.setVisible(false)
    end
    if nameNew ~= nil and processes[nameNew] == nil then
        return nil
    end
    if nameNew ~= nil and processes[nameNew] and processes[nameNew].win then
        processes[nameNew].win.setVisible(true)
    end
    return processes[nameNew] and nameNew or nil
end

local function daemonUIClicks()
    local openedProcessWindow
    -- openedProcessWindow = updateOpenedWindow(openedProcessWindow, "incremental")

    while true do
        drawMainBar(
            openedProcessWindow == nil and "Daemon UI" or openedProcessWindow .. " (" .. processes[openedProcessWindow].entrypoint ..")",
            openedProcessWindow ~= nil
        )
        if multishell then
            multishell.setTitle(multishell.getCurrent(),
                openedProcessWindow == nil and "Daemon UI" or "DUI:" .. openedProcessWindow)
        end
        if openedProcessWindow == nil then
            updateProcessList()
        end

        local w, h = term.getSize()
        local eventData = { os.pullEvent() }
        local event = table.remove(eventData, 1)

        if event == "mouse_click" then
            local button, x, y = table.unpack(eventData)
            if openedProcessWindow ~= nil then
                if y == 1 and x >= w - 3 then -- Exit button (close process window view)
                    openedProcessWindow = updateOpenedWindow(openedProcessWindow, nil)
                end
            elseif y > 1 and processList[y - 1] ~= nil then -- in the process list, on a valid process
                local process_name = processList[y - 1]
                if x >= w - 8 and x <= w - 4 then           -- View button
                    openedProcessWindow = updateOpenedWindow(openedProcessWindow, process_name)
                elseif x >= w - 3 then                      -- Kill button
                    local log = fs.open("error.log", "w")
                    log.write("killing " .. process_name .. "\n")
                    log.flush()

                    ---@class Process
                    local process = processes[process_name]
                    if process.confirmKill and process.lastKillClick == nil then
                        process.lastKillClick = 0
                    end

                    log.write("retrieved process:\n")
                    log.write(("confirmKill: %s\n"):format(process.confirmKill))
                    log.flush()

                    local now = os.epoch("utc") / 1000

                    if not process.confirmKill or now - process.lastKillClick < confirmKillTimeout then
                        if process.hooks and process.hooks.beforeKill then
                            process.hooks.beforeKill()
                        end
                        processes[process_name] = nil
                        process.task:remove()
                    else
                        process.lastKillClick = now
                    end

                    log.close()
                end
            end
        end
    end
end

addProcess("daemon_ui", daemonUIClicks, {
    confirmKill = true,
    eventBlacklist = {},
    hooks = {
        beforeKill = function()
            processListWin.setVisible(false)
            term.redirect(parentTerm)
            term.clear()
            term.setTextColor(colors.white)
            term.setBackgroundColor(colors.black)
            term.setCursorPos(1, 1)
            print("Daemon UI process was killed, processes are still running\nRestart daemon.lua to restart Daemon UI")
        end,
    },
})

loop:run()

term.redirect(parentTerm)
term.clear()
term.setTextColor(colors.white)
term.setBackgroundColor(colors.black)
term.setCursorPos(1, 1)
print("Deamon stopped")

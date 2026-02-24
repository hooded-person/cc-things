-- Daemon: A basic script runner that runs scripts from a specific folder
-- Has a UI to oversee all running processes and view their output windows
-- Requires Taskmaster by JackMacWindows: https://gist.github.com/MCJack123/1678fb2c240052f1480b07e9053d4537
-- Made by kinggreen
-- Licensed under the MIT license

local loop = require("taskmaster")()
local defaultEventBlacklist = { "key", "key_up", "char", "paste", "mouse_click", "mouse_up", "mouse_scroll", "mouse_drag" }
loop:setEventBlacklist(defaultEventBlacklist)

local base_dir = "/programs"
local data_dir = "/data"
local confirmKillTimeout = 1

---@class Process
---@field name string Name of the process
---@field entrypoint string Absolute path to the main file of this process
---@field data_folder string Absolute path to the data folder of this process
---@field task Task The taskmaster Task that this process is running in.
---@field confirmKill boolean Wether killing this process requires confirmation
---@field lastKillClick? number Epoch miliseconds (utc) when the kill button was last pressed

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

    process.task = loop:addTask(function()
        term.redirect(process.win)
        func()
        term.redirect(parentTerm)
    end)
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

    local process = {
        name = name,
        entrypoint = entrypoint,
        data_folder = "/" .. fs.combine(data_dir, name),
    }
    processes[name] = process

    process.shared = copyTable(process)

    process.win = window.create(parentTerm, 1, 2, width, height - 1, false)

    process.task = loop:addTask(function()
        term.redirect(process.win)
        ---@diagnostic disable-next-line: undefined-field
        os.run({}, entrypoint, process.shared)
        term.redirect(parentTerm)
    end)

    return true, process
end

local h = fs.open("/" .. fs.combine(base_dir, "daemons.lon"), "r")
if not h then
    error("'daemons.lon' definition file does not exist")
end
local serialised = h.readAll()
h.close()
local daemons = textutils.unserialise(serialised)

for name, data in pairs(daemons) do
    local entrypoint = data
    if type(data) == "table" then
        entrypoint = data.entrypoint
    end

    addProcessFile(name, entrypoint)
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
    write(name .. (" "):rep(w - #name))

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
        drawMainBar(openedProcessWindow or "Daemon UI", openedProcessWindow ~= nil)
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

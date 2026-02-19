return function(file)
    local h = fs.open(file, "a")

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

    return log
end

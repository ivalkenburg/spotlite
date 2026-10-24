local s = require("spotlite")
local own, external, host_pid, last_query = false, false, nil, ""
local duration_task, last_icon, last_indicator
local render, set_enabled

local function refresh()
    own = s.power.get({handle="display"})
    external = false
    for _, assertion in ipairs(s.power.list()) do
        if assertion.pid ~= host_pid and assertion.process:lower() == "caffeinate"
           and assertion.type == "PreventUserIdleDisplaySleep" and assertion.level > 0 then
            external = true
        end
    end
    local icon = own and "cup.and.saucer.fill" or "cup.and.saucer"
    if icon ~= last_icon then
        s.commands.update({id="caffeinate", icon=icon})
        last_icon = icon
    end
    local signature = tostring(own) .. ":" .. tostring(external)
    if signature ~= last_indicator then
        if own or external then
            local lines, menu = {}, {}
            if own then lines[#lines+1] = "Caffeinate active in Spotlite" end
            if external then lines[#lines+1] = own and "Also active in another app" or "Caffeinate active in another app" end
            for _, line in ipairs(lines) do menu[#menu+1] = {title=line, enabled=false} end
            if own then
                menu[#menu+1] = {separator=true}
                menu[#menu+1] = {id="off",title="Turn Off Caffeinate"}
            end
            s.status.set({id="indicator",icon="cup.and.saucer.fill",tooltip=table.concat(lines,"\n"),menu=menu})
        else s.status.remove({id="indicator"}) end
        last_indicator = signature
    end
end

set_enabled = function(enabled, seconds, silent)
    if duration_task then s.cancel_background(duration_task); duration_task = nil end
    local ok, failure = pcall(function()
        if enabled then
            s.power.create({id="display", type="PreventUserIdleDisplaySleep", name="Spotlite caffeinate"})
        else s.power.release({handle="display"}) end
    end)
    if not ok then
        if not silent then s.toast.show({text="Couldn’t " .. (enabled and "enable" or "disable") .. " Caffeinate",icon="exclamationmark.triangle"}) end
        error(failure)
    end
    refresh()
    if enabled and seconds then
        duration_task = s.background(function()
            s.timers.sleep({seconds=seconds})
            duration_task = nil
            set_enabled(false, nil, true)
            s.ui.update(render(last_query))
        end)
    end
    if not silent then
        local text = own and "Caffeinate enabled" or external and "Spotlite Caffeinate disabled; another app is keeping the display awake" or "Caffeinate disabled"
        s.toast.show({text=text, icon=own and "cup.and.saucer.fill" or "cup.and.saucer"})
    end
end

render = function(query)
    local items = {
        {id="toggle", title="Toggle Caffeinate", state=own,
         subtitle=external and "Also active in another app" or nil,
         icon=own and "cup.and.saucer.fill" or "cup.and.saucer",
         actions={{id="toggle",title=own and "Turn Off" or "Turn On"}}},
        {id="30m",title="Keep Awake for 30 Minutes",icon="clock",actions={{id="duration",title="Turn On",data={seconds=1800}}}},
        {id="1h",title="Keep Awake for 1 Hour",icon="clock",actions={{id="duration",title="Turn On",data={seconds=3600}}}},
        {id="2h",title="Keep Awake for 2 Hours",icon="clock",actions={{id="duration",title="Turn On",data={seconds=7200}}}}
    }
    if query and query ~= "" then
        local found = {}
        for _, item in ipairs(items) do
            local at, title, matched = 1, item.title:lower(), true
            for character in query:lower():gmatch(".") do
                local position = title:find(character, at, true)
                if not position then matched = false; break end
                at = position + 1
            end
            if matched then found[#found+1] = item end
        end
        items = found
    end
    return {id="caffeinate",title="Caffeinate",items=items}
end

return {
    start = function()
        host_pid = s.system.info().pid
        refresh()
        s.background(function()
            while true do
                s.timers.sleep({seconds=5,tolerance=1})
                refresh()
                s.ui.update(render(last_query))
            end
        end)
    end,
    search = function(args) last_query = args.query or ""; return render(last_query) end,
    action = function(args)
        own = s.power.get({handle="display"})
        if args.action.id == "duration" then set_enabled(true,args.action.data.seconds,args.silent)
        else set_enabled(not own,nil,args.silent) end
        s.ui.update(render(last_query))
    end,
    event = function(args)
        if args.type == "status.action" and args.action == "off" then set_enabled(false,nil,args.silent)
        else refresh() end
        s.ui.update(render(last_query))
    end
}

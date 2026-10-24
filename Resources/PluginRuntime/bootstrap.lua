local runtime = _spotlite_bootstrap:match("^(.*)/[^/]+$")
local package_root = _spotlite_package
package.path = package_root .. "/?.lua;" .. package_root .. "/?/init.lua;" .. runtime .. "/?.lua;" .. package.path
local json = dofile(runtime .. "/json.lua")
local tasks, waiting, ready, plugin, sequence = {}, {}, {}, nil, 0
local api = { json = json, api_version = 1 }
package.loaded.spotlite = api
local function send(message) _spotlite_send(json.encode(message)) end
local function host(method, params)
    local result, err = coroutine.yield({ method = method, params = params or json.object() })
    if err then error(err, 2) end
    return result
end
local function section(name, methods)
    api[name] = {}
    for _, method in ipairs(methods) do
        api[name][method] = function(params) return host(name .. "." .. method, params) end
    end
end
section("http", { "request" })
section("process", { "run" })
section("clipboard", { "read", "write" })
section("system", { "open", "notify", "info" })
section("power", { "create", "release", "get", "list" })
section("status", { "set", "get", "remove" })
section("toast", { "show" })
section("commands", { "update" })
section("storage", { "get", "set", "remove", "paths" })
section("credentials", { "get", "set", "remove" })
section("settings", { "get", "set" })
section("ui", { "push", "replace", "pop", "close", "update" })
section("timers", { "sleep" })
function api.log(message, level) return host("log", { message = tostring(message), level = level or "info" }) end
function api.background(fn)
    assert(type(fn) == "function", "background expects a function")
    sequence = sequence + 1
    local id = "background:" .. sequence
    tasks[id] = { coroutine = coroutine.create(fn), background = true }
    ready[#ready + 1] = id
    send({method="background.started", params={id=id}})
    return id
end
local function clear_task(id)
    local task = tasks[id]
    if not task then return end
    tasks[id] = nil
    if task.background then send({method="background.finished", params={id=id}}) end
    for request, parent in pairs(waiting) do if parent == id then waiting[request] = nil end end
    coroutine.close(task.coroutine)
end
function api.cancel_background(id)
    local task = tasks[id]
    if not task or not task.background then return false end
    send({method="background.cancelled",params={id=id}})
    clear_task(id)
    return true
end
local function resume_task(id, result, err)
    local task = tasks[id]
    if not task then return end
    local ok, value = coroutine.resume(task.coroutine, result, err)
    if not ok then
        local trace = debug.traceback(task.coroutine, tostring(value))
        if task.background then send({ method="log", params={message=trace, level="error"} })
        else send({ id=id, error=trace }) end
        clear_task(id)
    elseif coroutine.status(task.coroutine) == "dead" then
        if not task.background then send({ id=id, result=value == nil and json.null or value }) end
        clear_task(id)
    else
        if type(value) ~= "table" or type(value.method) ~= "string" then
            send({ id=id, error="Plugins must yield through the spotlite API" }); clear_task(id); return
        end
        sequence = sequence + 1; local request = "host:" .. sequence
        waiting[request] = id
        send({ id=request, method=value.method, params={ task=id, arguments=value.params } })
    end
end
local function start(message)
    tasks[message.id] = { coroutine = coroutine.create(function()
        local args = message.params or {}
        if message.method == "initialize" then
            api.plugin = args
            local file, err = loadfile(package_root .. "/" .. args.entry)
            assert(file, err)
            plugin = file()
            assert(type(plugin) == "table", "main.lua must return a plugin table")
            if plugin.start then plugin.start(args) end
            return true
        end
        assert(plugin, "plugin is not initialized")
        if message.method == "test" and type(api.plugin.testEntry) == "string" then
            local run = assert(loadfile(package_root .. "/" .. api.plugin.testEntry))()
            return run(plugin, args)
        end
        local handler = plugin[message.method]
        if handler then return handler(args) end
        if message.method == "search" then return { id=args.command, title=args.title, items={} } end
        if message.method == "event" then return true end
        error("Plugin does not implement " .. tostring(message.method))
    end) }
    resume_task(message.id)
end
local function dispatch(message)
    if message.method == "cancel" then
        local target = message.params and message.params.id
        clear_task(target)
    elseif message.method then
        assert(type(message.id) == "string", "request ID missing")
        start(message)
    elseif message.id and waiting[message.id] then
        local parent = waiting[message.id]; waiting[message.id] = nil
        local result = message.result
        if result == json.null then result = nil end
        resume_task(parent, result, message.error)
    end
    -- Background coroutines start after their creating callback first yields/returns.
    -- Drain children created by other backgrounds before waiting for more input.
    local index = 1
    while index <= #ready do
        resume_task(ready[index])
        index = index + 1
    end
    ready = {}
end
for line in io.lines() do
    if #line > 4 * 1024 * 1024 then error("host message exceeds 4 MiB") end
    local ok, message = pcall(json.decode, line)
    if not ok then io.stderr:write(tostring(message), "\n"); break end
    local success, err = pcall(dispatch, message)
    if not success then send({ id=message.id, error=tostring(err) }) end
end

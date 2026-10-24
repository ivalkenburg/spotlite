-- JSON codec for the runner protocol and plugin APIs. No external Lua modules.
local json = {}
json.null = setmetatable({}, { __json = "null" })
function json.array(t) return setmetatable(t or {}, { __json = "array" }) end
function json.object(t) return setmetatable(t or {}, { __json = "object" }) end
local escapes = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local function quote(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c) return escapes[c] or string.format('\\u%04x', c:byte()) end) .. '"'
end
function json.encode(value)
    local seen = {}
    local function encode(v, depth)
        if depth > 64 then error("JSON nesting exceeds 64") end
        local kind = type(v)
        if v == json.null or kind == "nil" then return "null" end
        if kind == "boolean" then return tostring(v) end
        if kind == "number" then
            assert(v == v and v ~= math.huge and v ~= -math.huge, "non-finite JSON number")
            return string.format("%.17g", v)
        end
        if kind == "string" then return quote(v) end
        assert(kind == "table", "unsupported JSON value: " .. kind)
        assert(not seen[v], "cyclic JSON value"); seen[v] = true
        local mt, length, count, array = getmetatable(v), #v, 0, true
        for k in pairs(v) do count = count + 1; if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > length then array = false end end
        array = array and count == length
        if mt and mt.__json == "object" then array = false end
        if mt and mt.__json == "array" then assert(array, "invalid JSON array") end
        local parts = {}
        if array then
            for i = 1, length do parts[i] = encode(v[i], depth + 1) end
        else
            for k, item in pairs(v) do
                assert(type(k) == "string", "JSON object keys must be strings")
                parts[#parts + 1] = quote(k) .. ":" .. encode(item, depth + 1)
            end
        end
        seen[v] = nil
        return (array and "[" or "{") .. table.concat(parts, ",") .. (array and "]" or "}")
    end
    return encode(value, 0)
end
function json.decode(text)
    local pos = 1
    local function ws() local _, finish = text:find("^[ \t\r\n]*", pos); pos = (finish or pos - 1) + 1 end
    local function fail(message) error(message .. " at byte " .. pos, 0) end
    local function hex()
        local digits = text:sub(pos, pos + 3)
        if #digits ~= 4 or not digits:match("^%x%x%x%x$") then fail("invalid Unicode escape") end
        pos = pos + 4; return tonumber(digits, 16)
    end
    local function str()
        pos = pos + 1
        local parts, begin = {}, pos
        while pos <= #text do
            local c = text:sub(pos, pos)
            if c == '"' then parts[#parts + 1] = text:sub(begin, pos - 1); pos = pos + 1; return table.concat(parts) end
            if c == "\\" then
                parts[#parts + 1] = text:sub(begin, pos - 1)
                pos = pos + 1; c = text:sub(pos, pos); pos = pos + 1
                local simple = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
                if c == "u" then
                    local code = hex()
                    if code >= 0xd800 and code <= 0xdbff then
                        if text:sub(pos, pos + 1) ~= "\\u" then fail("missing low surrogate") end
                        pos = pos + 2; local low = hex()
                        if low < 0xdc00 or low > 0xdfff then fail("invalid low surrogate") end
                        code = 0x10000 + (code - 0xd800) * 0x400 + low - 0xdc00
                    elseif code >= 0xdc00 and code <= 0xdfff then fail("unexpected low surrogate") end
                    parts[#parts + 1] = utf8.char(code)
                elseif simple[c] then parts[#parts + 1] = simple[c]
                else fail("invalid string escape") end
                begin = pos
            else
                if c:byte() < 32 then fail("control character in string") end
                pos = pos + 1
            end
        end
        fail("unterminated string")
    end
    local parse
    parse = function(depth)
        if depth > 64 then fail("JSON nesting exceeds 64") end
        ws(); local c = text:sub(pos, pos)
        if c == '"' then return str() end
        if c == "{" or c == "[" then
            local object, out = c == "{", c == "{" and json.object() or json.array()
            local finish = object and "}" or "]"
            pos = pos + 1; ws()
            if text:sub(pos, pos) == finish then pos = pos + 1; return out end
            while true do
                local key
                if object then
                    ws(); if text:sub(pos, pos) ~= '"' then fail("expected object key") end
                    key = str(); ws(); if text:sub(pos, pos) ~= ":" then fail("expected colon") end
                    pos = pos + 1
                else key = #out + 1 end
                out[key] = parse(depth + 1); ws(); c = text:sub(pos, pos); pos = pos + 1
                if c == finish then return out end
                if c ~= "," then fail("expected comma") end
            end
        end
        for token, value in pairs({ ["true"]=true, ["false"]=false, ["null"]=json.null }) do
            if text:sub(pos, pos + #token - 1) == token then pos = pos + #token; return value end
        end
        local _, finish = text:find("^-?%d+%.%d+[eE][+-]?%d+", pos)
        if not finish then _, finish = text:find("^-?%d+[eE][+-]?%d+", pos) end
        if not finish then _, finish = text:find("^-?%d+%.%d+", pos) end
        if not finish then _, finish = text:find("^-?%d+", pos) end
        if finish then
            local number = text:sub(pos, finish)
            if number:match("^-?0%d") then fail("leading zero") end
            local value = tonumber(number)
            if not value or value == math.huge or value == -math.huge then fail("invalid number") end
            pos = finish + 1; return value
        end
        fail("invalid JSON value")
    end
    local value = parse(0); ws()
    if pos <= #text then fail("trailing JSON data") end
    return value
end
return json

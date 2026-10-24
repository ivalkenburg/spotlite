local s = require("spotlite")
local function escape(text)
    return (text:gsub("[^%w%-%.%_%~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local categories = {{id="repositories", title="Repositories", icon="folder"}, {id="issues", title="Issues", icon="circle.dotted"}, {id="pulls", title="Pull Requests", icon="arrow.triangle.pull"}}
local function search_view(category)
    local title = category == "repositories" and "Repositories" or category == "issues" and "Issues" or "Pull Requests"
    return {id=category, title=title, placeholder="Search " .. title:lower(), data={category=category}, items={}}
end
return {
    search = function(args)
        local category = args.view and args.view.data and args.view.data.category
        if not category and (not args.query or args.query == "") then
            local items = {}
            for _, cat in ipairs(categories) do
                items[#items+1] = {id=cat.id, title="Search " .. cat.title, icon=cat.icon, actions={{id="category", title="Open", data={category=cat.id}}}}
            end
            return {id="github", title="GitHub", items=items}
        end
        local settings = s.settings.get()
        if not category then
            category = settings.category == "Issues" and "issues" or settings.category == "Pull requests" and "pulls" or "repositories"
        end
        local view = search_view(category)
        if not args.query or args.query == "" then return view end
        local headers = {Accept="application/vnd.github+json", ["User-Agent"]="Spotlite", ["X-GitHub-Api-Version"]="2022-11-28"}
        if type(settings.token) == "string" and settings.token ~= "" then headers.Authorization = "Bearer " .. settings.token end
        local query = args.query
        if category == "issues" then query = query .. " is:issue" elseif category == "pulls" then query = query .. " is:pr" end
        local endpoint = category == "repositories" and "repositories" or "issues"
        local response = s.http.request({url="https://api.github.com/search/" .. endpoint .. "?per_page=40&q=" .. escape(query), headers=headers})
        local body = s.json.decode(response.body)
        if response.status ~= 200 then
            error("GitHub: " .. (body.message or ("HTTP " .. tostring(response.status))) .. ". Check the query and token in Plugins settings.")
        end
        for _, item in ipairs(body.items or {}) do
            local actions = {{id="open", title="Open in GitHub", close=true}, {id="copy_url", title="Copy URL", key="cmd+c"}}
            if item.number then actions[#actions+1] = {id="copy_number", title="Copy Number"} end
            actions[#actions+1] = {id="details", title="Show Details"}
            view.items[#view.items+1] = {
                id=tostring(item.id), title=item.full_name or item.title,
                subtitle=item.full_name and (item.description ~= s.json.null and item.description or "") or ("#" .. tostring(item.number) .. " · " .. (item.state or "")),
                icon=category == "repositories" and "folder" or category == "issues" and "circle.dotted" or "arrow.triangle.pull",
                data={url=item.html_url, number=item.number, title=item.full_name or item.title,
                      body=(item.body ~= s.json.null and item.body or nil) or (item.description ~= s.json.null and item.description or nil) or ""},
                actions=actions
            }
        end
        return view
    end,
    action = function(args)
        local action, item = args.action, args.item
        if action.id == "category" then s.ui.push(search_view(action.data.category)); return end
        if action.id == "open" then s.system.open({target=item.data.url})
        elseif action.id == "copy_url" then s.clipboard.write({text=item.data.url})
        elseif action.id == "copy_number" then s.clipboard.write({text=tostring(item.data.number)})
        elseif action.id == "details" then
            s.ui.push({id="detail:" .. item.id, title=item.data.title, type="detail", markdown="# " .. item.data.title .. "\n\n" .. item.data.body,
                data=item.data, actions={{id="detail_open", title="Open in GitHub", close=true}}})
        elseif action.id == "detail_open" then s.system.open({target=args.view.data.url}) end
    end
}

-- ~/.config/nvim/lua/gitlab-timer/init.lua
-- GitLab Time Tracker Plugin - Refactored Clean Version

local M = {}

-- Configuration
local config = {
    gitlab_url = "https://gitlab.com",
    gitlab_token = nil,
    project_id = nil,
    group_id = nil,
    subgroup_id = nil,
    scope = "group",
    debug_logging = true,
    data_file = vim.fn.stdpath("data") .. "/gitlab-timer.json",

    -- File logging
    file_logging = true,       -- write logs to a file in addition to vim.notify
    log_file = vim.fn.stdpath("cache") .. "/gitlab-timer.log",
    log_max_size = 200 * 1024, -- 200KB simple rotation threshold
}

-- State
local state = {
    timer_start = nil,
    current_issue = nil,
    timer_handle = nil,
    elapsed_time = 0,
    current_subgroup = nil, -- Runtime subgroup selection
}

-- === UTILITY FUNCTIONS ===

local function format_time(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)

    if hours > 0 and minutes > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif hours > 0 then
        return string.format("%dh", hours)
    elseif minutes > 0 then
        return string.format("%dm", minutes)
    else
        return "1m"
    end
end

local function parse_duration_to_seconds(duration_str)
    local total_seconds = 0
    local hours = duration_str:match("(%d+)h")
    local minutes = duration_str:match("(%d+)m")
    local seconds = duration_str:match("(%d+)s")

    if hours then
        total_seconds = total_seconds + (tonumber(hours) * 3600)
    end
    if minutes then
        total_seconds = total_seconds + (tonumber(minutes) * 60)
    end
    if seconds then
        total_seconds = total_seconds + tonumber(seconds)
    end

    -- If no units found, assume minutes
    if total_seconds == 0 then
        local number = duration_str:match("^(%d+)$")
        if number then
            total_seconds = tonumber(number) * 60
        end
    end

    return total_seconds > 0 and total_seconds or nil
end

-- === LOGGING (notify + file logging) ===

local function ensure_parent_dir(path)
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir and dir ~= "" then
        pcall(vim.fn.mkdir, dir, "p")
    end
end

local function rotate_log_if_needed(path)
    local max_size = config.log_max_size or (200 * 1024)
    local stat = nil
    if vim and vim.loop and path then
        stat = vim.loop.fs_stat(path)
    end
    local size = stat and stat.size or 0
    if size > max_size then
        pcall(os.remove, path .. ".1")
        pcall(os.rename, path, path .. ".1")
    end
end

local function write_log(level_name, title, message)
    if not config.file_logging then
        return
    end
    local path = config.log_file or (vim.fn.stdpath("cache") .. "/gitlab-timer.log")
    ensure_parent_dir(path)
    rotate_log_if_needed(path)
    local ok, f = pcall(io.open, path, "a")
    if not ok or not f then
        return
    end
    local ts = os.date("%Y-%m-%d %H:%M:%S")
    local msg = tostring(message or ""):gsub("\r?\n", " | ")
    local line = string.format("%s [%s] %s: %s\n", ts, level_name or "INFO", title or "GitLab Timer", msg)
    f:write(line)
    f:close()
end

local function notify(message, level, title)
    local lvl = level or vim.log.levels.INFO
    local ttl = title or "GitLab Timer"
    local lvl_name = (ttl == "Debug" and "DEBUG")
        or (lvl == vim.log.levels.ERROR and "ERROR")
        or (lvl == vim.log.levels.WARN and "WARN")
        or "INFO"
    write_log(lvl_name, ttl, message)
    vim.notify(message, lvl, { title = ttl })
end

local function debug_log(message, data)
    if not config.debug_logging then
        return
    end

    local function pretty(v)
        local t = type(v)
        if t == "string" then
            local s = v
            local ok, decoded = pcall(vim.fn.json_decode, s)
            if ok and type(decoded) == "table" then
                return vim.inspect(decoded, { newline = "\n", indent = "  " })
            end
            if #s > 500 then
                s = s:sub(1, 500) .. "…"
            end
            return s
        elseif t == "table" then
            return vim.inspect(v, { newline = "\n", indent = "  " })
        else
            return tostring(v)
        end
    end

    local msg = data and (message .. "\n" .. pretty(data)) or message
    notify(msg, vim.log.levels.INFO, "Debug")
end

-- === STATE MANAGEMENT ===

local function save_state()
    local data = {
        timer_start = state.timer_start,
        current_issue = state.current_issue,
        elapsed_time = state.elapsed_time,
    }

    local file = io.open(config.data_file, "w")
    if file then
        file:write(vim.fn.json_encode(data))
        file:close()
    end
end

local function load_state()
    local file = io.open(config.data_file, "r")
    if not file then
        return
    end

    local content = file:read("*all")
    file:close()

    local ok, data = pcall(vim.fn.json_decode, content)
    if ok and data then
        state.timer_start = data.timer_start
        state.current_issue = data.current_issue
        state.elapsed_time = data.elapsed_time or 0
    end
end

-- === GIT/GITLAB DETECTION ===

local function get_git_remote()
    local handle = io.popen("git remote get-url origin 2>/dev/null")
    if not handle then
        return nil
    end

    local remote_url = handle:read("*all"):gsub("\n", "")
    handle:close()

    local project_path = remote_url:match("https?://[^/]+/(.+)%.git$") or remote_url:match("git@[^:]+:(.+)%.git$")

    return project_path and project_path:gsub("/", "%%2F") or nil
end

local function detect_project_id()
    return config.project_id or get_git_remote()
end

local function detect_group_id()
    -- Runtime subgroup has highest priority
    if state.current_subgroup then
        return state.current_subgroup
    end
    if config.subgroup_id then
        return config.subgroup_id
    end
    if config.group_id then
        return config.group_id
    end

    local project_id = detect_project_id()
    if project_id then
        local decoded = project_id:gsub("%%2F", "/")
        local group_path = decoded:match("(.+)/[^/]+$")
        return group_path and group_path:gsub("/", "%%2F") or nil
    end

    return nil
end

-- === GITLAB API ===

local function get_token()
    -- Prefer environment variable if set and non-empty
    if vim.env.GITLAB_TOKEN and vim.env.GITLAB_TOKEN ~= "" then
        return vim.env.GITLAB_TOKEN
    end
    -- Fallback to config value if provided and non-empty
    if config.gitlab_token and config.gitlab_token ~= "" then
        return config.gitlab_token
    end
    return nil
end

local function get_gitlab_headers()
    return {
        ["Private-Token"] = get_token(),
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }
end

-- Robust JSON decoder to handle truncated bodies and minor issues
local function decode_json_safe(body)
    if not body or body == "" then
        return nil, "empty"
    end
    local json_decode = (vim.json and vim.json.decode) or vim.fn.json_decode
    -- fast path
    local ok, data = pcall(json_decode, body)
    if ok and data ~= nil then
        return data, nil
    end
    -- strip NULs
    local trimmed = body:gsub("%z", "")
    if trimmed ~= body then
        local ok2, data2 = pcall(json_decode, trimmed)
        if ok2 and data2 ~= nil then
            return data2, nil
        end
    end
    -- try cutting at last closing brace/bracket
    local last_brace = trimmed:match(".*()}")
    local last_bracket = trimmed:match(".*()%]")
    local cutpos = math.max(last_brace or 0, last_bracket or 0)
    if cutpos > 0 then
        local cut = trimmed:sub(1, cutpos)
        local ok3, data3 = pcall(json_decode, cut)
        if ok3 and data3 ~= nil then
            return data3, nil
        end
    end
    -- try to balance braces/brackets
    local open_obj, open_arr = 0, 0
    for c in trimmed:gmatch(".") do
        if c == "{" then
            open_obj = open_obj + 1
        elseif c == "}" then
            open_obj = math.max(0, open_obj - 1)
        elseif c == "[" then
            open_arr = open_arr + 1
        elseif c == "]" then
            open_arr = math.max(0, open_arr - 1)
        end
    end
    if open_obj > 0 or open_arr > 0 then
        local repaired = trimmed .. string.rep("}", open_obj) .. string.rep("]", open_arr)
        local ok4, data4 = pcall(json_decode, repaired)
        if ok4 and data4 ~= nil then
            return data4, nil
        end
    end
    return nil, "invalid_json"
end

local function graphql_request(query, variables, opts)
    local curl = require("plenary.curl")
    local url = config.gitlab_url .. "/api/graphql"

    local request_body = {
        query = query,
        variables = variables or {},
    }

    local retries = (opts and opts.retries) or 2
    local attempts = retries + 1
    local last_status, last_body

    for i = 1, attempts do
        debug_log("GraphQL Query", { query = query, variables = variables, attempt = i })

        local response = curl.post(url, {
            headers = get_gitlab_headers(),
            body = vim.fn.json_encode(request_body),
            timeout = 10000,
        })

        last_status, last_body = response.status, response.body
        debug_log("Response", {
            status = response.status,
            body = response.body and response.body:sub(1, 200),
            body_len = response.body and #response.body or 0,
        })

        if response.status >= 200 and response.status < 300 then
            local data, perr = decode_json_safe(response.body)
            if not data then
                notify("Failed to parse GraphQL response: " .. tostring(perr), vim.log.levels.ERROR)
                return nil
            end

            if data.errors then
                notify("GraphQL Errors: " .. vim.inspect(data.errors), vim.log.levels.ERROR)
                return nil
            end

            return data.data
        end

        if i < attempts then
            -- brief backoff before retrying
            vim.wait(200 * i)
        end
    end

    notify("GraphQL request failed: HTTP " .. tostring(last_status), vim.log.levels.ERROR)
    return nil
end

-- === SUBGROUP MANAGEMENT ===

local function fetch_subgroups()
    local group_id = config.group_id or config.subgroup_id
    if not group_id then
        notify("No base group configured", vim.log.levels.ERROR)
        return {}
    end

    -- Use REST API to get subgroups since GraphQL doesn't have direct subgroups field
    local curl = require("plenary.curl")
    local url = config.gitlab_url .. "/api/v4/groups/" .. group_id:gsub("/", "%2F") .. "/subgroups?per_page=100"

    debug_log("Fetching subgroups from: " .. url)

    local response
    local last_status
    for i = 1, 3 do
        response = curl.get(url, {
            headers = get_gitlab_headers(),
            timeout = 10000,
        })
        last_status = response.status

        debug_log("Subgroups response",
            { attempt = i, status = response.status, body = response.body and response.body:sub(1, 200) })

        if response.status >= 200 and response.status < 300 then
            break
        end
        if i < 3 then
            vim.wait(200 * i)
        end
    end

    if not response or last_status < 200 or last_status >= 300 then
        notify("Failed to fetch subgroups: HTTP " .. tostring(last_status), vim.log.levels.ERROR)
        return {}
    end

    local ok, data = pcall(vim.fn.json_decode, response.body or "[]")
    if not ok or not data then
        notify("Failed to parse subgroups response", vim.log.levels.ERROR)
        return {}
    end

    return data
end

function M.select_subgroup()
    local subgroups = fetch_subgroups()

    local options = { "🏠 Main Group (All Issues)" }
    local subgroup_map = { [1] = nil } -- Main group maps to nil

    for i, subgroup in ipairs(subgroups) do
        local display_name = subgroup.name or subgroup.path or "Unknown"
        table.insert(options, string.format("📁 %s", display_name))
        -- Use full_path for the actual subgroup selection
        local __raw = subgroup.full_path or subgroup.path
        subgroup_map[i + 1] = __raw and __raw:gsub("/", "%%2F") or nil
    end

    if #options == 1 then
        notify("No subgroups found", vim.log.levels.WARN)
        return
    end

    vim.ui.select(options, {
        prompt = "Select Subgroup:",
        format_item = function(item)
            return item
        end,
    }, function(choice, idx)
        if choice and idx then
            state.current_subgroup = subgroup_map[idx]

            local display_name = state.current_subgroup and state.current_subgroup:gsub("%%2F", "/") or "Main Group"

            notify("Selected subgroup: " .. display_name)
        end
    end)
end

function M.clear_subgroup()
    state.current_subgroup = nil
    notify("Cleared subgroup selection - using main group")
end

local function create_project_lookup(projects)
    local lookup = {}
    for _, project in ipairs(projects or {}) do
        local numeric_id = project.id:match("gid://gitlab/Project/(%d+)")
        if numeric_id then
            lookup[numeric_id] = project
        end
    end
    return lookup
end

local function extract_project_from_url(webUrl)
    if not webUrl then
        return "Unknown Project"
    end

    local url_parts = {}
    for part in webUrl:gmatch("([^/]+)") do
        table.insert(url_parts, part)
    end

    -- URL structure: protocol, empty, domain, group, project, -, issues, iid
    if #url_parts >= 5 then
        local group_name = url_parts[4]
        local project_name = url_parts[5]
        return group_name .. "/" .. project_name
    end

    return "Unknown Project"
end

local function enrich_issues_with_projects(issues, projects)
    local project_lookup = create_project_lookup(projects)

    for _, issue in ipairs(issues) do
        issue.project_id = issue.projectId

        local project_info = project_lookup[tostring(issue.projectId)]
        if project_info then
            issue.project = {
                id = project_info.id,
                name = project_info.name,
                fullPath = project_info.fullPath,
                nameWithNamespace = project_info.nameWithNamespace,
            }
        else
            -- Fallback: extract from URL
            local project_path = extract_project_from_url(issue.webUrl)
            issue.project = {
                id = "gid://gitlab/Project/" .. issue.projectId,
                name = project_path:match("/([^/]+)$") or project_path,
                fullPath = project_path,
                nameWithNamespace = project_path,
            }
        end
    end
end

local function fetch_group_issues()
    local group_id = detect_group_id()
    if not group_id then
        notify("Could not detect GitLab group", vim.log.levels.ERROR)
        return {}
    end

    local group_path = group_id:gsub("%%2F", "/")
    local query = [[
    query($groupPath: ID!) {
      group(fullPath: $groupPath) {
        issues(state: opened, first: 100) {
          nodes {
            id
            iid
            title
            description
            webUrl
            projectId
            assignees {
              nodes {
                name
                username
              }
            }
          }
        }
        projects(first: 100) {
          nodes {
            id
            name
            fullPath
            nameWithNamespace
          }
        }
      }
    }
  ]]

    local result = graphql_request(query, { groupPath = group_path })
    if not (result and result.group and result.group.issues) then
        return {}
    end

    local issues = result.group.issues.nodes
    local projects = result.group.projects and result.group.projects.nodes or {}

    notify(string.format("Found %d issues and %d projects", #issues, #projects))

    enrich_issues_with_projects(issues, projects)
    return issues
end

local function fetch_project_issues()
    local project_id = detect_project_id()
    if not project_id then
        notify("Could not detect GitLab project", vim.log.levels.ERROR)
        return {}
    end

    local project_path = project_id:gsub("%%2F", "/")
    local query = [[
    query($projectPath: ID!) {
      project(fullPath: $projectPath) {
        id
        name
        fullPath
        nameWithNamespace
        issues(state: opened, first: 100) {
          nodes {
            id
            iid
            title
            description
            webUrl
            assignees {
              nodes {
                name
                username
              }
            }
          }
        }
      }
    }
  ]]

    local result = graphql_request(query, { projectPath = project_path })
    if not (result and result.project and result.project.issues) then
        return {}
    end

    local issues = result.project.issues.nodes
    notify(string.format("Found %d project issues", #issues))

    -- Add project info to all issues
    for _, issue in ipairs(issues) do
        issue.project_id = result.project.id:match("gid://gitlab/Project/(%d+)")
        issue.project = {
            id = result.project.id,
            name = result.project.name,
            fullPath = result.project.fullPath,
            nameWithNamespace = result.project.nameWithNamespace,
        }
    end

    return issues
end

local function fetch_issues()
    local scope = (M._effective_scope and M._effective_scope()) or (config.scope or "group")
    if scope == "project" then
        return fetch_project_issues()
    else
        return fetch_group_issues()
    end
end

-- === TIME TRACKING ===

local function add_time_to_issue(issue, time_spent, message)
    local seconds = parse_duration_to_seconds(time_spent)
    if not seconds then
        notify("Invalid time format: " .. time_spent, vim.log.levels.ERROR)
        return false
    end

    local mutation = [[
    mutation($input: TimelogCreateInput!) {
      timelogCreate(input: $input) {
        timelog {
          id
          timeSpent
          summary
          spentAt
          user {
            name
          }
        }
        errors
      }
    }
  ]]

    local variables = {
        input = {
            issuableId = issue.id,
            timeSpent = tostring(seconds) .. "s", -- Convert to string with 's' suffix
            spentAt = os.date("%Y-%m-%d"),
            summary = message,
        },
    }

    notify(string.format("Creating timelog: %s (%ds) for issue #%s", time_spent, seconds, issue.iid))

    debug_log("Timelog mutation variables", variables)

    local result = graphql_request(mutation, variables)
    if not (result and result.timelogCreate) then
        notify("Failed to create timelog", vim.log.levels.ERROR)
        return false
    end

    if result.timelogCreate.errors and #result.timelogCreate.errors > 0 then
        notify("Timelog errors: " .. table.concat(result.timelogCreate.errors, ", "), vim.log.levels.ERROR)
        return false
    end

    if result.timelogCreate.timelog then
        notify("✅ Successfully created timelog: " .. time_spent .. " for issue #" .. issue.iid)
        if result.timelogCreate.timelog.summary then
            notify("📝 Summary: " .. result.timelogCreate.timelog.summary)
        end
        return true
    end

    return false
end

-- === TIMER FUNCTIONS ===

local function update_timer()
    if state.timer_start then
        state.elapsed_time = os.time() - state.timer_start
        save_state()
    end
end

local function start_timer_loop()
    if state.timer_handle then
        vim.fn.timer_stop(state.timer_handle)
    end

    state.timer_handle = vim.fn.timer_start(1000, function()
        update_timer()
    end, { ["repeat"] = -1 })
end

-- === MAIN FUNCTIONS ===

function M.start_timer(issue)
    if state.timer_start then
        notify("Timer already running! Stop current timer first.", vim.log.levels.WARN)
        return
    end

    if not issue then
        M.pick_issue(function(selected_issue)
            if selected_issue then
                M.start_timer(selected_issue)
            end
        end)
        return
    end

    state.timer_start = os.time()
    state.current_issue = issue
    state.elapsed_time = 0

    start_timer_loop()
    save_state()

    notify(string.format("Started timer for issue #%s: %s", issue.iid, issue.title))
end

function M.stop_timer()
    if not state.timer_start then
        notify("No timer running.", vim.log.levels.WARN)
        return
    end

    if state.timer_handle then
        vim.fn.timer_stop(state.timer_handle)
        state.timer_handle = nil
    end

    local total_time = state.elapsed_time
    local formatted_time = format_time(total_time)
    local issue = state.current_issue

    -- Reset state
    state.timer_start = nil
    state.current_issue = nil
    state.elapsed_time = 0
    save_state()

    if total_time < 60 then
        notify("Timer stopped. Less than 1 minute, not posting to GitLab.")
        return
    end

    vim.ui.select({ "Yes", "No" }, {
        prompt = string.format("Post %s to issue #%s?", formatted_time, issue.iid),
    }, function(choice)
        if choice == "Yes" then
            vim.ui.input({
                prompt = "What did you work on? (optional): ",
            }, function(message)
                if M.add_time_to_issue_async then
                    M.add_time_to_issue_async(issue, formatted_time, message, function(ok, err_msg)
                        if ok then
                            notify("✅ Timelog added", nil, "GitLab Timer")
                        else
                            notify("Failed to add timelog: " .. tostring(err_msg), vim.log.levels.ERROR)
                        end
                    end)
                else
                    add_time_to_issue(issue, formatted_time, message)
                end
            end)
        end
    end)
end

function M.pick_issue(callback)
    notify("Fetching issues…", nil, "GitLab Timer")
    local function render_picker(issues)
        if #issues == 0 then
            notify("No open issues found.", vim.log.levels.WARN)
            if callback then callback(nil) end
            return
        end

        local issue_items = {}
        for _, issue in ipairs(issues) do
            local project_display = "Unknown"
            if issue.project then
                project_display = issue.project.nameWithNamespace or issue.project.name or "Unknown"
            end

            if #project_display > 30 then
                project_display = project_display:sub(1, 27) .. "..."
            end

            local title_display = issue.title
            if #title_display > 60 then
                title_display = title_display:sub(1, 57) .. "..."
            end

            table.insert(issue_items, string.format("#%s [%s]: %s", issue.iid, project_display, title_display))
        end

        vim.ui.select(issue_items, {
            prompt = "Select GitLab Issue:",
        }, function(choice, idx)
            if choice and idx and callback then
                callback(issues[idx])
            elseif callback then
                callback(nil)
            end
        end)
    end

    if M._fetch_issues_async then
        M._fetch_issues_async(function(err, issues)
            if err then
                notify("Failed to fetch issues: " .. tostring(err), vim.log.levels.ERROR)
                if callback then callback(nil) end
                return
            end
            render_picker(issues or {})
        end)
    else
        local issues = fetch_issues()
        render_picker(issues or {})
    end
end

function M.show_status()
    if state.timer_start then
        local time_str = format_time(state.elapsed_time)
        local issue_str = state.current_issue
            and string.format("#%s: %s", state.current_issue.iid, state.current_issue.title:sub(1, 30))
            or "No Issue"

        notify(string.format("Timer Running: %s\nIssue: %s", time_str, issue_str), nil, "Timer Status")
    else
        notify("No timer running.")
    end
end

function M.add_manual_time()
    M.pick_issue(function(issue)
        if not issue then
            return
        end

        vim.ui.input({
            prompt = "Time to add (e.g., 2h, 30m, 1h30m): ",
        }, function(time_input)
            if not time_input or time_input == "" then
                return
            end

            vim.ui.input({
                prompt = "What did you work on?: ",
            }, function(message)
                if M.add_time_to_issue_async then
                    M.add_time_to_issue_async(issue, time_input, message, function(ok, err_msg)
                        if ok then
                            notify("✅ Timelog added", nil, "GitLab Timer")
                        else
                            notify("Failed to add timelog: " .. tostring(err_msg), vim.log.levels.ERROR)
                        end
                    end)
                else
                    add_time_to_issue(issue, time_input, message)
                end
            end)
        end)
    end)
end

function M.toggle_scope()
    local order = { "group", "project", "auto" }
    local current = config.scope or "group"
    local idx = 1
    for i, v in ipairs(order) do
        if v == current then
            idx = i
            break
        end
    end
    local next_scope = order[(idx % #order) + 1]
    config.scope = next_scope
    notify("Scope set to: " .. next_scope)
end

function M.show_time_entries()
    M.pick_issue(function(issue)
        if not issue then
            return
        end

        notify("Fetching timelogs for issue #" .. issue.iid)
        local query = [[
      query($issueId: IssueID!) {
        issue(id: $issueId) {
          timelogs {
            nodes {
              timeSpent
              user {
                name
              }
              spentAt
              summary
            }
          }
          totalTimeSpent
        }
      }
    ]]

        if M._graphql_request_async then
            M._graphql_request_async(query, { issueId = issue.id }, function(err, data)
                if err or not (data and data.issue) then
                    notify("Failed to fetch timelogs: " .. tostring(err or "no data"), vim.log.levels.ERROR)
                    return
                end

                local timelogs = data.issue.timelogs.nodes
                local total_time_spent = data.issue.totalTimeSpent

                if #timelogs > 0 then
                    local info_lines = { string.format("Timelogs for issue #%s:", issue.iid), "" }

                    for _, timelog in ipairs(timelogs) do
                        local user_name = timelog.user and timelog.user.name or "Unknown"
                        local time_str = format_time(timelog.timeSpent)
                        local summary = timelog.summary or "No summary"
                        local spent_at = timelog.spentAt or "Unknown date"

                        table.insert(info_lines, string.format("• %s - %s (%s)", time_str, user_name, spent_at))
                        table.insert(info_lines, string.format("  %s", summary))
                        table.insert(info_lines, "")
                    end

                    table.insert(info_lines, string.format("Total time: %s", format_time(total_time_spent)))
                    notify(table.concat(info_lines, "\n"), nil, "Timelogs")
                else
                    notify("No timelogs found for issue #" .. issue.iid)
                    if total_time_spent and total_time_spent > 0 then
                        notify("But total time spent: " .. format_time(total_time_spent))
                    end
                end
            end)
        else
            local result = graphql_request(query, { issueId = issue.id })
            if not (result and result.issue) then
                notify("Failed to fetch timelogs", vim.log.levels.ERROR)
                return
            end
            local timelogs = result.issue.timelogs.nodes
            local total_time_spent = result.issue.totalTimeSpent
            if #timelogs > 0 then
                local info_lines = { string.format("Timelogs for issue #%s:", issue.iid), "" }
                for _, timelog in ipairs(timelogs) do
                    local user_name = timelog.user and timelog.user.name or "Unknown"
                    local time_str = format_time(timelog.timeSpent)
                    local summary = timelog.summary or "No summary"
                    local spent_at = timelog.spentAt or "Unknown date"
                    table.insert(info_lines, string.format("• %s - %s (%s)", time_str, user_name, spent_at))
                    table.insert(info_lines, string.format("  %s", summary))
                    table.insert(info_lines, "")
                end
                table.insert(info_lines, string.format("Total time: %s", format_time(total_time_spent)))
                notify(table.concat(info_lines, "\n"), nil, "Timelogs")
            else
                notify("No timelogs found for issue #" .. issue.iid)
                if total_time_spent and total_time_spent > 0 then
                    notify("But total time spent: " .. format_time(total_time_spent))
                end
            end
        end
    end)
end

function M.test_time_tracking()
    M.pick_issue(function(issue)
        if not issue then
            return
        end
        notify("Testing timelog for issue #" .. issue.iid)
        if M.add_time_to_issue_async then
            M.add_time_to_issue_async(issue, "1m", "Test from Neovim", function(ok, err_msg)
                if ok then
                    notify("✅ Test timelog created", nil, "GitLab Timer")
                else
                    notify("Failed to create test timelog: " .. tostring(err_msg), vim.log.levels.ERROR)
                end
            end)
        else
            add_time_to_issue(issue, "1m", "Test from Neovim")
        end
    end)
end

-- Lightweight internal tests to verify core helpers. This is not a full test suite,
-- but helps catch regressions quickly while developing locally.
function M.run_tests()
    local failures = {}

    local function assert_eq(actual, expected, name)
        if actual ~= expected then
            table.insert(failures, string.format("%s: expected=%s got=%s", name, tostring(expected), tostring(actual)))
        end
    end

    -- parse_duration_to_seconds
    assert_eq(parse_duration_to_seconds("1h30m"), 5400, "parse_duration_to_seconds(1h30m)")
    assert_eq(parse_duration_to_seconds("45m"), 2700, "parse_duration_to_seconds(45m)")
    assert_eq(parse_duration_to_seconds("5"), 300, "parse_duration_to_seconds(5 default minutes)")

    -- format_time
    assert_eq(format_time(60), "1m", "format_time(60)")
    assert_eq(format_time(3600), "1h", "format_time(3600)")
    assert_eq(format_time(3660), "1h 1m", "format_time(3660) normalized display")

    -- extract_project_from_url
    assert_eq(extract_project_from_url("https://gitlab.com/group/project/-/issues/1"), "group/project",
        "extract_project_from_url")

    local msg
    if #failures == 0 then
        msg = "All tests passed"
        notify(msg, vim.log.levels.INFO, "gitlab-timer tests")
    else
        msg = "Tests failed:\n- " .. table.concat(failures, "\n- ")
        notify(msg, vim.log.levels.ERROR, "gitlab-timer tests")
    end
    return #failures == 0, failures
end

function M.debug_info()
    local token = config.gitlab_token or vim.env.GITLAB_TOKEN

    local info = {
        "=== GitLab Timer Debug ===",
        "GitLab URL: " .. config.gitlab_url,
        "Project ID: " .. (detect_project_id() or "not detected"),
        "Group ID: " .. (detect_group_id() or "not detected"),
        "Config Subgroup: " .. (config.subgroup_id or "not set"),
        "Runtime Subgroup: " .. (state.current_subgroup and state.current_subgroup:gsub("%%2F", "/") or "not set"),
        "Token: " .. (token and token ~= "" and ("set (length: " .. #token .. ")") or "not set"),
    }

    if state.timer_start then
        table.insert(info, "Timer: running for " .. format_time(state.elapsed_time))
        table.insert(info, "Issue: #" .. (state.current_issue.iid or "unknown"))
    else
        table.insert(info, "Timer: not running")
    end

    notify(table.concat(info, "\n"), nil, "Debug Info")

    -- Show setup instructions if needed
    if not token or token == "" then
        notify(
            [[
GitLab Token Setup Required:

Environment Variable:
  export GITLAB_TOKEN="your_token_here"

Plugin Config:
  require("gitlab-timer").setup({
    gitlab_url = "https://gitlab.dev.ewolutions.de",
    gitlab_token = "your_token_here",
    group_id = "main-group",  -- Base group for subgroup discovery
  })

Token needs 'api' scope from GitLab Settings → Access Tokens
]],
            vim.log.levels.WARN,
            "Setup Instructions"
        )
    end
end

function M.show_menu()
    local current_subgroup_display = state.current_subgroup and ("(" .. state.current_subgroup:gsub("%%2F", "/") .. ")")
        or "(Main Group)"

    local menu_options = {
        "Start Timer",
        "Stop Timer",
        "Show Status",
        "Add Manual Time",
        "Show Time Entries",
        "─────────────────", -- Separator
        "Select Subgroup " .. current_subgroup_display,
        "Clear Subgroup",
        "─────────────────", -- Separator
        "Test Time Tracking",
        "Debug Info",
    }

    vim.ui.select(menu_options, {
        prompt = "GitLab Timer:",
    }, function(choice)
        if not choice or choice:match("^─") then
            return
        end -- Ignore separators

        local actions = {
            ["Start Timer"] = M.start_timer,
            ["Stop Timer"] = M.stop_timer,
            ["Show Status"] = M.show_status,
            ["Add Manual Time"] = M.add_manual_time,
            ["Show Time Entries"] = M.show_time_entries,
            ["Clear Subgroup"] = M.clear_subgroup,
            ["Test Time Tracking"] = M.test_time_tracking,
            ["Debug Info"] = M.debug_info,
        }

        if choice:match("^Select Subgroup") then
            M.select_subgroup()
        elseif actions[choice] then
            actions[choice]()
        end
    end)
end

-- File log helpers exposed as user commands
function M.open_log()
    local path = config.log_file or (vim.fn.stdpath("cache") .. "/gitlab-timer.log")
    ensure_parent_dir(path)
    vim.cmd("tabnew " .. vim.fn.fnameescape(path))
end

function M.clear_log()
    local path = config.log_file or (vim.fn.stdpath("cache") .. "/gitlab-timer.log")
    ensure_parent_dir(path)
    local f = io.open(path, "w")
    if f then f:close() end
    notify("Log cleared: " .. path)
end

-- === SETUP ===

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
    load_state()

    -- Warn early if token is missing
    local __token = get_token()
    if not __token or __token == "" then
        notify("GitLab token is not set. Export $GITLAB_TOKEN or set gitlab_token in setup().", vim.log.levels.WARN)
    end
    local __url = config.gitlab_url or ""
    if __url == "" or not __url:match("^https?://") then
        notify("gitlab_url seems invalid. Set a proper URL like https://gitlab.com or your self-hosted instance.",
            vim.log.levels.WARN)
    end

    if state.timer_start then
        start_timer_loop()
        notify("Resumed GitLab timer")
    end

    -- Create commands
    local commands = {
        GitlabTimer = M.show_menu,
        GitlabTimerStart = M.start_timer,
        GitlabTimerStop = M.stop_timer,
        GitlabTimerStatus = M.show_status,
        GitlabTimerAdd = M.add_manual_time,
        GitlabTimerDebug = M.debug_info,
        GitlabTimerTest = M.test_time_tracking,
        GitlabTimerEntries = M.show_time_entries,
        GitlabTimerSubgroup = M.select_subgroup,
        GitlabTimerClearSubgroup = M.clear_subgroup,
        GitlabTimerToggleScope = M.toggle_scope,
        GitlabTimerOpenLog = M.open_log,
        GitlabTimerClearLog = M.clear_log,
        GitlabTimerRunTests = M.run_tests,
    }

    for cmd, func in pairs(commands) do
        vim.api.nvim_create_user_command(cmd, func, {})
    end
end

-- Expose a few helpers for testing and advanced usage
M._internal = {
    format_time = format_time,
    parse_duration_to_seconds = parse_duration_to_seconds,
    detect_project_id = detect_project_id,
    detect_group_id = detect_group_id,
    extract_project_from_url = extract_project_from_url,
    create_project_lookup = create_project_lookup,
    get_token = get_token,
}

-- Async helpers and overrides for non-blocking UI

function M._effective_scope()
    local scope = config.scope or "group"
    if scope == "auto" then
        return detect_group_id() and "group" or "project"
    end
    return scope
end

function M._graphql_request_async(query, variables, cb)
    local curl = require("plenary.curl")
    local url = config.gitlab_url .. "/api/graphql"
    local request_body = {
        query = query,
        variables = variables or {},
    }
    debug_log("GraphQL Async Request", { url = url, query = query, variables = variables })
    curl.post(url, {
        headers = get_gitlab_headers(),
        body = vim.fn.json_encode(request_body),
        timeout = 10000,
        callback = function(response)
            debug_log("GraphQL Async Response", {
                status = response and response.status or nil,
                body = response and response.body and response.body:sub(1, 200) or nil,
                body_len = response and response.body and #response.body or 0,
            })
            local err, payload
            if not response or response.status < 200 or response.status >= 300 then
                local snippet = response and response.body and response.body:sub(1, 200) or ""
                err = string.format("HTTP %s: %s", tostring(response and response.status or "nil"), snippet)
            else
                local data, perr = decode_json_safe(response.body)
                if not data then
                    local snippet = response and response.body and response.body:sub(1, 200) or ""
                    err = "parse_error: " .. tostring(perr) .. " | " .. snippet
                elseif data.errors then
                    err = "graphql_errors: " .. vim.inspect(data.errors)
                else
                    payload = data.data
                end
            end
            vim.schedule(function()
                cb(err, payload, response)
            end)
        end,
    })
end

function M._fetch_group_issues_async(cb)
    local group_id = detect_group_id()
    if not group_id then
        vim.schedule(function() cb("no_group", {}) end)
        return
    end
    local group_path = group_id:gsub("%%2F", "/")

    local issues_acc = {}
    local projects_acc = nil

    local query = [[
    query($groupPath: ID!, $after: String) {
      group(fullPath: $groupPath) {
        issues(state: opened, first: 100, after: $after) {
          nodes {
            id
            iid
            title
            webUrl
            projectId
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
        projects(first: 100) {
          nodes {
            id
            name
            fullPath
            nameWithNamespace
          }
        }
      }
    }
  ]]

    local function rest_fallback_group()
        local curl = require("plenary.curl")
        local url = config.gitlab_url .. "/api/v4/groups/" .. group_id .. "/issues?state=opened&per_page=100"
        curl.get(url, {
            headers = get_gitlab_headers(),
            timeout = 10000,
            callback = function(response)
                debug_log("REST fallback (group) response", {
                    status = response and response.status or nil,
                    body = response and response.body and response.body:sub(1, 200) or nil,
                    body_len = response and response.body and #response.body or 0,
                })
                local err
                if not response or response.status < 200 or response.status >= 300 then
                    err = string.format("REST HTTP %s", tostring(response and response.status or "nil"))
                end
                local data, perr
                if not err then
                    data, perr = decode_json_safe(response.body)
                    if not data then
                        err = "rest_parse_error: " .. tostring(perr)
                    end
                end
                vim.schedule(function()
                    if err then
                        cb(err, {})
                    else
                        for _, issue in ipairs(data or {}) do
                            issue.id = issue.id and ("gid://gitlab/Issue/" .. tostring(issue.id)) or issue.id
                            issue.iid = tostring(issue.iid)
                            issue.webUrl = issue.web_url or issue.webUrl
                            issue.title = issue.title
                            local project_path = extract_project_from_url(issue.webUrl or "")
                            issue.project = {
                                id = "gid://gitlab/Project/" .. (issue.project_id and tostring(issue.project_id) or ""),
                                name = project_path:match("/([^/]+)$") or project_path or "Unknown",
                                fullPath = project_path or "Unknown",
                                nameWithNamespace = project_path or "Unknown",
                            }
                        end
                        cb(nil, data or {})
                    end
                end)
            end,
        })
    end

    local function rest_fallback_project()
        local curl = require("plenary.curl")
        local url = config.gitlab_url .. "/api/v4/projects/" .. project_id .. "/issues?state=opened&per_page=100"
        curl.get(url, {
            headers = get_gitlab_headers(),
            timeout = 10000,
            callback = function(response)
                debug_log("REST fallback (project) response", {
                    status = response and response.status or nil,
                    body = response and response.body and response.body:sub(1, 200) or nil,
                    body_len = response and response.body and #response.body or 0,
                })
                local err
                if not response or response.status < 200 or response.status >= 300 then
                    err = string.format("REST HTTP %s", tostring(response and response.status or "nil"))
                end
                local data, perr
                if not err then
                    data, perr = decode_json_safe(response.body)
                    if not data then
                        err = "rest_parse_error: " .. tostring(perr)
                    end
                end
                vim.schedule(function()
                    if err then
                        cb(err, {})
                    else
                        for _, issue in ipairs(data or {}) do
                            issue.id = issue.id and ("gid://gitlab/Issue/" .. tostring(issue.id)) or issue.id
                            issue.iid = tostring(issue.iid)
                            issue.webUrl = issue.web_url or issue.webUrl
                            issue.title = issue.title
                            local project_path = extract_project_from_url(issue.webUrl or "")
                            issue.project = {
                                id = proj_meta and proj_meta.id or
                                    ("gid://gitlab/Project/" .. (issue.project_id and tostring(issue.project_id) or "")),
                                name = (proj_meta and proj_meta.name) or
                                    (project_path:match("/([^/]+)$") or project_path or "Unknown"),
                                fullPath = (proj_meta and proj_meta.fullPath) or (project_path or "Unknown"),
                                nameWithNamespace = (proj_meta and proj_meta.nameWithNamespace) or
                                    (project_path or "Unknown"),
                            }
                        end
                        cb(nil, data or {})
                    end
                end)
            end,
        })
    end

    local function fetch_page(cursor)
        M._graphql_request_async(query, { groupPath = group_path, after = cursor }, function(err, data)
            if err or not (data and data.group and data.group.issues) then
                if err and tostring(err):match("parse_error") then
                    rest_fallback_group()
                else
                    cb(err or "no_data", {})
                end
                return
            end
            local nodes = data.group.issues.nodes or {}
            for _, it in ipairs(nodes) do
                table.insert(issues_acc, it)
            end
            if not projects_acc and data.group.projects then
                projects_acc = data.group.projects.nodes or {}
            end
            local pi = data.group.issues.pageInfo
            if pi and pi.hasNextPage and pi.endCursor then
                fetch_page(pi.endCursor)
            else
                enrich_issues_with_projects(issues_acc, projects_acc or {})
                cb(nil, issues_acc)
            end
        end)
    end

    fetch_page(nil)
end

function M._fetch_project_issues_async(cb)
    local project_id = detect_project_id()
    if not project_id then
        vim.schedule(function() cb("no_project", {}) end)
        return
    end
    local project_path = project_id:gsub("%%2F", "/")

    local proj_meta = nil
    local issues_acc = {}

    local query = [[
    query($projectPath: ID!, $after: String) {
      project(fullPath: $projectPath) {
        id
        name
        fullPath
        nameWithNamespace
        issues(state: opened, first: 100, after: $after) {
          nodes {
            id
            iid
            title
            webUrl
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  ]]

    local function fetch_page(cursor)
        M._graphql_request_async(query, { projectPath = project_path, after = cursor }, function(err, data)
            if err or not (data and data.project and data.project.issues) then
                if err and tostring(err):match("parse_error") then
                    rest_fallback_project()
                else
                    cb(err or "no_data", {})
                end
                return
            end
            if not proj_meta then
                proj_meta = {
                    id = data.project.id,
                    name = data.project.name,
                    fullPath = data.project.fullPath,
                    nameWithNamespace = data.project.nameWithNamespace,
                }
            end
            local nodes = data.project.issues.nodes or {}
            for _, it in ipairs(nodes) do
                table.insert(issues_acc, it)
            end
            local pi = data.project.issues.pageInfo
            if pi and pi.hasNextPage and pi.endCursor then
                fetch_page(pi.endCursor)
            else
                for _, issue in ipairs(issues_acc) do
                    issue.project_id = proj_meta.id:match("gid://gitlab/Project/(%d+)")
                    issue.project = {
                        id = proj_meta.id,
                        name = proj_meta.name,
                        fullPath = proj_meta.fullPath,
                        nameWithNamespace = proj_meta.nameWithNamespace,
                    }
                end
                cb(nil, issues_acc)
            end
        end)
    end

    fetch_page(nil)
end

function M._fetch_issues_async(cb)
    local scope = M._effective_scope()
    if scope == "project" then
        M._fetch_project_issues_async(cb)
    else
        M._fetch_group_issues_async(cb)
    end
end

function M.add_time_to_issue_async(issue, time_spent, message, cb)
    local seconds = parse_duration_to_seconds(time_spent)
    if not seconds then
        vim.schedule(function() cb(false, "Invalid time format: " .. tostring(time_spent)) end)
        return
    end
    local mutation = [[
    mutation($input: TimelogCreateInput!) {
      timelogCreate(input: $input) {
        timelog {
          id
          timeSpent
          spentAt
          summary
        }
        errors
      }
    }
  ]]
    local variables = {
        input = {
            issuableId = issue.id,
            timeSpent = tostring(seconds) .. "s",
            spentAt = os.date("%Y-%m-%d"),
            summary = message,
        },
    }
    M._graphql_request_async(mutation, variables, function(err, data)
        if err or not (data and data.timelogCreate) then
            cb(false, err or "no_data")
            return
        end
        if data.timelogCreate.errors and #data.timelogCreate.errors > 0 then
            cb(false, table.concat(data.timelogCreate.errors, ", "))
            return
        end
        cb(true)
    end)
end

function M.statusline()
    if state.timer_start then
        local time_str = format_time(state.elapsed_time)
        local issue_part = ""
        if state.current_issue and state.current_issue.iid then
            issue_part = string.format(" #%s", state.current_issue.iid)
        end
        local scope = (M._effective_scope and M._effective_scope()) or (config.scope or "group")
        return string.format("GitLab %s%s [%s]", time_str, issue_part, scope)
    else
        return ""
    end
end

return M

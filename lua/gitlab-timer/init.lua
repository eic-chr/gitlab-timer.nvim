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
    debug_logging = true,
    data_file = vim.fn.stdpath("data") .. "/gitlab-timer.json",
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

local function notify(message, level, title)
    vim.notify(message, level or vim.log.levels.INFO, { title = title or "GitLab Timer" })
end

local function debug_log(message, data)
    if config.debug_logging then
        local msg = data and (message .. "\n" .. vim.inspect(data)) or message
        notify(msg, vim.log.levels.INFO, "Debug")
    end
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

local function get_gitlab_headers()
    return {
        ["Private-Token"] = (vim.env.GITLAB_TOKEN ~= "" and vim.env.GITLAB_TOKEN) or
        (config.gitlab_token ~= "" and config.gitlab_token or nil),
        ["Content-Type"] = "application/json",
    }
end

local function graphql_request(query, variables)
    local curl = require("plenary.curl")
    local url = config.gitlab_url .. "/api/graphql"

    local request_body = {
        query = query,
        variables = variables or {},
    }

    debug_log("GraphQL Query", { query = query, variables = variables })

    local response = curl.post(url, {
        headers = get_gitlab_headers(),
        body = vim.fn.json_encode(request_body),
        timeout = 10000,
    })

    debug_log("Response", { status = response.status, body = response.body and response.body:sub(1, 200) })

    if response.status < 200 or response.status >= 300 then
        notify("GraphQL request failed: HTTP " .. response.status, vim.log.levels.ERROR)
        return nil
    end

    local ok, data = pcall(vim.fn.json_decode, response.body or "{}")
    if not ok or not data then
        notify("Failed to parse GraphQL response", vim.log.levels.ERROR)
        return nil
    end

    if data.errors then
        notify("GraphQL Errors: " .. vim.inspect(data.errors), vim.log.levels.ERROR)
        return nil
    end

    return data.data
end

-- === SUBGROUP MANAGEMENT ===

local function fetch_subgroups()
    local group_id = config.group_id or config.subgroup_id
    if not group_id then
        notify("No base group configured", vim.log.levels.ERROR)
        return {}
    end

    local group_path = group_id:gsub("%%2F", "/")

    -- Use REST API to get subgroups since GraphQL doesn't have direct subgroups field
    local curl = require("plenary.curl")
    local url = config.gitlab_url .. "/api/v4/groups/" .. group_id:gsub("/", "%2F") .. "/subgroups"

    debug_log("Fetching subgroups from: " .. url)

    local response = curl.get(url, {
        headers = get_gitlab_headers(),
        timeout = 10000,
    })

    debug_log("Subgroups response", { status = response.status, body = response.body and response.body:sub(1, 200) })

    if response.status < 200 or response.status >= 300 then
        notify("Failed to fetch subgroups: HTTP " .. response.status, vim.log.levels.ERROR)
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
        subgroup_map[i + 1] = subgroup.full_path and subgroup.full_path:gsub("/", "%%2F") or
        subgroup.path:gsub("/", "%%2F")
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
    return fetch_group_issues()
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
                add_time_to_issue(issue, formatted_time, message)
            end)
        end
    end)
end

function M.pick_issue(callback)
    local issues = fetch_issues()
    if #issues == 0 then
        notify("No open issues found.", vim.log.levels.WARN)
        return
    end

    local issue_items = {}
    for _, issue in ipairs(issues) do
        local project_display = "Unknown"
        if issue.project then
            project_display = issue.project.nameWithNamespace or issue.project.name or "Unknown"
        end

        -- Truncate for better display
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
                add_time_to_issue(issue, time_input, message)
            end)
        end)
    end)
end

function M.toggle_scope()
    notify("Scope toggle removed - always using group-based issue fetching")
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
              id
              timeSpent
              summary
              spentAt
              user {
                name
                username
              }
            }
          }
          totalTimeSpent
        }
      }
    ]]

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
    end)
end

function M.test_time_tracking()
    M.pick_issue(function(issue)
        if not issue then
            return
        end

        notify("Testing timelog for issue #" .. issue.iid)
        add_time_to_issue(issue, "1m", "Test from Neovim")
    end)
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

-- === SETUP ===

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
    load_state()

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
    }

    for cmd, func in pairs(commands) do
        vim.api.nvim_create_user_command(cmd, func, {})
    end
end

return M

# gitlab-timer.nvim

Track and log time to GitLab issues directly from Neovim. Start/stop a timer for a selected issue, add manual time logs, browse timelogs, and post entries to GitLab via the GraphQL API.

- Issue picker (from a group or project)
- Start/stop timer with confirmation to post spent time
- Manual time logging
- View timelogs for an issue
- Subgroup selection at runtime
- Auto-detects group/project from your Git remote
- Persists timer state across sessions
- Uses $GITLAB_TOKEN by default for authentication

## Requirements

- Neovim 0.8+ (recommended)
- [nvim-lua/plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- Git configured for your project (to auto-detect group/project)
- A GitLab Personal Access Token with the `api` scope

## Install

### lazy.nvim

~~~lua
{
  "eic-chr/gitlab-timer.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("gitlab-timer").setup({
      gitlab_url = "https://gitlab.com", -- or your self-hosted GitLab
      -- gitlab_token = nil,             -- omit to use $GITLAB_TOKEN from your environment
      -- group_id = "my-group",          -- optional: base group (see Configuration)
      debug_logging = true,
    })
  end,
  keys = {
    { "<leader>gt", function() require("gitlab-timer").show_menu() end, desc = "GitLab Timer" },
    { "<leader>gs", function() require("gitlab-timer").start_timer() end, desc = "Start Timer" },
    { "<leader>gS", function() require("gitlab-timer").stop_timer() end,  desc = "Stop Timer" },
  },
  cmd = {
    "GitlabTimer",
    "GitlabTimerStart",
    "GitlabTimerStop",
    "GitlabTimerStatus",
    "GitlabTimerAdd",
    "GitlabTimerDebug",
    "GitlabTimerTest",
    "GitlabTimerEntries",
    "GitlabTimerSubgroup",
    "GitlabTimerClearSubgroup",
  },
}
~~~

### packer.nvim

~~~lua
use({
  "eic-chr/gitlab-timer.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("gitlab-timer").setup({
      gitlab_url = "https://gitlab.com",
      -- gitlab_token = nil, -- omit to use $GITLAB_TOKEN
      debug_logging = true,
    })
  end,
})
~~~

## Authentication

Set your GitLab token via environment variable (preferred). It must have the `api` scope.

- Bash/zsh:
  - `export GITLAB_TOKEN="your_personal_access_token"`
- fish:
  - `set -x GITLAB_TOKEN your_personal_access_token`
- PowerShell:
  - `[Environment]::SetEnvironmentVariable("GITLAB_TOKEN","your_personal_access_token","User")`

You can also set `gitlab_token` in `setup({ gitlab_token = "..." })`, but if you omit it the plugin uses `$GITLAB_TOKEN` automatically.

## Configuration

Below are the available options and their defaults. You can override any of them in `setup`.

~~~lua
require("gitlab-timer").setup({
  gitlab_url = "https://gitlab.com",
  -- gitlab_token = nil, -- omit to use $GITLAB_TOKEN from your environment
  project_id = nil,      -- when nil, auto-detected from your git remote
  group_id = nil,        -- base group for fetching issues (see notes below)
  subgroup_id = nil,     -- optional default subgroup (can be changed at runtime)
  debug_logging = true,  -- verbose notifications for debugging
  data_file = vim.fn.stdpath("data") .. "/gitlab-timer.json", -- persisted timer state
})
~~~

Notes:
- group_id and subgroup_id should be the GitLab group path (e.g. `"my-group"` or `"parent/subgroup"`).
- project_id (when set) should be the GitLab project full path (e.g. `"group/project"`). If unset, it is derived from your current repo’s `origin` remote.
- The plugin primarily fetches issues at the group level to present a unified picker. Use the Subgroup menu to narrow results.

## Commands

- `:GitlabTimer` — Open the menu
- `:GitlabTimerStart` — Start a timer (prompts to pick an issue if none selected)
- `:GitlabTimerStop` — Stop the timer (prompts to post time to GitLab)
- `:GitlabTimerStatus` — Show the current timer status
- `:GitlabTimerAdd` — Add manual time to a selected issue (e.g., `30m`, `2h`, `1h30m`)
- `:GitlabTimerEntries` — Show timelogs for a selected issue
- `:GitlabTimerSubgroup` — Select a subgroup (runtime)
- `:GitlabTimerClearSubgroup` — Clear subgroup selection
- `:GitlabTimerDebug` — Show debug info (token status, detected IDs, etc.)
- `:GitlabTimerTest` — Post a 1-minute test timelog to a selected issue

## Usage

### Quick start

1) Ensure `$GITLAB_TOKEN` is set with the `api` scope (see Authentication).
2) Open a project that has a Git remote pointing to GitLab.
3) Run `:GitlabTimer` to open the menu, or:
   - `:GitlabTimerStart` to pick an issue and start the timer
   - `:GitlabTimerStop` to stop and optionally post the time
   - `:GitlabTimerAdd` to add manual time (you’ll be prompted for a summary)

### Typical workflow

- Start timer:
  - `:GitlabTimerStart`
  - Pick an issue from your group/project list.
- Work…
- Stop timer:
  - `:GitlabTimerStop`
  - Confirm to post the tracked time to GitLab and optionally add a summary.
- Review timelogs:
  - `:GitlabTimerEntries`
- Adjust scope:
  - `:GitlabTimerSubgroup` to narrow issues by subgroup
  - `:GitlabTimerClearSubgroup` to go back to the base group

## Examples

### Minimal setup (GitLab.com, token from env)

~~~lua
require("gitlab-timer").setup({
  gitlab_url = "https://gitlab.com",
  -- token comes from $GITLAB_TOKEN
})
~~~

### Self-hosted GitLab with base group

~~~lua
require("gitlab-timer").setup({
  gitlab_url = "https://gitlab.yourcompany.tld",
  group_id = "engineering/platform", -- base group to browse issues from
})
~~~

### Keymaps

~~~lua
vim.keymap.set("n", "<leader>gt", function() require("gitlab-timer").show_menu() end, { desc = "GitLab Timer" })
vim.keymap.set("n", "<leader>gs", function() require("gitlab-timer").start_timer() end, { desc = "Start Timer" })
vim.keymap.set("n", "<leader>gS", function() require("gitlab-timer").stop_timer()  end, { desc = "Stop Timer" })
~~~

## Troubleshooting

- 401 Unauthorized or “Token not set”
  - Verify `$GITLAB_TOKEN` is exported in your shell that launches Neovim.
  - Token must include the `api` scope.
  - Use `:GitlabTimerDebug` to confirm the token is detected (length shown, not the token itself).
- “Could not detect GitLab group”
  - Set `group_id` in setup, or ensure your repo’s `origin` points to a GitLab project under the intended group.
- Self-hosted instance issues
  - Set `gitlab_url` to your instance base URL (e.g., `https://gitlab.internal.tld`).
  - Ensure your token was created on that instance with the right scopes.

## Security

- Prefer `$GITLAB_TOKEN` over hardcoding tokens in your config.
- Consider storing environment variables in your shell profile or a secure secrets manager.

---
Happy tracking!
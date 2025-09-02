-- gitlab-timer.nvim/tests/core_spec.lua
-- Minimal busted-style tests for core helpers

-- Extend Lua module path to find the plugin under ./lua
package.path = table.concat({
    "./lua/?.lua",
    "./lua/?/init.lua",
    package.path,
}, ";")

-- Minimal Neovim API stubs to allow requiring the module outside Neovim
_G.vim = _G.vim or {}
vim.env = vim.env or {}
vim.notify = vim.notify or function() end
vim.log = vim.log or { levels = { INFO = 1, WARN = 2, ERROR = 3 } }
vim.inspect = vim.inspect or function(_) return "<inspect>" end
vim.fn = vim.fn or {}
vim.fn.stdpath = vim.fn.stdpath or function(_) return "/tmp" end
vim.fn.json_encode = vim.fn.json_encode or function(_) return "{}" end
vim.fn.json_decode = vim.fn.json_decode or function(_) return {} end
vim.tbl_deep_extend = vim.tbl_deep_extend or function(strategy, base, override)
    -- Simple deep extend (sufficient for tests)
    local function merge(a, b)
        local out = {}
        for k, v in pairs(a or {}) do out[k] = v end
        for k, v in pairs(b or {}) do
            if type(v) == "table" and type(out[k]) == "table" then
                out[k] = merge(out[k], v)
            else
                out[k] = v
            end
        end
        return out
    end
    return merge(base, override)
end
vim.api = vim.api or {}
vim.api.nvim_create_user_command = vim.api.nvim_create_user_command or function() end

-- Require plugin
local plugin = require("gitlab-timer")
local I = assert(plugin._internal, "internal helpers not exposed")

describe("gitlab-timer.nvim core helpers", function()
    describe("parse_duration_to_seconds", function()
        it("parses hours and minutes", function()
            assert.are.equal(5400, I.parse_duration_to_seconds("1h30m"))
            assert.are.equal(7200, I.parse_duration_to_seconds("2h"))
            assert.are.equal(2700, I.parse_duration_to_seconds("45m"))
        end)

        it("assumes minutes when no unit given", function()
            assert.are.equal(300, I.parse_duration_to_seconds("5"))
        end)

        it("returns nil on invalid input", function()
            assert.is_nil(I.parse_duration_to_seconds("abc"))
            assert.is_nil(I.parse_duration_to_seconds(""))
        end)
    end)

    describe("format_time", function()
        it("formats minutes", function()
            assert.are.equal("1m", I.format_time(60))
            assert.are.equal("5m", I.format_time(300))
        end)

        it("formats hours", function()
            assert.are.equal("1h", I.format_time(3600))
            assert.are.equal("2h", I.format_time(7200))
        end)

        it("formats hour+minute combo", function()
            assert.are.equal("1h 1m", I.format_time(3660))
            assert.are.equal("2h 15m", I.format_time(8100))
        end)
    end)

    describe("extract_project_from_url", function()
        it("extracts group/project from GitLab issue URL", function()
            local url = "https://gitlab.com/group/project/-/issues/123"
            assert.are.equal("group/project", I.extract_project_from_url(url))
        end)

        it("falls back to 'Unknown Project' for unsupported URLs", function()
            assert.are.equal("Unknown Project", I.extract_project_from_url("https://gitlab.com/"))
            assert.are.equal("Unknown Project", I.extract_project_from_url(nil))
        end)
    end)

    describe("create_project_lookup", function()
        it("creates lookup keyed by numeric project id", function()
            local projects = {
                { id = "gid://gitlab/Project/1",   name = "a" },
                { id = "gid://gitlab/Project/42",  name = "b" },
                { id = "gid://gitlab/Project/777", name = "c" },
            }
            local lookup = I.create_project_lookup(projects)
            assert.are.same("a", lookup["1"].name)
            assert.are.same("b", lookup["42"].name)
            assert.are.same("c", lookup["777"].name)
        end)

        it("handles empty/nil input", function()
            local lookup = I.create_project_lookup(nil)
            assert.are.same({}, lookup)
        end)
    end)

    describe("get_token", function()
        local saved_env

        before_each(function()
            -- backup env
            saved_env = { GITLAB_TOKEN = vim.env.GITLAB_TOKEN }
            vim.env.GITLAB_TOKEN = nil
        end)

        after_each(function()
            -- restore env
            vim.env.GITLAB_TOKEN = saved_env.GITLAB_TOKEN
        end)

        it("prefers environment variable when set", function()
            vim.env.GITLAB_TOKEN = "env-token"
            assert.are.equal("env-token", I.get_token())
        end)

        it("falls back to configured token when env is empty", function()
            vim.env.GITLAB_TOKEN = ""
            -- configure plugin token via setup
            plugin.setup({ gitlab_token = "cfg-token" })
            assert.are.equal("cfg-token", I.get_token())
        end)

        it("returns nil when neither env nor config are set", function()
            vim.env.GITLAB_TOKEN = nil
            -- reset with empty config
            plugin.setup({})
            assert.is_nil(I.get_token())
        end)
    end)
end)

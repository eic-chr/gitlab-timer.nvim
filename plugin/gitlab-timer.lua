return {
  {
    "gitlab-timer.nvim",
    dir = vim.fn.stdpath("config") .. "/lua/gitlab-timer",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    config = function()
      require("gitlab-timer").setup({
        gitlab_url = "",
        gitlab_token = "",
        group_id = "",
        scope = "group",
        debug_logging = true,
      })
    end,
    keys = {
      {
        "<leader>gt",
        function()
          require("gitlab-timer").show_menu()
        end,
        desc = "GitLab Timer",
      },
      {
        "<leader>gs",
        function()
          require("gitlab-timer").start_timer()
        end,
        desc = "Start Timer",
      },
      {
        "<leader>gS",
        function()
          require("gitlab-timer").stop_timer()
        end,
        desc = "Stop Timer",
      },
    },
    cmd = {
      "GitlabTimer",
      "GitlabTimerStart",
      "GitlabTimerStop",
      "GitlabTimerTest",
      "GitlabTimerEntries",
    },
  },
}

" Avoid neovim/neovim#11362
set display=lastline
set directory=""
set noswapfile

let $mason = getcwd()
let $test_helpers = getcwd() .. "/tests/helpers"
let $dependencies = getcwd() .. "/dependencies"

set rtp^=$mason,$test_helpers
set packpath=$dependencies

packloadall

lua require("luassertx")
lua require("test_helpers")

lua <<EOF
local index = require "mason-registry.index"
index["dummy"] = "dummy_package"
index["dummy2"] = "dummy2_package"
index["fail_dummy"] = "fail_dummy"

local configs = require 'lspconfig.configs'
configs.dummylsp = { default_config = { cmd = { "dummylsp" } } }
configs.dummy2lsp = { default_config = { cmd = { "dummy2lsp"} } }
configs.fail_dummylsp = { default_config = { cmd = { "fail_dummylsp"} } }

require("mason").setup {
    install_root_dir = vim.env.INSTALL_ROOT_DIR,
}
EOF

function! RunTests() abort
    lua <<EOF
    require("plenary.test_harness").test_directory(os.getenv("FILE") or "./tests", {
        minimal_init = vim.fn.getcwd() .. "/tests/minimal_init.vim",
        sequential = true,
    })
EOF
endfunction

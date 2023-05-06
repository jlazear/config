---
name: Bug report
about: Create a bug report
title: "[Bug]"
labels: bug
assignees: ''

---

**Neovim version**
The output of `nvim --version`.

**Describe the bug**
A clear and concise description of what the bug is.

**To Reproduce**
Steps to reproduce the behavior:
1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

**Expected behavior**
A clear and concise description of what you expected to happen.

**Does this error occur in the minimal init file?**
Use the following commands to download the minimal init file provided by bufdelete:
`curl -fLO https://raw.githubusercontent.com/famiu/bufdelete.nvim/master/minimal_init.lua`

Modify the file to your needs (if necessary), then load Neovim using:
`nvim --noplugin -u minimal_init.lua`

And check if your issue still occurs.

**Provide modified minimal_init.lua**
If you modified the minimal_init.lua that bufdelete provides by default in order to fit your configuration, put it here. Otherwise ignore this part.

**Screenshots**
If applicable, add screenshots to help explain your problem.

**Additional context**
Add any other context about the problem here (eg: other plugins that may conflict with this plugin, configuration options that you think might cause the issue, etc.).

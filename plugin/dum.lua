-- Guard against double-loading.
if vim.g.loaded_dum then
	return
end
vim.g.loaded_dum = true

vim.api.nvim_create_user_command("Dum", function()
	require("dum").ask()
end, {
	desc = "Ask Copilot to complete the current visual selection",
})

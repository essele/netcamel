#!/usr/bin/luajit
--------------------------------------------------------------------------------
--  This file is part of NetCamel
--  Copyright (C) 2014,15 Lee Essen <lee.essen@nowonline.co.uk>
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <http://www.gnu.org/licenses/>.
------------------------------------------------------------------------------

--
-- We support undo for any configuration changes
--
local __undo


--
-- Support functions for using stdin or an editor
--
local function edit_value(value)
	local file = lib.file.create_with_data(nil, value)
	lib.term.push("normal")
	os.execute("/bin/vi "..file.filename)
	lib.term.pop()

	local value = file:read()
	file:delete()
	return value
end

--
-- Read from stdin up to a CTRL-D so we can facilitate cut and paste
--
-- (Note: CTRL-D needs to be on a blank line, not sure it's a real problem)
--
local function stdin_value()
	lib.term.push("normal")
	local value = io.read("*a")
	lib.term.pop()
	return value
end



-- ------------------------------------------------------------------------------
-- UNDO COMMAND
-- ------------------------------------------------------------------------------
CMDS["undo"] = {
	desc = "undo the last configuration change",
	usage = "undo",
	argc = { min = 0, max = 0 },
	args = {}
}
CMDS["undo"].func = function(cmd, cmdline, tokens)
	if not __undo then
		print("undo: not available.")
		return
	end
	local rc, err = lib.config.undo(CF_new, __undo)
	if not rc then print("error: " .. err) return end
	print(string.format("undo: undoing command: %s", __undo.cmd))
	print(string.format("undo: processed %s configuration item%s.", rc, (rc > 1 and "s") or ""))
	__undo = nil
end

-- ------------------------------------------------------------------------------
-- SHOW COMMAND
-- ------------------------------------------------------------------------------
CMDS["show"] = {
	desc = "display configuration",
	usage = "show [<config_path>]",
	flags = {
		["help"] = { 1,2,3 },
		["fast"] = { 3, 4, 5 },
		["mode="] = { "a" },
	},
	argc = { min = 0, max = 1 },
	args = {
		{ validator = rlv_cfpath, opts = { allow_value = 1, allow_container = 1, use_master = 1, use_new = 1 }}
	}
}
CMDS["show"].func = function(cmd, cmdline, tokens)
    local kp = (tokens[2] and tokens[2].kp) or __path_kp
    lib.config.show(CF_current, CF_new, kp)
end

-- ------------------------------------------------------------------------------
-- SET COMMAND
-- ------------------------------------------------------------------------------
CMDS["set"] = {
	desc = "set configuration values",
	usage = "set <config_path> <value>",
	argc = { min = 2, max = 2 },
	args = {
		{ validator = rlv_cfpath, opts = { allow_value = 1, use_master = 1, use_new = 1, gap = 1 }},
		{ validator = rlv_cfvalue, all = 1 },
	}
}
CMDS["set"].func = function(cmd, cmdline, tokens)
	local mp, kp = tokens[2].mp, tokens[2].kp
	local value = tokens[3].value
	local is_file = master[mp]["type"]:sub(1,5) == "file/"
	local rc, err
	if master[mp].action then
		print("CALLING ACTION INSTEAD")
		rc, err = master[mp].action(value, mp, kp)
	else
		--
		-- Handle stdin or editor options
		--
		if is_file and (value == "+" or value == "-") then
			if value == "-" then
				value, err = stdin_value()
				if not value then print("error: " .. tostring(err)) return end
			else
				value, err = edit_value(CF_new[kp])
				if not value then print("error: " .. tostring(err)) return end
				if CF_new[kp] == value then print("no changed made") return end
			end
		end
		rc, err = lib.config.set(CF_new, kp, value)
	end
	if not rc then print("error: " .. tostring(err)) return end
	__undo = err
	__undo.cmd = cmdline
end


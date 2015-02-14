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
	usage = "show [<cfg_path>]",
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
	 local kp = (tokens[2] and tokens[2].kp) or lib.cmdline.get_path().kp
	 lib.config.show(CF_current, CF_new, kp)
end

-- ------------------------------------------------------------------------------
-- SET COMMAND
-- ------------------------------------------------------------------------------
CMDS["set"] = {
	desc = "set configuration values",
	usage = "set <cfg_path> <value>",
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

-- ------------------------------------------------------------------------------
-- DELETE COMMAND
-- ------------------------------------------------------------------------------
CMDS["delete"] = {
	desc = "delete sections or items from the configuration",
	usage = "delete <cfg_path> [<list value>]",
	argc = { min = 1, max = 2 },
	args = {
		{ validator = rlv_cfpath, opts = { use_new=1, allow_value=1, allow_container=1 }},
		{ validator = rlv_cfvalue, all = 1, opts = { only_if_list = 1 }},
	}
}
CMDS["delete"].func = function(cmd, cmdline, tokens)
	 local kp = tokens[2].kp
	 local list_elem = tokens[3] and tokens[3].value

	 local rc, err = lib.config.delete(CF_new, kp, list_elem)
	 if not rc then
		  print("error: " .. tostring(err))
		  return
	 end
	 print(string.format("delete: removed %s configuration item%s.", rc, (rc > 1 and "s") or ""))
	 __undo = err
	 __undo.cmd = cmdline
end

-- ----------------------------------------------------------------------------
-- RENAME COMMAND (for wildcards)
-- ----------------------------------------------------------------------------
CMDS["rename"] = {
	desc = "rename a (wildcard) node in the config",
	usage = "rename <cfg_path> <new_node>",
	argc = { min = 2, max = 2 },
	args = {
		{ validator = rlv_cfpath, opts = { use_new=1, must_be_wildcard=1, gap=1 }},
		{ validator = rlv_cfvalue },
	}
}
CMDS["rename"].func = function(cmd, cmdline, tokens)
	local rc, err = lib.config.rename(CF_new, tokens[2].kp, tokens[3].value)
	if not rc then
		print("error: " .. tostring(err))
		return
	end
	print("rename: done.")
	__undo = err
	__undo.cmd = cmdline
end

-- ----------------------------------------------------------------------------
-- REVERT COMMAND
-- ----------------------------------------------------------------------------
CMDS["revert"] = {
	desc = "revert part of the new config back to current settings",
	usage = "revert <cfg_path>",
	argc = { min = 1, max = 1 },
	args = {
		{ validator = rlv_cfpath, opts = { use_master=1, use_new=1, allow_value=1, allow_container=1 }}
	}
}
CMDS["revert"].func = function(cmd, cmdline, tokens)
	local rc, err = lib.config.revert(CF_new, tokens[2].kp)
	if not rc then
		print("error: " .. tostring(err))
		return
	end
	print(string.format("revert: considered %s configuration item%s.", rc, (rc > 1 and "s") or ""))
	__undo = err
	__undo.cmd = cmdline
end

-- ----------------------------------------------------------------------------
-- COMMIT COMMAND
-- ----------------------------------------------------------------------------
CMDS["commit"] = {
	desc = "make the new configuration active",
	usage = "commit",
	argc = { min = 0, max = 0 },
	args = {}
}
CMDS["commit"].func = function(cmd, cmdline, tokens)
	local rc, err = commit(CF_current, CF_new)
	if not rc then
		print("error: " .. err)
		return
	else
		CF_current = copy(CF_new)
	end
	__undo = nil
end

-- ----------------------------------------------------------------------------
-- SAVE COMMAND
-- ----------------------------------------------------------------------------
CMDS["save"] = {
	desc = "save the currently active configuration so its applied at boot time",
	usage = "save",
	argc = { min = 0, max = 0 },
	args = {}
}
CMDS["save"].func = function(cmd, cmdline, tokens)
	local rc, err = save(CF_current)
	if not rc then
		print("error: " .. err)
		return
	end
	__undo = nil
end

-- ----------------------------------------------------------------------------
-- CD COMMAND
-- ----------------------------------------------------------------------------
CMDS["cd"] = {
	desc = "change to a particular area of config",
	usage = "cd <cfg_path>",
	argc = { min = 1, max = 1 },
	args = {
		{ validator = rlv_cfpath, opts = { use_master=1, use_new=1, allow_container=1 }}
	}
}
CMDS["cd"].func = function(cmd, cmdline, tokens)
	lib.cmdline.set_path(tokens[2].mp, tokens[2].kp)
--	__prompt = setprompt(__path_kp)

end




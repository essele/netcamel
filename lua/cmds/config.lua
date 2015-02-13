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

CMDS["show"] = {
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
    show(CF_current, CF_new, kp)
end


CMDS["set"] = {
	desc = "set configuration values",
	usage = "set <config_path> <value>",
	argc = { min = 2, max = 2 },
	args = {
		{ validator = rlv_cfpath, opts = { allow_value = 1, use_master = 1, use_new = 1, gap = 1 }},
		{ validator = rlv_cfvalue, all = 1 },
	}
}


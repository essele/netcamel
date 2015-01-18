#!./luajit
--------------------------------------------------------------------------------
--  This file is part of NetCamel
--  Copyright (C) 2014 Lee Essen <lee.essen@nowonline.co.uk>
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

require("log")
runtime = require("runtime")

local function system_precommit(changes)
	return true
end

local function system_commit(changes)
	logroot("system")

	local cf = node_vars("/system", CF_new) or {}
	local hostname = cf.hostname or "camel"
	runtime.execute("/bin/hostname", { hostname })
	
	return true
end



VALIDATOR["hostname"] = function(v, kp)
	if v:match("^%-") then return FAIL, "hostnames cannot start with hyphen" end
	if v:match("%-$") then return FAIL, "hostnames cannot end with hyphen" end
	if v:match("^[%w%-]+$") then return OK end
	return FAIL, "hostnames must only be letters, numbers and hyphen"
end

--
-- Main interface config definition
--
master["/system"] = 								{ ["commit"] = system_commit,
                                                  ["precommit"] = system_precommit }
master["/system/hostname"] =						{ ["type"] = "hostname" }



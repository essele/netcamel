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

--
--
--
local function routing_commit(changes)
	print("Hello From ROUTINGQ")
end

--
--
--
local function routing_precommit(changes)
end


--
-- Main routing config definition
--
master["routing"] = { 
	["commit"] = dnsmasq_commit,
	["precommit"] = dnsmasq_precommit 
}

master["routing/route"] = {}
master["routing/route/*"] = 			{ ["style"] = "text_label" }
master["routing/route/*/interface"] = 	{ ["type"] = "any_interface",
										  ["options"] = options_all_interfaces }
master["routing/route/*/dest"] = 		{ ["type"] = "OK" }
master["routing/route/*/via"] = 		{ ["type"] = "OK" }
master["routing/route/*/table"] = 		{ ["type"] = "OK" }



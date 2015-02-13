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
-- Commit will just remove all the routes and then re-add them
--
-- TODO: what about live routes
--
local function routing_commit(changes)
	lib.runtime.block_on()
	print("Hello From ROUTINGQ")

	local state = process_changes(changes, "/routing/route")

	for name in each(state.added) do
		print("Adding route: " .. name)
		local cf = node_vars("/routing/route/"..name, CF_new)
		cf.interface = interface_name(cf.interface)
		cf.source = "routes"
		print("dest="..tostring(cf.dest).." interface="..tostring(cf.interface).." table="..tostring(cf.table))
--		runtime.insert_route(cf)		
	end

	for name in each(state.removed) do
		print("Removing route: " .. name)
		local cf = node_vars("/routing/route/"..name, CF_current)
		cf.interface = interface_name(cf.interface)
		cf.source = "routes"
--		runtime.delete_route(cf)		
	end

	for name in each(state.changed) do
		print("Changing route: " .. name)
		local cf = node_vars("/routing/route/"..ifnum, CF_new) or {}
		local oldcf = node_vars("/routing/route/"..ifnum, CF_current) or {}
		cf.interface = interface_name(cf.interface)
		cf.source = "routes"
		oldcf.interface = interface_name(oldcf.interface)
		oldcf.source = "routes"

--		runtime.delete_route(oldcf)		
--		runtime.insert_route(cf)		
	end
	lib.runtime.block_off()
	return true
end

--
--
--
local function routing_precommit(changes)
	return true
end


--
-- Main routing config definition
--
master["/routing"] = { 
	["commit"] = routing_commit,
	["precommit"] = routing_precommit 
}

master["/routing/route"] = { ["with_children"] = 1 }
master["/routing/route/*"] = 			{ ["style"] = "text_label" }
master["/routing/route/*/interface"] = 	{ ["type"] = "any_interface",
										  ["options"] = "all_interfaces" }
master["/routing/route/*/dest"] = 		{ ["type"] = "ipv4_nm_default" }
master["/routing/route/*/gateway"] = 	{ ["type"] = "OK" }
master["/routing/route/*/table"] =		{ ["type"] = "OK", ["default"] = "main" }
master["/routing/route/*/priority"] = 	{ ["type"] = "2-digit" }


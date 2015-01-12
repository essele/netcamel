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

local db = require("db")
local runtime = require("runtime")

--
-- Commit will just remove all the routes and then re-add them
--
-- TODO: what about live routes
--
local function routing_commit(changes)
	runtime.block_on()
	print("Hello From ROUTINGQ")

	local state = process_changes(changes, "routing/route")

	for name in each(state.added) do
		print("Adding route: " .. name)
		local cf = node_vars("routing/route/"..name, CF_new)
		cf.interface = interface_name(cf.interface)
		cf.source = "routes"
		print("dest="..tostring(cf.dest).." interface="..tostring(cf.interface).." table="..tostring(cf.table))
		runtime.insert_route(cf)		
	end

	for name in each(state.removed) do
		print("Removing route: " .. name)
		local cf = node_vars("routing/route/"..name, CF_current)
		cf.interface = interface_name(cf.interface)
		cf.source = "routes"
		runtime.delete_route(cf)		
	end

	for name in each(state.changed) do
		print("Changing route: " .. name)
		local cf = node_vars("routing/route/"..ifnum, CF_new) or {}
		local oldcf = node_vars("routing/route/"..ifnum, CF_current) or {}
		cf.interface = interface_name(cf.interface)
		cf.source = "routes"
		oldcf.interface = interface_name(oldcf.interface)
		oldcf.source = "routes"

		runtime.delete_route(oldcf)		
		runtime.insert_route(cf)		
	end
	runtime.block_off()

--[[

	local rc, err = db.query("routes", "remove_all_routes")
	print("remove: rc="..tostring(rc).." err="..tostring(err))

	for routename in each(node_list("routing/route", CF_new)) do
		local route = node_vars("routing/route/"..routename, CF_new)

		print("Route: "..routename.." dest="..route.dest)
		--
		-- Build an entry for the database...
		--
		local entry = copy_table(route)
		entry.source = "routes"
		entry.interface = interface_name(entry.interface)
	
		local rc, err = db.insert("routes", entry)
		print("add: rc="..tostring(rc).." err="..tostring(err))
	end
]]--
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
master["routing"] = { 
	["commit"] = routing_commit,
	["precommit"] = routing_precommit 
}

master["routing/route"] = { ["with_children"] = 1 }
master["routing/route/*"] = 			{ ["style"] = "text_label" }
master["routing/route/*/interface"] = 	{ ["type"] = "any_interface",
										  ["options"] = options_all_interfaces }
master["routing/route/*/dest"] = 		{ ["type"] = "ipv4_nm_default" }
master["routing/route/*/gateway"] = 	{ ["type"] = "OK" }
master["routing/route/*/table"] =		{ ["type"] = "OK", ["default"] = "main" }
master["routing/route/*/priority"] = 	{ ["type"] = "2-digit" }

TABLE["routes"] = {
	schema = { 	source="string key",
				dest="string",
				gateway="string" ,
				interface="string",
				priority="integer", 
				table="string",
	},
	
	--
	-- Remove a specific route matching source, dest and table
	--
	delete_route_for_source = "delete from routes where source = :source and dest = :dest and \"table\" = :table",

	--
	-- Return the defaultroute with the lowest priority for the given table
	--
	priority_defaultroutes_for_table = 
			"select * from routes where \"table\" = :table and dest = 'default' and " ..
			"priority = (select min(priority) from routes where \"table\" = :table and dest = 'default')",

	--
	-- Find all non-default routes for the given interface (where the interface is up!)
	--
	routes_for_interface = "select * from routes where interface = :interface",

	remove_all_routes = "delete from routes where source = 'routes'",
}



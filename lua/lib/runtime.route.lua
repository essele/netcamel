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
--package.path = "./lib/?.lua;" .. package.path

require("utils")
require("execute")
local db = require("db")

--
-- New route system, we create a table that contains any routes we might want
-- to apply. When applied we remove any for interfaces that aren't up, and we
-- remove any for gateway IP's that aren't locally accessable.
--
-- We then look at what's left ... where we have duplicates for a given destination
-- we use the priority, or if matching, pick the first one.
--
-- The table is purely a means to store data, we use a serialised table for the
-- real info
--
-- We *could* also store resolvers and rules in the same table if we have a type
-- field
--

--[[
db.insert("runtime", { class="route", source="eth0", 
	item=serialise({dest="30.20.10.0/24", gw=nil, dev="eth0", pri=10, table="joe"})
})
]]--

--
-- Add a route into our runtime table
--
local function add_route_from_source(route, source)
	db.insert("runtime", { class="route", source=source, item=serialise(route) })
end
local function remove_routes_from_source(source)
	local rc, err = db.query("runetime", "rm_routes", source)
	print("rmroutes: rc="..tostring(rc).." err="..tostring(err))
end

--
-- Given a route structure work out the arguments to the ip
-- command
--
local function ip_route_args(cmd, route)
	local rc = { "route", cmd, route.dest }
	if route.gateway then
		table.insert(rc, "via")
		table.insert(rc, route.gateway)
	end
	table.insert(rc, "dev")
	table.insert(rc, route.interface or route.dev)
	table.insert(rc, "table")
	table.insert(rc, route.table or "main")
	return rc
end

--
-- Create a table based on the destination, we prefix the dest with the routing
-- table so that we don't mix different tables routes.
--
local function get_all_up_interfaces()
	local rc = {}
	for _,i in ipairs(db.query("status", "all_up")) do
		print("Interface: "..i.node.." is up")
		rc[i.node] = 1
	end
	return rc
end

--
-- Work out which interface we use to get to the given address. If the
-- address isn't locally accessible then we return nil.
--
-- We also cache to save too many lookups of the same thing.
--
local __gri_cache = {}
local function get_routing_interface(gw)
	--
	-- Return a cached response if we have one...
	--
	if __gri_cache[gw] then
		if __gri_cache[gw] == false then return nil end
		return __gri_cache[gw]
	end

	--
	-- Pull out the response from ip route get, if there is a via then
	-- we are not local
	--
	local rc, out = pipe_execute("/sbin/ip", { "route", "get", gw })
	if rc == 0 and out[1] then
		local via = out[1]:match("via")
		local dev = out[1]:match(" dev ([^%s]+)")
			
		if via or not dev then
			__gri_cache[gw] = false
			return nil
		end
		__gri_cache[gw] = dev
		return dev
	end
	return nil
end

--
-- Read the routing table into a hash. Key is tablename/dest, the value
-- is a hash containing the route information.
--
function get_routes()
	local status, routes = pipe_execute("/sbin/ip", 
				{ "-4", "route", "list", "type", "unicast", "table", "all" })
	if status ~= 0 then 
		print("AARRGH")
		for _,v in ipairs(routes or {}) do print(">> "..v) end
		return nil 
	end

	local rc = {}
	for _, route in ipairs(routes) do
		local dev, gateway, dest, tbl, proto
		local f = split(route, "%s")

		dest = table.remove(f, 1)
		while f[1] do
			local cmd = table.remove(f, 1)
			if cmd == "dev" then dev = table.remove(f, 1)
			elseif cmd == "via" then gateway = table.remove(f, 1)
			elseif cmd == "table" then tbl = table.remove(f, 1)
			elseif cmd == "proto" then proto = table.remove(f, 1)
			else table.remove(f, 1) table.remove(f, 1) end
		end
		if proto ~= "kernel" then
			tbl = tbl or "main"
			rc[tbl.."/"..dest] = { dest = dest, dev = dev, gw = gateway, table = tbl }
		end
	end
	return rc
end


local function update_routes()
	--
	-- Clear gri routing cache, since we don't want it to persist
	-- through any routing changes. Also pull out the list of all
	-- of the interfaces that are up.
	--
	__gri_cache = {}
	local up_interfaces = get_all_up_interfaces()

	--
	-- Pull out all the routes
	--
	local rt = {}
	for _, r in ipairs(db.query("runtime", "routes")) do
		local route = unserialise(r.item)

		--
		-- Check that the gw is local and dev matches (if provided)
		--
		if route.gw then
			local route_if = get_routing_interface(route.gw)
			if not route_if then print("gw: "..route.gw.." not local") goto continue end
			if route.dev and route.dev ~= route_if then print("gw: "..route.gw.." device mismatch") goto continue end
			route.dev = route_if
		end
		if not route.dev then print("no device") goto continue end

		--
		-- See if the device is actually up
		--
		if not up_interfaces[route.dev] then print("device: "..route.dev.." not up") goto continue end

		--
		-- If our priority is better (lower) than the existing entry then we take over.
		-- If we are worse or the same then do nothing.
		--
		local tbl = route.table or "main"
		local key = tbl .. "/" .. route.dest

		local my_pri = route.pri
		local cur_pri = rt[key] and rt[key].pri

		if cur_pri and my_pri > cur_pri then goto continue end
		if not cur_pri or my_pri < cur_pri then rt[key] = route end
		print("Key = "..key)
::continue::
	end

	--
	-- So now we have a full list of all routes we should have installed,
	-- pull out a current routing table list and then work out what the deltas
	-- are and apply them.
	--
	local routes = get_routes()

	for d, cur in pairs(routes) do
		local new = rt[d]
		local different = new and (cur.dev ~= new.dev or cur.gw ~= new.gw)

		print("Current: "..d.." new="..tostring(rt[d]))
	
		--
		-- Not needed, or different?
		--
		if not new or different then
			print("Deleteing route: "..d)
			print("/sbin/ip "..table.concat(ip_route_args("del", cur), " "))
		end

		--
		-- Put the new one in place if we have one
		--
		if different then
			print("Adding route: "..d.." gw="..tostring(new.gw).." dev="..tostring(new.dev))
			print("/sbin/ip "..table.concat(ip_route_args("add", new), " "))
		end
		rt[d] = nil
	end
	--
	-- Add any extra routes
	--
	for d, new in pairs(rt) do
		print("Adding new route: "..d.." gw="..tostring(new.gw).." dev="..tostring(new.dev))
		print("/sbin/ip "..table.concat(ip_route_args("add", new), " "))
	end
end

return {
	add_route_from_source = add_route_from_source,
	remove_routes_from_source = remove_routes_from_source,
	update_routes = update_routes,
}


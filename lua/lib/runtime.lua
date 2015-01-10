--------------------------------------------------------------------------------
--  This file is part of NetCamel
--  Copyright (C) 2014,2015 Lee Essen <lee.essen@nowonline.co.uk>
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
-- This module provides a number of runtime helpers
--


--
-- We need to access the database
--
local db = require("db")


local function remove_resolvers(source)
	db.query("resolvers", "remove_source", source)
end
local function add_resolver(source, value, priority)
	db.insert("resolvers", { source = source, priority = priority, value = value })
end

--
-- Insert and remove routes from the routing database
--
local function insert_route(e)
	local entry = copy_table(e)
	entry.table = entry.table or "main"
	local rc, err = db.insert("routes", entry)
	print("route insert rc="..tostring(rc).." err="..tostring(err))
end
local function delete_route(f)
	local entry = copy_table(f)
	entry.dest = entry.dest or "default"
	entry.table = entry.table or "main"

	local rc, err = db.query("routes", "delete_route_for_source", entry)
	print("route delete rc="..tostring(rc).." err="..tostring(err))
end

--
-- Now work out what the correct route and resolvers are
--
local function update_resolvers()
	local resolvers = db.query("resolvers", "priority_resolvers")
	local file = io.open("/etc/resolv.conf", "w")
	for resolver in each(resolvers) do
		file:write(string.format("nameserver %s # %s\n", resolver.value, resolver.source))
	end
	file:close()
end

--
-- Remove the default route, and then add from the prioritised records
--
-- We can only support one router at this stage, so just pick the first one
-- we get back.
--
local function update_defaultroute(table)
	table = table or "main"

	print(string.format("ip route del default table %s 2>/dev/null", table))
	os.execute(string.format("ip route del default table %s 2>/dev/null", table))
	local routers, err = db.query("routes", "priority_defaultroutes_for_table", table)
	if not routers then
		print("Err for pdft="..tostring(err))
	else
		print("count="..#routers)
	end
	if routers and routers[1] then
		local gateway, interface = routers[1].gateway, routers[1].interface
		os.execute(string.format("ip route add default via %s dev %s table %s", gateway, interface, table))
		print(string.format("ip route add default via %s dev %s table %s", gateway, interface, table))
	end
end

--
-- Redirect our output to the named logfile, we keep the posix require in here
-- so that we don't impact performance too much.
--
local function redirect(filename)
	posix = require("posix")
	posix.fcntl = require("posix.fcntl")
	require("bit")
	posix.close(1)
	posix.close(2)
	local fd = posix.fcntl.open(filename, bit.bor(posix.O_WRONLY, posix.O_CREAT, posix.O_APPEND, posix.O_SYNC))
	posix.dup(fd)
end

return {
	remove_resolvers = remove_resolvers,
	remove_defaultroute = remove_defaultroute,
	add_resolver = add_resolver,
	add_defaultroute = add_defaultroute,
	insert_route = insert_route,
	delete_route = delete_route,

	update_resolvers = update_resolvers,
	update_defaultroute = update_defaultroute,
	redirect = redirect,
}




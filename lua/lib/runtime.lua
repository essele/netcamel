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
local function remove_defaultroute(source)
	db.query("defaultroutes", "remove_source", source)
end
local function add_resolver(source, value, priority)
	db.insert("resolvers", { source = source, priority = priority, value = value })
end
local function add_defaultroute(source, value, priority)
	db.insert("defaultroutes", { source = source, priority = priority, value = value })
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
local function update_defaultroute()
	os.execute(string.format("ip route del default 2>/dev/null"))
	local routers = db.query("defaultroutes", "priority_defaultroutes")
	if routers and routers[1] then
		local router, interface = routers[1].value, routers[1].source
		os.execute(string.format("ip route add default via %s dev %s", router, interface))
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
	update_resolvers = update_resolvers,
	update_defaultroute = update_defaultroute,
	redirect = redirect,
}




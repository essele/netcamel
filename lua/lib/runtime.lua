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
-- Build the specific posix commands we need, this saves using the full
-- require which adds quite a delay to startup.
--
local posix = {
	fcntl = require("posix.fcntl"),
	unistd = require("posix.unistd"),
}
posix.fcntl.FD_CLOEXEC = 1

--
-- We need to access the database
--
local db = require("db")

--
-- We will need lots of logging
--
require("bit")
require("execute")
require("log")


--
-- Support blocking so we can have only one process doing something at a time
--
local __block_fd = nil
local __block_filename = "/tmp/.nc_block"
local __block_i = 0

function block_on()
	--
	-- Only actually lock the first time, otherwise just keep count
	--
	__block_i = __block_i + 1
	if __block_i > 1 then return end

	local lock = {
		l_type = posix.fcntl.F_WRLCK,
		l_whence = posix.fcntl.SEEK_SET,
		l_start = 0,
		l_len = 0,
	}
	__block_fd = posix.fcntl.open(__block_filename, bit.bor(posix.fcntl.O_CREAT, posix.fcntl.O_WRONLY), tonumber(644, 8))
	local rc = posix.fcntl.fcntl(__block_fd, posix.fcntl.F_SETFD, posix.fcntl.FD_CLOEXEC)
	print("setfd="..rc)

	local result = posix.fcntl.fcntl(__block_fd, posix.fcntl.F_SETLKW, lock)
	if result == -1 then
		print("result = "..result)
	end
end
function block_off(name)
	__block_i = __block_i - 1
	if __block_i > 0 then return end

	if __block_fd then
		posix.unistd.close(__block_fd)
		posix.unistd.unlink(__block_filename)
		__block_fd = nil
	end
end

--
-- Simple execute function that wraps pipe_execute, but also logs
-- the commands and output.
--
function execute(binary, args)
	local rc, res = pipe_execute(binary, args, nil, nil)
	log("cmd", "# %s%s (exit: %d)", binary,	args and " "..table.concat(args, " "), rc)
	for _, out in pairs(res) do
		log("cmd", "> %s", out)
	end
end


--
-- Allow set and get status 
--
local function get_status(node)
	local rc, err = db.query("status", "get_status", node)
	if rc and rc[1] then return rc[1].status end
	return false, err
end
local function set_status(node, status)
	local rc, err = db.query("status", "set_status", node, status)
	log("info", "%s is %s", node, status)
	return rc, err
end
local function is_up(node) return ((get_status(node)) == "up") end

local function remove_resolvers(source)
	db.query("resolvers", "remove_source", source)
end
local function add_resolver(source, value, priority)
	db.insert("resolvers", { source = source, priority = priority, value = value })
	log("info", "adding dns resolver option: %s (pri=%s)", value, priority)
end

--
-- Now work out what the correct route and resolvers are
--
local function update_resolvers()
	log("info", "selecting resolvers based on priority")

	local resolvers = db.query("resolvers", "priority_resolvers")
	local file = io.open("/etc/resolv.conf", "w+")
	for resolver in each(resolvers) do
		file:write(string.format("nameserver %s # %s\n", resolver.value, resolver.source))
		log("info", "- selected resolver %s (%s)", resolver.value, resolver.source)
	end
	file:close()
	if #resolvers == 0 then log("info", "- no resolvers available") end
end

-- ------------------------------------------------------------------------------
-- ROUTE MANIPULATION CODE
-- ------------------------------------------------------------------------------

--
-- Read the routing table into a hash. First key is the table name, then we have
-- interface and gateway.
--
function get_routes()
	tbl = tbl or "main"
	local status, routes = pipe_execute("/sbin/ip", { "-4", "route", "list", "type", "unicast", "table", "all" })
	if status ~= 0 then 
		print("AARRGH")
		for _,v in ipairs(routes or {}) do print(">> "..v) end
		return nil 
	end

	local rc = {}
	for _, route in ipairs(routes) do
		local dev, gateway, dest, tbl
		local f = split(route, "%s")

		dest = table.remove(f, 1)
		while f[1] do
			local cmd = table.remove(f, 1)
			if cmd == "dev" then dev = table.remove(f, 1)
			elseif cmd == "via" then gateway = table.remove(f, 1)
			elseif cmd == "table" then tbl = table.remove(f, 1)
			else table.remove(f, 1) table.remove(f, 1) end
		end
		tbl = tbl or "main"
		if not rc[tbl] then rc[tbl] = {} end
		rc[tbl][dest] = { dest = dest, interface = dev, gateway = gateway }
	end
	return rc
end

--
-- Prepare a list of arguments for the ip route commands
--
local function ip_route_args(cmd, route, tbl)
	tbl = tbl or "main"

	local rc = { "route", cmd, route.dest }
	if route.gateway then 
		table.insert(rc, "via") 
		table.insert(rc, route.gateway)
	end
	table.insert(rc, "dev")
	table.insert(rc, route.interface)
	table.insert(rc, "table")
	table.insert(rc, tbl)
	return rc
end



--
-- Insert and remove routes from the transient routing database, if they are from
-- the 'routes' system then we check if we need to really apply the route.
--
local function insert_route(e)
	local entry = copy_table(e)
	entry.table = entry.table or "main"

	local rc, err = db.insert("routes", entry)
	print("route insert rc="..tostring(rc).." err="..tostring(err))

	print("Source is: "..tostring(entry.source))
	print("ISUP: "..entry.interface.." " ..tostring(is_up(entry.interface)))

	if entry.source == "routes"	and is_up(entry.interface) then
		--
		-- TODO: only add if its not there
		--
		log("info", "interface is up - adding route")
		execute("/sbin/ip", ip_route_args("add", entry, entry.table))
	end
end
local function delete_route(f)
	local entry = copy_table(f)
	entry.dest = entry.dest or "default"
	entry.table = entry.table or "main"

	local rc, err = db.query("routes", "delete_route_for_source", entry)
	print("route delete rc="..tostring(rc).." err="..tostring(err))

	if entry.source == "routes"	and is_up(entry.interface) then
		--
		-- TODO: only delete if its in the list
		--
		log("info", "interface is up - deleting route")
		execute("/sbin/ip", ip_route_args("del", entry, entry.table))
	end
end

--
-- Remove any routes for the given interface, this will generally happen
-- automatically when the interface goes down, but we do this just in case
-- we have other things going on.
--
local function clear_routes_for_interface(interface)
	log("info", "clearing routes for interface")

	--
	-- Get our current routing table
	--
	local routes = get_routes()

	--
	-- Now delete anything relevant, from all tables
	--
	for tbl, rl in pairs(routes) do
		for dest, route in pairs(rl) do
			if route.interface == interface then execute("/sbin/ip", ip_route_args("del", route, tbl)) end
		end
	end
end

--
-- Make sure we have all the definied routes configured. Note that we won't delete extra
-- routes, but we will change routes if the destination is the same.
--
local function set_routes_for_interface(interface)
	log("info", "installing routes for interface")

	--
	-- Get our current routing table
	--
	local routes = get_routes()

	--
	-- Work out what routes we should have
	--
	local rc, err = db.query("routes", "routes_for_interface", interface)
	if not rc then return rc, err end

	for _, new in ipairs(rc) do
		local current = routes[new.table] and routes[new.table][new.dest]

		if current then
			if current.interface == new.interface or current.gateway == new.gateway then
				log("info", "- route for %s/%s via %s already installed", current.dest, current.table, current.interface)
				goto continue
			end
			execute("/sbin/ip", ip_route_args("del", current, new.table))
		end
		execute("/sbin/ip", ip_route_args("add", new, new.table))

::continue::
	end
end

--
-- Remove the default route, and then add from the prioritised records
--
-- We can only support one router at this stage, so just pick the first one
-- we get back.
--
local function update_defaultroute(table)
	table = table or "main"

	block_on()
	log("info", "selecting defaultroute/%s", table)

	--
	-- Work out what we have currently
	--
	local routes = get_routes()
	local current = routes[table] and routes[table]["default"]

	--
	-- Work out what the route should be...
	--
	local default = nil
	local routers, err = db.query("routes", "priority_defaultroutes_for_table", table)
	if not routers then
		log("error", "unable to get priority_defaultroutes_for_table %s: %s", table, tostring(err))
		goto done
	end
	if routers and routers[1] then default = routers[1] end

	--
	-- See if we need to change
	--
	if current == nil and default == nil then 
		log("info", "- no defaultroute available, already correct")
		goto done 
	end
	if current and default then
		if (current.interface == default.interface and current.gateway == default.gateway) then
			log("info", "- gateway via %s, already correct", current.interface)
			goto done
		end
	end

	--
	-- By now we know there is a difference, so remove and add as needed
	--
	if current then
		log("info", "- removing %s via %s", current.gateway or "*", current.interface)
		execute("/sbin/ip", ip_route_args("del", current))
	end
	if default then
		log("info", "- adding %s via %s", default.gateway or "*", default.interface)
		execute("/sbin/ip", ip_route_args("add", default))
	end

::done::
	block_off()
end

--
-- When an interface comes up, we need to mark it up, install all the relevant routes
-- deal with the provided resolvers, add the defaultroutes.
--
-- Finally, we recreate the resolv.conf and do the right thing with defaultroute.
--
local function interface_up(interface, dns, routers, vars)
	--
	-- Install any routes associated with this interface
	--
	set_routes_for_interface(interface)

	--
	-- Add the resolvers to the resolver table if we need to
	--
	remove_resolvers(interface)
	if not vars["no-resolv"] then
		for resolver in each(dns) do
			add_resolver(interface, resolver, vars["resolv-pri"])
		end
	end
	--
	-- Add the defaultroutes to the routes table
	--
	delete_route({ source = interface, dest = "default", table = vars["defaultroute-table"] })
	if not vars["no-defaultroute"] then
		for router in each(routers) do
			insert_route({ source = interface, dest = "default", gateway = router,
				interface = interface, priority = vars["defaultroute-pri"], table = vars["defaultroute-table"] })
		end
	end

	--
	-- Now update the resolvers and default routes
	--
	update_resolvers()
	update_defaultroute(vars["defaultroute-table"])
	set_status(interface, "up")
end
local function interface_down(interface, vars)
	remove_resolvers(interface)
	delete_route({ source = interface, dest = "default", table = vars["defaultroute-table"] })
	clear_routes_for_interface(interface)
	update_resolvers()
	update_defaultroute(vars["defaultroute-table"])
	set_status(interface, "down")
end


--
-- Redirect our output to the named logfile
--
local function redirect(filename)
	posix.unistd.close(1)
	posix.unistd.close(2)
	local fd = posix.fcntl.open(filename, bit.bor(posix.fcntl.O_WRONLY, 
				posix.fcntl.O_CREAT, posix.fcntl.O_APPEND, posix.fcntl.O_SYNC))
	posix.unistd.dup(fd)
end

--
-- Gets the vars from a service definition, this should probably be in
-- lib/service but having it here saves all the posix stuff.
--
local function get_vars(name)
--	print("Get VARS: "..name)
	local svc = db.query("services", "get_service", name)
	if not svc or #svc ~= 1 then return nil, "unknown service" end

	svc = svc[1]
	if svc.vars then return unserialise(svc.vars) end
	return nil
end


return {
	interface_up = interface_up,
	interface_down = interface_down,

	insert_route = insert_route,
	delete_route = delete_route,

	redirect = redirect,
	get_vars = get_vars,

	set_status = set_status,
	get_status = get_stats,

	execute = execute,

	block_on = block_on,
	block_off = block_off,
}


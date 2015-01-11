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

local function remove_resolvers(source)
	db.query("resolvers", "remove_source", source)
end
local function add_resolver(source, value, priority)
	db.insert("resolvers", { source = source, priority = priority, value = value })
	log("info", "adding dns resovler option: %s (pri=%s)", value, priority)
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
	log("info", "selecting resolvers based on priority")

	local resolvers = db.query("resolvers", "priority_resolvers")
	local file = io.open("/etc/resolv.conf", "w")
	for resolver in each(resolvers) do
		file:write(string.format("nameserver %s # %s\n", resolver.value, resolver.source))
		log("info", "- selected resolver %s (%s)", resolver.value, resolver.source)
	end
	file:close()
	if #resolvers == 0 then log("info", "- no resolvers available") end
end

--
-- Get all the non-defaulroute routes for the given interface where the
-- interface is up.
--
local function set_routes_for_interface(interface, op)
	op = op or "add"
	local verb = (op == "add" and "installing") or "removing"

	log("info", "%s routes for interface", verb)

	local rc, err = db.query("routes", "routes_for_interface", interface)
	if not rc then return rc, err end

	for _, route in ipairs(rc) do
		if route.gateway then
			runtime.execute("/sbin/ip", { "route", op, route.dest, "via", route.gateway,
								"dev", route.interface, "table", route.table }) 
		else
			runtime.execute("/sbin/ip", { "route", op, route.dest, "dev", route.interface,
								"table", route.table })
		end
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

	log("info", "selecting defaultroute/%s", table)
	
	runtime.execute("/sbin/ip", { "route", "del", "default", "table", table })
	local routers, err = db.query("routes", "priority_defaultroutes_for_table", table)
	if not routers then
		print("Err for pdft="..tostring(err))
	else
		print("count="..#routers)
	end
	if routers and routers[1] then
		local gateway, interface = routers[1].gateway, routers[1].interface
		log("info", "- selecting defaultroute/%s %s", table, gateway)
		runtime.execute("/sbin/ip", { "route", "add", "default", "via", gateway, "dev", interface, "table", table })
	else
		log("info", "- no defaultroute/%s available", table)
	end
end

--
-- When an interface comes up, we need to mark it up, install all the relevant routes
-- deal with the provided resolvers, add the defaultroutes.
--
-- Finally, we recreate the resolv.conf and do the right thing with defaultroute.
--
local function interface_up(interface, dns, routers, vars)
	--
	-- Mark the interface as up
	--
	set_status(interface, "up")

	--
	-- Install any routes associated with this interface
	--
	set_routes_for_interface(interface, "add")

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
end
local function interface_down(interface, vars)
	remove_resolvers(interface)
	delete_route({ source = interface, dest = "default", table = vars["defaultroute-table"] })
	set_routes_for_interface(interface, "del")
	set_status(interface, "down")
	update_resolvers()
	update_defaultroute(vars["defaultroute-table"])
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
-- Simple execute function that wraps os.execute, but also logs
-- the commands
--
--function execute(cmd)
--	log("cmd", "# %s", cmd)
--	return os.execute(cmd)
--end
function execute(binary, args)
	local rc, res = pipe_execute(binary, args, nil, nil)
	log("cmd", "# %s%s (exit: %d)", binary,	args and " "..table.concat(args, " "), rc)
	for _, out in pairs(res) do
		log("cmd", "> %s", out)
	end
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
	set_routes_for_interface = set_routes_for_interface,

	interface_up = interface_up,
	interface_down = interface_down,

	redirect = redirect,
	get_vars = get_vars,

	set_status = set_status,
	get_status = get_stats,

	exec = exec,
	execute = execute,
}




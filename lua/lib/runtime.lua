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

posix.fcntl.FD_CLOEXEC = 1
local bit = require("bit")

--
-- Support blocking so we can have only one process doing something at a time
--
local __block_fd = {}
local __block_filename = "/tmp/.nc_block"
local __block_i = {}

local function block_on(b)
	--
	-- Setup 
	--
	b = b or "default"
	if not __block_i[b] then 
		__block_i[b] = 0 
	end

	--
	-- Only actually lock the first time, otherwise just keep count
	--
	__block_i[b] = __block_i[b] + 1
	if __block_i[b] > 1 then return end

	local lock = {
		l_type = posix.fcntl.F_WRLCK,
		l_whence = posix.unistd.SEEK_SET,
		l_start = 0,
		l_len = 0,
	}
	__block_fd[b] = posix.fcntl.open(__block_filename.."_"..b, 
						bit.bor(posix.fcntl.O_CREAT, posix.fcntl.O_WRONLY), tonumber(644, 8))
	local rc = posix.fcntl.fcntl(__block_fd[b], posix.fcntl.F_SETFD, posix.fcntl.FD_CLOEXEC)
	print("setfd="..rc)

	local result = posix.fcntl.fcntl(__block_fd[b], posix.fcntl.F_SETLKW, lock)
	if result == -1 then
		print("result = "..result)
	end
end
local function block_off(b)
	b = b or "default"
	__block_i[b] = __block_i[b] - 1
	if __block_i[b] > 0 then return end

	if __block_fd[b] then
		posix.unistd.close(__block_fd[b])
		posix.unistd.unlink(__block_filename.."_"..b)
		__block_fd[b] = nil
	end
end

--
-- Simple execute function that wraps pipe_execute, but also logs
-- the commands and output.
--
local function execute(binary, args)
	local rc, res = lib.execute.pipe(binary, args, nil, nil)
	lib.log.log("cmd", "# %s%s (exit: %d)", binary,	args and " "..table.concat(args, " "), rc)
	for _, out in pairs(res) do
		lib.log.log("cmd", "> %s", out)
	end
end

--
-- Allow set and get status 
--
local function get_status(node)
	local rc, err = lib.db.query("status", "get_status", node)
	if rc and rc[1] then return rc[1].status end
	return false, err
end
local function set_status(node, status)
	local rc, err = lib.db.query("status", "set_status", node, status)
	lib.log.log("info", "%s is %s", node, status)
	return rc, err
end
local function is_up(node) return ((get_status(node)) == "up") end


-- ------------------------------------------------------------------------------
--
-- INTERNAL ROUTE MANIPULATION STUFF, not exposed outside of runtime
--
-- ------------------------------------------------------------------------------

--
-- Add a route into our runtime table
--
local function add_route_from_source(route, source)
	lib.db.insert("runtime", { class="route", source=source, item=lib.utils.serialise(route) })
end
local function remove_routes_from_source(source)
	local rc, err = lib.db.query("runtime", "rm_routes", source)
end
--
-- Remove a specific route from the runtime table. We need to be careful with
-- non-deterministic serialisation, so we look at each route and compare
-- source, dest and table.
--
local function remove_route_from_source(route, source)
	for _, r in ipairs(lib.db.query("runtime", "routes")) do
		if r.source == source then
			local rr = lib.utils.unserialise(r.item)
			if rr.dest == route.dest and rr.table == route.table then
				local rc, err = lib.db.query("runtime", "rm_route", {source=source, item=r.item})
			end
		end
	end
end

--
-- Add resolvers into our runtime table
--
local function add_resolver_from_source(resolver, source)
	lib.db.insert("runtime", { class="resolver", source=source, item=lib.utils.serialise(resolver) })
end
local function remove_resolvers_from_source(source)
	local rc, err = lib.db.query("runtime", "rm_resolvers", source)
end

--
-- Given a route structure work out the arguments to the ip
-- command
--
local function ip_route_args(cmd, route)
	local rc = { "route", cmd, route.dest }
	if route.gw then
		table.insert(rc, "via")
		table.insert(rc, route.gw)
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
	for _,i in ipairs(lib.db.query("status", "all_up")) do
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
	local rc, out = lib.execute.pipe("/sbin/ip", { "route", "get", gw })
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
	local status, routes = lib.execute.pipe("/sbin/ip", 
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
		-- ensure /32 is added on where needed
		if dest ~= "default" and not dest:find("/", 1, true) then dest = dest .. "/32" end

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

--
-- Given a hash of up interfaces, build a list of all the routes that we would
-- apply.
--
-- TODO: put back local
function build_route_list_for_interfaces(interfaces)
	local rt = {}
	for _, r in ipairs(lib.db.query("runtime", "routes")) do
		local route = lib.utils.unserialise(r.item)
		
		--
		-- Check that the gw is local and dev matches (if provided), we will add any
		-- PRIOR-DEFAULT devices by default with no checks
		--
		if route.gw and route.gw ~= "PRIOR-DEFAULT" then
			local route_if = get_routing_interface(route.gw)
			if not route_if then print("gw: "..route.gw.." not local") goto continue end
			if route.dev and route.dev ~= route_if then print("gw: "..route.gw.." device mismatch") goto continue end
			route.dev = route_if
		end
		if not route.dev then print("dest: "..route.dest.." no device") goto continue end
		if not interfaces[route.dev] then print("device: "..route.dev.." not considered") goto continue end

		--
		-- If our priority is better (lower) than the existing entry then we take over.
		-- If we are worse or the same then do nothing.
		--
		local tbl = route.table or "main"
		local key = tbl .. "/" .. route.dest

		local my_pri = route.pri or 50
		local cur_pri = rt[key] and rt[key].pri

		if cur_pri and my_pri > cur_pri then goto continue end
		if not cur_pri or my_pri < cur_pri then rt[key] = route end
		print("Key = "..key)
::continue::
	end
	return rt
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
	local rt = build_route_list_for_interfaces(up_interfaces)

	--
	-- Now process any PRIOR-DEFAULT routes
	--
	for dest, route in pairs(rt) do
		if route.gw == "PRIOR-DEFAULT" then
			local reduced_interfaces = lib.utils.copy(up_interfaces)
			reduced_interfaces[route.dev] = nil
			local new_routes = build_route_list_for_interfaces(reduced_interfaces)
			local prior_default = new_routes["main/default"]
			if prior_default then
				route.gw = prior_default.gw
				route.dev = prior_default.dev
			else
				print("Unable to make PRIOR-DEFAULT for "..dest)
				rt[dest] = nil
			end
		end
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
			execute("/sbin/ip", ip_route_args("del", cur))
		end

		--
		-- Put the new one in place if we have one
		--
		if different then
			print("Adding route: "..d.." gw="..tostring(new.gw).." dev="..tostring(new.dev))
			if new.table and new.table ~= "main" then lib.ipr2.use("table", new.table) end
			execute("/sbin/ip", ip_route_args("add", new))
		end
		rt[d] = nil
	end
	--
	-- Add any extra routes
	--
	for d, new in pairs(rt) do
		print("Adding new route: "..d.." gw="..tostring(new.gw).." dev="..tostring(new.dev))
		if new.table and new.table ~= "main" then lib.ipr2.use("table", new.table) end
		execute("/sbin/ip", ip_route_args("add", new))
	end
	
	--
	-- Flush the cache to make changes effective immediately
	--
	execute("/sbin/ip", {"route", "flush", "cache"})
end

--
-- Create a resolv.conf file based on the correct set of resolvers
-- (we pick the ones with the lowest priority, but bearing in mind we
-- might have many at the same pri)
--
--
local function update_resolvers()
    lib.log.log("info", "selecting resolvers based on priority")

	local resolvers = lib.db.query("runtime", "resolvers")

	--
	-- First we find the items with the lowest priority...
	--
	local min = math.huge
	local resolvers = {}
	for _, r in ipairs(lib.db.query("runtime", "resolvers")) do
		local resolver = lib.utils.unserialise(r.item)
		if resolver.pri < min then 
			resolvers = {} 
			min = resolver.pri 
		end
		if resolver.pri == min then 
			resolver.source = r.source			-- carry over source for later use
			table.insert(resolvers, resolver) 
		end
	end

	--
	-- Now create the file containing those matching min
	--
    local file = io.open("/tmp/resolv.conf.auto", "w+")
	for _, resolver in ipairs(resolvers) do
        file:write(string.format("nameserver %s # %s\n", resolver.ip, resolver.source))
        lib.log.log("info", "- selected resolver %s (%s)", resolver.ip, resolver.source)
	end
    file:close()
    if #resolvers == 0 then lib.log.log("info", "- no resolvers available") end
end

-- ------------------------------------------------------------------------------
-- ROUTE MANIPULATION CODE
-- ------------------------------------------------------------------------------

--
-- When an interface comes up, we need to mark it up, install all the relevant routes
-- deal with the provided resolvers, add the defaultroutes.
--
-- Finally, we recreate the resolv.conf and do the right thing with defaultroute.
--
local function interface_up(interface, dns, router, vars)
	block_on()
	--
	-- Mark the interface up (needed for the routes to work properly)
	--
	set_status(interface, "up")

	--
	-- Add any listed resolvers, translate AUTO into each of the
	-- provided resolver addresses
	--
	remove_resolvers_from_source(interface)
	for _,resolver in ipairs(vars.resolver or {}) do
		if resolver.ip == "AUTO" and dns then
			for _,r in ipairs(dns) do
				resolver.ip = r
				add_resolver_from_source(resolver, interface)
			end
		else
			add_resolver_from_source(resolver, interface)
		end
	end

	--
	-- Add the auto resolvers if we haven't provided any (or no-resolv)
	--
	if not vars.resolver and not vars["no-resolv"] and dns then
		local pri = vars["resolver-pri"] or 50
		for _,r in ipairs(dns) do
			add_resolver_from_source({ip=r, pri=pri}, interface)
		end
	end
	update_resolvers()

	--
	--  Add all of our routes, switch AUTO for the provided router if
	--  given, otherwise drop the route.
	--
	remove_routes_from_source(interface)
	for _,route in ipairs(vars.route or {}) do
		if route.gw == "AUTO" and router then route.gw = router end
		if route.gw ~= "AUTO" then add_route_from_source(route, interface) end
	end

	--
	-- Add a defaultroute unless we have provided routes, or no-defaultroute
	--
	if not vars.route and not vars["no-defaultroute"] and router then
		local pri = vars["defaultroute-pri"] or 50
		add_route_from_source({ dest="default", gw=router, dev=interface, pri=pri }, interface)
	end
	update_routes()
	block_off()
end

--
-- Add/remove a list of routes to the runtime table and then re-update so they
-- are applied if relevant
--
local function add_routes(routes, source)
	block_on()
	for _, route in ipairs(routes) do
		add_route_from_source(route, source)
	end
	update_routes()
	block_off()
end
local function del_routes(routes, source)
	block_on()
	for _, route in ipairs(routes) do
		remove_route_from_source(route, source)
	end
	update_routes()
	block_off()
end


local function interface_down(interface, vars)
	block_on()
	set_status(interface, "down")

	remove_resolvers_from_source(interface)
	update_resolvers()

	remove_routes_from_source(interface)
	update_routes()
	block_off()
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
	local svc = lib.db.query("services", "get_service", name)
	if not svc or #svc ~= 1 then return nil, "unknown service" end

	svc = svc[1]
	if svc.vars then return lib.utils.unserialise(svc.vars) end
	return nil
end

return {
	interface_up = interface_up,
	interface_down = interface_down,

	add_routes = add_routes,
	del_routes = del_routes,

	redirect = redirect,
	get_vars = get_vars,

	set_status = set_status,
	get_status = get_stats,

	execute = execute,

	block_on = block_on,
	block_off = block_off,
}


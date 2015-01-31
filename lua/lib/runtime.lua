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
	stdlib = require("posix.stdlib"),
	sys = { 
		stat = require("posix.sys.stat") 
	}
}
posix.fcntl.FD_CLOEXEC = 1

--
-- We need to access the database
--
local db = require("db")
local rr = require("runtime-route")

--
-- We will need lots of logging
--
require("bit")
require("execute")
require("log")


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
		l_whence = posix.fcntl.SEEK_SET,
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
	rr.remove_resolvers_from_source(interface)
	for _,resolver in ipairs(vars.resolver or {}) do
		if resolver.ip == "AUTO" and dns then
			for _,r in ipairs(dns) do
				resolver.ip = r
				rr.add_resolver_from_source(resolver, interface)
			end
		else
			rr.add_resolver_from_source(resolver, interface)
		end
	end

	--
	-- Add the auto resolvers if we haven't provided any (or no-resolv)
	--
	if not vars.resolver and not vars["no-resolv"] and dns then
		local pri = vars["resolver-pri"] or 50
		for _,r in ipairs(dns) do
			rr.add_resolver_from_source({ip=r, pri=pri}, interface)
		end
	end
	rr.update_resolvers()

	--
	--  Add all of our routes, switch AUTO for the provided router if
	--  given, otherwise drop the route.
	--
	rr.remove_routes_from_source(interface)
	for _,route in ipairs(vars.route or {}) do
		if route.gw == "AUTO" and router then route.gw = router end
		if route.gw ~= "AUTO" then rr.add_route_from_source(route, interface) end
	end

	--
	-- Add a defaultroute unless we have provided routes, or no-defaultroute
	--
	if not vars.route and not vars["no-defaultroute"] and router then
		local pri = vars["defaultroute-pri"] or 50
		rr.add_route_from_source({ dest="default", gw=router, dev=interface, pri=pri }, interface)
	end
	rr.update_routes()
	block_off()
end
local function interface_down(interface, vars)
	block_on()
	set_status(interface, "down")

	rr.remove_resolvers_from_source(interface)
	rr.update_resolvers()

	rr.remove_routes_from_source(interface)
	rr.update_routes()
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
	local svc = db.query("services", "get_service", name)
	if not svc or #svc ~= 1 then return nil, "unknown service" end

	svc = svc[1]
	if svc.vars then return unserialise(svc.vars) end
	return nil
end

return {
	interface_up = interface_up,
	interface_down = interface_down,

	redirect = redirect,
	get_vars = get_vars,

	set_status = set_status,
	get_status = get_stats,

	execute = execute,

	block_on = block_on,
	block_off = block_off,
}


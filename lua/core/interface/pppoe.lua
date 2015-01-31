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

--require("log")

--require("route")
--local runtime = require("runtime")
--local service = require("service")

local PPPD="/usr/sbin/pppd"


--------------------------------------------------------------------------------
--
-- pppoe -- we create or remove the pppoe config files as needed, we need to
--	      make sure that the "attach" interface is valid, up, and has no
--	      ip address. (We use a trigger to ensure this)
--
--------------------------------------------------------------------------------
local function pppoe_precommit(changes)
	--
	-- Do the interface level precommit
	--
	local rc, err = interface_precommit(changes)
	if not rc then return false, err end

	--
	-- Now handle our specific changes
	--
	for nodename in each(node_list("/interface/pppoe", CF_new)) do
		local cf = node_vars("/interface/pppoe/"..nodename, CF_new) or {}
		print("PPPOE Precommit -- node: " .. nodename)

		--
		-- TODO: check all the required fields are present for each
		--	   pppoe interface definition
		--

		--
		-- Check the interface we are attaching to meets our requirements
		--
		if not cf.disabled then
			if not cf.attach or not is_valid_interface(cf.attach) then
				return false, "require valid interface in attach field"
			end
			local ifpath = interface_path(cf.attach)
			local ethcf = node_vars(ifpath, CF_new)
			if not ethcf then 
				return false, string.format("attach interface unknown for pppoe/%s: %s", nodename, ifpath)
			end
			if ethcf.ip then
				return false, string.format("attach interface must have no IP address for pppoe/%s: %s", nodename, ifpath)
			end
			if ethcf["dhcp-enable"] then
				return false, string.format("attach interface must not have DHCP for pppoe/%s: %s", nodename, ifpath)
			end
			if ethcf.disabled and not cf.disabled then
				return false, string.format("attach interface must be enabled for pppoe/%s: %s", nodename, ifpath)
			end
		end
	end
	return true
end

--
-- Actually start the pppoe process, this means creating the config file and
-- then adding the service and starting it.
--
local function start_pppoe(ifname, cf)
	--
	-- Build a set of information to pass into the ppp script so that
	-- it can be a bit more clever
	--
	local vars = {
		["logfile"] 			= "/tmp/pppoe/pppoe."..ifname..".log",
		["no-defaultroute"] 	= cf["no-defaultroute"],
		["no-resolv"]			= cf["no-resolv"],
		["resolver-pri"] 		= 40,
		["defaultroute-pri"] 	= 40,
		["route"]				= cf["route"] and lib.route.var(cf["route"], ifname),
	}

	--
	-- Build the command line args. For ppp it's just simply a call with a logfile
	-- so that we can get the output of the daemon.
	--
	local args = { 	"nodetach",
					"logfile", "/tmp/pppoe/pppoe."..ifname..".log",
					"call", ifname, 
	}

	--
	-- Use the service framework to start the service so we can track it properly
	-- later
	--
	lib.service.define("pppoe."..ifname, {
		["binary"] = PPPD,
		["args"] = args,
		["vars"] = vars,
		["pidfile"] = "/tmp/pppoe/pppoe."..ifname..".pid",
		["create_pidfile"] = true,
		["maxkilltime"] = 2500,

		["start"] = "ASDAEMON",
		["stop"] = "BYPIDFILE",
	})

	lib.log.log("info", "starting pppoe")

	local rc, err = lib.service.start("pppoe."..ifname)
	print("rc="..tostring(rc).." err="..tostring(err))

	--if not rc then return false, "DHCP start failed: "..err end
	return true
end
local function stop_pppoe(ifname)
	lib.log.log("info", "stopping pppoe")

	local rc, err = lib.service.stop("pppoe."..ifname)
	print("rc="..tostring(rc).." err="..tostring(err))

	--
	-- Remove the definition
	--
	lib.service.remove("pppoe."..ifname)
end

--
-- If deleted then remove peer config
-- If added or modded then (re-)create the peer config
--
-- Work out if we need to restart anything.
--
local function pppoe_commit(changes)
	print("PPPOE")

	--
	-- Make sure we have the main directory in /tmp
	--
	lib.file.create_directory("/tmp/pppoe")

	--
	-- Now work out what we need to do
	--
	local state = process_changes(changes, "/interface/pppoe")

	--
	-- If we have added, modified or changed any of the interfaces we are
	-- going to stop the service (if its running), and then start it again
	-- if we need to
	--
	local todo = {}
	for num in each(state.added) do push(todo, num) end
	for num in each(state.removed) do push(todo, num) end
	for num in each(state.changed) do push(todo, num) end
	table.sort(todo)

	for nodename in each(todo) do
		print("WOULD PROCESS: pppoe/"..nodename)
		local cf = node_vars("/interface/pppoe/"..nodename, CF_new) or {}
		local oldcf = node_vars("/interface/pppoe/"..nodename, CF_current) or {}
		local ifname = interface_name("pppoe/"..nodename)

		lib.log.root("intf", ifname)
		lib.log.log("info", "processing interface")

		--
		-- If we were running pppoe then we need to kill it
		--
		-- TODO: disable??
		if oldcf.attach and not oldcf.disabled then
			print("WOULD STOP: "..ifname)
			stop_pppoe(ifname)
		end

		--
		-- Now start the new service if we need to...
		--
		if not cf.disabled then
			print("WOULD START: "..ifname)
	
			local cfdict = {
				["interface"] = ifname,
				["attach"] = interface_name(cf.attach),
				["username"] = cf.username or {},
				["password"] = cf.password or {},
			}
			local cfdata = [[
				#
				# <autogenerated ppp peer file -- do not edit>
				#
				plugin rp-pppoe.so
				{{attach}}
				ifname {{interface}}
				persist
				usepeerdns
				noresolv
				nopidfiles
				nodefaultroute
				debug
				user "{{username}}"
				password "{{password}}"
			]]
			create_config_file("/etc/ppp/peers/"..ifname, cfdata, cfdict)
			start_pppoe(ifname, cf)
		end	
	end

	for trig in each(state.triggers) do
		print("We were triggered by: "..trig)
	end

	return true
end


--
--
--
VALIDATOR["pppoe_if"] = interface_validate_number_and_alpha

--[[
VALIDATOR["pppoe_if"] = function(v, mp, kp)
	local err = "interface numbers should be [nnn] only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	return FAIL, err
end
]]--

--
-- pppoe interfaces...
--
master["/interface/pppoe"] = {
	["commit"] = pppoe_commit,
	["precommit"] = pppoe_precommit,
	["with_children"] = 1,
}

master["/interface/pppoe/*"] =						{ ["style"] = "pppoe_if" }
master["/interface/pppoe/*/attach"] =				{ ["type"] = "eth_interface",
											  		  ["options"] = "eth_interfaces" }
master["/interface/pppoe/*/no-defaultroute"] =		{ ["type"] = "boolean", ["default"] = false }
master["/interface/pppoe/*/no-resolv"] =			{ ["type"] = "boolean", ["default"] = false }
master["/interface/pppoe/*/mtu"] =					{ ["type"] = "mtu" }
master["/interface/pppoe/*/username"] =				{ ["type"] = "OK" }
master["/interface/pppoe/*/password"] =				{ ["type"] = "OK" }
master["/interface/pppoe/*/disabled"] = 			{ ["type"] = "boolean" }
master["/interface/pppoe/*/route"] =				{ ["type"] = "OK", ["list"] = 1 }

--
-- Deal with triggers and depdencies
--
function interface_pppoe_init()
	--
	-- Tell the interface module we are here
	--
	interface_register({ module = "pppoe", path = "/interface/pppoe", 
						if_numeric = "pppoe%", if_alpha = "%", 
						classes = { "all", "ppp" }})
	--
	-- Trigger the pppoe work if the underlying ethernet changes
	--
	add_trigger("/interface/ethernet/*", "/interface/pppoe/@ethernet_change")

	--
	-- Make sure we deal with ethernet before we consider pppoe
	--
	add_dependency("/interface/pppoe", "/interface/ethernet")
end


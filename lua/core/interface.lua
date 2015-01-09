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

local DHCPC="/sbin/udhcpc"
local DHCP_SCRIPT="/netcamel/scripts/dhcp.script"

local PPPD="/usr/sbin/pppd"

local function start_dhcp(intf, cf)
	--
	-- Build a set of information to pass into the dhcp script so that
	-- it can be a bit more clever
	--
	local vars = {
		["no-resolv"]			= cf["dhcp-no-resolv"],
		["no-defaultroute"]		= cf["dhcp-no-defaultroute"],
		["resolv-pri"]			= cf["dhcp-resolv-pri"],
		["defaultroute-pri"]	= cf["dhcp-defaultroute-pri"],
	}
	save_vars(intf, vars)

	--
	-- Build the command line args. Don't include --release as we may create
	-- a race condition when unconfiguring dhcp where our ip commands run before
	-- the dhcp script undoes them!
	--
	local args = { 
		"--interface", intf,
		"--pidfile", "/var/run/dhcp."..intf..".pid",
		"--script", DHCP_SCRIPT,
		"--release",
		"--background",
	}
	if cf["ip"] then push(args, "--request", cf["ip"]) end

	--
	-- Use the service framework to start the service so we can track it properly
	-- later
	--
	service.define("dhcp."..intf, {
		["binary"] = DHCPC,
		["args"] = args,
		["name"] = "dhcp."..intf,
		["pidfile"] = "/var/run/dhcp."..intf..".pid",
		["logfile"] = "/tmp/dhcp."..intf..".log",
		["maxkilltime"] = 1500,

		["start"] = "ASDAEMON",
		["stop"] = "BYPIDFILE",
	})

	print("ARGS: " .. table.concat(args, " "))

	local rc, err = service.start("dhcp."..intf)
	print("rc="..tostring(rc).." err="..tostring(err))

	--if not rc then return false, "DHCP start failed: "..err end
	return true
end
local function stop_dhcp(intf)
	--
	-- Setup enough so we can kill the process
	--
	print("Stopping dhcp")
	local rc, err = service.stop("dhcp."..intf)
	print("rc="..tostring(rc).." err="..tostring(err))

	--
	-- Remove the definition
	--
	service.remove("dhcp."..intf)
end


local function ethernet_commit(changes)
	print("Hello From Interface")

	local state = process_changes(changes, "interface/ethernet")

	--
	-- Remove any interface that has been removed from the system...
	--
	for ifnum in each(state.removed) do 
		print("Removed: "..ifnum) 
		local oldcf = node_vars("interface/ethernet/"..ifnum, CF_current) or {}
		local physical = interface_name("ethernet/"..ifnum)

		if oldcf["dhcp-enable"] then
			stop_dhcp(physical)
		end
		os.execute(string.format("ip addr flush dev %s", physical))
		os.execute(string.format("ip link set dev %s down", physical))
	end

	--
	-- Modify an interface ... we'll work through the actual changes
	--
	for ifnum in each(state.changed) do 
		print("Changed: "..ifnum) 
		local cf = node_vars("interface/ethernet/"..ifnum, CF_new) or {}
		local oldcf = node_vars("interface/ethernet/"..ifnum, CF_current) or {}
		local physical = interface_name("ethernet/"..ifnum)

		local changed = values_to_keys(node_list("interface/ethernet/"..ifnum, changes))

		--
		-- If we have changed any of our dhcp settings then we definitely need to
		-- stop dhcp (and maybe restart)
		--
		-- Also, if we change our IP address when dhcp is enabled (used to request
		-- specific IP address) then we also need to restart
		--
		local dhcp_ip_restart = changed.ip and oldcf["dhcp-enable"]

		if dhcp_ip_restart or next(prefixmatches(changed, "dhcp-")) then
			if oldcf["dhcp-enable"] then
				stop_dhcp(physical)
			end

			if cf["dhcp-enable"] then
				print("dhcp-enable type="..type(cf["dhcp-enable"]))
				start_dhcp(physical, cf)
			else
				if cf.ip then
					os.execute(string.format("ip addr add %s dev %s", cf.ip, physical))
				end
			end
		else
			--
			-- Handle standard IP address changes here
			--
			if changed.ip and not cf["dhcp-enable"] then
				if oldcf.ip then os.execute(string.format("ip addr del %s dev %s", oldcf.ip, physical)) end
				os.execute(string.format("ip addr add %s dev %s", cf.ip, physical))
			end
		end
	
		if changed.mtu then
			os.execute(string.format("ip link set dev %s mtu %s", physical, cf.mtu))
		end
		if changed.disabled then
			os.execute(string.format("ip link set dev %s %s", physical, 
							(cf.disabled and "down") or "up" ))
		end
		
		for p in each(changed) do
			print("CAHNANANAN: " .. p)
		end
		-- TODO
	end

	--
	-- Add an interface
	--
	for ifnum in each(state.added) do 
		print("Added: "..ifnum) 
		local cf = node_vars("interface/ethernet/"..ifnum, CF_new)
		local physical = interface_name("ethernet/"..ifnum)

		--
		-- Remove any addresses, and set the link up or down
		--
		os.execute(string.format("ip addr flush dev %s", physical))
		os.execute(string.format("ip link set dev %s %s", physical, (cf.disabled and "down") or "up" ))
		if(cf.mtu) then os.execute(string.format("ip link set dev %s mtu %s", physical, cf.mtu)) end

		--
		-- The IP address only goes on the interface if we don't have dhcp enabled
		--
		if(not cf["dhcp-enable"]) then
			if(cf.ip) then os.execute(string.format("ip addr add %s brd + dev %s", cf.ip, physical)) end
		else
			start_dhcp(physical, cf)
		end
	end	

	return true
end

--------------------------------------------------------------------------------
--
-- pppoe -- we create or remove the pppoe config files as needed, we need to
--	      make sure that the "attach" interface is valid, up, and has no
--	      ip address. (We use a trigger to ensure this)
--
--------------------------------------------------------------------------------
local function pppoe_precommit(changes)
	for ifnum in each(node_list("interface/pppoe", CF_new)) do
		local cf = node_vars("interface/pppoe/"..ifnum, CF_new) or {}
		print("PPPOE Precommit -- node: " .. ifnum)

		--
		-- TODO: check all the required fields are present for each
		--	   pppoe interface definition
		--

		--
		-- Check the interface we are attaching to meets our requirements
		--
		if not cf.disabled then
			if not cf.attach then
				return false, "required interface in attach field"
			end
			local ifpath = interface_path(cf.attach)
			if not ifpath then 
				return false, string.format("attach interface incorrect for pppoe/%s: %s", ifnum, cf.attach)
			end

			local ethcf = node_vars(ifpath, CF_new)
			if not ethcf then 
				return false, string.format("attach interface unknown for pppoe/%s: %s", ifnum, ifpath)
			end
			if ethcf.ip then
				return false, string.format("attach interface must have no IP address for pppoe/%s: %s", ifnum, ifpath)
			end
			if ethcf["dhcp-enable"] then
				return false, string.format("attach interface must not have DHCP for pppoe/%s: %s", ifnum, ifpath)
			end
			if ethcf.disabled and not cf.disabled then
				return false, string.format("attach interface must be enabled for pppoe/%s: %s", ifnum, ifpath)
			end
		end
	end
	return true
end

--
-- Actually start the pppoe process, this means creating the config file and
-- then adding the service and starting it.
--
local function start_pppoe(intf, cf)
	--
	-- Build a set of information to pass into the ppp script so that
	-- it can be a bit more clever
	--
	local vars = {
		["logfile"] 			= "/tmp/log."..intf,
		["no-defaultroute"] 	= cf["no-defaultroute"],
		["no-resolv"]			= cf["no-resolv"],
		["resolv-pri"] 			= cf["resolv-pri"],
		["defaultroute-pri"] 	= cf["defaultroute-pri"]
	}
	save_vars(intf, vars)

	--
	-- Build the command line args. For ppp it's just simply a call with a logfile
	-- so that we can get the output of the daemon.
	--
	local args = { 	"nodetach",
					"logfile", "/tmp/log."..intf,
					"call", intf, 
	}

	--
	-- Use the service framework to start the service so we can track it properly
	-- later
	--
	service.define(intf, {
		["binary"] = PPPD,
		["args"] = args,
		["pidfile"] = "/var/run/"..intf..".pidX",
		["create_pidfile"] = true,
		["maxkilltime"] = 2500,

		["start"] = "ASDAEMON",
		["stop"] = "BYPIDFILE",
	})

	print("ARGS: " .. table.concat(args, " "))

	local rc, err = service.start(intf)
	print("rc="..tostring(rc).." err="..tostring(err))

	--if not rc then return false, "DHCP start failed: "..err end
	return true
end
local function stop_pppoe(intf)
	print("Stopping pppoe")
	local rc, err = service.stop(intf)
	print("rc="..tostring(rc).." err="..tostring(err))

	--
	-- Remove the definition
	--
	service.remove("pppoe."..intf)
end

--
-- If deleted then remove peer config
-- If added or modded then (re-)create the peer config
--
-- Work out if we need to restart anything.
--
local function pppoe_commit(changes)
	print("PPPOE")
	local state = process_changes(changes, "interface/pppoe")

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

	for ifnum in each(todo) do
		print("WOULD PROCESS: pppoe"..ifnum)
		local cf = node_vars("interface/pppoe/"..ifnum, CF_new) or {}
		local oldcf = node_vars("interface/pppoe/"..ifnum, CF_current) or {}
		local physical = interface_name("pppoe/"..ifnum)

		--
		-- If we were running pppoe then we need to kill it
		--
		-- TODO: disable??
		if not oldcf.disabled then
			print("WOULD STOP: "..physical)
			stop_pppoe(physical)
		end

		--
		-- Now start the new service if we need to...
		--
		if not cf.disabled then
			print("WOULD START: "..physical)
	
			print("REOSLVC_PRI="..cf["resolv-pri"])

			local cfdict = {
				["interface"] = physical,
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
				nodefaultroute
				debug
				user "{{username}}"
				password "{{password}}"
			]]
			create_config_file("/etc/ppp/peers/"..physical, cfdata, cfdict)
			start_pppoe(physical, cf)
		end	
	end

	for trig in each(state.triggers) do
		print("We were triggered by: "..trig)
	end

	return true
end


--
-- For ethernet interfaces we expect a simple number, but it needs
-- to map to a real interface (or be a virtual)
--
VALIDATOR["ethernet_unit"] = function(v, kp)
	--
	-- TODO: once we know the numbers are ok, we need to test for a real
	--	   interface.
	--
	local err = "interface numbers should be [nnn] or [nnn:nnn] only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	if v:match("^%d+:$") then return PARTIAL end
	if v:match("^%d+:%d+$") then return OK end
	return FAIL, err
end

VALIDATOR["pppoe_if"] = function(v, kp)
	local err = "interface numbers should be [nnn] only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	return FAIL, err
end

--
-- The MTU needs to be a sensible number
--
VALIDATOR["mtu"] = function(v, kp)
	--
	-- TODO: check the proper range of MTU numbers, may need to support
	--	   jumbo frames
	--
	if not v:match("^%d+$") then return FAIL, "mtu must be numeric only" end
	local mtu = tonumber(v)

	if mtu < 100 then return PARTIAL, "mtu must be above 100" end
	if mtu > 1500 then return FAIL, "mtu must be 1500 or less" end
	return OK
end


function interface_validator(v, types)
	for _,item in ipairs(types) do
		if (item.."/"):sub(1, v:len()) == v then return PARTIAL end
	end
	for _,item in ipairs(types) do
		if v:match("^"..item.."/".."%d+$") then return OK end
	end
	return FAIL, "interfaces need to be ["..table.concat(types, "|").."]/nn"
end


--
-- Where we expect an interface name...
--
VALIDATOR["any_interface"] = function(v, kp)
	return interface_validator(v, {"ethernet", "pppoe"})
end
VALIDATOR["eth_interface"] = function(v, kp)
	return interface_validator(v, {"ethernet"})
end

--
-- Convert any format into a full keypath, this is used by any function that
-- takes any interface as an argument. It allows complete flexibility in what
-- can be used.
--
function interface_path(interface)
	local t, i = interface:match("^([^/]+)/%*?(%d+)$")
	if t then return string.format("interface/%s/*%s", t, i) end
	return nil
end

--
-- Given a name in any format, work out what the physical interface
-- should be...
--
function interface_name(path)
	local i = path:match("ethernet/%*?(%d+)$") or path:match("eth(%d+)$")
	if i then return string.format("eth%s", i) end
	local i = path:match("pppoe/%*?(%d+)$") or path:match("pppoe(%d+)$")
	if i then return string.format("pppoe%s", i) end
end
function interface_names(list)
	local rc = {}
	for interface in each(list) do table.insert(rc, interface_name(interface)) end
	return rc
end

--
-- Used to provide a list of configured ethernet interfaces for cmdline
-- completion.
--
function options_from_interfaces(types)
	local rc = {}
	for _,t in ipairs(types) do
		for node in each(node_list("interface/"..t, CF_new)) do
			push(rc, t .."/"..node:gsub("^%*", ""))
		end
	end
	return rc
end
		
function options_eth_interfaces(kp, mp)
	return options_from_interfaces({"ethernet"})
end
function options_all_interfaces(kp, mp)
	return options_from_interfaces({"ethernet", "pppoe"})
end

--
-- Ethernet interfaces...
--
master["interface"] = {}
master["interface/ethernet"] = { 
	["commit"] = ethernet_commit,
	["depends"] = { "iptables" }, 
	["with_children"] = 1
}

master["interface/ethernet/*"] = 			{ ["style"] = "ethernet_unit",
											  ["options"] = { "0", "1", "2" } }
master["interface/ethernet/*/ip"] = 		{ ["type"] = "ipv4_nm" }
master["interface/ethernet/*/ipx"] = 		{ ["type"] = "ipv4" }
master["interface/ethernet/*/mtu"] = 		{ ["type"] = "mtu" }
master["interface/ethernet/*/disabled"] = 	{ ["type"] = "boolean" }

--
-- Support DHCP on the interface (off by default)
--
master["interface/ethernet/*/dhcp-enable"] = 			{ ["type"] = "boolean", ["default"] = false }
master["interface/ethernet/*/dhcp-no-resolv"] = 		{ ["type"] = "boolean", ["default"] = false }
master["interface/ethernet/*/dhcp-no-defaultroute"] = 	{ ["type"] = "boolean", ["default"] = false }
master["interface/ethernet/*/dhcp-resolv-pri"] = 		{ ["type"] = "2-digit", ["default"] = "60" }
master["interface/ethernet/*/dhcp-defaultroute-pri"] = 	{ ["type"] = "2-digit", ["default"] = "60" }

--
-- pppoe interfaces...
--
master["interface/pppoe"] = {
	["commit"] = pppoe_commit,
	["precommit"] = pppoe_precommit,
	["with_children"] = 1,
}

master["interface/pppoe/*"] =					{ ["style"] = "pppoe_if" }
master["interface/pppoe/*/attach"] =			{ ["type"] = "eth_interface",
											  	  ["options"] = options_eth_interfaces }
master["interface/pppoe/*/no-defaultroute"] =	{ ["type"] = "boolean", ["default"] = false }
master["interface/pppoe/*/no-resolv"] =			{ ["type"] = "boolean", ["default"] = false }
master["interface/pppoe/*/mtu"] =				{ ["type"] = "mtu" }
master["interface/pppoe/*/resolv-pri"] = 		{ ["type"] = "2-digit", ["default"] = "40" }
master["interface/pppoe/*/defaultroute-pri"] = 	{ ["type"] = "2-digit", ["default"] = "40" }
master["interface/pppoe/*/username"] =			{ ["type"] = "OK" }
master["interface/pppoe/*/password"] =			{ ["type"] = "OK" }
master["interface/pppoe/*/disabled"] = 			{ ["type"] = "boolean" }

--
-- We will use a number of tables to manage dynamic information like
-- resolvers and defaultroutes
--
TABLE["resolvers"] = {
	schema = { source="string key", priority="integer", value="string" },
	priority_resolvers = "select * from resolvers where priority = (select min(priority) from resolvers)",
	remove_source = "delete from resolvers where source = :source"
}
TABLE["defaultroutes"] = {
	schema = { source="string key", priority="integer", value="string" },
	priority_defaultroutes = "select * from defaultroutes where priority = (select min(priority) from defaultroutes)",
	remove_source = "delete from defaultroutes where source = :source"
}

--
-- Deal with triggers and depdencies
--
function interface_init()
	--
	-- Trigger the pppoe work if the underlying ethernet changes
	--
	add_trigger("interface/ethernet/*", "interface/pppoe/@ethernet_change")

	--
	-- Make sure we deal with ethernet before we consider pppoe
	--
	add_dependency("interface/pppoe", "interface/ethernet")
end


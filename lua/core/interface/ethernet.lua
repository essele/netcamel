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

require("log")
local runtime = require("runtime")
local service = require("service")

local DHCPC="/sbin/udhcpc"
local DHCP_SCRIPT="/netcamel/scripts/dhcp.script"

local function start_dhcp(intf, cf)
	--
	-- Build a set of information to pass into the dhcp script so that
	-- it can be a bit more clever
	--
	local vars = {
		["logfile"]				= "/tmp/dhcp."..intf..".log",
		["no-resolv"]			= cf["dhcp-no-resolv"],
		["no-defaultroute"]		= cf["dhcp-no-defaultroute"],
		["resolv-pri"]			= cf["dhcp-resolv-pri"],
		["defaultroute-pri"]	= cf["dhcp-defaultroute-pri"],
	}

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
		"--background"
	}
	if cf["ip"] then push(args, "--request", cf["ip"]) end

	--
	-- Use the service framework to start the service so we can track it properly
	-- later
	--
	service.define("dhcp."..intf, {
		["binary"] = DHCPC,
		["args"] = args,
		["vars"] = vars,
		["name"] = "dhcp."..intf,
		["pidfile"] = "/var/run/dhcp."..intf..".pid",
		["logfile"] = "/tmp/dhcp."..intf..".log",
		["maxkilltime"] = 1500,

		["start"] = "ASDAEMON",
		["stop"] = "BYPIDFILE",
	})

	log("info", "starting dhcp")

	local rc, err = service.start("dhcp."..intf)
	print("service.start dhcp rc="..tostring(rc).." err="..tostring(err))

	--if not rc then return false, "DHCP start failed: "..err end
	return true
end
local function stop_dhcp(intf)
	--
	-- Setup enough so we can kill the process
	--
	log("info", "stopping dhcp")
	local rc, err = service.stop("dhcp."..intf)
	print("rc="..tostring(rc).." err="..tostring(err))

	--
	-- Remove the definition
	--
	service.remove("dhcp."..intf)
end


local function ethernet_commit(changes)
	logroot("intf")
	local state = process_changes(changes, "/interface/ethernet")

	--
	-- Remove any interface that has been removed from the system...
	--
	for ifnum in each(state.removed) do 
		local oldcf = node_vars("/interface/ethernet/"..ifnum, CF_current) or {}
		local physical = interface_name("ethernet/"..ifnum)

		logroot("intf", physical)
		log("info", "removing interface")
		if oldcf["dhcp-enable"] then
			stop_dhcp(physical)
		else
			runtime.execute("/sbin/ip", {"addr", "flush", "dev", physical })
			runtime.execute("/sbin/ip", {"link", "set", "dev", physical, "down"})
			runtime.interface_down(physical, {table = cf["defaultroute-table"]})
		end
	end

	--
	-- Modify an interface ... we'll work through the actual changes
	--
	for ifnum in each(state.changed) do 
		local cf = node_vars("/interface/ethernet/"..ifnum, CF_new) or {}
		local oldcf = node_vars("/interface/ethernet/"..ifnum, CF_current) or {}
		local physical = interface_name("ethernet/"..ifnum)

		local changed = values_to_keys(node_list("/interface/ethernet/"..ifnum, changes))
		logroot("intf", physical)
		log("info", "changing interface")

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
					runtime.execute("/sbin/ip", { "addr", "add", cf.ip, "dev", physical })
				end
			end
		else
			--
			-- Handle standard IP address changes here
			--
			if changed.ip and not cf["dhcp-enable"] then
				if oldcf.ip then runtime.execute("/sbin/ip", { "addr", "del", oldcf.ip, "dev", physical }) end
				runtime.execute("/sbin/ip", { "addr", "add", cf.ip, "dev", physical })
			end
		end
	
		if changed.mtu then
			runtime.execute("/sbin/ip", { "link", "set", "dev", physical, "mtu", cf.mtu })
		end
		if changed.disabled then
			runtime.execute("/sbin/ip", { "link", "set", "dev", physical, 
													(cf.disabled and "down") or "up" })
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
		local cf = node_vars("/interface/ethernet/"..ifnum, CF_new)
		local physical = interface_name("ethernet/"..ifnum)

		logroot("intf", physical)
		log("info", "creating interface")

		--
		-- Remove any addresses, and set the link up or down
		--
		runtime.execute("/sbin/ip", { "addr", "flush", "dev", physical})
		runtime.execute("/sbin/ip", { "link", "set", "dev", physical, (cf.disabled and "down") or "up" })
		if(cf.mtu) then runtime.execute("/sbin/ip", { "link", "set", "dev", physical, "mtu", cf.mtu}) end

		--
		-- The IP address only goes on the interface if we don't have dhcp enabled
		--
		if(not cf["dhcp-enable"]) then
			if cf.ip then
				runtime.execute("/sbin/ip", {"addr", "add", cf.ip, "brd", "+", "dev", physical})
				runtime.interface_up(physical, cf.resolver or {}, {cf.defaultroute}, cf)
			end
		else
			start_dhcp(physical, cf)
		end
	end	

	return true
end

--
-- For ethernet interfaces we expect a simple number, but it needs
-- to map to a real interface (or be a virtual)
--
VALIDATOR["ethernet_if"] = interface_validate_number

--
-- Where we expect an ethernet interface name...
--
VALIDATOR["eth_interface"] = function(v, mp, kp)
	return interface_validator(v, {"ethernet"})
end
OPTIONS["eth_interfaces"] = function(kp, mp)
	return options_from_interfaces({"ethernet"})
end

--
-- Ethernet interfaces...
--
master["/interface/ethernet"] = { 
	["commit"] = ethernet_commit,
	["depends"] = { "iptables" }, 
	["with_children"] = 1
}

master["/interface/ethernet/*"] = 						{ ["style"] = "ethernet_if",
											  			  ["options"] = { "0", "1", "2" } }
master["/interface/ethernet/*/ip"] = 					{ ["type"] = "ipv4_nm" }
master["/interface/ethernet/*/resolver"] =				{ ["type"] = "ipv4", ["list"] = true }
master["/interface/ethernet/*/defaultroute"] =			{ ["type"] = "ipv4" }
master["/interface/ethernet/*/resolv-pri"] =			{ ["type"] = "2-digit", ["default"] = "80" }
master["/interface/ethernet/*/defaultroute-pri"] =		{ ["type"] = "2-digit", ["default"] = "80" }
master["/interface/ethernet/*/defaultroute-table"] =	{ ["type"] = "OK", ["default"] = "main" }
master["/interface/ethernet/*/mtu"] = 					{ ["type"] = "mtu" }
master["/interface/ethernet/*/disabled"] = 				{ ["type"] = "boolean" }

--
-- Support DHCP on the interface (off by default)
--
master["/interface/ethernet/*/dhcp-enable"] = 				{ ["type"] = "boolean", ["default"] = false }
master["/interface/ethernet/*/dhcp-no-resolv"] = 			{ ["type"] = "boolean", ["default"] = false }
master["/interface/ethernet/*/dhcp-no-defaultroute"] = 		{ ["type"] = "boolean", ["default"] = false }
master["/interface/ethernet/*/dhcp-resolv-pri"] = 			{ ["type"] = "2-digit", ["default"] = "60" }
master["/interface/ethernet/*/dhcp-defaultroute-pri"] = 	{ ["type"] = "2-digit", ["default"] = "60" }
master["/interface/ethernet/*/dhcp-defaultroute-table"] = 	{ ["type"] = "OK", ["default"] = "main" }


function interface_ethernet_init()
	--
	-- Tell the interface module we are here, we don't support alpha names, so only
	-- numeric (matching the validator)
	--
	interface_register("ethernet", "/interface/ethernet", "eth%", nil, { "all", "ethernet" } )
end

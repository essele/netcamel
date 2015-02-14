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
--local runtime = require("runtime")
--local service = require("service")

local DHCPC="/sbin/udhcpc"
local DHCP_SCRIPT="/netcamel/scripts/dhcp.script"

local function start_dhcp(intf, cf)
	--
	-- Build a set of information to pass into the dhcp script so that
	-- it can be a bit more clever
	--
	local vars = {
		["logfile"]				= "/tmp/dhcp."..intf..".log",
		["no-resolv"]			= cf["no-resolv"],
		["no-defaultroute"]		= cf["no-defaultroute"],
		["resolver-pri"]		= 60,
		["defaultroute-pri"]	= 60,
		["route"]				= cf["route"] and lib.route.var(cf["route"], intf)
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
	lib.service.define("dhcp."..intf, {
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

	lib.log.log("info", "starting dhcp")

	local rc, err = lib.service.start("dhcp."..intf)
	print("service.start dhcp rc="..tostring(rc).." err="..tostring(err))

	--if not rc then return false, "DHCP start failed: "..err end
	return true
end
local function stop_dhcp(intf)
	--
	-- Setup enough so we can kill the process
	--
	lib.log.log("info", "stopping dhcp")
	local rc, err = lib.service.stop("dhcp."..intf)
	print("rc="..tostring(rc).." err="..tostring(err))

	--
	-- Remove the definition
	--
	lib.service.remove("dhcp."..intf)
end

local function ethernet_commit(changes)
	lib.log.root("intf")
	local state = process_changes(changes, "/interface/ethernet")

	--
	-- Remove any interface that has been removed from the system...
	--
	for ifnum in each(state.removed) do 
		local oldcf = node_vars("/interface/ethernet/"..ifnum, CF_current) or {}
		local physical = interface_name("ethernet/"..ifnum)

		lib.log.root("intf", physical)
		lib.log.log("info", "removing interface")
		if oldcf["dhcp-enable"] then
			stop_dhcp(physical)
		else
			lib.runtime.execute("/sbin/ip", {"addr", "flush", "dev", physical })
			lib.runtime.execute("/sbin/ip", {"link", "set", "dev", physical, "down"})
			lib.runtime.interface_down(physical)
		end
	end

	--
	-- Modify an interface ... if we aren't dhcp then we want to be careful not to take
	-- the interface down for small changes.
	--
	for ifnum in each(state.changed) do 
		local cf = node_vars("/interface/ethernet/"..ifnum, CF_new) or {}
		local oldcf = node_vars("/interface/ethernet/"..ifnum, CF_current) or {}
		local physical = interface_name("ethernet/"..ifnum)

		local changed = values_to_keys(node_list("/interface/ethernet/"..ifnum, changes))
		lib.log.root("intf", physical)
		lib.log.log("info", "changing interface")

		--
		-- Something has changed, if we were dhcp then stop it (it may restart later)
		--
		local dhcp_was_running = not oldcf.disabled and oldcf["dhcp-enable"]

		if dhcp_was_running then stop_dhcp(physical) end

		--
		-- If we have changed disabled state then reflect that, and take the interface
		-- down if it was up before
		--
		if changed.disabled then
			lib.runtime.execute("/sbin/ip", { "link", "set", "dev", physical, 
													(cf.disabled and "down") or "up" })
			if cf.disabled then lib.runtime.interface_down(physical) end
		end
	
		--
		-- MTU change is a simple update
		--
		if changed.mtu then
			lib.runtime.execute("/sbin/ip", { "link", "set", "dev", physical, "mtu", cf.mtu })
		end

		--
		-- IP address or routing/resolver changes require a re-up of the interface
		-- if it's not disabled
		--
		if not cf["dhcp-enable"] then
			if changed.ip then
				lib.runtime.execute("/sbin/ip", { "addr", "flush", "dev", physical})
				if cf.ip then
					lib.runtime.execute("/sbin/ip", {"addr", "add", cf.ip, "brd", "+", "dev", physical})
				end
			end
			if not cf.disabled then
				local vars = {
					["no-defaultroute"]	 = cf["no-defaultroute"],
					["no-resolv"]		   = cf["no-resolv"],
					["resolver-pri"]		= 80,
					["defaultroute-pri"]	= 80,
					["route"]			   = cf.route and lib.route.var(cf.route, physical),
				}
				lib.runtime.interface_up(physical, cf.resolver or {}, nil, vars)
			end
		end

		--
		-- If we are dhcp-enabled then just start it
		--
		if cf["dhcp-enable"] and not cf.disabled then start_dhcp(physical) end
	end

	--
	-- Add an interface
	--
	for ifnum in each(state.added) do 
		local cf = node_vars("/interface/ethernet/"..ifnum, CF_new)
		local physical = interface_name("ethernet/"..ifnum)

		lib.log.root("intf", physical)
		lib.log.log("info", "creating interface")

		--
		-- Remove any addresses, and set the link up or down
		--
		lib.runtime.execute("/sbin/ip", { "addr", "flush", "dev", physical})
		lib.runtime.execute("/sbin/ip", { "link", "set", "dev", physical, (cf.disabled and "down") or "up" })
		if(cf.mtu) then lib.runtime.execute("/sbin/ip", { "link", "set", "dev", physical, "mtu", cf.mtu}) end

		--
		-- The IP address only goes on the interface if we don't have dhcp enabled
		--
		if not cf.disabled then
			if cf["dhcp-enable"] then
				start_dhcp(physical, cf)
			else
				if cf.ip then
					lib.runtime.execute("/sbin/ip", {"addr", "add", cf.ip, "brd", "+", "dev", physical})
				end

				local vars = {
					["no-defaultroute"]	 = cf["no-defaultroute"],
					["no-resolv"]		   = cf["no-resolv"],
					["resolver-pri"]		= 80,
					["defaultroute-pri"]	= 80,
					["route"]			   = cf.route and lib.route.var(cf.route, physical),
				}
				lib.runtime.interface_up(physical, cf.resolver or {}, nil, vars)
			end
		end
	end	

	return true
end

--
-- For ethernet interfaces we expect a simple number, but it needs
-- to map to a real interface (or be a virtual)
--

VALIDATOR["ethernet_if"] = function(v, mp, kp)
	return interface_validate_number(v, mp, kp)
end

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
	["precommit"] = interface_precommit,
	["depends"] = { "iptables" }, 
	["with_children"] = 1
}

master["/interface/ethernet/*"] = 						{ ["style"] = "ethernet_if",
											  			  ["options"] = { "0", "1", "2" } }
master["/interface/ethernet/*/ip"] = 					{ ["type"] = "ipv4_nm" }
master["/interface/ethernet/*/resolver"] =				{ ["type"] = "ipv4", ["list"] = true }
master["/interface/ethernet/*/resolver-pri"] =			{ ["type"] = "2-digit", ["default"] = "80" }
master["/interface/ethernet/*/mtu"] = 					{ ["type"] = "mtu" }
master["/interface/ethernet/*/disabled"] = 				{ ["type"] = "boolean" }
master["/interface/ethernet/*/route"] = 				{ ["type"] = "route", ["list"] = 1 }

--
-- Support DHCP on the interface (off by default)
--
master["/interface/ethernet/*/dhcp-enable"] = 				{ ["type"] = "boolean", ["default"] = false }
master["/interface/ethernet/*/no-defaultroute"] = 		{ ["type"] = "boolean", ["default"] = false }
master["/interface/ethernet/*/no-resolv"] = 			{ ["type"] = "boolean", ["default"] = false }


function interface_ethernet_init()
	--
	-- Tell the interface module we are here, we don't support alpha names, so only
	-- numeric (matching the validator)
	--
	interface_register({ module = "ethernet", path = "/interface/ethernet",
						if_numeric = "eth%", if_alpha = nil,
						classes = { "all", "ethernet" } })
end

return {
	init = interface_ethernet_init
}


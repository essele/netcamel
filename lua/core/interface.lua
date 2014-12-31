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

local function ethernet_commit(changes)
	print("Hello From Interface")

	local state = process_changes(changes, "interface/ethernet")

	--
	-- Remove any interface that has been removed from the system...
	--
	for ifnum in each(state.removed) do 
		print("Removed: "..ifnum) 
		local physical = interface_name("ethernet/"..ifnum)

		print(string.format("# ip addr flush dev %s", physical))
		print(string.format("# ip link set dev %s down", physical))
	end

	--
	-- Modify an interface ... we'll work through the actual changes
	--
	for ifnum in each(state.changed) do 
		print("Changed: "..ifnum) 
		local cf = node_vars("interface/ethernet/"..ifnum, CF_new)
		local oldcf = node_vars("interface/ethernet/"..ifnum, CF_current)
		local physical = interface_name("ethernet/"..ifnum)

		local changed = values_to_keys(node_list("interface/ethernet/"..ifnum, changes))
		if changed.ip then
			print(string.format("# ip addr del %s dev %s", oldcf.ip, physical))
			print(string.format("# ip addr add %s dev %s", cf.ip, physical))
		end
		if changed.mtu then
			print(string.format("# ip link set dev %s mtu %s", physical, cf.mtu))
		end
		if changed.disabled then
			print(string.format("# ip link set dev %s %s", physical, 
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

		print(string.format("# ip addr flush dev %s", physical))
		if(cf.ip) then print(string.format("# ip addr add %s brd + dev %s", cf.ip, physical)) end
		if(cf.mtu) then print(string.format("# ip link set dev %s mtu %s", physical, cf.mtu)) end
		print(string.format("# ip link set dev %s %s", physical, (cf.disabled and "down") or "up" ))
	end	


	return true
end

--------------------------------------------------------------------------------
--
-- pppoe -- we create or remove the pppoe config files as needed, we need to
--          make sure that the "attach" interface is valid, up, and has no
--          ip address. (We use a trigger to ensure this)
--
--------------------------------------------------------------------------------
local function pppoe_precommit(changes)
	for ifnum in each(node_list("interface/pppoe", CF_new)) do
		local cf = node_vars("interface/pppoe/"..ifnum, CF_new)
		print("PPPOE Precommit -- node: " .. ifnum)

		--
		-- TODO: check all the required fields are present for each
		--       pppoe interface definition
		--

		--
		-- Check the interface we are attaching to meets our requirements
		--
		if cf.attach then
			local ifpath = interface_path(cf.attach)
			if not ifpath then 
				return false, string.format("attach interface incorrect for pppoe/%s: %s", ifnum, cf.attach)
			end
			local ethcf = node_vars(ifpath, CF_new)
			if not next(ethcf) then 
				return false, string.format("attach interface unknown for pppoe/%s: %s", ifnum, ifpath)
			end
			if ethcf.ip then
				return false, string.format("attach interface must have no IP address for pppoe/%s: %s", ifnum, ifpath)
			end
			if ethcf.disabled and not cf.disabled then
				return false, string.format("attach interface must be enabled for pppoe/%s: %s", ifnum, ifpath)
			end
		else
			return false, "required interface in attach field"
		end
	end
	return true
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

	for trig in each(state.triggers) do
		print("We were triggered by: "..trig)
	end

	return true
end


--
-- For ethernet interfaces we expect a simple number, but it needs
-- to map to a real interface (or be a virtual)
--
VALIDATOR["ethernet_if"] = function(v)
	--
	-- TODO: once we know the numbers are ok, we need to test for a real
	--       interface.
	--
	local err = "interface numbers should be [nnn] or [nnn:nnn] only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	if v:match("^%d+:$") then return PARTIAL end
	if v:match("^%d+:%d+$") then return OK end
	return FAIL, err
end

VALIDATOR["pppoe_if"] = function(v)
	local err = "interface numbers should be [nnn] only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	return FAIL, err
end

--
-- The MTU needs to be a sensible number
--
VALIDATOR["mtu"] = function(v)
	--
	-- TODO: check the proper range of MTU numbers, may need to support
	--       jumbo frames
	--
	if not v:match("^%d+$") then return FAIL, "mtu must be numeric only" end
	local mtu = tonumber(v)

	if mtu < 100 then return PARTIAL, "mtu must be above 100" end
	if mtu > 1500 then return FAIL, "mtu must be 1500 or less" end
	return OK
end

--
-- Where we expect an interface name...
--
VALIDATOR["interface"] = function(v)
	-- TODO
	return OK
end

VALIDATOR["ipv4"] = function(v)
	return OK
end

--
-- Convert any format into a full keypath, this is used by any function that
-- takes any interface as an argument. It allows complete flexibility in what
-- can be used.
--
function interface_path(interface)
	local t, i = interface:match("^interface/([^/]+)/%*?(%d+)$")
	if t then return string.format("interface/%s/*%s", t, i) end

	local t, i = interface:match("^([^/]+)/%*?(%d+)$")
	if t then return string.format("interface/%s/*%s", t, i) end

	local i = interface:match("^eth(%d+)$")
	if i then return string.format("interface/ethernet/*%s", i) end

	local i = interface:match("^pppoe(%d+)$")
	if i then return string.format("interface/pppoe/*%s", i) end

	return nil
end

--
-- Given a name in any format, work out what the physical interface
-- should be...
--
function interface_name(path)
	local i = path:match("ethernet/%*?(%d+)$") or path:match("eth(%d)+$")
	if i then return string.format("eth%s", i) end
	local i = path:match("pppoe/%*?(%d+)$") or path:match("pppoe(%d)$")
	if i then return string.format("pppoe%s", i) end
end
function interface_names(list)
	local rc = {}
	for interface in each(list) do table.insert(rc, interface_name(interface)) end
	return rc
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

master["interface/ethernet/*"] = 			{ ["style"] = "ethernet_if" }
master["interface/ethernet/*/ip"] = 		{ ["type"] = "ipv4" }
master["interface/ethernet/*/mtu"] = 		{ ["type"] = "mtu" }
master["interface/ethernet/*/disabled"] = 	{ ["type"] = "boolean" }

--
-- pppoe interfaces...
--
master["interface/pppoe"] = {
	["commit"] = pppoe_commit,
	["precommit"] = pppoe_precommit,
	["with_children"] = 1,
}

master["interface/pppoe/*"] =				{ ["style"] = "pppoe_if" }
master["interface/pppoe/*/attach"] =		{ ["type"] = "ethernet_if" }
master["interface/pppoe/*/default-route"] =	{ ["type"] = "OK" }
master["interface/pppoe/*/mtu"] =			{ ["type"] = "mtu" }
master["interface/pppoe/*/user-id"] =		{ ["type"] = "OK" }
master["interface/pppoe/*/password"] =		{ ["type"] = "OK" }
master["interface/pppoe/*/disabled"] = 		{ ["type"] = "boolean" }

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


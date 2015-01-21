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
require("utils")

--
-- A master list of interface types, used for validation and name mapping
--
-- This is a hash, keyed on physical name (if) with the node name as the
-- value
--
local INTERFACES = {}
local INTERFACE_NODE_LIST = {}

function interface_register(intf, node)
	INTERFACES[intf] = node
	table.insert(INTERFACE_NODE_LIST, node)
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

--
-- Validate an interface name given a set of acceptable types, this is a global
-- so that it can be used by other interface modules.
--
-- TODO: could make this part of the register (see VALIDATOR["xxx_interface"])
--
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
-- Used to provide a list of configured ethernet interfaces for cmdline
-- completion.
--
local function options_from_interfaces(types)
	local rc = {}
	for _,t in ipairs(types) do
		for node in each(node_list("/interface/"..t, CF_new)) do
			push(rc, t .."/"..node:gsub("^%*", ""))
		end
	end
	return rc
end
		


--
-- Where we expect an interface name...
--
VALIDATOR["any_interface"] = function(v, kp)
	return interface_validator(v, INTERFACE_NODE_LIST)
end
OPTIONS["all_interfaces"] = function(kp, mp)
	return options_from_interfaces(INTERFACE_NODE_LIST)
end

--
-- Convert any format into a full keypath, this is used by any function that
-- takes any interface as an argument. It allows complete flexibility in what
-- can be used.
--
function interface_path(interface)
	local t, i = interface:match("^([^/]+)/%*?(%d+)$")
	if t then return string.format("/interface/%s/*%s", t, i) end
	return nil
end

--
-- Given a name in node or physical format, work out what the physical interface
-- should be...
--
function interface_name(path)
	for intf, node in pairs(INTERFACES) do
		local i = path:match(node.."/%*?(%d+)$") or path:match(intf.."(%d+)$")
		if i then return string.format(intf.."%s", i) end
	end
	return nil
end
function interface_names(list)
	local rc = {}
	for interface in each(list) do table.insert(rc, interface_name(interface)) end
	return rc
end

--
-- Master interface node...
--
master["/interface"] = {}

--
-- We will use a table to manage the resolvers that come in from various sources
--
TABLE["resolvers"] = {
	schema = { source="string key", priority="integer", value="string" },
	priority_resolvers = "select * from resolvers where priority = (select min(priority) from resolvers)",
	remove_source = "delete from resolvers where source = :source"
}

--
-- We'll also use a table to track status information so we know whether to apply
-- routes etc.
--
TABLE["status"] = {
	schema = { node="string primary key", status="string" },
	set_status = "insert or replace into status (node, status) values (:node, :status)",
	get_status = "select status from status where node = :node",
}


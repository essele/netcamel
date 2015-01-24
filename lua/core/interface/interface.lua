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
local INTERFACE_TYPE_LIST = {}

--
-- Register a module that is capable of creating interfaces, we need to
-- know the path to the interface (the next element would be the name)
-- and how that maps to the physical name  (% is replaced by the wildcard
-- name)
--
function interface_register(path, fullpath, phys_num, phys_alpha, types)
	INTERFACE_TYPE_LIST[path] = {
		fullpath = fullpath,
		phys_num = phys_num,
		phys_alpha = phys_alpha,
		types = values_to_keys(types or {}),
	}
end


--
-- The MTU needs to be a sensible number
--
VALIDATOR["mtu"] = function(v, mp, kp)
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
-- For clarity, this is used when we want an interface name as a value.
--
function interface_validator(v, mp, kp, class)
	for path,entry in pairs(INTERFACE_TYPE_LIST) do
		--
		-- See if this entry matches our class
		--
		if entry.types[class] then
			--
			-- Now check if we have a full path match
			--
			if v:sub(1,path:len()+1) == path.."/" then
				local wc = v:sub(path:len()+2)
				local mp = entry.fullpath .. "/*"
				local iftype = master[mp]["style"]
				return VALIDATOR[iftype](wc, mp, kp)
			end
		
			-- Are we a partial
			if (path.."/"):sub(1, v:len()) == v then return PARTIAL end
		end
	end
	return FAIL, "interface not valid (need class "..class..")"
end

--
-- Used to provide a list of configured ethernet interfaces for cmdline
-- completion.
--
local function options_from_interfaces(class)
	local rc = {}
	for path,entry in pairs(INTERFACE_TYPE_LIST) do
		if entry.types[class] then
			for node in each(node_list(entry.fullpath, CF_new)) do
				push(rc, path.."/"..node:gsub("^%*", ""))
			end
		end
	end
	return rc
end

--
-- Predefined validators for a numeric interface and an alpha
-- interface
--
function interface_validate_number(v, mp, kp)
	local err = "this interface name should be a number only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	return FAIL, err
end
function interface_validate_alpha(v, mp, kp)
	local err = "this interface name should be alphanumeric strings only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%a%w*$") then return OK end
	return FAIL, err
end
function interface_validate_number_and_alpha(v, mp, kp)
	local err = "this interface name should be number of alphanumeric"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	if v:match("^%a%w*$") then return OK end
	return FAIL, err
end

--
-- Where we expect an interface name...
--
VALIDATOR["any_interface"] = function(v, mp, kp)
	return interface_validator(v, mp, kp, "all")
end
OPTIONS["all_interfaces"] = function(kp, mp)
	return options_from_interfaces("all")
end

--
-- Convert a short format into a full keypath. We split the string into
-- a shortpath and a detail bit and then look it all up in the TYPE table.
--
function interface_path(interface)
	local sp, wc = interface:match("^(.*)/%*?([^/]+)$")
	local entry = INTERFACE_TYPE_LIST[sp]
	-- TODO: what if entry doesn't exist?
	return entry.fullpath.."/*"..wc
end

--
-- Given a name in short format, work out what the physical interface
-- should be... 
--
function interface_name(path)
	local sp, wc = path:match("^(.*)/%*?([^/]+)$")
	local entry = INTERFACE_TYPE_LIST[sp]
	-- TODO: what if entry doesn't exist?

	if wc:match("^%d+$") and entry.phys_num then
		return entry.phys_num:gsub("%%", wc)
	else
		return entry.phys_alpha:gsub("%%", wc)
	end
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


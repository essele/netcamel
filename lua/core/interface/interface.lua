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
-- Details contains:
--
-- module 	-- the module name (or short path)
-- path 	-- the long path
-- if_numeric	-- the pyhsical if name (for numeric matches)
-- if_alpha		-- the physical if name (for alpha matches)
-- classes		-- a list of type matches (will be turned to keys)
--
--function interface_register(path, fullpath, phys_num, phys_alpha, types)
function interface_register(details)
	details.classes = values_to_keys(details.classes)
	INTERFACE_TYPE_LIST[details.module] = details

--[[
	INTERFACE_TYPE_LIST[path] = {
		fullpath = fullpath,
		phys_num = phys_num,
		phys_alpha = phys_alpha,
		types = values_to_keys(types or {}),
	}
]]--
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
-- Convert a short format into a full keypath. We split the string into
-- a shortpath and a detail bit and then look it all up in the TYPE table.
--
function interface_path(interface)
	local sp, wc = interface:match("^(.*)/%*?([^/]+)$")
	local entry = INTERFACE_TYPE_LIST[sp]
	-- TODO: what if entry doesn't exist?
	return entry.path.."/*"..wc
end

--
-- Given a name in short format, work out what the physical interface
-- should be... 
--
function interface_name(path)
	local sp, wc = path:match("^(.*)/%*?([^/]+)$")
	local entry = INTERFACE_TYPE_LIST[sp]
	-- TODO: what if entry doesn't exist?

	if wc:match("^%d+$") and entry.if_numeric then
		return entry.if_numeric:gsub("%%", wc)
	else
		return entry.if_alpha:gsub("%%", wc)
	end
end
function interface_names(list)
	local rc = {}
	for interface in each(list) do table.insert(rc, interface_name(interface)) end
	return rc
end


--
-- Check if a given interface is valid (i.e. exists in the config) 
--
function is_valid_interface(short)
	return node_exists(interface_path(short), CF_new)
end

--
-- Do some basic housekeeping to make sure we have a sensible overall
-- interface configuration. At the moment this means making sure we don't
-- have any interface name conflicts.
--
function interface_precommit(changes)
	local ifs={}

	for sp, entry in pairs(INTERFACE_TYPE_LIST) do
		for node in each(node_list(entry.path, CF_new, true)) do
			local intf = interface_name(sp.."/"..node)
			if ifs[intf] then
				return false, string.format("duplicate interface name: [%s] and [%s]", sp.."/"..node, ifs[intf])
			end
			ifs[intf] = sp.."/"..node
		end
	end
	return true
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
		if entry.classes[class] then
			--
			-- Now check if we have a full path match
			--
			if v:sub(1,path:len()+1) == path.."/" then
				local wc = v:sub(path:len()+2)
				local mp = entry.path .. "/*"
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
		if entry.classes[class] then
			for node in each(node_list(entry.path, CF_new)) do
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

VALIDATOR["route"] = lib.route.validate

--
-- Master interface node...
--
master["/interface"] = {}


--
-- We use the runtime table for tracking routes, resovlers and rules and then the status
-- table for tracking interface status
--
-- TODO: why not use runtime for interfaces???
--
local function boot()
	--
	-- Create the runtime table
	--
	local schema = {
		class = "string key",
		source = "string key",
		item = "string"
	}
	local queries = {
		routes = "select * from runtime where class = 'route'",
		rm_routes = "delete from runtime where class = 'route' and source = :source",
		rules = "select * from runtime where class = 'rule'",
		resolvers = "select * from runtime where class = 'resolver'",
		rm_resolvers = "delete from runtime where class = 'resolver' and source = :source",
	}
	lib.db.create("runtime", schema, queries)

	--
	-- Status table
	--
	local schema = {
		node="string primary key", 
		status="string" 
	}
	local queries = {
		set_status = "insert or replace into status (node, status) values (:node, :status)",
		get_status = "select status from status where node = :node",
		all_up = "select * from status where status = 'up'",
	}
	lib.db.create("status", schema, queries)
end

return {
	boot = boot
}




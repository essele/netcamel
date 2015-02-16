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

--
-- Route syntax processing. We generate a route structure, filling in the
-- interface if it's not present.
--
-- We assume that the value has been validated before so we don't need
-- to check for syntax.
--
local function parse(value, interface)
	local args = split(value, "%s")
	local route = {}

	route.dest = table.remove(args, 1)
	while args[1] do
		local c = table.remove(args, 1)
		route[c] = table.remove(args, 1)
	end
	route.dev = route.dev or interface
	route.pri = tonumber(route.pri)
	return route
end

--
-- Build a list of routes to populate the "routes" field
-- in the interface var structure
--
local function build_var(base, cf, interface)
	local rc = {}
	for _,name in ipairs(lib.config.node_list(base, cf, true)) do 
		local route = {}

		--
		-- Read the config and populate the route table
		--
		local vars = lib.config.node_vars(base.."/"..name, cf)
		route.dest = vars.dest
		route.dev = (vars.dev and interface_name(vars.dev)) or interface
		route.pri = tonumber(vars.pri)
		route.gw = vars.gw
		route.table = vars.table

		--
		-- Validate and add to rc
		--
		if not route.dest then return nil, "route "..name:sub(2).." must have valid destination" end
		table.insert(rc, route)
	end
	for i,r in ipairs(rc) do
		print("i="..i)
		for k,v in pairs(r) do
			print("   k="..k.." v="..tostring(v))
		end
	end
	return rc
end


local function var(list, interface)
	local rc = {}
	for _,r in ipairs(list) do
		table.insert(rc, parse(r, interface))
	end
	return rc
end

--
-- Completer function for command line input of a route spec
--
local function rlc(token, ptoken)
	if token.options then 
		local comp, value, match = lib.cmdline.standard_completer(token, token.options)
		if type(comp) == "table" then return lib.utils.keys_to_values(comp) end
		if match then return comp .. " " end
		return comp
	end
end

--
-- A custom readline validator for the route spec
--
local function rlv(v, mp, kp, token)
	local elem, rc, err, arg, pend
	local opts = { ["gw"]=1, ["dev"]=1, ["pri"]=1, ["table"]=1 }

	-- if we don't have a token then we simulate one
	if not token then token = { value = v } end

	-- prepare the tokeniser and completer	
	lib.readline.reset_state(token)
	token.completer = rlc

	-- first check the destination (allowing default as well)
	elem = lib.readline.get_token(token, "%s")
	if not elem.samevalue then
		elem.options = { ["default"] = 1 }
		rc, err = lib.types.validate_type(elem.value, "ipv4_nm_default")
		lib.cmdline.set_status(elem, rc, err)
	end

	-- now loop through all the arg/value pairs
	while elem.status == OK do
		-- arg
		elem = lib.readline.get_token(token, "%s")
		if not elem then break end
		if not elem.samevalue then
			elem.options = opts
			rc, err = lib.types.partial_match(elem.value, elem.options)
			lib.cmdline.set_status(elem, rc, err)
		end
		if elem.status ~= OK then break end
		arg, pend = elem.value, true
		-- value
		elem = lib.readline.get_token(token, "%s")
		if not elem then break end
		if not elem.samevalue then
			if arg == "gw" then 
				elem.options = { ["AUTO"] = 1 }
				rc, err = lib.types.partial_match(elem.value, elem.options)
				if rc == FAIL then rc, err = lib.types.validate_type(elem.value, "ipv4") end
			elseif arg == "dev" then 
				if not elem.options then elem.options = lib.types.options(nil, "any_interface") end
				rc, err = lib.types.validate_type(elem.value, "any_interface")
			elseif arg == "pri" then rc, err = lib.types.validate_type(elem.value, "2-digit")
			elseif arg == "table" then rc, err = OK, nil
			else rc, err = FAIL, "unknown route argument" end
			
			lib.cmdline.set_status(elem, rc, err)
		end
		pend = false
	end	

::done::
	-- if we have other stuff, mark it FAIL
	elem = lib.readline.get_token(token)
	if elem then set_status(elem, FAIL) end

	-- find the last token, check for PARTIAL at end, then return status and err
	-- since we are a custom validator. Also check for pending args.
	elem = token.tokens[#token.tokens]
	if elem.status == PARTIAL and not token.final then set_status(elem, FAIL) end
	if pend then return FAIL, "invalid route specification" end

	return elem.status, (elem.status ~= OK and "invalid route specification") or nil
end

--
-- Install the route configuration options at the given point in the
-- master structure
--
local function add_config(mp)
	master[mp] = { ["with_children"] = 1 }
	master[mp.."/*"] =							{ ["style"] = "label" }
	master[mp.."/*/dest"] =						{ ["type"] = "ipv4_nm_default" }
	master[mp.."/*/pri"] =						{ ["type"] = "2-digit" }
	master[mp.."/*/dev"] =						{ ["type"] = "any_interface" }
	master[mp.."/*/gw"] =						{ ["type"] = "ipv4" }
end


--
-- Setup the "route" type
--
lib.types.DB["route"] = {}
lib.types.DB["route"].validator = rlv

return {
	var = var,
	build_var = build_var,
	add_config = add_config,
}

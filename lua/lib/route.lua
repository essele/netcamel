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
local function var(list, interface)
	local rc = {}
	for _,r in ipairs(list) do
		table.insert(rc, parse(r, interface))
	end
	return rc
end

--
-- TODO: move somewhere else
--
local function partial_match(v, list)
	for _,l in ipairs(list) do
		if v == l then return OK end
		if l:sub(1,#v) == v then return PARTIAL end
	end
	return FAIL
end


--
-- The validator for a route spec
--
local function validate(v, mp, kp)
	local items = lib.utils.split(v, "%s")

	if #items == 0 then return PARTIAL end
	
	-- item 1 is a destination (default or ipv4_nm)
	local i1 = partial_match(items[1], {"default"})
	if i1 == FAIL then i1 = VALIDATOR["ipv4_nm"](items[1], mp, kp) end

	if i1 == PARTIAL and (#items > 1 or v:sub(-1) == " ") then return FAIL end
	if i1 == FAIL then return FAIL end
	if not items[2] then return i1 end

	-- item 2 is a specifier
	local i2 = partial_match(items[2], {"gw", "dev", "pri", "table"})
	if i2 == PARTIAL and (#items > 2 or v:sub(-1) == " ") then return FAIL end
	
	return i2



	--
	-- TODO ... gw, dev, pri or table
	--
end

--
-- A custom readline validator for the route spec
--
local function rlv(v, mp, kp, token)
	local elem
	lib.readline.reset_state(token)

	-- first check the destination (allowing default as well)
	elem = lib.readline.get_token(token, "%s")
	if not elem.samevalue then
		local rc, err = partial_match(elem.value, {"default"})
		if rc == FAIL then rc, err = VALIDATOR["ipv4_nm"](elem.value, mp, kp) end
		lib.cmdline.set_status(elem, rc, err)
		if rc ~= OK then goto done end
	end

	-- now loop through all the arg/value pairs
	while true do
		-- arg
		elem = lib.readline.get_token(token, "%s")
		if not elem then break end
		if not elem.samevalue then
			lib.cmdline.set_status(elem, partial_match(elem.value, {"gw", "dev", "pri", "table"}))
			if elem.status ~= OK then break end
		end
		local arg = elem.value
		-- value
		elem = lib.readline.get_token(token, "%s")
		if not elem then break end
		if not elem.samevalue then
			if arg == "gw" then rc, err = VALIDATOR["ipv4"](elem.value, mp, kp)
			elseif arg == "dev" then rc, err = VALIDATOR["any_interface"](elem.value, mp, kp)
			elseif arg == "pri" then rc = OK
			elseif arg == "table" then rc = OK
			else rc, err = FAIL, "unknown route argument" end
			
			lib.cmdline.set_status(elem, rc, err)
			if elem.status ~= OK then break end
		end
	end	

::done::
	-- if we have other stuff, mark it FAIL
	elem = lib.readline.get_token(token)
	if elem then set_status(elem, FAIL) end

	-- find the last token, check for PARTIAL at end, then propogate status, mp and kp
	elem = token.tokens[#token.tokens]
	if elem.status == PARTIAL and not token.final then set_status(elem, FAIL) end
	if elem.status == OK then token.mp, token.kp = elem.mp, elem.kp end
	set_status(token, elem.status, elem.status ~= OK and "invalid route specification")
end



return {
	parse = parse,
	var = var,
	validate = validate,
	rlv = rlv,
}

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


return {
	parse = parse,
	var = var
}

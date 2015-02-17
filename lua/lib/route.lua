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

lib.types.DB["route-dest"] = {}
lib.types.DB["route-dest"].validator = lib.types.validator_for_list_or_type({"default"}, "ipv4_nm",
										"route destinations should be standard ip/netmask or default")
lib.types.DB["route-dest"].options = { text=1, [1]=TEXT[[
	Use a standard ipv4 address with a /netmask (eg. 192.168.32.0/24)
	or use 'default' to use a default route (equivalent to 0.0.0.0/0)
]] }

lib.types.DB["route-gw"] = {}
lib.types.DB["route-gw"].validator = lib.types.validator_for_list_or_type({"AUTO", "PRIOR-DEFAULT"}, "ipv4",
										"route gateway should be standard ip, AUTO or PRIOR-DEFAULT")
lib.types.DB["route-gw"].options = { text=1, [1]=TEXT[[
	Use a standard ipv4 address as the gateway address (eg. 10.2.3.45) or:
	use "AUTO" to use the address provided by the interface mechanism
	use "PRIOR-DEFAULT" to use the defaultroute from before this interface
]] }




--
-- Install the route configuration options at the given point in the
-- master structure
--
local function add_config(mp)
	master[mp] = { ["with_children"] = 1 }
	master[mp.."/*"] =							{ ["style"] = "label" }
	master[mp.."/*/dest"] =						{ ["type"] = "route-dest" }
	master[mp.."/*/pri"] =						{ ["type"] = "2-digit" }
	master[mp.."/*/dev"] =						{ ["type"] = "any_interface" }
	master[mp.."/*/gw"] =						{ ["type"] = "route-gw" }
end


return {
	build_var = build_var,
	add_config = add_config,
}

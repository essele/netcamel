#!./luajit
--------------------------------------------------------------------------------
--  This file is part of OpenTik
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
-- Sets should be a simple case of create/delete/modify
--
local function ipt_set_commit(changes)
	local state = process_changes(changes, "iptables/set")

	for set in each(state.added) do
		local setname = set:gsub("*", "")
		local cf = node_vars("iptables/set/"..set, CF_new)

		io.write(string.format("# (add set %s)\n", setname))
		io.write(string.format("# ipset create %s %s\n", setname, cf["type"]))
		for item in each(cf.item) do
			io.write(string.format("# ipset add %s %s\n", setname, item))
		end
	end
	for set in each(state.removed) do
		local setname = set:gsub("*", "")
		io.write(string.format("# (remove set %s)\n", setname))
		io.write(string.format("# ipset -q destroy %s\n", setname))
	end
	for set in each(state.changed) do
		local setname = set:gsub("*", "")
		local old_cf = node_vars("iptables/set/"..set, CF_current)
		local cf = node_vars("iptables/set/"..set, CF_new)
		io.write(string.format("# (change set %s)\n", setname))

		if old_cf["type"] ~= cf["type"] then
			-- change of type means destroy and recreate
			io.write(string.format("# ipset -q destroy %s\n", setname))
			io.write(string.format("# ipset create %s %s\n", setname, cf["type"]))
		else
			-- remove any old record
			for item in each(old_cf.item) do
				if not in_list(cf.item, item) then
					io.write(string.format("# ipset -! del %s %s\n", setname, item))
				end
			end
		end
		-- now add back in any new records
		for item in each(cf.item) do
			if not in_list(old_cf.item, item) then
				io.write(string.format("# ipset add %s %s\n", setname, item))
			end
		end
	end
	return true
end


--------------------------------------------------------------------------------
--
-- The main iptables code. We start by building a list of tables that we will
-- need to rebuild, this is by looking at the change list, but also processing
-- the variables and seeing which chains they are referenced in.
--
-- Once we know which tables to re-create we then look for chain dependencies
-- and work through each chain in turn until we have completed them all.
--
--------------------------------------------------------------------------------

-- forward declare, so we can keep code order sensible
local process_table


local function ipt_table(changes)

	--
	-- Return a list of tables who reference the variable
	--
	function find_variable_references(var)
		local rc = {}
		for rule in each(matching_list("iptables/%/%/rule/%", CF_new)) do
			if CF_new[rule]:match("%["..var.."%]") then
				-- pull out the table name
				rc[rule:match("^iptables/(%*[^/]+)")] = 1
			end
		end
		return keys_to_values(rc)
	end


	--
	-- Build a list of tables we will need to rebuild, start with
	-- any added or changed...
	--
    print("Hello From IPTABLES")
	local state = process_changes(changes, "iptables", true)
	local rebuild = {}
	
	add_to_list(rebuild, state.added)
	add_to_list(rebuild, state.changed)
	
	--
	-- See if we have any variables that would cause additional
	-- tables to be reworked
	--
	for var in each(node_list("iptables/variable", changes)) do
		print("Changed var: ["..var.."]")
		add_to_list(rebuild, find_variable_references(var))
	end

	rebuild = uniq(rebuild)
	for t in each(rebuild) do print("NEED TO REBUILD: " .. t) end

	return true
end

--
-- 
--
function process_table(table, changes)
    local state = process_changes(changes, string.format("iptables/*%s", table))

    for v in each(state.added) do print("Added: "..v) end
    for v in each(state.removed) do print("Removed: "..v) end
    for v in each(state.changed) do print("Changed: "..v) end
	
end




VALIDATOR["iptables_table"] = function(v, kp)
	local valid = { ["filter"] = 1, ["mangle"] = 1, ["nat"] = 1, ["raw"] = 1 }

	if valid[v] then return OK end
	--
	-- Now check for partial...
	--
	for k,_ in pairs(valid) do
		if k:sub(1, #v) == v then return PARTIAL, "invalid table name" end
	end
	return FAIL, "invalid table name"
end

VALIDATOR["iptables_chain"] = function(v, kp)
	print("Validating chain ("..v..") for keypath ("..kp..")")
	return OK
end

VALIDATOR["iptables_rule"] = function(v, kp)
	print("Validating rule ("..v..") for keypath ("..kp..")")
	return OK
end

VALIDATOR["OK"] = function(v)
	return OK
end

--
-- Master Structure for iptables
--
master["iptables"] = 					{}

--
-- The main tables/chains/rules definition
--
master["iptables/*"] = 					{ ["commit"] = ipt_table,
										  ["depends"] = { "iptables/set" },
										  ["style"] = "iptables_table" }
master["iptables/*/*"] = 				{ ["style"] = "iptables_chain" }
master["iptables/*/*/policy"] = 		{ ["type"] = "iptables_policy" }
master["iptables/*/*/rule"] = 			{ ["with_children"] = 1 }
master["iptables/*/*/rule/*"] = 		{ ["style"] = "OK",
    	                               	  ["type"] = "iptables_rule",
       	                            	  ["quoted"] = 1 }
--
-- Support variables for replacement into iptables rules
--
master["iptables/variable"] =			{ ["delegate"] = "iptables/*" }
master["iptables/variable/*"] =			{ ["style"] = "ipt_variable" }
master["iptables/variable/*/value"] =	{ ["type"] = "OK",
										  ["list"] = 1 }

--
-- Creation of ipset with pre-poulation of items if needed
--
master["iptables/set"] = 				{ ["commit"] = ipt_set_commit }
master["iptables/set/*"] = 				{ ["style"] = "iptables_set" }
master["iptables/set/*/type"] = 		{ ["type"] = "iptables_set_type", 
										  ["default"] = "hash:ip" }
master["iptables/set/*/item"] = 		{ ["type"] = "hostname_or_ip",
										  ["list"] = 1 }



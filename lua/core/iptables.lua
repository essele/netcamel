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

--
-- Macros are a way of simplifying the look of the config, but also provides
-- other modules a way of updating sets of rules
--
local macros = {
	["(input-stateful-firewall)"] = {
			"-s 127.0.0.1/32 -j ACCEPT",
			"-m state --state RELATED,ESTABLISHED -j ACCEPT"
	},
	["(input-allowed-services)"] = build_input_services,
	["(ssh-limit-rate)"] = {
			"-p tcp --dport 22 -m state --state NEW -m recent --set --name SSH --rsource",
			"-p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --rttl --name SSH --rsource -j DROP"
	}
}


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
	-- Return a list of chains in a table who reference a given macro
	--
	-- TODO: do we really need chains, or should it be tables?
	function find_chains_with_macro(table, macro)
		local rc = {}
		for chain in each(node_list("iptables/"..table, CF_new, true)) do
			for rule in each(node_list("iptables/"..table.."/"..chain.."/rule", CF_new, true)) do
				local path = string.format("iptables/%s/%s/rule/%s", table, chain, rule)
				if(CF_new[path] == "("..macro..")") then
					print("Chain: "..chain.." --> path="..path)
					rc[chain] = 1
				end
			end
		end
		return rc
	end

	--
	-- does the given chain have any calls to chains we haven't completed yet
	--
	function has_incomplete_subchains(table, chain, outstanding)
		for rule in each(node_list("iptables/"..table.."/"..chain.."/rule", CF_new, true)) do
			local path = string.format("iptables/%s/%s/rule/%s", table, chain, rule)
			local jump = CF_new[path]:match("-j%s+([^%s]+)")
			if jump and outstanding["*"..jump] then return true end
		end
		return false
	end

	--
	-- Build all chains in a given table. 
	-- 1. Get a list of all the chains.
	-- 2. Look for chains that call others, record the depedencies
	-- 3. RUn through finding any with no depends (or complete ones)
	-- 4. Process that chain, mark as done.
	-- 5. Repeat from 3
	--
	function rebuild_table(iptable)
		-- 
		-- Get a list of all the chains we need to worry about...
		-- 
		print("TABLE REBUILD: "..iptable)
		local outstanding = values_to_keys(node_list("iptables/"..iptable, CF_new, true))

		while true do
			local chains = keys_to_values(outstanding)
			local done_work = false
			if #chains == 0 then break end

			for chain in each(chains) do
				if has_incomplete_subchains(iptable, chain, outstanding) then
					print("Chain "..chain.." has incomplete subchains")
				else
					print("Chain "..chain.." is ok to process")
					outstanding[chain] = nil
					done_work = true
				end
			end
	
			if not done_work then
				print("REFERENCE LOOP for chains: " .. table.concat(chains, ", "))
				return false
			end
		end

		print("FINDIG MACROS")
		find_chains_with_macro(iptable, "input-stateful-firewall")
		print("DONE")
--		chains_referencing_chain(table, "input-stateful-firewall")

		for ch in each(node_list("iptables/"..iptable, CF_new, true)) do
			print("  chain -- " .. ch)
		end
		
	end

	--
	-- Build a list of tables we will need to rebuild, start with
	-- triggers for macros, then add any added or changed...
	--
    print("Hello From IPTABLES")
	local state = process_changes(changes, "iptables", true)
	local rebuild = {}

	--
	-- If we were triggered, then it will probably be for a macro
	-- so we need to see which tables use the macro and add them
	-- to the list
	--
	print("LOOKING FOR TRIGGERS")
	for trigger in each(state.triggers) do
		print("IPTABLES TRIGGER: "..trigger)
		for t in each(node_list("iptables/"..trigger, changes)) do
			print("  --> " .. t)
		end
	end

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
	for t in each(rebuild) do 
		print("NEED TO REBUILD: " .. t) 
		rebuild_table(t)
	end

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

--
-- The init function is always called once all the modules
-- are fully loaded so we can configure dependencies/callbacks etc.
--
function iptables_init()
	print("IPTAB INIT")
	--
	-- We need to make sure the ipsets happen before the main chains
	--
	add_dependency("iptables/*", "iptables/set")
end



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

--
-- Macros are a way of simplifying the look of the config, but also provides
-- other modules a way of updating sets of rules
--
local macros = {
	--
	--
	--
	["(stateful-firewall)"] = {
			"-s 127.0.0.1/32 -j ACCEPT",
			"-m state --state RELATED,ESTABLISHED -j ACCEPT"
	},
	--
	-- input-allowed-services should be used by other modules to ensure standard
	-- stuff is allowed
	--
	["(input-allowed-services)"] = {},

	--
	--
	--
	["(ssh-limit-rate)"] = {
			"-p tcp --dport 22 -m state --state NEW -m recent --set --name SSH --rsource",
			"-p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --rttl --name SSH --rsource -j DROP"
	}
}


--
-- TODO: move somewhere else
--
-- Allow for other modules to add functions to the macros list
--
function iptables_add_macro_item(macro, item_or_func)
	if not macros[macro] then macros[macro] = {} end
	table.insert(macros[macro], item_or_func)
end

--
-- Look for any of the reasons that we might need to rebuild our iptables
--
-- 1. any triggers (relevant macros)
-- 2. actual table/chain changes
-- 3. variable changes that are used in rules
--
local function needs_rebuild(changes)
	--
	-- Return a list of tables who reference the variable
	--
	function find_variable_references(var)
		local rc = {}
		for rule in each(matching_list("iptables/%/%/rule/%", CF_new)) do
			if CF_new[rule]:match("{{"..var.."}}") then
				-- pull out the table name
				rc[rule:match("^iptables/(%*[^/]+)")] = 1
			end
		end
		return keys_to_values(rc)
	end

	--
	-- Return a list of tables who's chains reference a given macro
	--
	function find_tables_with_macro(macro)
		local rc = {}
		for iptable in each(node_list("iptables", CF_new, true)) do
			for rule in each(matching_list("iptables/"..iptable.."/%/rule/%", CF_new)) do
				if(CF_new[rule] == macro) then
					rc[iptable] = 1
				end
			end
		end
		return keys_to_values(rc)
	end

	-- ------------------------------------------------------------------------------
	-- NEEDS REBUILD ENTRY POINT
	-- ------------------------------------------------------------------------------
	local state = process_changes(changes, "iptables", true)
	local rebuild = {}

	--
	-- If we were triggered, then it will probably be for a macro
	-- so we need to see which tables use the macro and add them
	-- to the list
	--
	for trigger in each(state.triggers) do
		for macro in each(node_list("iptables/"..trigger, changes)) do
			add_to_list(rebuild, find_tables_with_macro(macro:gsub("^@", "")))
		end
	end

	--
	-- Add any tables that have been added or changed
	--
	add_to_list(rebuild, state.added)
	add_to_list(rebuild, state.changed)
	
	--
	-- See if we have any variables that would cause additional
	-- tables to be reworked
	--
	for var in each(node_list("iptables/variable", changes)) do
		add_to_list(rebuild, find_variable_references(var))
	end

	--
	-- Now, if rebuild is empty then we have nothing to do
	--
	if #rebuild == 0 then return false end
	return true
end

--
-- Build the full list of iptables-restore rules so we can either
-- pre-commit or commit them
--
local function ipt_generate()
	--
	-- Given a macro name run through getting the needed lines (which may involve
	-- calling a series of functions)
	--
	function expand_macro(name)
		local lines = {}
		for line in each(macros[name]) do
			if type(line) == "function" then
				local rc, items = pcall(line)
				assert(rc and items, "expand_macro failed: "..tostring(items))
				add_to_list(lines, items)
			else
				table.insert(lines, line)
			end
		end
		return lines
	end

	--
	-- Return a hash with all variables set
	--
	function load_variables()
		local vars = {}
		for var in each(node_list("iptables/variable", CF_new)) do
			local value = CF_new["iptables/variable/"..var.."/value"]
			vars[var:gsub("^%*", "")] = value
		end
		return vars
	end

	--
	-- For a given list of lines of text (iptables rule) we will return a list
	-- of lines that represent the same lines with variables expanded, we cope
	-- with multiple multi-value variables as well.
	--
	-- Referencing an unknown variable results in an error.
	--
	function variable_expand(lines, vars)
		local inlist = lines
		local outlist = {}

		while #inlist > 0 do
			local rule = table.remove(inlist, 1)
			local var = rule:match("{{([^}]+)}}")
			if var then
				if vars[var] then
					for newval in back_each(vars[var]) do
						table.insert(inlist, 1, (rule:gsub("{{"..var.."}}", newval)))
					end
				else
					return false, string.format("unknown variable: %s", var)
				end
			else
				table.insert(outlist, rule)
			end
		end
		return outlist
	end

	-- ------------------------------------------------------------------------------
	-- IPT_GENERATE ENTRY POINT
	-- ------------------------------------------------------------------------------
    print("Hello From IPTABLES Generate")

	--
	-- Start building an iptables-restore format file
	--
	local tables = {
		{ ["name"] = "nat",
		  ["chains"] = { "PREROUTING", "INPUT", "OUTPUT", "POSTROUTING" } },
		{ ["name"] = "filter",
		  ["chains"] = { "INPUT", "FORWARD", "OUTPUT" } },
		{ ["name"] = "mangle",
		  ["chains"] = { "PREROUTING", "INPUT", "FORWARD", "OUTPUT", "POSTROUTING" } },
		{ ["name"] = "raw",
		  ["chains"] = { "PREROUTING", "OUTPUT" } }
	}

	--
	-- Build a full list of chains for each of the tables
	--
	for iptable in each(tables) do
		for chain in each(node_list("iptables/*"..iptable.name, CF_new, true)) do
			chain = chain:sub(2)
			if not in_list(iptable.chains, chain) then
				table.insert(iptable.chains, chain)
			end
		end
	end

	--
	-- Process each table in turn...
	--
	local vars = load_variables()
	local output = {}
	for iptable in each(tables) do
		table.insert(output, "*"..iptable.name)
		for chain in each(iptable.chains) do
			table.insert(output, string.format(":%s ACCEPT [0:0]", chain))
		end
		for chain in each(iptable.chains) do
			local base = string.format("iptables/*%s/*%s/rule", iptable.name, chain)

			for rule in each(node_list(base, CF_new, true)) do
				local value = CF_new[base.."/"..rule]
				local rules = (macros[value] and expand_macro(value)) or { value }
				local vrules, err = variable_expand(rules, vars)	
				if not vrules then
					return false, string.format("iptables/%s/%s/rule/%s %s", 
								iptable.name, chain, rule, err)
				end
				for vr in each(vrules) do
					table.insert(output, string.format("-A %s %s -m comment --comment \"rule %s\"",
								chain, vr, rule:gsub("^*", "")))
				end
			end
		end
		table.insert(output, "COMMIT")
	end
	return output
end


--
-- If we need to make changes then call iptables-restore with the data and check
-- what return code we get
--
local function ipt_rebuild(testonly)
	local ipt_restore = { "testing/iptables-restore" }
	if testonly then table.insert(ipt_restore, "--test") end	

	--
	-- Map a line number in a set of iptables-restore inputs back into a table,
	-- chain and rule.
	-- 
	local function map_to_details(num, rules)
		local iptable = "unknown"

		for i,v in ipairs(rules) do
			if v:sub(1,1) == "*" then iptable = v:sub(2) end
			if i == num then
				local chain, rule = v:match("-A ([^ ]+) .* \"rule (.+)\"")
				if chain then return iptable, chain, rule end
			end
		end
		return nil
	end

	local rules, err = ipt_generate()
	if not rules then return false, err end
	
	local rc, stdout = execute(ipt_restore, rules)
	if rc == 0 then return true end

	--
	-- Try to pull out the error line
	--
	for x in each(stdout) do
		line = x:match("Error occurred at line: (%d+)")
		if line then
			local iptable, chain, rule = map_to_details(tonumber(line), rules)
			if iptable then
				return false, string.format("iptables/%s/%s error in rule %s",
								iptable, chain, rule)
			end
		end
	end
	return false, string.format("iptables unknown error trying to load rules")
end

--
-- The commit and pre-commit routines do the same, except that pre-commit
-- uses the iptables-restore -test mode.
--
local function ipt_commit(changes)
	if not needs_rebuild(changes) then return true end
	return ipt_rebuild()
end
local function ipt_precommit(changes)
	return ipt_rebuild(true)
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
master["iptables/*"] = 					{ ["commit"] = ipt_commit,
										  ["precommit"] = ipt_precommit,
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



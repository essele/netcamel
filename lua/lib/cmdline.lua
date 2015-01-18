#!luajit
----------------------------------------------------------------------------
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
-----------------------------------------------------------------------------

readline = require("readline")

--
-- Sample initial tab completer
-- 
-- We need to continuously determin if the token is OK, PARTIAL or FAIL
-- and if it's OK then we need to return a next tokens completer.
--
-- The token will always be anything up to (and including) a space
-- (quoted stuff tbd)
--
local CMDS = {}
local __cmds = {
	["set"] = { desc = "blah blah" },
	["cd"] = { cmd = cmd_cd },
	["show"] = {},
	["delete"] = {},
	["commit"] = {},
	["save"] = {},
	["revert"] = {},
}

--
-- Our prompt string
--
local __prompt

--
-- Our 'path' ... i.e. where are we in the config structure
--
local __path_kp = "/interface"
local __path_mp = "/interface"


local function match_list(list, t)
	local rc = {}
	for k,v in pairs(list) do
		if k:sub(1, t:len()) == t then table.insert(rc, k) end
	end
	table.sort(rc)
	return rc
end
--
-- Simple routine to append a token onto a string, we add a slash if
-- needed
--
local function append_token(s, t)
	local rc = s
	if s:sub(-1) ~= "/" then rc = rc .. "/" end
	rc = rc .. t
	return rc
end

--
-- Build a list of possible children from master or CF_new considering
-- constraints about container only.
--
local function populate_options(options, mp, kp, containeronly)
	if mp then
		for item in each(node_list(mp, master)) do
			if containeronly and master[append_token(mp, item)]["type"] ~= nil then goto nextmp end
			if item == "*" then
				local master_opts = master[append_token(mp, "*")]["options"]
				if type(master_opts) == "function" then
					master_opts = master_opts(append_token(kp, "*"), append_token(mp, "*"))
				end

				for item in each(master_opts or {}) do
					options[item] = { mp = "*", kp = "*"..item }
				end
			else
				options[item] = { mp = item, kp = item }
			end
::nextmp::
		end
	end
	if kp then
		for item in each(node_list(kp, CF_new)) do
			if containeronly and CF_new[append_token(kp, item)] ~= nil then goto nextkp end
			local wc, nitem = item:match("^(%*?)(.-)$")
			options[nitem] = { mp = (wc == "" and item) or "*", kp = item }
::nextkp::
		end
	end
end

--
-- We handle the token containing paths, so we first need to
-- work out which subtoken we are being referenced from.
--
local function cfpath_completer(tokens, n, prefix)
	--
	-- Map to the subtoken, keeping mtoken
	--
	local mtoken = tokens[1]
	local pos = tokens[n].start + prefix:len()
	local is_absolute = tokens[n].value:sub(1,1) == "/"

	tokens = tokens[n].subtokens
	n, prefix = readline.which_token(tokens, pos)
	local token = tokens[n]
	local value = token.value

	--
	-- Get our values of mp and kp
	--
	local kp, mp
	if n==1 then 
		if is_absolute then
			kp, mp = "", ""
		else
			kp, mp = __path_kp, __path_mp
		end
	else 
		kp, mp = tokens[n-1].kp, tokens[n-1].mp
	end

	--
	-- Autocomplete . and ..
	--
	if prefix == "." and token.status ~= FAIL then return "./" end
	if prefix == ".." and token.status ~= FAIL then return "/" end

	--
	-- Retrieve matches from our pre-cached list...
	--
	local matches = prefixmatches(token.options or {}, prefix)

	--
	-- If we have multiple matches then find the common prefix
	--
	if count(matches) > 1 then
		local cp = common_prefix(matches)
		if cp ~= prefix then return cp:sub(#prefix+1) else return keys_to_values(matches) end
	end

	--
	-- If we have zero or one match but are not in the original options list
	-- then we are a wildcard. 
	--
	local node = matches[next(matches)]
	if not node then
		if token.status ~= OK then return nil end
		node = { mp = "*", kp = "*"..value }
	end

	--
	-- Find out if we have more after this one ... if we don't get any options then just
	-- check if we are a wildcard.
	--
	local more = {}
	local container_only = mtoken.allow_container and not mtoken.allow_value

	populate_options(more, mtoken.use_master and append_token(mp, node.mp),
								mtoken.use_new and append_token(kp, node.kp), container_only)

	local match, moreflag = next(matches), next(more) ~= nil

	if not moreflag then
		--
		-- See if we are a wildcard, if we are then add a dummy more since there will be
		-- more fields. If we are containeronly then we need to check the extra
		-- fields to see if they are containers
		--
		local moremp = append_token(mp, node.mp)
		local wc = node_list(moremp, master)
		if container_only then
			for n in each(wc) do
				if master[append_token(moremp, n)]["type"] == nil then moreflag = true end
			end
			
		elseif #wc > 0 then moreflag = true end
	end

	--
	-- If we allow_container then we only put the slash on after a second tab
	-- on a full match
	--
	if mtoken.allow_container and moreflag then
		if match == prefix then return "/" end
		return (match and match:sub(#prefix+1))
	end

	return ((match and match:sub(#prefix+1)) or "") .. ((moreflag and "/") or " ")
end

--
-- For a set item we should look at potential values and see if we
-- have any options to present. We'll also include current values.
--
-- If it's delete then it's just limited to current values
--
-- TODO: if we are a list item then should we add a space after completion?
--
local function cfsetitem_completer(tokens, n, prefix)
	local token = tokens[n]
	local pos = token.start + prefix:len()
	local mp = tokens[2].mp
	local kp = tokens[2].kp
	local options = {}

	--
	-- Current value(s)
	--
	if CF_new[kp] then
		if master[mp].list then
			options = copy_table(CF_new[kp])
		else
			options = { tostring(CF_new[kp]) }
		end
	end

	--
	-- Provided options eithet from master or TYPEOPTS
	--
	local master_opts = master[mp].options

	if type(master_opts) == "table" then
		add_to_list(options, master_opts)
	elseif type(master_opts) == "string" then
		add_to_list(options, OPTIONS[master_opts](kp, mp))
	elseif TYPEOPTS[master[mp]["type"]] then
		add_to_list(options, TYPEOPTS[master[mp]["type"]])
	end

	--
	-- Sort and uniq
	--
	options = sorted_values(options)

	--
	-- Now completer logic
	--
	local matches = iprefixmatches(options, prefix)
	if #matches == 0 then return nil end
	if #matches > 1 then
		local cp = icommon_prefix(matches)
		if cp ~= prefix then return cp:sub(#prefix+1) else return matches end
	end
	if matches[1] == prefix then return nil end
	return matches[1]:sub(#prefix+1)
end


--
-- We get called for the path token (usually token 2) so we can 
-- re-tokenise and then run through each token that needs validating
--
local function cfpath_validator(tokens, n, input)
	local ptoken = tokens[n]
	local value = ptoken.value
	local allfail = false
	local mp, kp

	if not ptoken.subtokens then ptoken.subtokens = {} end
	readline.tokenise(ptoken.subtokens, value, "/", ptoken.start-1)

	if value:sub(1,1) == "/" then 
		mp, kp = "/", "/"
	else
		mp, kp = __path_mp, __path_kp
	end

	for i,token in ipairs(ptoken.subtokens) do
		local value = token.value
		if allfail then token.status = FAIL goto continue end
		if token.status == OK then mp, kp = token.mp, token.kp goto continue end

		--
		-- Build a list of the options we know about and add in the provided options
		-- for a wildcard
		--
		if not token.options then
			local container_only = tokens[1].allow_container and not tokens[1].allow_value
			token.options = {}
			populate_options(token.options, tokens[1].use_master and mp, 
								tokens[1].use_new and kp, container_only)
		end

		--
		-- Handle the case of "/" for a container
		--
		if tokens[1].allow_container and value == "" then token.status = OK goto done end

		--
		-- Allow the use of .. to go back if there is room
		--
		if value:sub(1,1) == "." and mp:match("/[^/]+$") then
			if value == "." then
				token.status = PARTIAL
			elseif value == ".." then
				mp = mp:gsub("/[^/]+$", "")
				kp = kp:gsub("/[^/]+$", "")
				if #mp == 0 then mp, kp = "/", "/" end
				token.status = OK
			end
			goto done
		end

		--
		-- * is not allowed, so instant fail.
		--
		if value:sub(1,1) == "*" then token.status = FAIL goto done end
		--
		-- try match against full values
		--
		if token.options[value] then
			mp = append_token(mp, token.options[value].mp)
			kp = append_token(kp, token.options[value].kp)
			token.status = OK
			goto done
		end
		--
		-- try wildcard match (only if we are matching possibles from the
		-- master list)
		--
		if tokens[1].use_master then
			if master[append_token(mp, "*")] then
				mp = append_token(mp, "*")
				kp = append_token(kp, "*"..value)
				local rc, err = VALIDATOR[master[mp].style](value, kp)
				if rc ~= FAIL then token.status = rc goto done end
			end
		end
		--
		-- if we are still failed, then try partial matches
		--
		if next(prefixmatches(token.options, value)) then
			token.status = PARTIAL
			goto done
		end
		token.status = FAIL

::done::
		-- We can only be PARTIAL if we are the last of the subtokens
		if token.status == PARTIAL then
			if i ~= #ptoken.subtokens then token.status = FAIL end
		end

		if token.status == FAIL then allfail = true end
		if token.status == OK then token.mp, token.kp = mp, kp end

::continue::
	end

	-- if we want to non-container then we are partial unless we have it
	local finalstatus = ptoken.subtokens[#ptoken.subtokens].status
	local must_be_node = tokens[1].allow_value and not tokens[1].allow_container

	if must_be_node and finalstatus ~= FAIL then
		if #mp == 0 or (master[mp] and master[mp]["type"] == nil) then
			readline.mark_all(ptoken.subtokens, 1, PARTIAL)
		end
	end

	-- propogate the status, mp and kp back from the last subtoken
	tokens[n].status = ptoken.subtokens[#ptoken.subtokens].status
	tokens[n].kp = ptoken.subtokens[#ptoken.subtokens].kp
	tokens[n].mp = ptoken.subtokens[#ptoken.subtokens].mp
end

local function tv2(tokens, n, input)
	local ptoken = tokens[n]
	local value = ptoken.value
	local mp = tokens[2].mp
	local kp = tokens[2].kp

	--
	-- Right hand side, need to run the validator
	--
	local m = master[mp]
	local mtype = m["type"]

--	print("type="..tostring(mtype))
	ptoken.status = VALIDATOR[mtype](value, kp)
--	print("st="..ptoken.status)
end


local function syntax_set(tokens)
	--
	-- Only allow the cfpath completer unless the cfpath
	-- gets properly validated
	--
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = true
	tokens[1].use_new = true

	tokens[1].allow_value = true
	tokens[1].allow_container = false

	--
	-- Make sure the cfpath is ok
	--
	if tokens[2].status ~= OK then cfpath_validator(tokens, 2) end
	if tokens[2].status ~= OK then readline.mark_all(tokens, 3, FAIL) return end

	--
	-- Setup the completer for all other fields
	--
	if tokens[3] then tokens[3].completer = cfsetitem_completer end
	--
	-- Check all other fields are correct
	--
	n = 3
	while tokens[n] do
		tv2(tokens, n)
		n = n + 1
	end
end

local function syntax_delete(tokens)
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = false
	tokens[1].use_new = true

	tokens[1].allow_value = true
	tokens[1].allow_container = true

	if tokens[2].status ~= OK then cfpath_validator(tokens, 2) end
	if tokens[2].status ~= OK then readline.mark_all(tokens, 3, FAIL) return end

	--
	-- We support additional tokens if we are deleting from a list
	--
	if tokens[2].status == OK and master[tokens[2].mp].list then
		tokens[1].default_completer = cfsetitem_completer
		local n = 3
		while tokens[n] do
			tv2(tokens, n)
			n = n + 1
		end
	else
		local n = 3
		while tokens[n] do tokens[n].status = FAIL n = n + 1 end
	end
end

local function syntax_cd(tokens)
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = true
	tokens[1].use_new = true

	tokens[1].allow_value = false
	tokens[1].allow_container = true

	if tokens[2].status ~= OK then cfpath_validator(tokens, 2) end
	if tokens[2].status ~= OK then readline.mark_all(tokens, 3, FAIL) return end
	if tokens[3] then readline.mark_all(tokens, 3, FAIL) return end
end

local function syntax_level1(tokens)
	local token = tokens[1]
	local value = token.value
	local status

	if __cmds[value] then 
		token.status = OK
		if value == "set" and tokens[2] then
			syntax_set(tokens, input)
		elseif value == "delete" and tokens[2] then
			syntax_delete(tokens, input)
		elseif value == "cd" and tokens[2] then
			syntax_cd(tokens, input)
		end
	elseif tokens[2] then
		token.status = FAIL
	else
		local matches = match_list(__cmds, value)
		if #matches > 0 then token.status = PARTIAL 
		else token.status = FAIL end
	end
	if token.status == FAIL then readline.mark_all(tokens, 2, FAIL) end
end

--
-- The syntax checker needs to put a status on each token so that
-- we can incorporate colour as we print the line out for syntax
-- highlighting
--
-- Keep the previous setting if we have one since nothing would have
-- changed. If we need to recalc then do so.
--
local function syntax_checker(tokens, input)
	local allfail = false

	syntax_level1(tokens)
	return
end

--
-- Provide completion information against the system commands.
--
-- Completion routines can return a string where there is a full match
-- or a partial common-prefix.
--
-- Or a list that will be output to the screen (and not used in any other
-- way so the format is free)
--
local function system_completer(tokens, n, prefix)
	local matches = match_list(__cmds, prefix)
	local ppos = prefix:len() + 1

	if #matches == 0 then return nil end

	if #matches == 1 then return matches[1]:sub(ppos) .. " " end

	if #matches > 1 then
		local cp = icommon_prefix(matches)
		if cp ~= prefix then
			return cp:sub(ppos)
		end
	end
	for i, m in ipairs(matches) do
		matches[i] = string.format("%-20.20s %s", m, __cmds[m].desc or "-")
	end

	return matches
end

--
-- The completer will work out which function to call
-- to provide completion information
--
local function initial_completer(tokens, input, pos)
	local n, prefix = readline.which_token(tokens, pos)

	if n == 1 then
		return system_completer(tokens, n, prefix)
	else
		if tokens[n].completer then return tokens[n].completer(tokens, n, prefix) end
		if tokens[1].default_completer then return tokens[1].default_completer(tokens, n, prefix) end
		return nil
	end
end


local function setprompt(kp)
	local str = kp:gsub("%*", "")

	local prompt = {
		{ txt = "[", clr = 7 },
		{ txt = str, clr = 6 },
		{ txt = "] ", clr = 7 },
		{ txt = "", clr = 9 } }
	return prompt
end

local function usage(cmd)
	print("Usage: "..cmd.usage)
end

-- ------------------------------------------------------------------------------
-- CD COMMAND
-- ------------------------------------------------------------------------------
CMDS["cd"] = {
	help = "change to a particular area of config",
	usage = "cd <cfg_path>",
}
CMDS["cd"].func = function(cmd, cmdline, tags)
	if not tags[2] then usage(cmd) return end

	print("kp="..tags[2].kp)
	print("mp="..tags[2].mp)
	__path_kp = tags[2].kp
	__path_mp = tags[2].mp
	__prompt = setprompt(__path_kp)
end


function interactive()
	-- Read History
	history = {}
	local file = io.open("etc/__history", "r")
	if file then
		for h in file:lines() do table.insert(history, h) end
	end

	__prompt = setprompt(__path_kp)

	readline.init()
	while true do
		local cmdline, tags = readline.readline(__prompt, history, syntax_checker, initial_completer)
		if not cmdline then break end
		if cmdline:match("^%s*$") then goto continue end
		table.insert(history, cmdline)

		local cmd = CMDS[tags[1].value]
		if cmd then
			cmd.func(cmd, cmdline, tags)
		elseif tags[1].value == "show" then
			show(CF_current, CF_new)
		elseif tags[1].value == "cd" then
			print("kp="..tags[2].kp)
			print("mp="..tags[2].mp)
			__path_kp = tags[2].kp
			__path_mp = tags[2].mp
			prompt = setprompt(__path_kp)
		elseif tags[1].value == "set" then
			print("2="..tags[2].value)
			print("3="..tags[3].value)

			local has_quotes = tags[3].value:match("^\"(.*)\"$")
			if has_quotes then
				tags[3].value = has_quotes
			end
		
			local rc, err = set(CF_new, tags[2].value, tags[3].value)
			if not rc then print("Error: " .. tostring(err)) end
		elseif tags[1].value == "delete" then
			print("2="..tostring(tags[2].value))
			print("3="..tostring(tags[3] and tags[3].value))
			local list_elem = (tags[3] and tags[3].value ~= "" and tags[3].value) or nil

			local rc, err = delete(CF_new, tags[2].value, list_elem)
			if not rc then print("Error: " .. tostring(err)) end
		elseif tags[1].value == "commit" then
			local rc, err = commit(CF_current, CF_new)
			if not rc then 
				print("Error: " .. err)
			else
				CF_current = copy_table(CF_new)
			end
		elseif tags[1].value == "save" then
			local rc, err = save(CF_current)
			if not rc then print("Error: " .. err) end
		end

	::continue::
	end
	readline.finish()

	-- Save history
	local file = io.open("etc/__history", "w+")
	if file then
		for h in each(history) do file:write(h .. "\n") end
		file:close()
	end
end




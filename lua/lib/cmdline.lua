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
local __cmds = {
	["set"] = { desc = "blah blah" },
	["show"] = {},
	["delete"] = {},
	["commit"] = {},
	["save"] = {},
	["revert"] = {},
}
function match_list(list, t)
	local rc = {}
	for k,v in pairs(list) do
		if k:sub(1, t:len()) == t then table.insert(rc, k) end
	end
	table.sort(rc)
	return rc
end

--
-- We handle the token containing paths, so we first need to
-- work out which subtoken we are being referenced from.
--
function cfpath_completer(tokens, n, prefix)
	--
	-- Map to the subtoken, keeping mtoken
	--
	local mtoken = tokens[1]
	local pos = tokens[n].start + prefix:len()

	tokens = tokens[n].subtokens
	n, prefix = readline.which_token(tokens, pos)
	token = tokens[n]
	value = token.value

	--
	-- Get our values of mp and kp
	--
	local kp, mp, slash
	if n==1 then kp, mp, slash = "", "", ""
	else kp, mp, slash = tokens[n-1].kp, tokens[n-1].mp, "/" end

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
	-- check if we are a wildcard and add a dummy entry.
	--
	local more = {}
	populate_options(more, mtoken.use_master and mp..slash..node.mp, 
								mtoken.use_new and kp..slash..node.kp, mtoken.containeronly)
	if #more == 0 then
		local wc = node_list(mp..slash..node.mp, master)
-- TODO: containeronly check here???
		if #wc > 0 then table.insert(more, "dummy") end
	end

	local match, more = next(matches), next(more)
	return ((match and match:sub(#prefix+1)) or "") .. ((more and "/") or " ")
end

--
-- For a set item we should look at potential values and see if we
-- have any options to present. We'll also include current values.
--
-- If it's delete then it's just limited to current values
--
-- TODO: if we are a list item then should we add a space after completion?
--
function cfsetitem_completer(tokens, n, prefix)
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
	elseif type(master_opts) == "function" then
		add_to_list(options, master_opts(kp, mp))
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
-- Build a list of possible children from master or CF_new considering
-- constraints about container only.
--
function populate_options(options, mp, kp, containeronly)
	if mp then
		local slash = (mp == "" and "") or "/"
		for item in each(node_list(mp, master)) do
			if containeronly and master[mp..slash..item]["type"] ~= nil then goto nextmp end
			if item == "*" then
				local master_opts = master[mp..slash.."*"]["options"]
				if type(master_opts) == "function" then
					master_opts = master_opts(kp..slash.."*", mp..slash.."*")
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
		local slash = (kp == "" and "") or "/"
		for item in each(node_list(kp, CF_new)) do
			if containeronly and CF_new[kp..slash..item] then goto nextkp end
			local wc, nitem = item:match("^(%*?)(.-)$")
			options[nitem] = { mp = (wc == "" and item) or "*", kp = item }
::nextkp::
		end
	end
end

--
-- We get called for the path token (usually token 2) so we can 
-- re-tokenise and then run through each token that needs validating
--
function cfpath_validator(tokens, n, input)
	local ptoken = tokens[n]
	local value = ptoken.value
	local allfail = false
	local mp, kp, slash = "", "", ""

	if not ptoken.subtokens then ptoken.subtokens = {} end
	readline.tokenise(ptoken.subtokens, value, "/", ptoken.start-1)

	for i,token in ipairs(ptoken.subtokens) do
		local value = token.value
		if allfail then token.status = FAIL goto continue end
		if token.status == OK then mp, kp = token.mp, token.kp goto continue end

		--
		-- Build a list of the options we know about and add in the provided options
		-- for a wildcard
		--
		if not token.options then
			token.options = {}
			populate_options(token.options, tokens[1].use_master and mp, 
								tokens[1].use_new and kp, tokens[1].containeronly)
		end

		--
		-- * is not allowed, so instant fail.
		--
		if value:sub(1,1) == "*" then token.status = FAIL goto done end
		--
		-- try match against full values
		--
		if token.options[value] then
			mp = mp..slash..token.options[value].mp
			kp = kp..slash..token.options[value].kp
			token.status = OK
			goto done
		end
		--
		-- try wildcard match (only if we are matching possibles from the
		-- master list)
		--
		if tokens[1].use_master then
			if master[mp..slash.."*"] then
				mp = mp..slash.."*"
				kp = kp..slash.."*"..value
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
		slash = "/"
	end

	-- if we want to non-container then we are partial unless we have it
	local finalstatus = ptoken.subtokens[#ptoken.subtokens].status
	if tokens[1].mustbenode and finalstatus ~= FAIL then
		if master[mp] and master[mp]["type"] == nil then
			readline.mark_all(ptoken.subtokens, 1, PARTIAL)
		end
	end

	-- propogate the status, mp and kp back from the last subtoken
	tokens[n].status = ptoken.subtokens[#ptoken.subtokens].status
	tokens[n].kp = ptoken.subtokens[#ptoken.subtokens].kp
	tokens[n].mp = ptoken.subtokens[#ptoken.subtokens].mp
end

function tv2(tokens, n, input)
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


function syntax_set(tokens)
	--
	-- Only allow the cfpath completer unless the cfpath
	-- gets properly validated
	--
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = true
	tokens[1].use_new = true
	tokens[1].containeronly = false
	tokens[1].mustbenode = true

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

function syntax_delete(tokens)
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = false
	tokens[1].use_new = true
	tokens[1].mustbenode = false

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



function syntax_level1(tokens)
	local token = tokens[1]
	local value = token.value
	local status

	if __cmds[value] then 
		token.status = OK
		if value == "set" and tokens[2] then
			syntax_set(tokens, input)
		elseif value == "delete" and tokens[2] then
			syntax_delete(tokens, input)
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
function syntax_checker(tokens, input)
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
function system_completer(tokens, n, prefix)
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
function initial_completer(tokens, input, pos)
	local n, prefix = readline.which_token(tokens, pos)

	if n == 1 then
		return system_completer(tokens, n, prefix)
	else
		if tokens[n].completer then return tokens[n].completer(tokens, n, prefix) end
		if tokens[1].default_completer then return tokens[1].default_completer(tokens, n, prefix) end
		return nil
	end
end





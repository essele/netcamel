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

require("config")
local readline = require("readline")
local posix = { 
	dirent = require("posix.dirent"),
	sys = { stat = require("posix.sys.stat") } 
}

--
-- Will be populated with our cmdline commands
--
local CMDS = {}

--
-- Our prompt string
--
local __prompt

--
-- Our 'path' ... i.e. where are we in the config structure
--
local __path_kp = "/"
local __path_mp = "/"

--
-- Undo capability
--
local __undo


local function match_list(list, t)
	local rc = {}
	for k,v in pairs(list) do
		if k:sub(1, t:len()) == t then table.insert(rc, k) end
	end
	table.sort(rc)
	return rc
end

--
-- Add any provided "options" from the master to the given list
--
local function add_master_options(options, mp)
	local master_opts = master[mp]["options"]
	if type(master_opts) == "function" then
		master_opts = master_opts()
	end
	for item in each(master_opts or {}) do
		options[item] = { mp="*", kp="*"..item }
	end
end

--
-- Given a path we need to work out what the possible options are, so we look
-- at the master, the new config and also any options from master.
--
local function node_selector(mp, kp, opts)
	--
	-- Get all the master nodes that match the options we have provided
	--
	local m_list = {}
	local match = mp:gsub("/$", ""):gsub("([%-%+%.%*])", "%%%1").."/([^/]+)"
	for k, m in pairs(master) do
		local item = k:match(match)
		if item then
			if opts.allow_container and master[k]["type"] == nil then m_list[item] = 1 end
			if opts.allow_value and master[k]["type"] ~= nil then m_list[item] = 1 end
		end
	end
	
	--
	-- Now build the final list
	--
	local list = {}

	--
	-- If use_master then add all master items (including * at this point)
	--
	if opts.use_master then
		for item,_ in pairs(m_list) do list[item] = { mp=item, kp=item } end
	end

	--
	-- Now add actuals where we have a match with the original master list
	-- so that we only include containers/values as needed
	--
	if opts.use_new then
		for item in each(node_list(kp, CF_new)) do
			if m_list[item] then 
				list[item] = { mp=item, kp=item }
			elseif item:sub(1,1) == "*" and m_list["*"] then 
				list[item:sub(2)] = { mp="*", kp=item }
			end
		end
	end

	--
	-- If we have a * then add master options, we leave the * so we know
	-- if we have options available (for 'more' calcs)
	--
	if list["*"] then
		add_master_options(list, mp.."/*")
	end
	return list
end


--
-- We handle the token containing paths, so we first need to
-- work out which subtoken we are being referenced from.
--
local function cfpath_completer(tokens, n, prefix)
	--
	-- Map to the subtoken
	--
	local pos = tokens[n].start + prefix:len()
	local opts = tokens[n].opts
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
	-- Retrieve matches from our pre-cached list, and remove the
	-- wildcard if its there.
	--
	local matches = prefixmatches(token.options or {}, prefix)
	matches["*"] = nil

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
	local container_only = opts.allow_container and not opts.allow_value
	local more = node_selector(append_token(mp, node.mp), append_token(kp, node.kp), opts)


	local match, moreflag = next(matches), next(more)

	--
	-- If we allow_container then we only put the slash on after a second tab
	-- on a full match
	--
	if opts.allow_container and moreflag then
		if match == prefix then return "/" end
		return (match and match:sub(#prefix+1))
	end

	return ((match and match:sub(#prefix+1)) or "") .. ((moreflag and "/") or " ")
end

--
-- Handle completion for a filename value, this uses tables prepared
-- by the cffilevalue_validator
--
-- TODO: options? perhaps limits of dir, or specific file types
--
local function cffilevalue_completer(tokens, n, prefix)
	local token = tokens[n]

	if token.status ~= PARTIAL then return nil end

	local matches = prefixmatches(token.options, token.basename)
	
	local m1 = next(matches)
	if not m1 then return nil end
	local m2 = next(matches, m1)

	--
	-- If one match then complete and see if we should add the slash
	--
	if not m2 then
		local match = m1:sub(#token.basename+1)
		if matches[m1] == 2 then match = match .. "/" end
		return match
	end

	--
	-- If more than one match then handle the common prefix
	--
	local cp = common_prefix(matches)
	if cp ~= token.basename then return cp:sub(#token.basename+1) end

	return sorted_keys(prefixmatches(token.options, token.basename))
end

--
-- For a set item we should look at potential values and see if we
-- have any options to present. We'll also include current values.
--
-- If it's delete then it's just limited to current values
--
local function cfvalue_completer(tokens, n, prefix)
	local token = tokens[n]
	local pos = token.start + prefix:len()
	local mp = tokens[2].mp
	local kp = tokens[2].kp
	local options = {}

	--
	-- Current value(s)
	--
	if CF_new[kp] then
		if master[mp].list then options = copy(CF_new[kp])
		else options = { tostring(CF_new[kp]) } end
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

	local opts = tokens[n].opts
	local container_only = opts.allow_container and not opts.allow_value

	for i,token in ipairs(ptoken.subtokens) do
		local value = token.value
		if allfail then token.status = FAIL goto continue end
		if token.status == OK then mp, kp = token.mp, token.kp goto continue end

		--
		-- Build a list of the options we know about and add in the provided options
		-- for a wildcard
		--
		if not token.options then token.options = node_selector(mp, kp, opts) end

		--
		-- Handle the case of "/" for a container
		--
		if opts.allow_container and ptoken.value == "/" then 
			token.kp, token.mp = "/", "/"
			token.status = OK 
			goto done 
		end

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
		if opts.use_master then
			if master[append_token(mp, "*")] then
				mp = append_token(mp, "*")
				kp = append_token(kp, "*"..value)
				local rc, err = VALIDATOR[master[mp].style](value, mp, kp)
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
	local must_be_node = opts.allow_value and not opts.allow_container

	if must_be_node and finalstatus ~= FAIL then
		if #mp == 0 or (master[mp] and master[mp]["type"] == nil) then
			readline.mark_all(ptoken.subtokens, 1, PARTIAL)
		end
	end

	-- propogate the status, mp and kp back from the last subtoken
	tokens[n].status = ptoken.subtokens[#ptoken.subtokens].status
	tokens[n].kp = ptoken.subtokens[#ptoken.subtokens].kp
	tokens[n].mp = ptoken.subtokens[#ptoken.subtokens].mp

	-- TODO: make the error right for value vs. container
	if tokens[n].status ~= OK then tokens[n].err = "not a valid configuration path" end
end

--
-- A simple file validator that uses glob to see if we are a partial match for
-- a real filename
--
local function cffilevalue_validator(ptoken)
	local value = ptoken.value
	local dirname, basename = value:match("^(/?.-)/?([^/]*)$")

	-- Set this before we put the "." in
	ptoken.basename = basename

	if dirname == "" then dirname = "." end
	if basename == "" then basename = "." end

	-- 
	-- Check the dirname and populate the filelist if it's different from
	-- last time
	--
	if dirname ~= ptoken.dirname then
		local stat = posix.sys.stat.stat(dirname)
		if not stat then return FAIL, "invalid path" end

		ptoken.dirname = dirname
		ptoken.options = {}
		for file in each(posix.dirent.dir(dirname)) do
			local stat = posix.sys.stat.stat(dirname.."/"..file)
			if stat and bit.band(stat.st_mode, posix.sys.stat.S_IFREG) ~= 0 then
				ptoken.options[file] = 1
			elseif stat and bit.band(stat.st_mode, posix.sys.stat.S_IFDIR) ~= 0 then
				ptoken.options[file] = 2
			end
		end
	end

	--
	-- Check to see if we match any of the known files
	--
	local matches = prefixmatches(ptoken.options, basename)
	
	--
	-- Matching scenarios ...
	--
	-- 1. Full match as file (but there might be others) = OK
	-- 2. No matches = FAIL
	-- 3. Anything else = PARTIAL
	--
	if matches[basename] and matches[basename] == 1 then return OK end
	if not next(matches) then return FAIL, "invalid file name" end
	return PARTIAL, "need full path to a file"
end

--
-- Validate a value for an item in a cfpath (index=pathn)
--
local function cfvalue_validator(tokens, n, pathn)
	local ptoken = tokens[n]
	local value = ptoken.value
	local mp = tokens[pathn].mp
	local kp = tokens[pathn].kp

	--
	-- Right hand side, need to run the validator
	--
	local m = master[mp]
	local mtype = m["type"]
	local err

	if mtype:sub(1,5) == "file/" then
		ptoken.status, ptoken.err = cffilevalue_validator(ptoken)
	else
		ptoken.status, ptoken.err = VALIDATOR[mtype](value, mp, kp)
	end

	-- TODO: is it really this simple?
end


--
-- Handle the validation/syntax checking based on our supplied cmd and options
--
local function syntax_action(cmd, tokens)
	local i = 2

	for a in each(cmd.args) do
		--
		-- If we don't have a token then we can't go on
		--
		if not tokens[i] then break end

		--
		-- Handle a cfpath argument, if we're not ok then all else must be FAIL
		--
		if a.arg == "cfpath" then
			tokens[i].completer = cfpath_completer
			tokens[i].opts = a.opts
			if tokens[i].status ~= OK then cfpath_validator(tokens, i) end
			if tokens[i].status ~= OK then i = i + 1 break end
		end

		--
		-- Handle a cfitem argument, need to work out which cfpath it refers to
		-- assume i-1 as a default
		--
		if a.arg == "cfvalue" then
			local path_index = a.path_index or i-1
			local value_type = master[tokens[path_index].mp]["type"]

			if a.only_if_list and not master[tokens[path_index].mp].list then break end

			if value_type:sub(1,5) == "file/" then
				tokens[i].completer = cffilevalue_completer
			else
				tokens[i].completer = cfvalue_completer
			end
			if tokens[i].status ~= OK then cfvalue_validator(tokens, i, path_index) end
			if tokens[i].status ~= OK then i = i + 1 break end
		end
		i = i + 1
	end
	readline.mark_all(tokens, i, FAIL)
	return
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
	local token = tokens[1]
	local value = token.value
	local status

	if CMDS[value] then
		token.status = OK
		syntax_action(CMDS[value], tokens)
	elseif tokens[2] then
		token.status = FAIL
	else
		local matches = match_list(CMDS, value)
		token.status = (#matches > 0 and PARTIAL) or FAIL
	end
	if token.status == FAIL then readline.mark_all(tokens, 2, FAIL) end
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
	local matches = match_list(CMDS, prefix)
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
		matches[i] = string.format("%-20.20s %s", m, CMDS[m].help or "-")
	end
	matches.text = true
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
-- SHOW COMMAND
-- ------------------------------------------------------------------------------
CMDS["show"] = {
	help = "show the configuration with delta to current",
	usage = "show [<cfg_path>]",
	min_args = 0,
	max_args = 1,
	args = {
		{ arg = "cfpath", opts = { use_master = true, use_new = true, allow_value = false, allow_container = true }}
	}
}
CMDS["show"].func = function(cmd, cmdline, tags)
	local kp = (tags[2] and tags[2].kp) or __path_kp
	show(CF_current, CF_new, kp)
end

-- ------------------------------------------------------------------------------
-- UNDO COMMAND
-- ------------------------------------------------------------------------------
CMDS["undo"] = {
	help = "undo the last activity",
	usage = "undo",
	min_args = 0,
	max_args = 0,
	args = {}
}
CMDS["undo"].func = function(cmd, cmdline, tags)
	if not __undo then
		print("undo: not available.")
		return
	end

	local rc, err = undo(CF_new, __undo)
	if not rc then 
		print("error: " .. err) 
		return
	end
	print(string.format("undo: undoing command: %s", __undo.cmd))
	print(string.format("undo: processed %s configuration item%s.", rc, (rc > 1 and "s") or ""))
	__undo = nil
end

-- ------------------------------------------------------------------------------
-- SAVE COMMAND
-- ------------------------------------------------------------------------------
CMDS["save"] = {
	help = "save the currently active configuration so its applied at boot time",
	usage = "save",
	min_args = 0,
	max_args = 0,
	args = {}
}
CMDS["save"].func = function(cmd, cmdline, tags)
	local rc, err = save(CF_current)
	if not rc then 
		print("error: " .. err)
		return
	end
	__undo = nil
end

-- ------------------------------------------------------------------------------
-- COMMIT COMMAND
-- ------------------------------------------------------------------------------
CMDS["commit"] = {
	help = "make the new configuration active",
	usage = "commit",
	min_args = 0,
	max_args = 0,
	args = {}
}
CMDS["commit"].func = function(cmd, cmdline, tags)
	local rc, err = commit(CF_current, CF_new)
	if not rc then 
		print("error: " .. err)
		return
	else
		CF_current = copy(CF_new)
	end
	__undo = nil
end

-- ------------------------------------------------------------------------------
-- DELETE COMMAND
-- ------------------------------------------------------------------------------
CMDS["delete"] = {
	help = "delete sections or items from the confinguration",
	usage = "delete <cfg_path> [<list value>]",
	min_args = 1,
	max_args = 2,
	args = {
		{ arg = "cfpath", opts = { use_master = true, use_new = true, allow_value = true, allow_container = true }},
		{ arg = "cfvalue", only_if_list = true },
	}
}
CMDS["delete"].func = function(cmd, cmdline, tags)
	local kp = tags[2].kp
	local list_elem = tags[3] and tags[3].value

	local rc, err = delete(CF_new, kp, list_elem)
	if not rc then 
		print("error: " .. tostring(err))
		return
	end
	print(string.format("delete: removed %s configuration item%s.", rc, (rc > 1 and "s") or ""))
	__undo = err
	__undo.cmd = cmdline
end

-- ------------------------------------------------------------------------------
-- SET COMMAND
-- ------------------------------------------------------------------------------
CMDS["set"] = {
	help = "set values for items in the configuration",
	usage = "set <cfg_path> <value>",
	min_args = 2,
	max_args = 2,
	args = {
		{ arg = "cfpath", opts = { use_master = true, use_new = true, allow_value = true, allow_container = false }},
		{ arg = "cfvalue" },
	}
}
CMDS["set"].func = function(cmd, cmdline, tags)
	local kp = tags[2].kp
	local mp = tags[2].mp
	local value = tags[3].value

	local has_quotes = value:match("^\"(.*)\"$")
	if has_quotes then value = has_quotes end

	if master[mp].action then
		print("CALLING ACTION INSTEAD")
		master[mp].action(value, mp, kp)
		return
	end

	local rc, err = set(CF_new, kp, value)
	if not rc then 
		print("error: " .. tostring(err))
		return
	end
	__undo = err
	__undo.cmd = cmdline
end

-- ------------------------------------------------------------------------------
-- REVERT COMMAND
-- ------------------------------------------------------------------------------
CMDS["revert"] = {
	help = "revert part of the new config back to current settings",
	usage = "revert <cfg_path>",
	min_args = 1,
	max_args = 1,
	args = {
		{ arg = "cfpath", opts = { use_master = true, use_new = true, allow_value = false, allow_container = true }}
	}
}
CMDS["revert"].func = function(cmd, cmdline, tags)
	local rc, err = revert(CF_new, tags[2].kp)
	if not rc then 
		print("error: " .. tostring(err))
		return
	end
	print(string.format("revert: considered %s configuration item%s.", rc, (rc > 1 and "s") or ""))
	__undo = err
	__undo.cmd = cmdline
end

-- ------------------------------------------------------------------------------
-- CD COMMAND
-- ------------------------------------------------------------------------------
CMDS["cd"] = {
	help = "change to a particular area of config",
	usage = "cd <cfg_path>",
	min_args = 1,
	max_args = 1,
	args = {
		{ arg = "cfpath", opts = { use_master = true, use_new = true, allow_value = false, allow_container = true }}
	}
}
CMDS["cd"].func = function(cmd, cmdline, tags)
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

		--
		-- Remove any trailing empty tags
		--
		if tags[#tags].value == "" then table.remove(tags) end

		--
		-- Ignore just empty lines
		--
		if #tags == 0 then goto continue end

		--
		-- Add to the history
		--
		table.insert(history, cmdline)

		--
		-- Find our command and do some basic usage checking, are all
		-- the tags OK, and do we have the right amount
		--
		local cmd = CMDS[tags[1].value]
		if not cmd then print("unknown command: "..tags[1].value) goto continue end
		if #tags-1 < cmd.min_args or #tags-1 > cmd.max_args then usage(cmd) goto continue end
			
		for i=1, #tags do
			if tags[i].status ~= OK then
				print(string.format("%s: arg %d: %s", tags[1].value, i-1, tags[i].err or "unknown error"))
				goto continue
			end
		end	

		--
		-- Execute the command
		--
		cmd.func(cmd, cmdline, tags)
		-- TODO: error checking

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




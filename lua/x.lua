#!/usr/bin/luajit
--------------------------------------------------------------------------------
--  This file is part of NetCamel
--  Copyright (C) 2014,15 Lee Essen <lee.essen@nowonline.co.uk>
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

dofile("lib/lib.lua")

--
-- TEST CODE ONLY
--
function completeCB(tokens, line, pos)
	local i = which_token(tokens, pos)

	if tokens[i].completer then return tokens[i].completer(tokens, i, pos) end

--	if i==2 then
--		local j = which_subtoken(tokens, i, pos)
--		print("j="..j)
--	end
end

--
-- Set the status (and colour) of a token
--
local OK = 1
local PARTIAL = 2
local FAIL = 3
local WEIRD = 4
local status_color = { [OK] = "green", [PARTIAL] = "yellow", [FAIL] = "red", [WEIRD] = "blue" }

function set_status(token, status)
	if token.status ~= status then
		token.status = status
		token.color = status_color[status]
		token.nochange = nil

		-- support one level of subtoken parent updating
		if token.parent then token.parent.nochange = nil end
	end	
end

--
--
--
function usage_completer(tokens, n, pos)
	print("Usage: <abc> <def> <ghosdkjhdfg>")
end

--
--
--
function flag_completer(tokens, n, pos)
	local flagtoken = tokens[n]

	if not flagtoken.tokens then return end
	
	local j = which_subtoken(tokens, n, pos)
	if j == 1 then
		for k,v in pairs(flagtoken.flagoptions) do
			print("OPT: "..k)
		end
	end
end

--
--
--
function cfpath_options(mp, kp, opts)
	--	
	-- Get the full list of master nodes that match mp and the options we have provided
	-- 
	--
	local m_list = {}
	local match = mp:gsub("/$", ""):gsub("([%-%+%.%*])", "%%%1").."/([^/]+)"
	for k, m in pairs(master) do
		local item = k:match(match)
		if item then
			if opts.must_be_wildcard and master[k].style ~= nil then m_list[item] = 1 end
			if opts.allow_container and master[k]["type"] == nil then m_list[item] = 1 end
			if opts.allow_value and master[k]["type"] ~= nil then m_list[item] = 1 end
		end
	end

	--
	-- Now build the main list
	--
	local list = {}

	--
	-- If opts.use_master then add all master items (leave * in at this point)
	--
	if opts.use_master then
		for item,_ in pairs(m_list) do list[item] = { mp=item, kp=item } end
	end

	--
	-- Now add the actuals where we have a match with the m_list so that we only
	-- include containers/values/wildcards as needed
	--
	if opts.use_new then
		local match = kp:gsub("/$", ""):gsub("([%-%+%.%*])", "%%%1").."/(%*?)([^/]+)(.*)"
		for k,_ in pairs(CF_new) do
			local wc, item, rest = k:match(match)
			if not wc or list[item] then goto continue end
	
			if m_list[item] then
				if opts.must_be_wildcard and (item:find("*", 1, true) or rest:find("*", 1, true)) then
					list[item] = { mp=item, kp=item }
				end
				if opts.allow_value or opts.allow_container then list[item] = { mp=item, kp=item } end
			elseif wc == "*" and list["*"] then
				list[item] = { mp="*", kp="*"..item }
			end
::continue::
		end
	end
	for k,t in pairs(list) do
		print("k="..k.." mp="..t.mp.." kp="..t.kp)
	end
	return list
end


--
-- Validate a configpath by running through each element in turn and
-- expanding kp and mp for each node. Build the options at each element
-- so we also prepare for the tab expansion.
--
function cfpath_validator(token, opts)
	if token.samevalue and not token.finalchange then return end

	local kp, mp = "/", "/"
	local value

	-- run through each subtoken
	lib.readline2.reset_state(token)
	local elem = lib.readline2.get_token(token, "/")
	while elem do
		if elem.nochange and not token.finalchange then goto continue end

		-- build options if we don't already have them
		if not elem.options then elem.options = cfpath_options(mp, kp, opts) end

		-- allow "/" for a container (at the token level, not elem)
		if opts.allow_container and token.value == "/" then
			elem.kp, elem.mp = "/", "/"
			set_status(elem, OK)
			goto continue
		end

		-- allow .. to go back
		value = elem.value
		if value:sub(1,1) == "." and mp:match("/[^/]+$") then
			if value == "." then 
				set_status(elem, PARTIAL)
			elseif value == ".." then
				elem.mp, elem.kp = mp:gsub("/[^/]+$", ""), kp:gsub("/[^/]+$", "")
				if #mp == 0 then mp, kp = "/", "/" end
				set_status(elem, OK)
			end
			goto continue
		end

		-- full match?	
		if elem.options[value] then
			elem.mp = lib.config.append_token(mp, elem.options[value].mp)
			elem.kp = lib.config.append_token(kp, elem.options[value].kp)
			set_status(elem, OK)
			goto continue
		end

		-- wildcard match (if use_master)
		if opts.use_master and master[lib.config.append_token(mp, "*")] then
			mp = lib.config.append_token(mp, "*")
			kp = lib.config.append_token(kp, "*"..value)
			local rc, err = VALIDATOR[master[mp].style](value, mp, kp)
			if rc ~= FAIL then
				elem.mp, elem.kp = mp, kp
				set_status(elem, rc)
				goto continue
			end
		end

		-- partial match, can drop through (equiv of break)
		set_status(elem, (next(lib.utils.prefixmatches(elem.options, value)) and PARTIAL) or FAIL)	

::continue::
		if elem.status ~= OK then break end
		mp, kp = elem.mp, elem.kp
		elem = lib.readline2.get_token(token, "/")
	end

	-- if we have other stuff, mark it FAIL
	elem = lib.readline2.get_token(token)
	if elem then set_status(elem, FAIL) end

	-- find the last token, check for PARTIAL at end, then propogate
	elem = token.tokens[#token.tokens]
	if elem.status == PARTIAL and not token.final then set_status(elem, FAIL) end
	set_status(token, elem.status)
end


--
-- Validate any provided flags ... we split into tokens, but if the first one
-- is a partial then we'll remove the kids and mark the parent
--
function flag_validator(token, flags)
	if token.samevalue and not token.finalchange then return end			-- optimise

	--
	-- Set valid options if we don't have them already
	--
	if not token.flagoptions then
		token.flagoptions = {}
		for n, f in pairs(flags) do
			local fname = "--" .. n:gsub("=$", "")
			token.flagoptions[fname] = true
		end
	end
--	token.completer = flag_completer

	--
	-- We have changed, so split the token, into two
	--
	lib.readline2.reset_state(token)
	local flag = lib.readline2.get_token(token, "=")
	local val = lib.readline2.get_token(token)

	--
	-- Process the flag...
	--
	if not flag.samevalue or flag.finalchange then
		if flag.value == "-" or flag.value == "--" then set_status(flag, PARTIAL) goto done end
		if flag.value:sub(1,2) ~= "--" then set_status(flag, FAIL) goto done end

		local item = flag.value:sub(3)
		if val then item = item .. "=" end	
		--
		-- Get the matches (and count them)
		--
		local m = lib.utils.prefixmatches(flags, item)
		local n = lib.utils.count(m)
		if n == 0 then set_status(flag, FAIL) goto done end
		if not flags[item] then set_status(flag, PARTIAL) goto done end
		set_status(flag, OK)
	end

	--
	-- Now the value
	--
	-- TODO: proper validation, this is a dummy 4-digit number validation
	--
	if val and (not val.samevalue or token.finalchange) then
		if val.value:match("^%d*$") then
			if val.value:len() == 4 then
				set_status(val, OK)
			else
				set_status(val, PARTIAL)
			end
		else
			set_status(val, FAIL)
		end
	end

::done::
	--
	-- We need to propogate the status from the last item, also need to handle non-end
	-- of line PARTIAL cases
	--
	if val and val.status == PARTIAL and not token.final then set_status(val, FAIL) end
	if flag.status == PARTIAL and not token.final then set_status(flag, FAIL) end

	if flag.status ~= OK then token.tokens = nil val = nil end
	set_status(token, (val and val.status) or flag.status)
end

CMDS = {}
CMDS["set"] = {
}

CMDS["show"] = {
	usage = "fred",
	flags = {
		["help"] = { 1,2,3 },
		["fast"] = { 3, 4, 5 },
		["mode="] = { "a" },
	},
	args = {
		{ ["type"] = "cfpath", validator = cfpath_validator, optional = nil, 
								opts = { allow_value = 1, allow_container = 1, use_master = 1, use_new = 1 },
		}
	}
}


--
-- TEST CODE ONLY
--
function processCB(state) 
	local token = lib.readline2.get_token(state, "%s")
	local cmd = CMDS[token.value]
	local argn = 1
	local args

	if not cmd then
		set_status(token, FAIL)
		goto restfail
	end

	set_status(token, OK)

	--
	-- Process all the remaining tokens
	--
	args = cmd.args

	--
	-- First handle flags (if present)
	--
	token = lib.readline2.get_token(state, "%s")
	while token and cmd.flags and token.value:sub(1, 1) == "-" do
		flag_validator(token, cmd.flags)
		print("tv=["..token.value.."] status="..token.status)
		if token.status ~= OK then goto restfail end

		token = lib.readline2.get_token(state, "%s")
	end

	--
	-- Now go through the arguments
	--
	while args[argn] do
		local arg = args[argn]
		--
		-- If arg is optional and we don't have a token, then that's ok we just
		-- skip it.
		--
		if not token and arg.optional then goto argnext end

		--
		-- If we have no token here then we haven't got enough args
		--
		if not token then print("NOT ENOUGH") goto done end

		--
		-- At this point we have a token and a matching arg, validate...
		--
		print("Argn="..argn.." type="..arg["type"].." token=["..token.value.."]")
		arg.validator(token, arg.opts)
		if token.status ~= OK then goto restfail end

		-- get the next token
		token = lib.readline2.get_token(state, "%s")

::argnext::
		argn = argn + 1
	end

	--
	-- If we get here and still have a token then we have too much on the 
	-- command line
	--
	if token then
		print("TOO MUCH STUFF")
		goto restfail
	end

::done::
		print("DONE")


::restfail::
	print("RESTFAIL")
	local rest = lib.readline2.get_token(state)
	if rest then
			print("rest: ["..rest.value.."]")
			set_status(rest, FAIL)
	end
end

--local prompt = { value = "prompt > ", len = 9 }
--local history = { "fred", "one two thre", "set /abc/def/ghi" }

--lib.readline2.read_command(prompt, history, processCB, completeCB)


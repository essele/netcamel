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

--
-- TEST CODE ONLY
--
function completeCB(tokens, line, pos)
	local toks = { lib.readline.which_token2(tokens, pos) }
	local ptoken = toks[#toks]

--	print("PTOKEN: "..tostring(ptoken))

--	if ptoken.completer then return ptoken.completer(tokens, ptoken.n, pos) end
	if ptoken.completer then return ptoken.completer(unpack(toks)) end
end

--
-- We have a concept of current directory for the config
--
local __path_kp = "/"
local __path_mp = "/"

function set_path(mp, kp) __path_mp = mp __path_kp = kp end
function get_path() return { mp = __path_mp, kp = __path_kp } end

--
-- Set the status (and colour) of a token
--
local FAIL = 0
local OK = 1
local PARTIAL = 2
local WEIRD = 3
local status_color = { [OK] = "green", [PARTIAL] = "yellow", [FAIL] = "red", [WEIRD] = "blue" }

function set_status(token, status, err)
	if token.status ~= status then
		token.status = status
		token.color = status_color[status]
		token.nochange = nil
		token.err = err

		-- support updating all parent nochange statuses
		local p = token.parent
		while p do p.nochange = nil p = p.parent end
	end	
end

--
--
--
function flag_completer(token, ptoken)
	--
	-- If we are in the flag (i.e. n=1) then give flag options
	--
	if token.n == 1 then
		for k,v in pairs(ptoken.flagoptions) do
			print("OPT: "..k)
		end
		return
	end

	-- TODO: value completion
end

--
-- Work out which options are available for a given mp/kp value and set of options,
-- we store mp,kp and term in the return so we can identify sensible next steps.
--
function cfpath_options(mp, kp, opts)
	--	
	-- Get the full list of master nodes that match mp and the options we have provided
	-- flag if it's a terminal match
	--
	local m_list = {}
	local match = mp:gsub("/$", ""):gsub("([%-%+%.%*])", "%%%1").."/([^/]+)(.*)"
	for k, m in pairs(master) do
		local item, extra = k:match(match)
		if item then
			local set = {
				term = (m_list[item] and m_list[item].term) or (extra==""),
				more = (m_list[item] and m_list[item].more) or (extra:len() > 0)
			}
			if opts.must_be_wildcard and master[k].style ~= nil then m_list[item] = set end
			if opts.allow_container and master[k]["type"] == nil then m_list[item] = set end
			if opts.allow_value and master[k]["type"] ~= nil then m_list[item] = set end
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
		for item,i in pairs(m_list) do list[item] = { mp=item, kp=item, term=i.term, more = i.more } end
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
				local i = m_list[item]
				if opts.must_be_wildcard and (item:find("*", 1, true) or rest:find("*", 1, true)) then
					list[item] = { mp=item, kp=item, term=i.term, more=i.more }
				end
				if opts.allow_value or opts.allow_container then 
					list[item] = { mp=item, kp=item, term=i.term, more=i.more } 
				end
			elseif wc == "*" and m_list["*"] then
				local i = m_list["*"]
				list[item] = { mp="*", kp="*"..item, term=i.term, more=i.more }
			end
::continue::
		end
	end
	return list
end

--
-- Given a token and a list of options handle the standard completer
-- actions (single match, common prefix etc)
--
function standard_completer(token, options)
	local value = token.value
	
	local m = lib.utils.prefixmatches(options, value)
	local n = lib.utils.count(m)

	if n == 0 then return end
	if n > 1 then
		local rc = common_prefix(m)
		if rc:len() > token.cpos then return rc:sub(token.cpos+1) end
		return m
	end
	local key = next(m)
	return key:sub(token.cpos + 1), key, m[key]
end

--
-- The cfpath completer uses a common completer but then adds logic to handle
-- the 'next' item (space or / could be added). Plus some logic for . and ..
--
function cfpath_completer(token, ptoken)
	--
	-- First consider . and ..
	--
	local value = token.value:sub(1, token.cpos)
	if value == "." then return "./" end
	if value == ".." then return "/" end

	--
	-- Now run the standard compeleter
	--
	local opts = ptoken.opts
	local comp, value, match = standard_completer(token, token.options)
	local gap = (opts.gap and " ") or ""

	--
	-- If we didn't fully complete then deal with the two cases, partial or output
	--
	if not match then
		if type(comp) == "table" then return lib.utils.keys_to_values(comp) end
		return comp
	end

	--
	-- If we are not a terminal node then we can add a slash
	--
	if not match.term then return comp .. "/" end

	--
	-- If we have returned something to complete, then we can use it
	--
	if comp:len() > 0 then return comp.. ((match.more and "") or gap) end

	--
	-- This means we have pressed tab again after we've already completed, so
	-- we need to see if we have more...  and add the slash
	--
	return comp .. ((match.more and "/") or gap)
end

--
-- Validator for a file based value
--
function rlv_cffilevalue(token, opts)
	local value = token.value
	
	--
	-- Handle + and -
	--
	if value == "+" or value == "-" then set_status(token, OK) return end
	
	local dirname, basename = value:match("^(/?.-)/?([^/]*)$")
	token.basename = basename
	
	if dirname == "" then dirname = "." end
	if basename == "" then basename = "." end
	
	--
	-- Check the last dirname and populate the filelist if its different
	-- from last time
	--
	if dirname ~= token.dirname then
		local stat = posix.sys.stat.stat(dirname)
		if not stat then set_status(token, FAIL, "invalid path") return end
		token.dirname = dirname
		token.options = {}
		for _,file in ipairs(posix.dirent.dir(dirname)) do
			local stat = posix.sys.stat.stat(dirname.."/"..file)
			if posix.sys.stat.S_ISREG(stat.st_mode) then token.options[file] = 1
			elseif posix.sys.stat.S_ISDIR(stat.st_mode) then token.options[file] = 2 end
		end
	end

	--
	-- See if we match any
	--
	local matches = lib.utils.prefixmatches(token.options, basename)
	if matches[basename] and matches[basename] == 1 then set_status(token, OK) return end
	if not next(matches) then set_status(token, FAIL, "invalid file name") return end
	set_status(token, PARTIAL, "need full path to a file")
end

--
-- Validator for a cfvalue, passes the error (if there is one) back into
-- the token using set_status
--
--
function rlv_cfvalue(token, opts)
	if token.samevalue and not token.finalchange then return end

	local cfindex = (opts and opts.path and opts.path+1) or token.n-1
	local cftoken = token.parent.tokens[cfindex]
	local t = master[cftoken.mp]["type"] or master[cftoken.mp]["style"]

	if opts and opts.only_if_list and not master[cftoken.mp].list then
		set_status(token, FAIL, "value only for list items")
		return
	end

	if t:sub(1,5) == "file/" then
		rlv_cffilevalue(token, opts)
	else
		set_status(token, VALIDATOR[t](token.value, cftoken.mp, cftoken.kp))
	end
end

--
-- Validate a configpath by running through each element in turn and
-- expanding kp and mp for each node. Build the options at each element
-- so we also prepare for the tab expansion.
--
function rlv_cfpath(token, opts)
	if token.samevalue and not token.finalchange then return end

	--
	-- Options from the argument, needed for the completer
	--
	token.opts = opts
	token.completer = cfpath_completer

	local mp, kp = __path_mp, __path_kp
	local value

	if token.value:sub(1,1) == "/" then mp, kp = "/", "/" end

	-- run through each subtoken
	lib.readline.reset_state(token)
	local elem = lib.readline.get_token(token, "/")
	while elem do
		if elem.nochange and not token.finalchange then goto continue end

		-- build options if we don't already have them (or don't have the right set)
		if elem.__okp ~= kp then 
			elem.options = cfpath_options(mp, kp, opts)
			elem.__okp = kp
		end

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
				if #elem.mp == 0 then elem.mp, elem.kp = "/", "/" end
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
		elem = lib.readline.get_token(token, "/")
	end

	-- if we have other stuff, mark it FAIL
	elem = lib.readline.get_token(token)
	if elem then set_status(elem, FAIL) end

	-- find the last token, check for PARTIAL at end, then propogate status, mp and kp
	elem = token.tokens[#token.tokens]
	if elem.status == PARTIAL and not token.final then set_status(elem, FAIL) end
	if elem.status == OK then token.mp, token.kp = elem.mp, elem.kp end
	set_status(token, elem.status, elem.status ~= OK and "invalid configuration path")
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
	token.completer = flag_completer

	--
	-- We have changed, so split the token, into two
	--
	lib.readline.reset_state(token)
	local flag = lib.readline.get_token(token, "=")
	print("flag="..tostring(flag).." p.toks="..tostring(token.tokens))
	local val = lib.readline.get_token(token)

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

	if flag.status ~= OK then token.tokens[2] = nil val = nil end
	set_status(token, (val and val.status) or flag.status)
end

--
-- Simple command completer, but output is done with the cmd descriptions
--
function rlc_cmds(token, ptoken)
	local comp, value, match = standard_completer(token, CMDS)

	if not match then
		if type(comp) == "table" then 
			local rc = { text = 1 }
			if token.value == "" then
				table.insert(rc, "Available Commands")
				table.insert(rc, "------------------")
			end
			for _,k in ipairs(lib.utils.sorted_keys(comp)) do
				table.insert(rc, string.format("%-20.20s %s", k, comp[k].desc or "?"))
			end
			return rc
		end
		return comp
	end
	return comp.." "
end

--
-- TEST CODE ONLY
--
function processCB(state) 
	local token = lib.readline.get_token(state, "%s")
	local cmd = CMDS[token.value]
	local argn = 0

	--
	-- Handle command syntax and completer
	--
	if not cmd then
		token.completer = rlc_cmds
		local m = lib.utils.prefixmatches(CMDS, token.value)
		if next(m) then set_status(token, PARTIAL) goto restfail end
		set_status(token, FAIL)
		goto restfail
	end

	token.cmd = cmd
	set_status(token, OK)

	--
	-- First handle flags (if present)
	--
	if cmd.flags and lib.readline.peek_char(state) == "-" then
		token = lib.readline.get_token(state, "%s")
		flag_validator(token, cmd.flags)
		print("tv=["..token.value.."] status="..token.status)
		if token.status ~= OK then goto restfail end
	end

	--
	-- Process all the remaining tokens
	--
	for _, arg in ipairs(cmd.args) do
		token = lib.readline.get_token(state, (not arg.all and "%s") or nil)
		if not token then break end
	
		arg.validator(token, arg.opts)
		if token.status ~= OK then goto restfail end
		argn = argn + 1
	end

::restfail::
	--
	-- If there is any more stuff (other than empty stuff) then it's wrong
	--
	if lib.readline.peek_char(state) ~= "" then
		local rest = lib.readline.get_token(state)
		set_status(rest, FAIL)
	end

	local fstat = state.tokens[#state.tokens].status
end

--
-- Build the prompt table with colour information for displaying by the
-- readline module.
--
local function build_prompt()
	local path = __path_kp:gsub("%*", "")
	local prompt = {
		{ text = "[", color = "green" },
		{ text = path, color = "blue" },
		{ text = "]", color = "green" },
		{ text = " > ", color = "normal" }
	}
	local len = 0
	for _,i in ipairs(prompt) do len = len + i.text:len() end
	prompt.len = len
	return prompt
end


-- ------------------------------------------------------------------------------
-- MAIN COMMAND LINE ENTRY POINT
--
-- We read all the cmds modules to populate the CMDS table so we can handle
-- any additionally supplied modules
-- ------------------------------------------------------------------------------

local function interactive()
	
	-- Read all the cmds modules if we don't already have them
	if not CMDS then
		CMDS = {}

		for file in posix.dirent.files("cmds") do
			if file:match("%.lua$") then
				print("Loading command module: "..file)
				dofile("cmds/"..file)
			end
		end
	end

	-- Read History
	local history = {}
	local file = io.open("etc/__history", "r")
	if file then
		for h in file:lines() do table.insert(history, h) end
	end

	-- Setup prompt
	local prompt = { value = "prompt > ", len = 9 }

	-- Interact!
	while true do
		local prompt = build_prompt()
		local state = lib.readline.read_command(prompt, history, processCB, completeCB)
		local tokens = state and state.tokens
	
		if not tokens then break end
		if tokens[1].value == "" then goto continue end

		-- update history
		table.insert(history, state.value)

		-- check for valid command
		local cmd = tokens[1].cmd
		if not cmd then print("Unknown command: "..tokens[1].value) goto continue end

		-- remove any trailing empty tokens
		if tokens[#tokens].value == "" then table.remove(tokens) end

		-- check for arg count
		local argc = #tokens - 1
		if argc < cmd.argc.min or argc > cmd.argc.max then
			if cmd.usage then print("Usage: "..cmd.usage)
			else print(string.format("%s: invalid usage", tokens[1].value)) end
			goto continue
		end

		-- check for valid status
		for i=1, #tokens do
			if tokens[i].status ~= OK then
				print(string.format("%s: arg %d: %s", tokens[1].value, i-1, tokens[i].err or "unknown error"))
				goto continue
			end
		end	
	
		-- execute the cmd function
		cmd.func(cmd, state.value, tokens)

::continue::		
	end

	-- TODO: Write history (if it's changed)
end



return {
	interactive = interactive,
	set_path = set_path,
	get_path = get_path,
}



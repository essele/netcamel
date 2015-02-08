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
function process_cfpath(state)
	-- pull the token, return if unchanged
	local path = lib.readline2.get_token(state, "%s")

	if not path or path.samevalue then return end

	-- update accordingly
	lib.readline2.reset_state(path)

	while true do
		local elem = lib.readline2.get_token(path, "/")
		if not elem then break end


		if elem.valid and elem.samevalue then
--			print("no check needed")
		else
--			print("processing")
			elem.valid = true
		end
	end	
end

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
		{ ["type"] = "cfpath", optional = true, allow_value = true }
	}
}

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
		token.stats = status
		token.color = status_color[status]
		token.nochange = nil
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
	
	print("HERE")
	local j = which_subtoken(tokens, n, pos)
	print("j="..j)
	if j == 1 then
		for k,v in pairs(flagtoken.flagoptions) do
			print("OPT: "..k)
		end
	end
end

--
-- Validate any provided flags
--
function flag_validator(token, flags)
	local dash = token.value:sub(1,2)

	--
	-- Make sure we really are a flag...
	--
	if dash ~= "-" and dash ~= "--" then set_status(token, FAIL) return end

	--
	-- Populate a set of options we could be choosing from...
	--
	if not token.flagoptions then
		token.flagoptions = {}
		for n, f in pairs(flags) do
			local fname = "--" .. n:gsub("=$", "")
			token.flagoptions[fname] = true
			print("Added option: "..fname)
		end
	end
	token.completer = flag_completer

	if value == "-" or value == "--" then set_status(token, PARTIAL) return end

	--
	-- Get the parts of the flag
	--
	lib.readline2.reset_state(token)
	local flag = lib.readline2.get_token(token, "=")
	print("Flag="..tostring(flag and flag.value))
	local val = lib.readline2.get_token(token, "=")

	--
	-- See if we need a trailing equals
	--
	local item = flag.value:sub(3)
	if val then item = item .. "=" end

	--
	-- Get the matches (and count them)
	--
	local m = lib.utils.prefixmatches(flags, item)
	local n = lib.utils.count(m)

	if n == 0 then set_status(token, FAIL) return end
	if flags[item] then 	
		set_status(flag, OK)
		if val then 
			if val.value:match("^%d*$") then
				if val.value:len() == 4 then set_status(val, OK)
				else set_status(val, PARTIAL) end
			else
				set_status(val, FAIL) 
			end
		end 
		return 
	end

	--
	-- We can only be partial if we are at the end (i.e. we are still typing)
	--
	set_status(token, (token.final and PARTIAL) or FAIL)
end


--
-- TEST CODE ONLY
--
function processCB(state) 
	local token = lib.readline2.get_token(state, "%s")
	local cmd = CMDS[token.value]
	local argn = 0

	if cmd then
		set_status(token, OK)

		--
		-- Process all the remaining tokens
		--
		local args = cmd.args
		while true do
			token = lib.readline2.get_token(state, "%s")
			if not token then break end
			if token.value == "" then 
				token.completer = usage_completer
				goto continue 
			end

			--
			-- See if we have flags
			--
			if argn == 0 then
				if cmd.flags then
					if token.value:sub(1, 1) == "-" then
						flag_validator(token, cmd.flags)
						goto continue
					end
				end
				argn = 1
			end

			--
			-- Try to match our argument
			--
			print("Looking at ["..token.value.."] for arg type "..args[argn]["type"])

			argn = argn + 1
::continue::
		end
	end


--[[
	if cmd then
		if cmd.value == "set" then
			cmd.color = "green"
			process_cfpath(state)
			if state.tokens and state.tokens[2] and state.tokens[2].tokens and state.tokens[2].tokens[2] then
				state.tokens[2].tokens[2].color = "green"
			end
		else
			cmd.color = "red"
		end
	end

	local rest = lib.readline2.get_token(state)
	if rest then
			print("rest: ["..rest.value.."]")
--			print("rsame: " .. tostring(rest.samevalue))
	end
]]--
end

local prompt = { value = "prompt > ", len = 9 }
local history = { "fred", "one two thre", "set /abc/def/ghi" }

lib.readline2.read_command(prompt, history, processCB, completeCB)


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
lib = { term = dofile("./term.lua") }

-- ==============================================================================
--
-- Requiring this library will cause subsequent modules to be loaded on demand
-- into the lib table.
--
-- ==============================================================================

--
-- Return a token for each call, once we get to the end the flag the end
-- state (calling again is undefined)
--
local function get_token(state, sep)
	sep = sep or "%z"
	local start, finish = state.value:find("[^"..sep.."]+", state.pos)
	if not start then return nil end

	-- update our basic state to past the separator
	state.pos = state.value:find("[^"..sep.."]+", finish + 1)
	state.pos = state.pos or #state.value + 1

	-- update token number and ensure token table setup
	state.n = (state.n and state.n+1) or 1
	state.tokens = state.tokens or {}

	-- see if we have an existing token, if not create a new one
	local token = state.tokens[state.n] or {}
	local value = state.value:sub(start, finish)

	-- set flags for change/nochange
	token.samevalue = value == token.value
	token.nochange = value == token.value and value.begin == start and value.finish == finish

	-- if we have changed value then we need to remove all futures since they need recheck
	if not token.samevalue then
		while state.tokens[state.n+1] do table.remove(state.tokens, state.n+1) end
	end

	token.begin = start
	token.finish = finish
	token.value = value
	token.final = (finish == #state.value)

	-- make sure our state is accurate
	state.tokens[state.n] = token

	return token
end
local function reset_state(state)
	state.pos = nil
	state.n = nil
end


function process_cfpath(state)
	-- pull the token, return if unchanged
	local path = get_token(state, "%s")
	if not path or path.samevalue then return end
	print("path="..path.value)

	-- update accordingly
	reset_state(path)

	while true do
		local elem = get_token(path, "/")
		if not elem then break end

		print("got elem: "..elem.value)

		if elem.valid and elem.samevalue then
			print("no check needed")
		else
			print("processing")
			elem.valid = true
		end
	end	
end



function process(state) 
	reset_state(state)
	local cmd = get_token(state, "%s")
	if cmd.value == "set" then
		process_cfpath(state)

		local rest = get_token(state)
		if rest then
			print("rest: ["..rest.value.."]")
			print("rsame: " .. tostring(rest.samevalue))
		end
	end
end

local state = {
value = "set /bill/fred/joe 1abc 2d$ef 3xzxx 4yyy"
}

print("-----")
process(state)
print("-----")
state.value = "set /bill/fred/joe 1abc 2d$ef 3xzxx 4yyy"
process(state)

lib.term.push("raw")
local line = ""						-- running buffer
local pos = 0						-- cursor pos
while true do
	local x = lib.term.read()
	if x == "q" then break end

	if x == "BACKSPACE" then
		if pos > 0 then	
			pos = pos - 1
		end
	else
		line = line .. x
		pos = pos + 1
	end

	state.value = line
	process(state)

	print()
	lib.term.reset_pos()
	lib.term.output(line)
	lib.term.move_to_pos(pos)
	io.flush()
end
lib.term.pop()



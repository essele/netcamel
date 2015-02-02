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
	-- update token number and ensure token table setup
	state.n = (state.n and state.n+1) or 1
	state.tokens = state.tokens or {}
	sep = sep or "%z"

	-- if previous was last then return nil and clear our old tokesn
	if state.final then
		while state.tokens[state.n] do table.remove(state.tokens, state.n) end
		return nil 
	end

	-- find the token (or empty)
	local start, finish = state.value:find("[^"..sep.."]+", state.pos)
	if not start then start = #state.value + 1 finish = start - 1 end

	-- work out if we are the last and setup pos for next time
	state.final = start == #state.value or finish == #state.value or nil
	state.pos = finish + 1

	-- see if we have an existing token, if not create a new one
	local token = state.tokens[state.n] or {}
	local value = state.value:sub(start, finish)

	-- set flags for change/nochange
	token.samevalue = value == token.value
	token.nochange = value == token.value and token.start == start and token.finish == finish

	-- if we have changed value then we need to remove all futures since they need recheck
	-- if we are the last item then make sure we clear all subsequent old tokens
	if not token.samevalue then
		while state.tokens[state.n+1] do table.remove(state.tokens, state.n+1) end
	end

	token.start = start
	token.finish = finish
	token.value = value
	token.final = state.final

	-- make sure our state is accurate
	state.tokens[state.n] = token

	return token
end
local function reset_state(state)
	state.pos = nil
	state.n = nil
	state.final = nil
end


function process_cfpath(state)
	-- pull the token, return if unchanged
	local path = get_token(state, "%s")

	if not path or path.samevalue then return end

	-- update accordingly
	reset_state(path)

	while true do
		local elem = get_token(path, "/")
		if not elem then break end

--		print("got elem: "..elem.value)

		if elem.valid and elem.samevalue then
--			print("no check needed")
		else
--			print("processing")
			elem.valid = true
		end
	end	
end



function process(state) 
	reset_state(state)
	local cmd = get_token(state, "%s")

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

	local rest = get_token(state)
	if rest then
--			print("rest: ["..rest.value.."]")
--			print("rsame: " .. tostring(rest.samevalue))
	end
end

--
-- String manipulation (should be in utils)
--
function string_insert(s, i, pos)
	return s:sub(1,pos-1) .. i .. s:sub(pos)
end
function string_remove(s, pos, count)
	return s:sub(1,pos-1) .. s:sub(pos+count)
end


--
-- Efficiently output the line working on things that have specifically changed
-- only
--
local function display_line(state, force)
	local function token_output(tokens, value, offset, force)
		local p = 1
		-- process the tokens
		for _,token in ipairs(tokens) do
			if not token.nochange or force then
				lib.term.set_color(token.color or "red")

				-- leading separators
				if token.start > p then
					lib.term.move_to_pos(offset+p-1)
					lib.term.output(value:sub(p, token.start-1))
				end
				if token.tokens then
					token_output(token.tokens, token.value, offset + token.start-1, force)
				else
					lib.term.move_to_pos(offset+token.start-1)
					lib.term.output(token.value)
				end
				lib.term.set_color("default")
			end
			p = token.finish+1
		end
		lib.term.set_color("default")

		-- if we just deleted the last char in the second token and the first one is unchanged
		-- then we won't have output anything, when we clreol we will delete the first token!
	end
	token_output(state.tokens, state.value, 0, force)
	lib.term.move_to_pos(#state.value)
	lib.term.clear_to_eol()
end


lib.term.push("raw")
local line = ""						-- running buffer
local pos = 0						-- cursor pos
local state = {}
while true do
	local oldpos = pos
	local chg = false

	local x = lib.term.read()
	if x == "q" then break end

	if x == "BACKSPACE" then
		if pos > 0 then	line = string_remove(line, pos, 1) chg = true pos = pos - 1 end
	elseif x == "DELETE" then
		if pos < #line+1 then line = string_remove(line, pos+1, 1) chg = true end
	elseif x == "LEFT" then
		if pos > 0 then pos = pos - 1 end
	elseif x == "RIGHT" then
		if pos < #line then pos = pos + 1 end
	else
		line = string_insert(line, x, pos+1) chg = true pos = pos + #x
	end

	if chg then
		state.value = line
		process(state)

	--	lib.term.output(line)
		lib.term.move_to(0, 0)
		display_line(state)
--		lib.term.move_to_pos(#line)

		lib.term.move_to_pos(pos)
	elseif pos ~= oldpos then
		lib.term.move_to_pos(pos)
	end
	io.flush()
end
lib.term.pop()



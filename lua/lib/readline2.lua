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

--
-- Return a token for each call, once we get to the end the flag the end
-- state (calling again is undefined)
--
local function get_token(state, sep)
	-- update token number and ensure token table setup
	state.__n = (state.__n and state.__n+1) or 1
	state.tokens = state.tokens or {}
	sep = sep or "%z"

	-- if previous was last then return nil and clear our old tokesn
	if state.__final then
		while state.tokens[state.__n] do table.remove(state.tokens, state.__n) end
		return nil 
	end

	-- find the token (or empty)
	local start, finish = state.value:find("[^"..sep.."]+", state.__pos)
	if not start then start = #state.value + 1 finish = start - 1 end

	-- work out if we are the last and setup pos for next time, past the seps
	state.__final = start == #state.value or finish == #state.value or nil
--	state.__pos = finish + 1
	local ss, sf = state.value:find("["..sep.."]*", finish+1)
	state.__pos = math.max(ss, sf+1)

	-- see if we have an existing token, if not create a new one
	local token = state.tokens[state.__n] or {}
	local value = state.value:sub(start, finish)

	-- set flags for change/nochange
	token.samevalue = value == token.value
	token.nochange = value == token.value and token.start == start and token.finish == finish
	token.finalchange = token.final ~= state.__final

	-- if we have changed value then we need to remove all futures since they need recheck
	if not token.samevalue then
		while state.tokens[state.__n+1] do table.remove(state.tokens, state.__n+1) end
	end

	token.start = start
	token.finish = finish
	token.value = value
	token.final = state.__final
	token.n = state.__n
	token.parent = state

	-- make sure our state is accurate
	state.tokens[state.__n] = token
	return token
end

--
-- Before we start getting tokens we need to ensure our state is clean
--
local function reset_state(state)
	state.__pos = nil
	state.__n = nil
	state.__final = nil
end

--
-- String manipulation (should be in utils)
--
function string_insert(s, i, pos) return s:sub(1,pos-1) .. i .. s:sub(pos) end
function string_remove(s, pos, count) return s:sub(1,pos-1) .. s:sub(pos+count) end

--
-- Go backwards to the nearest word start
--
local function bword(line, pos)
    if pos <= 1 then return 0 end

    pos = pos - 1
    while pos >= 1 do
        if line:sub(pos+1, pos+1):match("%w") and not line:sub(pos, pos):match("%w") then return pos end
        pos = pos - 1
    end
    return 0
end
--
-- Go to the next non-alpha after an alpha
--
local function fword(line, pos)
	if pos >= line:len() then return pos end
	pos = pos + 1
	while pos < line:len() do
		if not line:sub(pos+1, pos+1):match("%w") and line:sub(pos, pos):match("%w") then return pos end
		pos = pos + 1
	end
	return line:len()
end

--
-- Efficiently output the line working on things that have specifically changed
-- only. We treat all adjacent separators as a single coloured entity and it will
-- be output in its entirely if needed (hence the need for p to be outside the func)
--
local function display_line(prompt, state, force)
	local p = 1
	local value = state.value

	local function token_output(tokens, offset, force)
		-- process the tokens
		for _,token in ipairs(tokens) do
			if not token.nochange or force then
				if token.tokens then
					token_output(token.tokens, offset+token.start-1, force)
				else
					-- leading separators
					lib.term.set_color(token.color or "red")
					if offset+token.start > p then
						lib.term.move_to_pos(prompt.len+p-1)
						lib.term.output(value:sub(p, offset+token.start-1))
					end
					-- main token
					lib.term.move_to_pos(prompt.len+offset+token.start-1)
					lib.term.output(value:sub(offset+token.start, offset+token.finish))
				end
				lib.term.set_color("default")
			end
			p = offset+token.finish+1
		end
		lib.term.set_color("default")
	end

	if prompt.show or force then
		lib.term.move_to_pos(0)
		lib.term.set_color("bright blue")
		lib.term.output(prompt.value)
	end

	token_output(state.tokens, 0, force)
	lib.term.move_to_pos(prompt.len + #state.value)
	lib.term.clear_to_eol()
end

--
-- Read a line in and handle history, as well as syntax and completion
-- callbacks
--
local function read_command(prompt, history, syntax_cb, complete_cb)
	lib.term.push("raw")				-- raw term
	table.insert(history, "")			-- space for our line
	local line, hline = "", ""			-- running buffer, history line
	local pos, oldpos = 0, 0			-- cursor pos
	local state = { value = line }		-- starting point
	local chg = true					-- show prompt first time
	local hpos = #history				-- at end of history

	prompt.show = true					-- show prompt first time

	while true do
		--
		-- Process (syntax_cb) and output the line if needed
		--
		if chg then
			state.value = line
			reset_state(state)
			syntax_cb(state)
			display_line(prompt, state)
			lib.term.move_to_pos(prompt.len + pos)
		elseif pos ~= oldpos then
			lib.term.move_to_pos(prompt.len + pos)
		end
		io.flush()

		--
		-- Reset state variables for the next user input
		--
		oldpos = pos
		chg = false

		--
		-- Process input
		--
		local x = lib.term.read()
		if x == "q" then break end

		if x == "BACKSPACE" then if pos > 0 then line = string_remove(line, pos, 1) chg = true pos = pos - 1 end
		elseif x == "DELETE" then if pos < #line+1 then line = string_remove(line, pos+1, 1) chg = true end
		elseif x == "LEFT" then if pos > 0 then pos = pos - 1 end
		elseif x == "RIGHT" then if pos < #line then pos = pos + 1 end
		elseif x == "UP" or x == "DOWN" then
			if (x == "UP" and hpos > 1) or (x == "DOWN" and hpos < #history) then 
				history[hpos] = line
				hpos = hpos + ((x == "UP" and -1) or 1)
				line = history[hpos] 
				chg = true 
				pos = #line 
			end
		elseif x == "GO_EOL" then pos = #line
		elseif x == "GO_BOL" then pos = 0
		elseif x == "GO_BWORD" then pos = bword(line, pos)
		elseif x == "GO_FWORD" then pos = fword(line, pos)
		elseif x == "INT" then 
			print("^C") 
			lib.term.reset_pos() 
			line, pos, chg, prompt.show = "", 0, true, true
		elseif x == "TAB" then
			local comp = complete_cb(state.tokens, line, pos)
			if type(comp) == "string" then
				line = string_insert(line, comp, pos+1) chg = true pos = pos + comp:len()
			end
		else
			if #x > 1 then x = "?" end
			line = string_insert(line, x, pos+1) chg = true pos = pos + 1
		end
	end
	lib.term.pop()
	table.remove(history)
end

--
-- Given the tokens and a position work out which token we are in so
-- that we can run the completer effectively.
--
local function which_token(tokens, pos)
	for i,token in ipairs(tokens) do
		print("i="..i.." pos="..pos)
		if pos <= token.finish then return i end
	end
	return nil
end
--
-- If we are subtoken'd then given the tokens and main token index
-- and the cursor pos then work out which subtoken.
--
local function which_subtoken(tokens, n, pos)
	return which_token(tokens[n].tokens, pos+1 - tokens[n].start)
end

--
-- Find out which token and return a set of args going back up
-- the whole heirarchy chain
--
local function which_token2(tokens, pos)
	local function wt(tokens, pos)
		for i,token in ipairs(tokens) do
			if pos <= token.finish then return tokens[i] end
		end
		return nil
	end

	local rc = {}
	while tokens do
		local t = wt(tokens, pos)
		if t then 
			t.cpos = pos + 1 - t.start
			table.insert(rc, 1, t) 
			pos = pos + 1 - t.start
		end
		tokens = t and t.tokens
	end
	return unpack(rc)
end

return {
	read_command = read_command,
	get_token = get_token,
	reset_state = reset_state,
	which_token = which_token,
	which_token2 = which_token2,
	which_subtoken = which_subtoken,
}
	

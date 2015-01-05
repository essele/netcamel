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

require("utils")

ffi = require("ffi")
bit = require("bit")
posix = require("posix")



local __row = 0
local __col = 0
local __width = 0
local __height = 0
local __pos = 1

local __prompt
local __promptlen

local __saved_tios
local __sigfd
local __sigint = false
local __sigwinch = false

local FAIL = 0
local OK = 1
local PARTIAL = 2

local __color = {
	[OK] = 2,
	[PARTIAL] = 3,
	[FAIL] = 1
}


-- ------------------------------------------------------------------------------
-- TERMINFO Bits...
-- ------------------------------------------------------------------------------

local ti = {}

ffi.cdef[[
	char *boolnames[], *boolcodes[], *boolfnames[];
	char *numnames[], *numcodes[], *numfnames[];
	char *strnames[], *strcodes[], *strfnames[];

	int setupterm(char *term, int fildes, int *errret);
	char *tigetstr(const char *capname);
	int tigetflag(const char *capname);
	int tigetnum(const char *capname);
	const char *tparm(const char *str, ...);
	int putp(const char *str);
]]


local __libtinfo = ffi.load("ncurses")
local ti = {}
local keymap = {}

function ti.init()
	local rc = __libtinfo.setupterm(nil, 1, nil)

	local i = 0
	while true do
		local cap = __libtinfo.strnames[i]
		if cap == nil then break end
		local fname = ffi.string(__libtinfo.strfnames[i])
		local value = __libtinfo.tigetstr(cap)
		if value ~= nil then ti[fname] = value end
		i = i + 1
	end
	i = 0
	while true do
		local cap = __libtinfo.boolnames[i]
		if cap == nil then break end
		local fname = ffi.string(__libtinfo.boolfnames[i])
		local value = __libtinfo.tigetflag(cap)
		if value == 1 then ti[fname] = true end
		i = i + 1
	end
	i = 0
	while true do
		local cap = __libtinfo.numnames[i]
		if cap == nil then break end
		local fname = ffi.string(__libtinfo.numfnames[i])
		local value = __libtinfo.tigetnum(cap)
		if value >= 0 then ti[fname] = value end
		i = i + 1
	end

	if ti.parm_up_cursor and ti.parm_down_cursor and ti.parm_left_cursor and ti.parm_right_cursor then
		ti.have_multi_move = true
	end

	--
	-- We can also build the keymap here
	--
	keymap = {
		[ffi.string(ti.key_left)] = 		"LEFT",
		[ffi.string(ti.key_right)] = 		"RIGHT",
		[ffi.string(ti.key_up)] = 			"UP",
		[ffi.string(ti.key_down)] = 		"DOWN",
		["\009"] =							"TAB",
		["\127"] =							"BACKSPACE",
		["\n"] =							"ENTER",
		["\003"] =							"INT",			-- Ctr-C
		["\004"] =							"EOF",			-- Ctrl-D
		["\028"] =							"RESIZE",		-- Window Resize
		["\001"] =							"GO_BOL",		-- Ctrl-A beginning of line
		["\002"] =							"LEFT",			-- Ctrl-B back one char
		["\005"] =							"GO_EOL",		-- Ctrl-E end of line
		["\006"] =							"RIGHT",		-- Ctrl-F forward one char
	}
	--
	-- VT100 doesn't have a delete key???
	--
	if ti.key_dc then
		keymap[ffi.string(ti.key_dc)] = "DELETE"
	end
end

--
-- Equivalent of putp(tparm(...)) but we need to convert any numbers
-- into proper ints.
--
function ti.out(str, ...)
	if not ... then
		__libtinfo.putp(str)
		return
	end
	local args = {...}
	for i,arg in ipairs(args) do
		if type(arg) == "number" then args[i] = ffi.new("int", arg) end
	end
	__libtinfo.putp(__libtinfo.tparm(str, unpack(args)))
end
function ti.tparm(str, ...)
	local args = {...}
	for i,arg in ipairs(args) do
		if type(arg) == "number" then args[i] = ffi.new("int", arg) end
	end
	return ffi.string(__libtinfo.tparm(str, unpack(args)))
end


-- ------------------------------------------------------------------------------
-- SIMPLE TOKENISER
-- ------------------------------------------------------------------------------

local function tokenise(tokens, input, sep, offset)
	offset = offset or 0
	local token = nil
	local inquote, backslash = false, false
	local allow_inherit = true
	local token_n = 0

	for i=1, input:len()+1 do
		local ch = input:sub(i,i)

		--
		-- If we get a space outside of backslash or quote then
		-- we have found a token
		--
		if ch == "" or (ch == sep and not backslash and not inquote) then
			if token and token.value ~= "" then
			
				-- do we need?
				if ch == "" then token.sep = nil else token.sep = ch end

				if tokens[token_n] then
					if tokens[token_n].value ~= token.value then
						tokens[token_n].status = nil
						tokens[token_n].value = token.value
					end
					tokens[token_n].start = token.start
					tokens[token_n].finish = token.finish
				else
					tokens[token_n] = token
				end
				token = nil
			end
		else
			--
			-- Any other character now is part of the token
			--
			if not token then
				token = {}
				token.value = ""
				token.start = i + offset
				token_n = token_n + 1
			end
			token.value = token.value .. ch
			token.finish = i + offset

			--
			-- If we get a quote, then it's either in our out of
			-- quoted mode (unless its after a backslash)
			--
			if ch == "\"" and not backslash then
				inquote = not inquote
			end

			if backslash then
				backslash = false
			end

			if ch == "\\" then backslash = true end
		end
	end

	--
	-- Tidy up if we used to have more tokens...
	--
	while #tokens > token_n do table.remove(tokens) end

	--
	-- If we have nothing, or something with a trailing space then we add
	-- a dummy token so that we can use it for 'next token' completion
	--
	if token_n == 0 or input:sub(-1) == sep then
		table.insert(tokens, { value = "", start = offset+input:len()+1, finish = offset+input:len()+1 })
	end

	return tokens
end

-- ------------------------------------------------------------------------------
-- For supporting save and restore of termios
-- ------------------------------------------------------------------------------
--

local function init()
	--
	-- Make the required changes to the termios struct...
	--
	print("INIT")
	__saved_tios = posix.tcgetattr(0)
	local tios = posix.tcgetattr(0)
	tios.lflag = bit.band(tios.lflag, bit.bnot(posix.ECHO))
	tios.lflag = bit.band(tios.lflag, bit.bnot(posix.ICANON))
	posix.tcsetattr(0, posix.TCSANOW, tios)

	--
	--
	-- Setup the signal filehandle so we can receive
	-- the window size change signal and adjust accordingly
	--
	-- SIGWINCH
	posix.signal(28, function() __sigwinch = true end)
	posix.signal(2, function() __sigint = true end)

	ti.init()
	ti.out(ti.keypad_xmit)

	__width = ti.columns
	__height = ti.lines
end
local function finish()
	posix.tcsetattr(0, posix.TCSANOW, __saved_tios)
end


--
-- Wait up to a maximum time for a character, return the char
-- and how much time is left (or nil if we didn't get one)
--
local function getchar(ms)
	local fds = {
		[0] = { events = { IN = true }},
	}

	local before = posix.gettimeofday()
	local rc, err = posix.poll(fds, ms)

	if not rc then
		-- Interrupted system call probably, most likely
		-- a window resize, so if we return nil then we will
		-- cause a redraw
		if __sigint then __sigint = false return "\003" end
		if __sigwinch then __sigwinch = false return "\028" end
		print("nil")
		return nil, 0
	end
	
	if rc < 1 then return nil, 0 end
	local after = posix.gettimeofday()

	local beforems = before.sec * 1000 + math.floor(before.usec/1000)
	local afterms = after.sec * 1000 + math.floor(after.usec/1000)

	ms = ms - (afterms - beforems)
	ms = (ms < 0 and 0) or ms

	--
	-- If we get here it will be a key...
	--
	if fds[0].revents.IN then
		local char, err = posix.read(0, 1)
		if not char then
			print("Error reading char: " .. err)
			return nil
		end
		return char, ms
	end
	return nil
end

--
-- Read a character (or escape sequence) from stdin
--
local function read_key()
	local buf = ""
	local remaining = 0
	
	local c, time = getchar(-1)
	if c ~= "\027" then return keymap[c] or c end

	buf = c
	remaining = 300
	while true do
		local c, time = getchar(remaining)
		if not c then return keymap[buf] or buf end

		remaining = time

		buf = buf .. c
		if #buf == 2 and c == "[" then goto continue end
		if #buf == 2 and c == "O" then goto continue end

		local b = string.byte(c)
		if string.byte(c) >= 64 and string.byte(c) <= 126 then 
			return keymap[buf] or buf
		end
::continue::
	end
end

local function move_to(r, c)
	if ti.have_multi_move then
		if r > __row then ti.out(ti.parm_down_cursor, r-__row) end
		if r < __row then ti.out(ti.parm_up_cursor, __row-r) end
		if c > __col then ti.out(ti.parm_right_cursor, c-__col) end
		if c < __col then ti.out(ti.parm_left_cursor, __col-c) end
		__row, __col = r, c
	else
		while r > __row do ti.out(ti.cursor_down) __row = __row + 1 end
		while r < __row do ti.out(ti.cursor_up) __row = __row - 1 end
		if math.abs(__col - c) then ti.out(ti.carriage_return) __col = 0 end
		while c > __col do ti.out(ti.cursor_right) __col = __col + 1 end
		while c < __col do ti.out(ti.cursor_left) __col = __col - 1 end
	end
end

--
-- We need to track our position relative to the start of the line
-- where the input started.
--

local function move_back()
	if __col == 0 then
		ti.out(ti.cursor_up)
		if ti.have_multi_move then ti.out(ti.parm_right_cursor, __width-1)
		else for i=1,#width-1 do ti.out(ti.cursor_right) end end
		__col = __width - 1
		__row = __row - 1
	else
		ti.out(ti.cursor_left)
		__col = __col -1
	end
end

local function row_and_col_from_pos(pos)
	return math.floor(pos/__width), pos%__width
end

--
-- If just n is specified then move right that amount (using ti.cursor right)
-- If string is specified with n, then output the string and move right n.
-- (That allows for embedded colour etc.)
-- If nothing is specified then move right one.
--
local function move_on(n, str)
	n = n or 1

	if n == 0 then return end

	if not str then
		if ti.have_multi_move then ti.out(ti.parm_right_cursor, n) else
		ti.out(string.rep(ffi.string(ti.cursor_right), n)) end
	else
		ti.out(str)
	end

--[[
	local npos = __col + n
	local extra_rows = math.floor(npos/__width)
	local final_col = npos % __width

	__col = final_col
	__row = __row + extra_rows
--]]
	__row, __col = row_and_col_from_pos(__col + n)

	if (n > 0 and __col == 0) and ti.auto_right_margin then
		if ti.eat_newline_glitch then ti.out(ti.carriage_return) end
		ti.out(ti.carriage_return)
		ti.out(ti.cursor_down)
	end
end

--
-- If we have color support then work out what colours are needed for the
-- given token
--
local function colourise_token(token, sep)
	local color = ti.set_a_foreground and token.status and 
								ti.tparm(ti.set_a_foreground, __color[token.status])
	local stdcolor = (color and ti.tparm(ti.set_a_foreground, 9)) or ""
	color = color or ""

	local rc = ""
	if ti.set_a_foreground and token.status then
		return ti.tparm(ti.set_a_foreground, __color[token.status])..sep..token.value..ti.tparm(ti.set_a_foreground, 9)
	else
		return sep..token.value
	end
end

--
-- Try to efficiently show a line based on which tokens have changed and therefore need to be
-- redrawn.
--
local function show_line(tokens, input, offset, force)
	function show_token_list(tokens, input, offset, force, p, lop)
		for i, token in ipairs(tokens) do
			if token.subtokens then 
				p, lop = show_token_list(token.subtokens, input, offset, force, p, lop)
			else
				local hash = string.format("%d/%d/%s", token.start, token.status, token.value)
				if token.hash ~= hash or force then
					-- 
					-- If we are not sequential then we need to go the the right place
					--
					if p > lop+1 then 
						local r, c = row_and_col_from_pos((p-1)+offset)
						move_to(r, c)
					end
					--
					-- We will output the separator if needed
					--
					local sep = (p < token.start and input:sub(p, token.start-1)) or ""
					--
					-- And finally the actual token
					--
					move_on(token.value:len() + sep:len(), colourise_token(token, sep))
					token.hash = hash
					lop = token.start + token.value:len()
				end
				p = token.start + token.value:len()
			end
		end
		return p, lop
	end
	local p, lop = show_token_list(tokens, input, offset, force, 1, -1)
	if lop == 1 or lop == #input+1 then
		ti.out(ti.clr_eol)
	end
end




local function redraw_line(tokens, input, full_redraw)
	ti.out(ti.cursor_invisible)

	if full_redraw then
		move_to(0,0)
		move_on(__promptlen, __prompt)
	end
	show_line(tokens, input, __promptlen, full_redraw)

	move_to(row_and_col_from_pos((__pos-1) + __promptlen))
	ti.out(ti.cursor_normal)
end

local function clear_line(input)
	local lastrow = math.floor(input:len()/__width)
	for i = lastrow, 0, -1 do
		move_to(i,0)
		ti.out(ti.clr_eol)
	end
end

local function handle_resize()
	--
	-- Re-setup and update the ti database accordingly
	--
	local rc = __libtinfo.setupterm(nil, 1, nil)
	assert(rc == 0, "unable to re-setupterm in winch_handler")

	ti.columns = __libtinfo.tigetnum("cols")
	ti.lines = __libtinfo.tigetnum("lines")

	--
	-- Update our view of the size
	--
	__width = ti.columns
	__height = ti.lines

	--
	-- Work out how far down we are now likely to be, then move back up that many lines
	-- and clear to EOS.
	--
	-- Different terminals handle this differently so we've just do the best we can.
	--
	local r, c = row_and_col_from_pos((__pos-1) + __promptlen)
	ti.out(ti.carriage_return)

	__row, __col = r, 0
	move_to(0, 0)
	ti.out(ti.clr_eos)
end


--
-- Given a set of tokens and a position return the index and
-- prefix for the token
--
local function which_token(tokens, pos)
	for i,token in ipairs(tokens) do
		if pos >= token.start and pos <= (token.finish+1) then
			return i, token.value:sub(1, pos - token.start)
		end
	end
	print("WARNING: which_token no token matches")
	return #tokens+1, ""
end

--
-- Flag all following as failed, also clear the subtokens since
-- they won't be valid unless we know what we are doing.
--
local function mark_all(tokens, n, value)
	while tokens[n] do
		tokens[n].status = value
		tokens[n].subtokens = nil
		tokens[n].completer = nil
		n =n + 1
	end
end

--
--
--
--


local function readline(prompt, history, syntax_func, completer_func)
	table.insert(history, "")
	local hindex = #history
	local line = ""
	local tokens = {}
	local needs_redraw = true
	local needs_full_redraw = true
	__row, __col, __pos = 0, 0, 1

	--
	-- Build the prompt
	--
	__prompt, __promptlen = "", 0
	for pelem in each(prompt) do
		if ti.set_a_foreground then
			__prompt = __prompt .. ti.tparm(ti.set_a_foreground, pelem.clr) .. pelem.txt
		else
			__prompt = __prompt .. pelem.txt
		end
		__promptlen = __promptlen + pelem.txt:len()
	end
	if ti.set_a_foreground then __prompt = __prompt .. ti.tparm(ti.set_a_foreground, 9) end

	while true do
		--
		-- we will redraw up front...
		--
		if needs_redraw or needs_full_redraw then
			--
			-- Build list of tokens
			--
			tokenise(tokens, line, " ")

			if syntax_func then syntax_func(tokens, line) end

			redraw_line(tokens, line, needs_full_redraw)
			needs_redraw = false
			needs_full_redraw = false
		end
		io.flush()


		--
		-- Now process key presses...
		--
		local c = read_key()
		if c == nil then 
			needs_redraw = true
			goto continue 
		end

		if c:len() == 1 then
			if c == "q" then break end
			line = string_insert(line, c, __pos)
			__pos = __pos + 1
			needs_redraw = true
		elseif c == "UP" then
			--
			-- Keep our edits for the last in history
			--
			if hindex == #history then
				history[hindex] = line
			end
			--
			-- Move back...
			--
			if hindex > 1 then
				clear_line(line)
				hindex = hindex - 1
				tokens = {}
				line = history[hindex]
				__pos = #line + 1
				needs_full_redraw = true
			end
		elseif c == "DOWN" then
			if hindex < #history then
				clear_line(line)
				hindex = hindex + 1
				tokens = {}
				line = history[hindex]
				__pos = #line + 1
				needs_full_redraw = true
			end
		elseif c == "LEFT" then 
			if __pos > 1 then
				move_back()
				__pos = __pos - 1
			end
		elseif c == "RIGHT" then 
			if __pos <= line:len() then
				move_on()
				__pos = __pos + 1
			end
		elseif c == "BACKSPACE" then
			if __pos > 1 then
				line = string_remove(line, __pos-1, 1)
				__pos = __pos - 1
				needs_redraw = true
			end
		elseif c == "TAB" then
			if completer_func then
				local rc = completer_func(tokens, line, __pos)
				if type(rc) == "string" then
					line = string_insert(line, rc, __pos)
					__pos = __pos + rc:len()
					needs_redraw = true
				elseif rc then
					ti.out(ti.carriage_return)
					ti.out(ti.cursor_down)
					__col, __row = 0, 0
					for _,m in ipairs(rc) do
						ti.out(m .. "\n")
					end
					needs_full_redraw = true
				end
			end
		elseif c == "ENTER" then
			--
			-- Remove history (we process outside)
			--
			table.remove(history)
			ti.out(ti.carriage_return)
			ti.out(ti.cursor_down)
			return line, tokens
		elseif c == "INT" then
			ti.out("^C")
			ti.out(ti.carriage_return)
			ti.out(ti.cursor_down)
			__row, __col = 0, 0
			__pos = 1
			line = ""
			needs_full_redraw = true
		elseif c == "RESIZE" then
			handle_resize()
			needs_full_redraw = true
		elseif c == "GO_BOL" then
			__pos = 1
			needs_redraw = true
		elseif c == "GO_EOL" then
			__pos = #line + 1
			needs_redraw = true
		elseif c == "DELETE" or c == "EOF" then
			if __pos <= line:len() then
				line = string_remove(line, __pos, 1)
				needs_redraw = true
			elseif c == "EOF" and __pos == 1 and line == "" then 
				ti.out(ti.carriage_return)
				ti.out(ti.cursor_down) 
				return nil 
			end
		end

::continue::
	end
end

return {
	readline = readline,
	mark_all = mark_all,
	which_token = which_token,
	tokenise = tokenise,
	
	init = init,
	finish = finish,
}


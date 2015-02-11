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

local ffi = require("ffi")
local bit = require("bit")

local __sigwinch = false
local __sigint = false
local __width
local __height
local __row = 0
local __col = 0

-- ------------------------------------------------------------------------------
-- TERMINFO Bits...
--
-- Build an array of all of the terminfo capabilities so we can query and use
-- them as needed
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

local libtinfo = ffi.load("ncurses")
local ti = {}
local keymap = {}

--
-- Initialise all the terminfo and keymap data
--
local function ti_init()
	local rc = libtinfo.setupterm(nil, 1, nil)

	local i = 0
	while true do
		local cap = libtinfo.strnames[i]
		if cap == nil then break end
		local fname = ffi.string(libtinfo.strfnames[i])
		local value = libtinfo.tigetstr(cap)
		if value ~= nil then ti[fname] = value end
		i = i + 1
	end
	i = 0
	while true do
		local cap = libtinfo.boolnames[i]
		if cap == nil then break end
		local fname = ffi.string(libtinfo.boolfnames[i])
		local value = libtinfo.tigetflag(cap)
		if value == 1 then ti[fname] = true end
		i = i + 1
	end
	i = 0
	while true do
		local cap = libtinfo.numnames[i]
		if cap == nil then break end
		local fname = ffi.string(libtinfo.numfnames[i])
		local value = libtinfo.tigetnum(cap)
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
		["\000"] =							"WATCH",
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
		["\027f"] =							"GO_FWORD",		-- Alt-F forward one word
		["\027b"] = 						"GO_BWORD",		-- Alt-B backward one work
		["\027"] =							"ESCAPE",
	}
	--
	-- VT100 doesn't have a delete key???
	--
	if ti.key_dc then keymap[ffi.string(ti.key_dc)] = "DELETE" end
end

--
-- Equivalent of putp(tparm(...)) but we need to convert any numbers
-- into proper ints.
--
function ti.out(str, ...)
	if not ... then
		libtinfo.putp(str)
		return
	end
	local args = {...}
	for i,arg in ipairs(args) do
		if type(arg) == "number" then args[i] = ffi.new("int", arg) end
	end
	libtinfo.putp(libtinfo.tparm(str, unpack(args)))
end
function ti.tparm(str, ...)
	local args = {...}
	for i,arg in ipairs(args) do
		if type(arg) == "number" then args[i] = ffi.new("int", arg) end
	end
	return ffi.string(libtinfo.tparm(str, unpack(args)))
end

-- ------------------------------------------------------------------------------
-- For supporting save and restore of termios, we use a push and pop construct
-- with push taking a mode argument ("normal" or "raw") when we pop we attempt
-- to put everything back to the state it was prior to the push.
-- ------------------------------------------------------------------------------
local tio_stack = {}

local function push(mode)
	local state = {}
	
	state.tios = posix.termio.tcgetattr(0)
	state.lastmode = (tio_stack[1] and tio_stack[1].mode) or "normal"
	state.mode = mode

	local tios = posix.termio.tcgetattr(0)
	if mode == "normal" then
		ti.out(ti.keypad_local)
		tios.lflag = bit.bor(tios.lflag, posix.termio.ECHO)
		tios.lflag = bit.bor(tios.lflag, posix.termio.ICANON)
	else
		ti.out(ti.keypad_xmit)
		tios.lflag = bit.band(tios.lflag, bit.bnot(posix.termio.ECHO))
		tios.lflag = bit.band(tios.lflag, bit.bnot(posix.termio.ICANON))
	end
	posix.termio.tcsetattr(0, posix.termio.TCSANOW, tios)
	table.insert(tio_stack, 1, state)
end

local function pop()
	local state = table.remove(tio_stack, 1)
	
	posix.termio.tcsetattr(0, posix.termio.TCSANOW, state.tios)

	if state.lastmode == "normal" then
		ti.out(ti.keypad_local)
	else
		ti.out(ti.keypad_xmit)
	end	
end

--
-- current time in milliseconds
--
local function now()
	local timeval = posix.sys.time.gettimeofday()
	return math.floor((timeval.tv_sec * 1000) + (timeval.tv_usec/1000))
end

-- ------------------------------------------------------------------------------
-- Read a char (or sequence) from stdin, we also support other filehandles
-- for reading other things in parallel.
-- ------------------------------------------------------------------------------
local function read()
	local buf
	--
	-- Wait indefinitely for our first char (or other fh), if it's an escape
	-- then wait a max time for the remainder of the sequence
	--
	local fds = {
		[0] = { events = { IN = true } },
	}

	local rc = posix.poll.poll(fds, -1)
	if not rc then
		-- Interruped system call SIGINT or SIGWINCH
		if __sigint then __sigint = false return keymap["\003"] end
		if __sigwinch then __sigwinch = false return keymap["\028"] end
		print("nil")
		return nil
	end

	if fds[0].revents then
		buf = posix.unistd.read(0, 1)
	end
	if buf ~= "\027" then return keymap[buf] or buf end

	-- We have an escape sequence we need to read...
	local time = 200
	while time > 0 do
		local before = now()
		if posix.poll.poll(fds, time) == 0 then break end

		local c = posix.unistd.read(0, 1)
		buf = buf .. c

		-- detect end, but not for two special cases...
		if not(#buf == 2 and (c == "[" or c == "O")) then
			if string.byte(c) >= 64 and string.byte(c) <=128 then break end
		end
		time = time - (now() - before)
	end
	return keymap[buf] or buf
end

--
-- Helper row and col function
--
local function row_and_col_from_pos(pos)
	return math.floor(pos/__width), pos%__width
end

-- ------------------------------------------------------------------------------
-- Routine to output some text and update the __row and __col vars accordingly
-- ------------------------------------------------------------------------------
local function output(str)
	local n = #str
	local newpos = (__row * __width) + __col + n

	ti.out(str)
		
	__row, __col = row_and_col_from_pos(newpos)

	if (n > 0 and __col == 0) and ti.auto_right_margin then
		if ti.eat_newline_glitch then ti.out(ti.carriage_return) end
		ti.out(ti.carriage_return)
		ti.out(ti.cursor_down)
	end
end

-- ------------------------------------------------------------------------------
-- Move to a specfic row and col given where we are currently, try to be efficient
-- ------------------------------------------------------------------------------
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
		if math.abs(__col - c) > c then ti.out(ti.carriage_return) __col = 0 end
		while c > __col do ti.out(ti.cursor_right) __col = __col + 1 end
		while c < __col do ti.out(ti.cursor_left) __col = __col - 1 end
	end
end
local function move_to_pos(pos) move_to(row_and_col_from_pos(pos)) end

--
-- If we do something that puts the cursor back at the start then we need a way
-- to tell the term code.
--
local function reset_pos() __row, __col = 0, 0 end

-- 
-- Send a clr_eol, used by the readline code to properly display editable command
-- lines
--
local function clear_to_eol() ti.out(ti.clr_eol) end

--
-- Colours for set_color()
--
local __color = {
	black = 0,
	red = 1,
	green = 2,
	yellow = 3,
	blue = 4,
	magenta = 5,
	cyan = 6,
	white = 7,
	default = 9,
}
local __last_color = "default"
local __last_bold = false

--
-- Change the colour of the subsequent text, but optimised to only do this
-- if the previous colour was different.
--
-- We also support "bright <colour>" to use the brighter versions, unfortunately
-- there is no way to turn off bold so we have to exit all attributes.
--
local function set_color(c)
	if ti.set_a_foreground then
		local bold = (c:sub(1,7) == "bright ")
		local color = c:match("([^%s]+)$") or "default"

		if bold ~= __last_bold then
			if bold then ti.out(ti.enter_bold_mode)
			else ti.out(ti.exit_attribute_mode) __last_color = "default" end
			__last_bold = bold
		end

		if color ~= __last_color then
			ti.out(ti.tparm(ti.set_a_foreground, __color[color]))
			__last_color = color
		end
	end
end

--
-- For column drawing etc
--
local function get_width() return __width end

-- ------------------------------------------------------------------------------
-- Setup the ti stuff automatically when we are accessed
-- ------------------------------------------------------------------------------

ti_init()
posix.signal.signal(28, function() __sigwinch = true end)
posix.signal.signal(2, function() __sigint = true end)
__width = ti.columns
__height = ti.lines

return {
	push = push,
	pop = pop,
	read = read,
	output = output,
	move_to = move_to,
	move_to_pos = move_to_pos,
	reset_pos = reset_pos,
	clear_to_eol = clear_to_eol,
	set_color = set_color,
	width = get_width,
}


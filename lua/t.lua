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
package.path = "/usr/share/lua/5.1/?.lua"
package.cpath = "/usr/lib/lua/5.1/?.so;./lib/?.so;./c/?.so"

package.path = "./lib/?.lua"
package.cpath = "./lib/?.so;./c/?.so"

--require("readline")

ffi = require("ffi")
bit = require("bit")

-- ------------------------------------------------------------------------------
-- TERMINFO Bits...
-- ------------------------------------------------------------------------------

local ti = {}

ffi.cdef[[
	char *boolnames[], *boolcodes[], *boolfnames[];
	char *numnames[], *numcodes[], *numfnames[];
	char *strnames[], *strcodes[], *strfnames[];

	int setupterm(char *term, int fildes, int *errret);
	char *tigetstr(char *capname);
	int tigetflag(char *capname);
	int tigetnum(char *capname);
	const char *tparm(const char *str, ...);
	int putp(const char *str);
]]


local __libtinfo = ffi.load("tinfo")
local ti = {}
local keymap = {}

function ti.init()
	local err = ffi.new("int [1]", 0)
	local rc = __libtinfo.setupterm(nil, 1, err)
	print("rc="..rc)
	print("err="..err[0])

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
		["\127"] =							"DELETE",
	}
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

--print("CAP: " .. __libtinfo_caps["set_a_foreground"])

--local p = ffi.new("int", 2)
--local x = __libtinfo.tparm(set_a_foreground, p)
--print(":" .. ffi.string(x))
--

ffi.cdef[[
	typedef unsigned char   cc_t;
	typedef unsigned int    speed_t;
	typedef unsigned int    tcflag_t;

	struct termios
	  {
		tcflag_t c_iflag;		/* input mode flags */
		tcflag_t c_oflag;		/* output mode flags */
		tcflag_t c_cflag;		/* control mode flags */
		tcflag_t c_lflag;		/* local mode flags */
		cc_t c_line;			/* line discipline */
		cc_t c_cc[32];			/* control characters */
		speed_t c_ispeed;		/* input speed */
		speed_t c_ospeed;		/* output speed */
	  };
	enum {
		ICANON = 2,
		ECHO = 000010
	};
	enum {
		TCGETS = 0x5401,
		TCSETS = 0x5402,
		TIOCGWINSZ = 0x5413
	};
	int ioctl(int d, int request, void *p);

	struct winsize {
		unsigned short ws_row;
		unsigned short ws_col;
		unsigned short ws_xpixel;
		unsigned short ws_ypixel;
	};

	typedef unsigned long int nfds_t;
	struct pollfd {
		int fd;
		short events;
		short revents;
	};
	enum {
		POLLIN = 0x0001
	};
	int poll(struct pollfd *fds, nfds_t nfds, int timeout);

	typedef int		clockid_t;
	typedef long		time_t;
	struct timespec {
		time_t	tv_sec;
		long	tv_nsec;
	};
	int clock_gettime(clockid_t clk_id, struct timespec *tp);
	enum {
		CLOCK_MONOTONIC = 1
	};

	// This size could be wrong on 32bit??
	typedef unsigned long 	size_t;
	typedef long			ssize_t;
	ssize_t read(int fd, void *buf, size_t count);

	typedef struct
	  {
		unsigned long int __val[(1024 / (8 * sizeof (unsigned long int)))];
	  } __sigset_t;
	typedef __sigset_t sigset_t;
	int signalfd(int fd, const sigset_t *mask, int flags);
	int sigemptyset(sigset_t *set);
	int sigaddset(sigset_t *set, int signum);
	int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
	enum {
		SIG_BLOCK = 0,
		SIGWINCH = 28
	};
	struct signalfd_siginfo {
		uint32_t ssi_signo;
		uint8_t pad[124];
	};
]]
local rt = ffi.load("rt")

--
-- For supporting save and restore of termios
--
local __tios = ffi.new("struct termios")
local __sigfd

function init()
	--
	-- Make the required changes to the termios struct...
	--
	local __new_tios = ffi.new("struct termios")
	local rc = ffi.C.ioctl(0, ffi.C.TCGETS, __tios)
	assert(rc == 0, "unable to ioctl(TCGETS)")
	ffi.copy(__new_tios, __tios, ffi.sizeof(__tios))
	__new_tios.c_lflag = bit.band(__new_tios.c_lflag, bit.bnot(ffi.C.ECHO))
	__new_tios.c_lflag = bit.band(__new_tios.c_lflag, bit.bnot(ffi.C.ICANON))
	local rc = ffi.C.ioctl(0, ffi.C.TCSETS, __new_tios)
	assert(rc == 0, "unable to ioctl(TCSETS)")

	--
	-- Setup the signal filehandle so we can receive
	-- the window size change signal in the read loop...
	--
	local set = ffi.new("sigset_t [1]")
	ffi.C.sigemptyset(set)
	ffi.C.sigaddset(set, ffi.C.SIGWINCH)
	__sigfd = ffi.C.signalfd(-1, set, 0)
	local rc = ffi.C.sigprocmask(ffi.C.SIG_BLOCK, set, nil)
	print("SPM="..rc)

end
function finish()
	local rc = ffi.C.ioctl(0, ffi.C.TCSETS, __tios)
	assert(rc == 0, "unable to ioctl(TCSETS)")
end


--
-- Wait up to a maximum time for a character, return the char
-- and how much time is left (or nil if we didn't get one)
--
function getchar(ms)
	local before = ffi.new("struct timespec")
	local after = ffi.new("struct timespec")
	local fds = ffi.new("struct pollfd [?]", 2)
	
	fds[0].fd = 0
	fds[0].events = ffi.C.POLLIN
	fds[0].revents = 0

	fds[1].fd = __sigfd
	fds[1].events = ffi.C.POLLIN
	fds[1].revents = 0

	rt.clock_gettime(ffi.C.CLOCK_MONOTONIC, before)
	local rc = ffi.C.poll(fds, 2, ms)
	if rc == 0 then return nil, 0 end
	rt.clock_gettime(ffi.C.CLOCK_MONOTONIC, after)

	local beforems = tonumber(before.tv_sec)*100 + 
					math.floor(tonumber(before.tv_nsec)/1000000)
	local afterms = tonumber(after.tv_sec)*100 + 
					math.floor(tonumber(after.tv_nsec)/1000000)

--	ms = ms - math.floor(((after.tv_sec - before.tv_sec)*100) + ((after.tv_nsec - before.tv_nsec)/1000000))
	ms = ms - (afterms - beforems)
	ms = (ms < 0 and 0) or ms

	--
	-- If we have a window size event, then return "SIGWINCH"
	--
	if fds[1].revents == ffi.C.POLLIN then
		local sig = ffi.new("struct signalfd_siginfo")
		local rc = ffi.C.read(__sigfd, sig, 128)
		return "SIGWINCH"
	end

	--
	-- Otherwise it will be a key...
	--
	if fds[0].revents == ffi.C.POLLIN then
		local char = ffi.new("char [1]")
		local rc = ffi.C.read(0, char, 1)
		if rc ~= 1 then
			print("READ CHAR rc="..rc)
		end
		return ffi.string(char, 1), ms
	end
	return nil
end

--
-- Read a character (or escape sequence) from stdin
--
function read_key()
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

ti.init()
for k,v in pairs(ti) do
--	print("k="..k.." v="..tostring(v))
end
init()

function hex(s) 
	for i=1,s:len() do
		io.write(string.format("%02x ", string.byte(s,i)))
	end
	io.write("\n")
end


--
-- Initialise the terminal and make sure we are in app mode so
-- the cursor keys work as expected.
--
ti.out(ti.init_2string)
ti.out(ti.keypad_xmit)

--
-- We need to track our position relative to the start of the line
-- where the input started.
--
local __row = 0
local __col = 0
local __srow = 0
local __scol = 0
local __width = ti.columns
local __height = ti.lines
local __line = ""
local __pos = 1

function move_back()
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

--
-- If just n is specified then move right that amount (using ti.cursor right)
-- If string is specified with n, then output the string and move right n.
-- (That allows for embedded colour etc.)
-- If nothing is specified then move right one.
--
function move_on(n, str)
	n = n or 1

	if not str then
		if ti.have_multi_move then ti.out(ti.parm_right_cursor, n) else
		ti.out(string.rep(ffi.string(ti.cursor_right), n)) end
	else
		ti.out(str)
	end

	local npos = __col + n
	local extra_rows = math.floor(npos/__width)
	local final_col = npos % __width

	__col = final_col
	__row = __row + extra_rows

	if (__col == 0) and ti.auto_right_margin then
		if ti.eat_newline_glitch then ti.out(ti.carriage_return) end
		ti.out(ti.carriage_return)
		ti.out(ti.cursor_down)
	end
end

--
-- Output the list of tokens with relevant colour highlighting
-- (make sure we re-create any whitespace gaps)
--

local FAIL = 0
local PARTIAL = 1
local OK = 2

local __color = {
	[OK] = 2,
	[PARTIAL] = 3,
	[FAIL] = 1
}

--
-- Output each token in turn, making sure to recreate the appropriate
-- amount of whitespace...
--
function show_line(tokens, input)
	local p = 1
	local out = ""

	for n, token in ipairs(tokens) do
		if p < token.start then 
			out = out .. string.rep(" ", token.start - p)
			p = token.start
		end
		p = p + token.value:len()
		out = out .. ti.tparm(ti.set_a_foreground, __color[token.status])
		out = out .. token.value
		out = out .. ti.tparm(ti.set_a_foreground, 0)
	end
	p = p - 1
	if p < input:len() then
		out = out .. string.rep(" ", input:len() - p)
		p = input:len()
	end
	if out:len() > 0 then move_on(p, out) end
end

function move_to(r, c)
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
function save_pos()
	__srow, __scol = __row, __col
end
function restore_pos()
	move_to(__srow, __scol)
end

function redraw_line(tokens, input)
	save_pos()
	move_to(0,0)
	show_line(tokens, input)
	ti.out(ti.clr_eol)
	restore_pos()
end

function string_insert(src, extra, pos)
	return src:sub(1, pos-1) .. extra .. src:sub(pos)
end
function string_remove(src, pos, count)
	return src:sub(1, pos-1) .. src:sub(pos+count)
end

--
-- If we get a window resize event then we need to do something sensible
-- to redraw the line
--
function winch_handler()
	local ws = ffi.new("struct winsize [1]")
	
	local rc = ffi.C.ioctl(0, ffi.C.TIOCGWINSZ, ws)

	__width = ws[0].ws_col
	__height = ws[0].ws_row

	--
	-- TODO: we can do better than clear the screen, perhaps work out
	-- how many rows down we were, move back up clear to eos, then redraw.
	--
	ti.out(ti.clear_screen)
	__row, __col = 0, 0
	redraw_line()
	move_to(math.floor((__pos-1)/__width), (__pos-1)%__width)
end


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
	["aabbcc"] = {},
	["aabdef"] = {},
	["aabxxx"] = {},
	["show"] = {},
	["delete"] = {},
	["commit"] = {},
	["save"] = {},
	["revert"] = {},
}
function match_list(t)
	local rc = {}
	for k,v in pairs(__cmds) do
		if k:sub(1, t:len()) == t then table.insert(rc, k) end
	end
	table.sort(rc)
	return rc
end


function syntax_level1(tokens, n, input)
	local token = tokens[n]
	local value = token.value

	if __cmds[value] then 
		status = OK 
	elseif token.finish < input:len() then
		status = FAIL
	else
		local matches = match_list(value)
		if #matches > 0 then status = PARTIAL 
		else status = FAIL end
	end
	return status
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

	--
	-- Make sure we have a base level validator
	--
	tokens[1].validator = syntax_level1

	for n,token in ipairs(tokens) do
		if allfail then
			token.status = FAIL
		else
			if token.status ~= OK then
				if not token.validator then
					token.status = FAIL
				else
					local rc, status = pcall(token.validator, tokens, n, input)
		--			print("Validator rc="..tostring(rc).." status="..tostring(status))
					token.status = status
				end
			end
			if token.status ~= OK then allfail = true end
		end
	end
	return tokens[1].status
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
	local matches = match_list(prefix)
	local ppos = prefix:len() + 1

	if #matches == 0 then return nil end

	if #matches == 1 then
		return matches[1]:sub(ppos) .. " "
	end

	if #matches > 1 then
		local cp = common_prefix(matches)
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
	--
	-- Given out pos, we should be able to work out
	-- which token we are in, return the token index and
	-- valid prefix for that token.
	--
	-- pos is the cursor pos, so it's after the chars so we need
	-- to check for finish + 1
	--
	-- If we are about to start a new token (i.e. as pos 0 or after
	-- a space) then we return the pretend token number.
	--
	function which_token(tokens, pos)
		for i,token in ipairs(tokens) do
			if pos >= token.start and pos <= (token.finish+1) then
				return i, token.value:sub(1, pos - token.start)
			end
		end
		return #tokens + 1, ""
	end

	--
	-- Given a list work out what the common prefix
	-- is (if any)
	--
	function common_prefix(t)
		local str = t[1] or ""
		local n = str:len()

		for _,s in ipairs(t) do
			while s:sub(1, n) ~= str and n > 0 do
				n = n - 1
				str=str:sub(1, n)
			end
		end
		return str
	end

	--
	--
	--
	local n, prefix = which_token(tokens, pos)
	local func = nil
	if n == 1 then
		--
		-- This is the system command list...
		--
		func = system_completer
	else
		-- TODO: use the function from the token
	end
	if not func then 
		ti.out(ti.bell)
		return nil 
	end
	local rv, rc = pcall(func, tokens, n, prefix)
	assert(rv, "unable to execute completer func: " .. tostring(rc))

	return rc
end


dofile("x.lua")

--
--
--
--

local __tokens = {}
local needs_redraw = true

while true do
	local c = read_key()
	if c == nil then goto continue end

	if c:len() == 1 then
		if c == "q" then break end
		__line = string_insert(__line, c, __pos)
		__pos = __pos + 1
		needs_redraw = true
--		redraw_line()
		move_on()


	elseif c == "UP" then
	elseif c == "LEFT" then 
		if __pos > 1 then
			move_back()
			__pos = __pos - 1
		end
	elseif c == "RIGHT" then 
		if __pos <= __line:len() then
			move_on()
			__pos = __pos + 1
		end
	elseif c == "DOWN" then print("DOWN") 
	elseif c == "DELETE" then
		if __pos > 1 then
			__line = string_remove(__line, __pos-1, 1)
			__pos = __pos - 1
			needs_redraw = true
--			redraw_line()
			move_back()
		end
	elseif c == "TAB" then
		--
		-- TODO: tab completion here
		--
		local rc = initial_completer(__tokens, __line, __pos)
		if type(rc) == "string" then
			__line = string_insert(__line, rc, __pos)
			__pos = __pos + rc:len()
			needs_redraw = true
--			redraw_line()
			move_on(rc:len())
		elseif rc then
			save_pos()
			ti.out(ti.carriage_return)
			ti.out(ti.cursor_down)
			__col, __row = 0, 0
			for _,m in ipairs(rc) do
				ti.out(m .. "\n")
			end
			restore_pos()
			needs_redraw = true
--			redraw_line()
		end
	elseif c == "SIGWINCH" then
		winch_handler()
	end

	if needs_redraw then
		--
		-- Build list of tokens
		--
		tokenise(__tokens, __line)

		--
		-- Handle completer tokenisation and syntax check
		--
		if __tokens[1] then
			rc = syntax_checker(__tokens, __line)
--			print("rc = "..rc)
		end

		redraw_line(__tokens, __line)
		needs_redraw = false
	end
	

	io.flush()
::continue::
end

finish()

--[[
print("\027[6n")
local c = read_key()
print("c=["..c.."] .. " .. #c)
]]--

--tout("set_a_foreground", 2)
--ti.out(ti.set_a_foreground, 2)


--print("INT:" .. ffi.string(__libtinfo.tparm(set_a_forground, 2)) .. "..ok")


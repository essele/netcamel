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
		TCSETS = 0x5402
	};
	int ioctl(int d, int request, void *p);


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
	typedef long	time_t;
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
	ms = ms - math.floor(((after.tv_sec - before.tv_sec)*100) + ((after.tv_nsec - before.tv_nsec)/1000000))
	ms = (ms < 0 and 0) or ms

	print("1="..fds[1].revents.." rc="..rc)

	-- WINSTUFF
	if fds[1].revents == ffi.C.POLLIN then
		local sig = ffi.new("struct signalfd_siginfo")
		print("HERE")
		local rc = ffi.C.read(__sigfd, sig, 128)
		print("SIGREAD="..rc)
		return nil
	end

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
	if c ~= "\027" then return c end

	buf = c
	remaining = 300
	while true do
		local c, time = getchar(remaining)
		if not c then return buf end

		remaining = time

		buf = buf .. c
		if #buf == 2 and c == "[" then goto continue end
		if #buf == 2 and c == "O" then goto continue end

		local b = string.byte(c)
		if string.byte(c) >= 64 and string.byte(c) <= 126 then return buf end
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
-- Moves right n spaces (1 by default), but also supports outputting
-- a string since the code is identical (used by show_line)
--
function move_on(n, string)
	n = n or 1
	if n == 0 then return end

	for i=1, n do
		ti.out((string and string:sub(i,i)) or ti.cursor_right)
		__col = __col + 1
		if __col == __width then
			__col = 0
			__row = __row + 1
		end
	end
	if (__col == 0) and ti.auto_right_margin then
		if ti.eat_newline_glitch then ti.out(ti.carriage_return) end
		ti.out(ti.carriage_return)
		ti.out(ti.cursor_down)
	end
end
function show_line()
	move_on(__line:len(), __line)
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

function redraw_line()
	save_pos()
	move_to(0,0)
	show_line()
	ti.out(ti.clr_eol)
	restore_pos()
end

function string_insert(src, extra, pos)
	return src:sub(1, pos-1) .. extra .. src:sub(pos)
end
function string_remove(src, pos, count)
	return src:sub(1, pos-1) .. src:sub(pos+count)
end

--[[
__line = string.rep("abcdefghijklmnopqrstuvwxyz ", 10)
	save_pos()
show_line()
move_to(0,0)
ti.out("XYZ")
__col = __col + 3
--restore_pos()
move_to(0,0)
io.flush()
]]--
while true do
	local c = read_key()
	if c == "q" then break end
	if c == ffi.string(ti.key_up) then print("UP") 
	elseif c == ffi.string(ti.key_left) then 
		if __pos > 1 then
			move_back()
			__pos = __pos - 1
		end
	elseif c == ffi.string(ti.key_right) then 
		if __pos <= __line:len() then
			move_on()
			__pos = __pos + 1
		end
	elseif c == ffi.string(ti.key_down) then print("DOWN") 
	elseif c == "\127" then
		if __pos > 1 then
			__line = string_remove(__line, __pos-1, 1)
			__pos = __pos - 1
			redraw_line()
			move_back()
		end
	elseif c == "\009" then
		--
		-- TODO: tab completion here
		--
		if __line == "s" then
			__line = string_insert(__line, "ave ", __pos)
			__pos = __pos + 4
			redraw_line()
			move_on(4)
		end
	elseif c ~= nil then
		__line = string_insert(__line, c, __pos)
		__pos = __pos + 1
		redraw_line()
		move_on()
	end

	io.flush()
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


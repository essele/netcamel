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

posix = require("posix")
ffi = require("ffi")

ffi.cdef[[
	typedef int ssize_t;

	int pipe(int pipefd[2]);
	int dup2(int oldfd, int newfd);
	ssize_t read(int fd, void *buf, size_t count);
	ssize_t write(int fd, const void *buf, size_t count);
	char *strstr(const char *haystack, const char *needle);
]]

--
-- FFI based rework of pipe() and dup2() calls since they are not including
-- in the posix lib if LuaJIT is used.
--
function posix.pipe()
	local fds = ffi.new("int [2]")
	local rc = ffi.C.pipe(fds)
	return fds[0], fds[1]
end
function posix.dup2(old, new)
	return ffi.C.dup2(old, new)
end

--
-- Given a file descriptor, return an iterator that will return each line
-- in turn, closing the filehandle at the end.
--
function lines_from_fd(fd)
	local __bufsize = 1024
	local __linebuf = ffi.new("char [?]", __bufsize)
	local __str = ""
	local __nomore = false

	return function()
		while true do
			local line, extra = __str:match("^([^\n]*)\n(.*)$")
			if line then
				__str = extra
				return line
			end

			if __nomore then 
				line = (__str ~= "" and __str) or nil 
				__str = ""
				return line
			end

			local c = ffi.C.read(fd, __linebuf, __bufsize)
			if c < 1 then
				__nomore = true
				posix.close(fd)
			else 
				__str = __str .. ffi.string(__linebuf, c)
			end
		end
	end
end

--
-- Execute some other binary, but allow us to pipe in to stdin and
-- collect stdout and stderr
--
function execute(cmdline, stdin)
	local outr, outw = posix.pipe()
	local pid = posix.fork()
	if pid == 0 then
		-- child
		posix.close(outr)
		posix.dup2(outw, 1)
		posix.dup2(outw, 2)

		-- build the pipe to feed input
		local inr, inw = posix.pipe()
		local cpid = posix.fork()
		if cpid == 0 then
			-- real child
			posix.close(inw)
			posix.dup2(inr, 0)
		
			posix.execp(unpack(cmdline))
			print("unable to exec")
			os.exit(1)
		end
		posix.close(inr)
		-- Feed in the stdin if we have some
		for _,line in ipairs(stdin or {}) do
			line = line .. "\n"
			ffi.C.write(inw, line, #line)
		end
		posix.close(inw)
		local pid, reason, status = posix.wait(cpid)
		os.exit(status)
	end
	posix.close(outw)
	local output = {}
	for line in lines_from_fd(outr) do
		table.insert(output, line)
	end
    local pid, reason, status = posix.wait(pid)
	return status, output
end


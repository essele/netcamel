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

--
-- Given a file descriptor, return an iterator that will return each line
-- in turn, closing the filehandle at the end.
--
function lines_from_fd(fd)
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

			local c = posix.unistd.read(fd, 1024)
			if not c or c == "" then
				__nomore = true
				posix.unistd.close(fd)
			else 
				__str = __str .. c
			end
		end
	end
end

--
-- Execute some other binary, but allow us to pipe in to stdin and
-- collect stdout and stderr
--
function pipe_execute(cmd, args, stdin, env)
	local outr, outw = posix.unistd.pipe()
	local pid = posix.unistd.fork()
	if pid == 0 then
		-- child
		posix.unistd.close(outr)
		posix.unistd.dup2(outw, 1)
		posix.unistd.dup2(outw, 2)

		-- set any required environment
		for k,v in pairs(env or {}) do posix.stdlib.setenv(k, v) end

		if stdin then
			-- build the pipe to feed input
			local inr, inw = posix.unistd.pipe()
			local cpid = posix.unistd.fork()
			if cpid == 0 then
				-- real child
				posix.unistd.close(inw)
				posix.unistd.dup2(inr, 0)

				posix.unistd.exec(cmd, args or {})
				print("unable to exec")
				os.exit(1)
			end
			posix.unistd.close(inr)
			-- Feed in the stdin if we have some
			for _,line in ipairs(stdin) do
				line = line .. "\n"
				posix.unistd.write(inw, line)
			end
			posix.unistd.close(inw)
			local pid, reason, status = posix.sys.wait.wait(cpid)
			os.exit(status)
		else
			posix.unistd.exec(cmd, args or {})
			print("unable to exec")
			os.exit(1)
		end
	end
	posix.unistd.close(outw)
	local output = {}
	for line in lines_from_fd(outr) do
		table.insert(output, line)
	end
    local pid, reason, status = posix.sys.wait.wait(pid)
	return status, output
end

return {
	pipe = pipe_execute
}

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

ffi = require("ffi")
posix = {}
posix.fcntl = require("posix.fcntl")
posix.unistd = require("posix.unistd")

ffi.cdef[[
	typedef int32_t		ssize_t;
	typedef uint32_t	size_t;;

	ssize_t read(int fd, void *buf, size_t count);

	struct inotify_event {
	   int	  	wd;	   /* Watch descriptor */
	   uint32_t mask;	 /* Mask of events */
	   uint32_t cookie;   /* Unique cookie associating related events (for rename(2)) */
	   uint32_t len;	  /* Size of name field */
	   char	 	name[];   /* Optional null-terminated name */
	};

	int inotify_init(void);
	int inotify_add_watch(int fd, const char *pathname, uint32_t mask);

	enum {
		IN_MODIFY	=	2
	};
]]

local __watch = {}
local __ifd

function init()
	__ifd = ffi.C.inotify_init()
	return __ifd
end

--
-- Work out the position we need to be at in order to show the last however
-- many lines of the file
--
local CHUNK_SIZE = 1024
function find_x_lines_back(fd, x)
	local data = ""
	local pos = posix.unistd.lseek(fd, -CHUNK_SIZE, posix.unistd.SEEK_END) or 0

	while pos >= 0 do
		data = posix.unistd.read(fd, CHUNK_SIZE) .. data

		--
		-- See if we have enough newlines
		--
		local nls = 0
		for i=#data,1,-1 do
			if data:sub(i,i) == "\n" then
				nls = nls + 1
				if nls == x + 1 then
					pos = pos + i
					posix.unistd.lseek(fd, pos, posix.unistd.SEEK_SET)
					return
				end
			end
		end
		pos = pos - CHUNK_SIZE
	end
end


--
-- Add a file to the watch list, with an optional function that will
-- process each line
--
-- TODO: how far back? should it be optional
function add_watch(filename, func)
	local fd = posix.fcntl.open(filename, posix.fcntl.O_RDONLY)
	func = func or watch_func_normal

	find_x_lines_back(fd, 5)
	
	local wid = ffi.C.inotify_add_watch(__ifd, filename, ffi.C.IN_MODIFY)
	__watch[wid] = { filename = filename, fd = fd, data = "", func = func }
	return process_file(wid)
end

--
-- The default function doesn't do anything to the line
--
function watch_func_normal(line) return line end

--
-- If we get an inotify event then we need to process the file, this
-- returns a list of lines
--
function process_file(wid)
	local watch = __watch[wid]
	if not watch then print("UNKNOWN WATCH") return end

	--
	-- Read all the data we can
	--
	while true do
		local data = posix.unistd.read(watch.fd, 8192)
		if #data == 0 then break end
		watch.data = watch.data .. data
	end
	
	--
	-- Now pull out each line
	--
	local rc = {}
	while true do
		local p = watch.data:find("\n", 1, true)
		if(p) then
			table.insert(rc, watch.func(watch.data:sub(1, p-1)))
			watch.data = watch.data:sub(p+1)
		else break end
	end
	return rc
end

function lee(line)
	return("!!"..line.."!!")
end

function read_inotify()
	local readsize = ffi.sizeof("struct inotify_event")
	local ev = ffi.new("struct inotify_event")

	local count = ffi.C.read(__ifd, ev, readsize)
	if count ~= 0 then
		local lines = process_file(ev.wd)
		return lines
	end
end

return {
	init = init,
	read_inotify = read_inotify,
	add_watch = add_watch,
}



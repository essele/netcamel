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

-- ------------------------------------------------------------------------------
-- Utility functions for file and directory manipulation
-- ------------------------------------------------------------------------------

--
-- Find a temporary name that doesn't exist, we'll use our pid and some random
-- stuff to try to stop race condition conflicts.
--
local rndchar="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local function tmp_name()
	local pid = posix.unistd.getpid()
	local seed = posix.sys.time.gettimeofday().tv_usec * pid

	math.randomseed(seed)

	while true do	
		local rpart = ""
		for i = 1, 6 do 
			local rnd = math.random(1, #rndchar)
			rpart = rpart .. rndchar:sub(rnd, rnd)
		end
	
		local fname = string.format("/tmp/nctmp%s%d", rpart, pid)
		print("Trying: "..fname)
		if not posix.sys.stat.stat(fname) then return fname end
	end
end

--
-- Simple delete file routine, but it also will take a table as an arg
-- so it can work as a method to create_file_with_data
--
local function delete_file(filename)
	if type(filename) == "table" then filename = filename.filename end

	if not filename then return nil, "no filename provded" end
	return os.remove(filename)
end
local function read_file(filename)
	if type(filename) == "table" then filename = filename.filename end

    local file = io.open(filename)
    if not file then return nil, "unable to open file" end
    local rc = file:read("*a")
    file:close()
    return rc
end

--
-- Create a file and populate it with the data. It returns an object that you
-- can use to read and delete the file
--
-- If no filename is provided then it will use a random filename (in /tmp)
--
local function create_file_with_data(filename, data, perm)
	if not filename then filename = tmp_name() end
	
	local file = io.open(filename, "w+")	
	if not file then return nil end

	if data then file:write(data) end
	file:close()

	if perm then posix.sys.stat.chmod(filename, tonumber(perm, 8)) end

	return { filename = filename, delete = delete_file, read = read_file }
end

--
-- Recursively remove a directory, for safety we are only allowed to do this
-- within /tmp. We also support the table object returned by create_directory.
--
-- If it doesn't exist, then we don't do anything
--
local function remove_directory(dirname)
	if type(dirname) == "table" then dirname = dirname.dirname end
	if not dirname then return nil, "no dirname provided" end
	if dirname:sub(1, 5) ~= "/tmp/" then return nil, "only able to remove within /tmp" end

	if not posix.sys.stat.stat(dirname) then return true end

	os.execute("rm -r "..dirname)
	return true
end

--
-- Create a directory if it doesn't already exist, if no name is given then
-- a random filename is used.
--
-- It returns an object that you can use to cleanup()
--
local function create_directory(dirname)
	if not dirname then dirname = tmp_name() end
	
	local stat = posix.sys.stat.stat(dirname)
	if stat and not posix.sys.stat.S_ISDIR(stat.st_mode) then
		return false, "unable to create directory: something is in the way: "..dirname
	end
	local rc, err = posix.sys.stat.mkdir(dirname)
	if not rc then return false, "unable to create directory: "..err end

	return { dirname = dirname, cleanup = remove_directory }
end

--
-- Create a symbolic link
--
local function create_symlink(link, target)
	return posix.unistd.link(target, link, true)
end

return {
	create_with_data = create_file_with_data,
	read = read_file,
	delete = delete_file,
	remove_directory = remove_directory,
	create_directory = create_directory,
	create_symlink = create_symlink,
}

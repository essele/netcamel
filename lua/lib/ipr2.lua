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

-- ==============================================================================
--
-- Module for manipulating the iproute2 tables so that we can use descriptive
-- names for the routing tables and protos.
--
-- We assume /etc/iproute2 is a symlink to /tmp/iproute2 so that we can write
-- these even in the rootfs is readonly.
--
-- ==============================================================================

local ipr2 = {
	["table"] = {
		filename = "/etc/iproute2/rt_tables",
		low = 16,
		high = 248,
		cache = {},
	},
	["proto"] = {
		filename = "/etc/iproute2/rt_protos",
		low = 64,
		high = 192,
		cache = {},
	}
}

--
-- Read one of the files into cache. If the file doesn't exist
-- then read the master
--
local function update_cache_if_needed(f)
	local stat = posix.sys.stat.stat(ipr2[f].filename)
	if not stat then return end
	local ftime = stat.st_mtime

	if ftime and ipr2[f].time and ftime <= ipr2[f].time then return end

	ipr2[f].cache = {}
	for line in io.lines(ipr2[f].filename) do
		local num, value = line:match("^(%d+)%s+([^%s]+)")
		if num then
			num = tonumber(num)
			ipr2[f].cache[num] = value
			ipr2[f].cache[value] = num
		end
	end
	ipr2[f].time = os.time()
end

--
-- Write our cache out into the file, not super efficient, but we only count
-- up to 255 so this should be pretty quick.
--
local function write_cache(f)
	local file = io.open(ipr2[f].filename, "w+")
	if not file then return nil, "unable to create file: "..ipr2[f].filename end

	file:write("#\n# Autogenerated file, do not edit manually\n#\n")
	
	for i = 0, 255 do
		if ipr2[f].cache[i] then
			file:write(string.format("%d\t%s\n", i, ipr2[f].cache[i]))
		end
	end
	file:close()
end

--
-- Manipulate the iproute2 utility files so we make out output a little
-- nicer for some of the routing commands
--
local function rt_value(f, value)
	lib.runtime.block_on("iproute2")
	--
	-- Is our cache current?
	--
	update_cache_if_needed(f)

	--
	-- See if our value is already cached
	--
	if ipr2[f][value] then return ipr2[f][value] end

	--
	-- Set a new value and then write out the file
	--
	local num = 0
	for i = ipr2[f].low, ipr2[f].high do
		if not ipr2[f][i] then
			num = i
			ipr2[f].cache[value] = num
			ipr2[f].cache[num] = value
			break
		end
	end
	assert(num ~= 0, "unable to find slot in rt_"..f)

	--
	-- Update the file
	--
	write_cache(f)
	lib.runtime.block_off("iproute2")
	return num
end

--
-- Remove a value from the cache and then update the file
--
local function rt_remove(f, value)
	lib.runtime.block_on("iproute2")
	update_cache_if_needed(f)

	local num = ipr2[f][value]
	if num then
		ipr2[f].cache[num] = nil
		ipr2[f].cache[value] = nil
	end
	write_cache(f)
	lib.runtime.block_off("iproute2")
end

--
-- We need to make sure the /tmp/iproute2 directory is present
--
lib.file.create_directory("/tmp/iproute2")

return {
	use = rt_value,
	free = rt_remove,
}


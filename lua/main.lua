#!/usr/bin/luajit
--------------------------------------------------------------------------------
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
------------------------------------------------------------------------------

package.path = "./lib/?.lua;" .. package.path

--
-- Use our library autoloading mechanism
--
dofile("lib/lib.lua")


--package.path = "/usr/share/lua/5.1/?.lua;./lib/?.lua;./?.lua"
--package.cpath = "/usr/lib/lua/5.1/?.so;./lib/?.so"

-- global level packages
--require("lfs")
require("utils")
require("config")
require("execute")
require("validators")
--require("api")

-- different namespace packages
local posix		= { 
	dirent = require("posix.dirent"), 
	glob = require("posix.glob"),
	fnmatch = require("posix.fnmatch"),
	sys = { stat = require("posix.sys.stat") }
}
local base64 	= require("base64")
local ffi 		= require("ffi")
local service 	= require("service")
local db 		= require("db")

-- bring in our syntax checkers and completers
-- this also brings in readline
require("cmdline")


--
-- global configuration spaces
--
master={ ["/"] = {} }
current={}
new={}


--
-- Find all files (recursively) in a directory that match a given
-- shell like match (i.e. *.lua)
--
local function matching_files_in(dir, match)
	local rc = {}
	match = match or "*"

	local function recursive_files(dir, match, rc)
		for file in posix.dirent.files(dir) do
			if file:sub(1,1) ~= "." then
				local stat = posix.sys.stat.stat(dir.."/"..file)

				if posix.sys.stat.S_ISDIR(stat.st_mode) ~= 0 then
					recursive_files(dir.."/"..file, match, rc)
				elseif posix.fnmatch.fnmatch(match, file) == 0 then
					table.insert(rc, dir.."/"..file)
				end
			end
		end
	end

	recursive_files(dir, match, rc)
	table.sort(rc)
	return rc
end

--
-- Build a list of all the modules, working out the right init
-- function name as well
--
local core_modules = {}
for _,f in ipairs(matching_files_in("core", "*.lua")) do
	local mname = f:gsub("^core/(.*)%.lua$", "%1"):gsub("/", "_")
	table.insert(core_modules, { name = mname, file = f })
end


--
-- work out which are all of the core modules
--
--[[
local core_modules = {}
for _,m in ipairs(posix.glob.glob("core/*.lua")) do
	local mname = m:match("^core/(.*)%.lua$")
	if mname then table.insert(core_modules, mname) end
end
table.sort(core_modules)
]]--
--
-- Import each of the modules...
--
for module in each(core_modules) do
	print("Loading: "..module.file)
	dofile(module.file)
end

--
-- If we are in "init" mode then initialise the transient data
-- before we run each modules init() function since it might want
-- to use the database tables
--
if arg[1] == "init" then
	print("Initialising transient data...")
	db.init()
end

--
-- If the module has a <modname>_init() function then we call it, the
-- intent of this is to initialise the depends and triggers once we know
-- that all the structures are initialised.
--
for module in each(core_modules) do
--	local funcname = string.format("%s_init", module)
	local funcname = module.name .. "_init"
	if _G[funcname] then
		-- TODO: return code (assert)
--		local ok, err = pcall(_G[funcname])
--		if not ok then assert(false, string.format("[%s]: %s code error: %s", key, funcname, err)) end
		print("Initialising module: "..module.file)
		_G[funcname]()
	end
end



--
-- INIT (commit)
--
-- current = empty (i.e. no config)
-- new = saved_config (i.e. the last properly saved)
-- execute, then write out current.
--
-- OTHER OPS (commit)
--
-- current = current
-- new = based on changes
-- execute, then write out current.
--
-- SAVE (save)
--
-- take current and write it out as saved.
--

CF_current = {}
CF_new = {}

--[[
CF_new["/system/hostname"] = "blahblah"


show(CF_current, CF_new)
set(CF_new, "/system/hostname", "freddy")
set(CF_new, "/service/ntp/server", "freddy")
set(CF_new, "/interface/ethernet/2/ip", "1.2.3.4/16")

show(CF_current, CF_new)

dump("/tmp/lee", CF_new)


xx = import("/tmp/lee")
show(CF_current, xx)

os.exit(0)
]]--
--
-- If we are called with "init" as the arg then we load and commit the boot config
--
if arg[1] == "init" then
	print("Loading boot config...")
	CF_new = import("etc/boot.conf")
	if not CF_new then
		print("LOAD FAILED")
		os.exit(1)
	end
	local rc, err = commit(CF_current, CF_new)
	if not rc then 
		print("Error: " .. err)
		os.exit(1)
	end
	os.exit(0)
end

-- Read current config
CF_current = import("etc/boot.conf")
if not CF_current then
	print("Failed to load config, starting with nothing")
	CF_current = {}
end
CF_new = copy(CF_current)

interactive()
os.exit(0)



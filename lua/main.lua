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

--
-- Important globals for configuration
--
VALIDATOR = {}

-- global level packages
--require("utils")
require("config")
require("validators")

local ffi 		= require("ffi")

--
-- global configuration spaces
--


master={ ["/"] = {} }
current={}
new={}
CF_current = {}
CF_new = {}

--
-- Import all of the modules into a core table so that we can
-- make functions public etc. This is recursive to ensure the
-- directory structure is maintained in the table.
--
local function load_modules(dir)
	local rc = {}
	for file in posix.dirent.files(dir) do
		if file:sub(1,1) ~= "." then
			local stat = posix.sys.stat.stat(dir.."/"..file)
			if posix.sys.stat.S_ISDIR(stat.st_mode) ~= 0 then
				rc[file] = load_modules(dir.."/"..file)
			else
				local mod = file:match("^(.*)%.lua$")
				if mod then
					print("Loading: "..dir.."/"..mod)
					rc[mod] = dofile(dir.."/"..file)
				end
			end
		end
	end
	return rc
end

--
-- For all of our core modules look through the table recursively
-- and call any init routines that we find.
--
local function init_modules(t, funcname, path)
	path = path or "core"

	for k,v in pairs(t) do
		if type(v) == "table" and v[funcname] and type(v[funcname]) == "function" then
			print(string.format("Initialising (%s): %s.%s", funcname, path, k))
			v[funcname]()
		elseif type(v) == "table" then
			init_modules(v, funcname, path.."."..k)
		end
	end
end

core = load_modules("core")

--
-- If we are in "init" mode then initialise the transient data
-- before we run each modules init() function since it might want
-- to use the database tables
--
if arg[1] == "init" then
	print("Initialising transient data...")
	lib.db.boot()

	print("Initialising service manager...")
	lib.service.boot()

	init_modules(core, "boot")
end

--
-- If the module has a <modname>_init() function then we call it, the
-- intent of this is to initialise the depends and triggers once we know
-- that all the structures are initialised.
--
init_modules(core, "init")

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

--dofile("x.lua")
local prompt = { value = "prompt > ", len = 9 }
local history = { "fred", "one two thre", "set /abc/def/ghi" }

--lib.readline2.read_command(prompt, history, processCB, completeCB, enterCB)
lib.cmdline.interactive()



--lib.cmdline.interactive()
os.exit(0)



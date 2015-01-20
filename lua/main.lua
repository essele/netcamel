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
local posix		= { glob = require("posix.glob") }
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
-- work out which are all of the core modules
--
local core_modules = {}
--for m in lfs.dir("core") do
for _,m in ipairs(posix.glob.glob("core/*.lua")) do
	local mname = m:match("^core/(.*)%.lua$")
	if mname then table.insert(core_modules, mname) end
end
table.sort(core_modules)

--
-- Import each of the modules...
--
for module in each(core_modules) do
	dofile("core/" .. module .. ".lua")
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
	local funcname = string.format("%s_init", module)
	if _G[funcname] then
		-- TODO: return code (assert)
		local ok, err = pcall(_G[funcname])
		if not ok then assert(false, string.format("[%s]: %s code error: %s", key, funcname, err)) end
	end
end


function other() 
	print("other: dummy function called")
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



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
-- The main services array
--
local services = {}
local posix = require("posix")
posix.time = require("posix.time")
posix.sys = {}
posix.sys.stat = require("posix.sys.stat")
posix.fcntl = require("posix.fcntl")
require("bit")

--
-- Read the name from the proc stat file
--
local function readname(pid)
	local file = io.open("/proc/"..pid.."/stat")
	if not file then return nil end
	local line = file:read("*all")
	file:close()
	return((line:match("%(([^%)]+)%)")))
end

--
-- Build a three-way hash using the process information so we can search based
-- on pid, name or exe.
--
local function get_pidinfo()
	local rc = { ["pid"] = {}, ["binary"] = {}, ["name"] = {} }

	for _,exe in ipairs(posix.glob("/proc/[0-9]*/exe")) do
		local pid = tonumber(exe:match("(%d+)"))
		local binary = posix.readlink(exe)
		local name = readname(pid)

		rc.pid[pid] = { ["binary"] = exe, ["name"] = name }
		if binary then 
			if not rc.binary[binary] then rc.binary[binary] = {} end
			table.insert(rc.binary[binary], pid)
		end
		if name then
			if not rc.name[name] then rc.name[name] = {} end
			table.insert(rc.name[name], pid)
		end
	end
	return rc
end

--
-- Given a service name, get the pids by either "name" or
-- "binary"
--
local function get_pids_by(v, field)
	local info = services[v]
	local pidinfo = get_pidinfo()
	return pidinfo[field][info[field]] or {}
end
local function get_pids_from_pidfile(v)
	local pids = {}
	local file = io.open(services[v].pidfile)
	local line = file:read("*all")
	file:close()
	for pid in line:gmatch("%d+") do table.insert(pids, tonumber(pid)) end
	return pids
end

--
-- Kill the process(es) by one of three references, name, binary name,
-- or pid numbers in the pidfile
--
local function kill_by_name(v)
	local pids = get_pids_by(v, "name")
	for _, pid in ipairs(pids) do posix.kill(pid, posix.SIGTERM) end
end

local function kill_by_binary(v)
	local pids = get_pids_by(v, "binary")
	for _, pid in ipairs(pids) do posix.kill(pid, posix.SIGTERM) end
end
local function kill_by_pidfile(v)
	local pids = get_pids_from_pidfile(v)
	for _, pid in ipairs(pids) do posix.kill(pid, posix.SIGTERM) end
end

--
-- Check whether the service is runing by checking pids using one
-- of the three methods
--
local function check_pid_by_name(v)
	local pids = get_pids_by(v, "name") or {}
	return #pids > 0
end
local function check_pid_by_binary(v)
	local pids = get_pids_by(v, "binary") or {}
	return #pids > 0
end
local function check_pid_by_pidfile(v)
	local pids = get_pids_from_pidfile(v)
	return #pids > 0
end

--
-- The main start and stop functions
--
local function start(name)
	local svc = services[name]
	if not svc then return false, "unknown service" end

	print("START IS "..tostring(svc.start))
	local rc, rv, err = pcall(svc.start, name)
	print("Start returned rc="..tostring(rc).." rv="..tostring(rv) .. " err="..tostring(err))
end
local function stop(name)
	local svc = services[name]
	if not svc then return false, "unknown service" end

	local rc, rv, err = pcall(svc.stop, name)
	print("Stop returned rc="..tostring(rc).." rv="..tostring(rv).." err="..tostring(err))
end
local function restart(name)
	local svc = services[name]
	if not svc then return false, "unknown service" end

	local rc, rv, err = pcall(svc.restart, name)
	print("Restart returned rc="..tostring(rc).." rv="..tostring(rv).." err="..tostring(err))
end
local function status(name)
	local svc = services[name]
	if not svc then return false, "unknown service" end

	local rc, rv, err = pcall(svc.status, name)
	print("Status  returned rc="..tostring(rc).." rv="..tostring(rv).." err="..tostring(err))
	if not rc then print("AARGGH") return falase end
	return rv
end

local function stop_then_start(name)
	local svc = services[name]
	stop(name)
	if svc.restart_delay then posix.time.nanosleep({ tv_sec = svc.restart_delay }) end
	start(name)
end

--
-- Basic start function, used when the binary will take care
-- of daemonising itself
--
local function start_normally(name)
	svc = services[name]

	print("would run (normally): " .. tostring(svc.binary))

	local rc, err = execute(svc.binary, svc.args, nil, svc.env )
	print("rc="..tostring(rc))
	for _,x in ipairs(err) do
		print("> "..x)
	end
	return
end

--
-- Used when a service needs to be started as a daemon
--
local function start_as_daemon(name)
	svc = services[name]

	print("would run: " .. tostring(svc.binary))

	local cpid = posix.fork()
	if cpid ~= 0 then		-- parent
		local rc, state, status = posix.wait(cpid)
		print("rc = "..tostring(rc).." status=" .. status)
		return
	end

	--
	-- We are the child, prepare for a second fork, and exec. Call
	-- setsid, chdir to /, then close our key filehandles.
	--
	posix.sys.stat.umask(0)
	if(not posix.setpid("s")) then os.exit(1) end
	if(posix.chdir("/") ~= 0) then os.exit(1) end
	posix.close(0)
	posix.close(1)
	posix.close(2)

	--
	-- Re-open the three filehandles, all /dev/null
	--
	local fdnull = posix.fcntl.open("/dev/null", posix.O_RDWR)	-- stdin
	posix.dup(fdnull)										-- stdout
	posix.dup(fdnull)										-- stderr

	--
	-- Fork again, so the parent can exit, orphaning the child
	--
	local npid = posix.fork()
	if npid ~= 0 then os.exit(0) end
	
	--
	-- Create a pidfile if we've been asked to
	--
	if svc.create_pidfile then
		local file = io.open(svc.pidfile, "w+")
		local pid = posix.getpid()
		if file then
			file:write(tostring(pid))
			file:close()
		end
	end

	--
	-- Create a logfile if asked
	--
	if svc.logfile then
		local logfd = posix.fcntl.open(svc.logfile, bit.bor(posix.O_CREAT, posix.O_WRONLY))
		if logfd then
			posix.close(1)
			posix.close(2)
			posix.dup(logfd)
			posix.dup(logfd)
		end
	end

	for k, v in pairs(svc.env or {}) do posix.setenv(k, v) end

	posix.exec(svc.binary, svc.args)
	--
	-- if we get here then the exec has failed
	-- TODO get err and write an error out to a log (which we need to open)
	--
	os.exit(1)
end

--
-- Add a service into the list or modify one of the values
--
local function define(name, svc)
	services[name] = svc
end
local function getservice(name)
	return services[name]
end
local function set(name, item, value)
	services[name][item] = value
end


--
-- Return the functions...
--
return {
	--
	-- Main Functions
	--
	define = define,
	set = set,
	get = getservice,
	start = start,
	stop = stop,
	restart = restart,
	status = status,

	--
	-- Functions to be used in the service 
	--
	start_as_daemon = start_as_daemon,
	start_normally = start_normally,
	stop_then_start = stop_then_start,
	kill_by_name = kill_by_name,
	kill_by_binary = kill_by_binary,
	kill_by_pidfile = kill_by_pidfile,
	check_pid_by_name = check_pid_by_name,
	check_pid_by_binary = check_pid_by_binary,
	check_pid_by_pidfile = check_pid_by_pidfile,
}



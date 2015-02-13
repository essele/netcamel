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

local bit = require("bit")

--
-- Install a service defnition into the transient database
-- (serialise data where needed)
--
local function define(name, svc)
	svc.service = name
	if svc.args then svc.args = lib.utils.serialise(svc.args) end
	if svc.env then svc.env = lib.utils.serialise(svc.env) end
	if svc.vars then svc.vars = lib.utils.serialise(svc.vars) end
	if svc.stop_args then svc.stop_args = lib.utils.serialise(svc.stop_args) end
	rc, err = lib.db.query("services", "remove_service", name)
	print("remove rc="..tostring(rc).." err="..tostring(err))
	rc, err = lib.db.insert("services", svc)
	print("rc="..tostring(rc).." err="..tostring(err))
end
--
-- Remove a service definition from the databaase
--
local function remove(name)
	rc, err = lib.db.query("services", "remove_service", name)
	print("remove rc="..tostring(rc).." err="..tostring(err))
end

--
-- Pull out a service definition
-- (unserialise as needed)
--
local function get(name)
	local svc = lib.db.query("services", "get_service", name)
	if not svc or #svc ~= 1 then return nil, "unknown service" end

	svc = svc[1]
	if svc.args then svc.args = lib.utils.unserialise(svc.args) end
	if svc.env then svc.env = lib.utils.unserialise(svc.env) end
	if svc.stop_args then svc.stop_args = lib.utils.unserialise(svc.stop_args) end
	svc.create_pidfile = (svc.create_pidfile == 1)
	return svc
end

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

	for _,exe in ipairs(posix.glob.glob("/proc/[0-9]*/exe")) do
		local pid = tonumber(exe:match("(%d+)"))
		local binary = posix.unistd.readlink(exe)
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
local function get_pids_by(svc, field)
	local pidinfo = get_pidinfo()
	return pidinfo[field][svc[field]] or {}
end
local function get_pids_from_pidfile(svc)
	local pids = {}
	local pidfile = svc.pidfile

	print("pidfile="..pidfile)
	local file = io.open(pidfile)
	print("file="..tostring(file))
	if file then
		local line = file:read("*all")
		file:close()
		for pid in line:gmatch("%d+") do table.insert(pids, tonumber(pid)) end
	end
	return pids
end

--
-- Given a list of pids, check that they are valid (and what they are)
-- then kill them and busy wait for them to die. Check the name so
-- that we don't have a issue with the slot being reused.
--
local function kill_and_wait_to_die(pids, time)
	local pidmap = {}

	-- Get names...
	for _,pid in ipairs(pids) do pidmap[pid] = readname(pid) end

	-- Kill any valid ones...
	for _,pid in ipairs(pids) do
		print("pid="..pid.." name="..tostring(pidmap[pid]))
		if pidmap[pid] then posix.signal.kill(pid, posix.signal.SIGTERM) end
	end
	print("time = "..tostring(time))

	local maxkilltime = time or 0
	while maxkilltime > 0 do
		-- wait for up to 10ms
		local waittime = (maxkilltime > 50 and 50) or maxkilltime
		posix.time.nanosleep({ tv_nsec = waittime * 1000000 })
		maxkilltime = maxkilltime - waittime

		-- see if we have really gone
		for pid,name in pairs(pidmap) do
			local newname = readname(pid)
			print("Checking on pid: "..pid.." was="..tostring(name).." now="..tostring(newname))
			if not newname or newname ~= name then pidmap[pid] = nil end
		end
		-- are we done?
		if not next(pidmap) then return end

	end
	print("DEBUG: didn't die in time or no killtime")
end

--
-- Kill the process(es) by one of three references, name, binary name,
-- or pid numbers in the pidfile
--
local function kill_by_name(svc)
	local pids = get_pids_by(svc, "name")
	kill_and_wait_to_die(pids, svc.maxkilltime)
end

local function kill_by_binary(svc)
	local pids = get_pids_by(svc, "binary")
	kill_and_wait_to_die(pids, svc.maxkilltime)
end
local function kill_by_pidfile(svc)
	local pids = get_pids_from_pidfile(svc)
	kill_and_wait_to_die(pids, svc.maxkilltime)
end
local function kill_by_command(svc)
	print("stop command: " .. tostring(svc.stop_binary))

	local rc, err = lib.execute.pipe(svc.stop_binary, svc.stop_args, nil, svc.env )
	print("rc="..tostring(rc))
	if not rc then return false, err end

	if svc.logfile then
		local file = io.open(svc.logfile, "a+")
		if file then
			for _,line in ipairs(err) do file:write(line.."\n") end
			file:close()
		end
	end
end

--
-- Check whether the service is runing by checking pids using one
-- of the three methods
--
local function check_pid_by_name(svc)
	local pids = get_pids_by(svc, "name") or {}
	return #pids > 0
end
local function check_pid_by_binary(svc)
	local pids = get_pids_by(svc, "binary") or {}
	return #pids > 0
end
local function check_pid_by_pidfile(svc)
	local pids = get_pids_from_pidfile(svc)
	return #pids > 0
end


local function stop_then_start(svc)
	stop(svc.service)
	if svc.restart_delay then posix.time.nanosleep({ tv_sec = svc.restart_delay }) end
	start(svc.service)
end

--
-- Basic start function, used when the binary will take care
-- of daemonising itself
--
local function start_normally(svc)
	print("would run (normally): " .. tostring(svc.binary))

	local rc, err = lib.execute.pipe(svc.binary, svc.args, nil, svc.env )
	print("rc="..tostring(rc))
	if not rc then return false, err end

	if svc.logfile then
		local file = io.open(svc.logfile, "a+")
		if file then
			for _,line in ipairs(err) do file:write(line.."\n") end
			file:close()
		end
	end
	return
end

--
-- Used when a service needs to be started as a daemon
--
local function start_as_daemon(svc)
	print("would run: " .. tostring(svc.binary))

	local cpid = posix.unistd.fork()
	if cpid ~= 0 then		-- parent
		local rc, state, status = posix.sys.wait.wait(cpid)
		print("start as daemon rc = "..tostring(rc).." status=" .. status)
		return
	end

	--
	-- We are the child, prepare for a second fork, and exec. Call
	-- setsid, chdir to /, then close our key filehandles.
	--
	posix.sys.stat.umask(0)
	if(not posix.unistd.setpid("s")) then os.exit(1) end
	if(posix.unistd.chdir("/") ~= 0) then os.exit(1) end
	posix.unistd.close(0)
	posix.unistd.close(1)
	posix.unistd.close(2)

	--
	-- Re-open the three filehandles, all /dev/null
	--
	local fdnull = posix.fcntl.open("/dev/null", posix.fcntl.O_RDWR)	-- stdin
	posix.unistd.dup(fdnull)										-- stdout
	posix.unistd.dup(fdnull)										-- stderr

	--
	-- Fork again, so the parent can exit, orphaning the child
	--
	local npid = posix.unistd.fork()
	if npid ~= 0 then os.exit(0) end
	
	--
	-- Create a pidfile if we've been asked to
	--
	if svc.create_pidfile then
		local file = io.open(svc.pidfile, "w+")
		local pid = posix.unistd.getpid()
		if file then
			file:write(tostring(pid))
			file:close()
		end
	end

	--
	-- Create a logfile if asked
	--
	if svc.logfile then
		local logfd = posix.fcntl.open(svc.logfile, bit.bor(posix.fcntl.O_CREAT, posix.fcntl.O_WRONLY, posix.fcntl.O_TRUNC))
		if logfd then
			posix.unistd.close(1)
			posix.unistd.close(2)
			posix.unistd.dup(logfd)
			posix.unistd.dup(logfd)
		end
	end

	for k, v in pairs(svc.env or {}) do posix.stdlib.setenv(k, v) end

	posix.unistd.exec(svc.binary, svc.args)
	--
	-- if we get here then the exec has failed
	-- TODO get err and write an error out to a log (which we need to open)
	--
	os.exit(1)
end

--
-- The main start and stop functions
--
local function start(name)
	print("START: " .. name)
	local svc = get(name)
	print("SVC: "..tostring(svc))
	if not svc then return false, "unknown service" end

	print("START IS "..tostring(svc.start))
	if svc.start == "NORMALLY" then
		rc, err = start_normally(svc)
	elseif svc.start == "ASDAEMON" then
		rc, err = start_as_daemon(svc)
	else
		return false, "unknown start method"
	end
	print("Start returned rc="..tostring(rc).." err="..tostring(err))
end
local function stop(name)
	local svc = get(name)
	if not svc then return false, "unknown service" end

	print("STOP IS "..tostring(svc.stop))
	if svc.stop == "BYNAME" then
		rc, err = kill_by_name(svc)
	elseif svc.stop == "BYBINARY" then
		rc, err = kill_by_binary(svc)
	elseif svc.stop == "BYPIDFILE" then
		rc, err = kill_by_pidfile(svc)
	elseif svc.stop == "BYCOMMAND" then
		rc, err = kill_by_command(svc)
	else
		return false, "unknown stop method"
	end
	print("Stop returned rc="..tostring(rc).." err="..tostring(err))
end
local function restart(name)
	local svc = get(name)
	if not svc then return false, "unknown service" end

	if svc.restart == "STOP_THEN_START" then
		rc, err = stop_then_start(svc)
	else
		return false, "unknown restart method"
	end
	print("Restart returned rc="..tostring(rc).." err="..tostring(err))
end
local function status(name)
	local svc = get(name)
	if not svc then return false, "unknown service" end

	print("STATUS is "..tostring(svc.status))
	if svc.status == "BYNAME" then
		rc, err = check_pid_by_name(svc)
	elseif svc.status == "BYBINARY" then
		rc, err = check_pid_by_binary(svc)
	elseif svc.status == "BYPIDFILE" then
		rc, err = check_pid_by_pidfile(svc)
	else
		return false, "unknown status method"
	end
end

--
-- We will create a services table for tracking the state of
-- active services
--
local function boot()
	local schema = {  service="string primary key",
					name="string",
					binary="string",
					pidfile="string",
					create_pidfile="boolean",
					logfile="string",
					start="string",
					stop="string",
					status="string",
					args="string",
					env="string",
					vars="string",
					maxkilltime="integer",
					stop_binary="string",
					stop_args="string",
	}
	local queries = {
		["get_service"] = "select * from services where service = :service",
		["remove_service"] = "delete from services where service = :service",
	}
	lib.db.create("services", schema, queries)
end

--
-- Return the functions...
--
return {
	--
	-- Main Functions
	--
	boot = boot,
	define = define,
	remove = remove,
	get = get,
	start = start,
	stop = stop,
	restart = restart,
	status = status,
}



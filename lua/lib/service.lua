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

--
-- We use quite a few c libary function with ffi in this module...
--
local ffi = require("ffi")
ffi.cdef[[
	typedef int 			pid_t;
	typedef int				ssize_t;
	typedef unsigned short 	mode_t;
	typedef long			useconds_t;

	pid_t 	fork(void);
	int		kill(pid_t pid, int sig);
	pid_t	getpid(void);
	pid_t 	setsid(void);
	mode_t	umask(mode_t mask);
	int		chdir(const char *path);
	int		open(const char *pathname, int flags);
	int		close(int fd);
	int		execvp(const char *file, char *const argv[]);
	void 	exit(int status);
	pid_t	wait(int *status);
	pid_t	waitpid(pid_t pid, int *status, int options);
	int		dup(int oldfd);
	ssize_t	readlink(const char *path, char *buf, size_t bufsiz);
	int		usleep(useconds_t useconds);

	enum { O_RDWR = 2 };
	enum { SIGTERM = 15 };
]]

--
-- Used to help us prepare the args for execvp
--
local k_char_p_arr_t = ffi.typeof('const char * [?]')
local char_p_k_p_t   = ffi.typeof('char * const *')

--
-- Interface to the C readlink call... returns a lua string
--
local function readlink(path)
	local buf = ffi.new("char [?]", 1024)
	local rc = ffi.C.readlink(path, buf, 1024)
	if(rc > 0) then return ffi.string(buf) end
	return nil
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

	for pid in lfs.dir("/proc") do
		if pid:match("^%d+") then
			pid = tonumber(pid)
			local binary = readlink("/proc/"..pid.."/exe")
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
	for _, pid in ipairs(pids) do ffi.C.kill(pid, ffi.C.SIGTERM) end
end

local function kill_by_binary(v)
	local pids = get_pids_by(v, "binary")
	for _, pid in ipairs(pids) do ffi.C.kill(pid, ffi.C.SIGTERM) end
end
local function kill_by_pidfile(v)
	local pids = get_pids_from_pidfile(v)
	for _, pid in ipairs(pids) do ffi.C.kill(pid, ffi.C.SIGTERM) end
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
	if svc.restart_delay then ffi.C.usleep(svc.restart_delay * 1000) end
	start(name)
end

--
-- Used when a service needs to be started as a daemon
--
local function start_as_daemon(name)
	svc = services[name]

	print("would run: " .. tostring(svc.binary))

	local cpid = ffi.C.fork()
	if cpid ~= 0 then		-- parent
		local st = ffi.new("int [1]", 0)
		local rc = ffi.C.waitpid(cpid, st, 0)
		print("rc = "..tostring(rc).." status=" .. st[1])
		return
	end

	--
	-- We are the child, prepare for a second fork, and exec. Call
	-- setsid, chdir to /, then close our key filehandles.
	--
	ffi.C.umask(0)
	if(ffi.C.setsid() < 0) then ffi.C.exit(1) end
	if(ffi.C.chdir("/") < 0) then ffi.C.exit(1) end
	ffi.C.close(0)
	ffi.C.close(1)
	ffi.C.close(2)

	--
	-- Re-open the three filehandles, all /dev/null
	--
	local fdnull = ffi.C.open("/dev/null", ffi.C.O_RDWR)	-- stdin
	ffi.C.dup(fdnull)										-- stdout
	ffi.C.dup(fdnull)										-- stderr

	--
	-- Fork again, so the parent can exit, orphaning the child
	--
	local npid = ffi.C.fork()
	if npid ~= 0 then ffi.C.exit(0) end
	
	--
	-- TODO: create a pidfile if we've been asked to
	--
	if svc.create_pidfile then
		local file = io.open(svc.pidfile, "w+")
		local pid = ffi.C.getpid()
		if file then
			file:write(tostring(pid))
			file:close()
		end
	end

	local argv = k_char_p_arr_t(#svc.args + 1)
	for i = 1, #svc.args do argv[i-1] = svc.args[i] end

	ffi.C.execvp(svc.binary, ffi.cast(char_p_k_p_t, argv))
	--
	-- if we get here then the exec has failed
	-- TODO use ffi.errno() and write an error out to a log (which we need to open)
	--
	ffi.C.exit(1)
end

--
-- Add a service into the list or modify one of the values
--
local function define(name, svc)
	services[name] = svc
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
	start = start,
	stop = stop,
	restart = restart,
	status = status,

	--
	-- Functions to be used in the service 
	--
	start_as_daemon = start_as_daemon,
	stop_then_start = stop_then_start,
	kill_by_name = kill_by_name,
	kill_by_binary = kill_by_binary,
	kill_by_pidfile = kill_by_pidfile,
	check_pid_by_name = check_pid_by_name,
	check_pid_by_binary = check_pid_by_binary,
	check_pid_by_pidfile = check_pid_by_pidfile,
}



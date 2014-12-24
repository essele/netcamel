#!luajit

package.cpath = "/usr/lib/lua/5.1/?.so;./lib/?.so"

local ffi = require("ffi")
require("lfs")

ffi.cdef[[
	typedef int 			pid_t;
	typedef int				ssize_t;
	typedef unsigned short 	mode_t;

	pid_t 	fork(void);
	int		kill(pid_t pid, int sig);
	pid_t 	setsid(void);
	mode_t	umask(mode_t mask);
	int		chdir(const char *path);
	int		open(const char *pathname, int flags);
	int		close(int fd);
	int 	execv(const char *path, const char *argv[]);
	int		execvp(const char *file, char *const argv[]);
	void 	exit(int status);
	pid_t	wait(int *status);
	pid_t	waitpid(pid_t pid, int *status, int options);
	int		getdtablesize(void);
	int		dup(int oldfd);
	ssize_t	readlink(const char *path, char *buf, size_t bufsiz);

	enum { O_RDWR = 2 };
	enum { SIGTERM = 15 };
]]

--
-- Used to help us prepare the args for execvp
--
local k_char_p_arr_t = ffi.typeof('const char * [?]')
local char_p_k_p_t   = ffi.typeof('char * const *')




local p = require("posix_c")

local daemon = {}

--
-- Build a three-way hash using the process information so we can search based
-- on pid, name or exe.
--
local function get_pidinfo()
	local rc = { ["pid"] = {}, ["exe"] = {}, ["name"] = {} }

	for pid in lfs.dir("/proc") do
		if pid:match("^%d+") then
			pid = tonumber(pid)
			local exe = readlink("/proc/"..pid.."/exe")
			local name = readname(pid)

			rc.pid[pid] = { ["exe"] = exe, ["name"] = name }
			if exe then 
				if not rc.exe[exe] then rc.exe[exe] = {} end
				table.insert(rc.exe[exe], pid)
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
-- Kill the process(es) by one of three references, name, binary name,
-- or pid numbers in the pidfile
--
local function kill_by_name(v)
	local info = daemon[v]
	local pidinfo = get_pidinfo()
	local pids = pidinfo.name[info.name] or {}

	print("would kill " .. table.concat(pids, ", "))
	for _, pid in ipairs(pids) do ffi.C.kill(pid, ffi.C.SIGTERM) end
end

local function kill_by_binary(v)
	local info = daemon[v]
	local pidinfo = get_pidinfo()
	local pids = pidinfo.exe[info.binary] or {}

	print("would kill " .. table.concat(pids, ", "))
	for _, pid in ipairs(pids) do ffi.C.kill(pid, ffi.C.SIGTERM) end
end

local function kill_by_pidfile(v)
end

--
-- The main start and stop functions
--
local function start(name)
	local svc = daemon[name]
	if not svc then return false, "unknown service" end

	print("START IS "..tostring(svc.start))
	local rc, err = pcall(svc.start, name)
	print("Start returned rc="..tostring(rc).." err="..tostring(err))
end
local function stop(name)
	local svc = daemon[name]
	if not svc then return false, "unknown service" end

	local rc, err = pcall(svc.stop, name)
	print("Stop returned rc="..tostring(rc).." err="..tostring(err))
end



--
-- Used when a service needs to be started as a daemon
--
local function start_as_daemon(name)
	info = daemon[name]

	print("would run: " .. tostring(info.binary))

	local cpid = ffi.C.fork()
	if cpid ~= 0 then		-- parent
		local st = ffi.new("int [1]", 0)
		local rc = ffi.C.waitpid(cpid, st, 0)
		print("rc = "..tostring(rc).." status=" .. st[1])
		return
	end

	--
	-- We are the child, prepare for a second fork, and exec
	--
	ffi.C.umask(0)
	if(ffi.C.setsid() < 0) then ffi.C.exit(1) end
	if(ffi.C.chdir("/") < 0) then ffi.C.exit(1) end
	ffi.C.close(0)
	ffi.C.close(1)
	ffi.C.close(2)

	local fdnull = ffi.C.open("/dev/null", ffi.C.O_RDWR)	-- stdin
	ffi.C.dup(fdnull)	-- stdout
	ffi.C.dup(fdnull)	-- stderr

	--
	-- Fork again, so the parent can exit, orphaning the child
	--
	local npid = ffi.C.fork()
	if npid ~= 0 then ffi.C.exit(0) end
		

	local argv = k_char_p_arr_t(#info.args + 1)
	for i = 1, #info.args do argv[i-1] = info.args[i] end

	ffi.C.execvp(daemon[name].binary, ffi.cast(char_p_k_p_t, argv))
	--
	-- if we get here then the exec has failed
	-- TODO use ffi.errno() and write an error out to a log (which we need to open)
	--
	ffi.C.exit(1)
end

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

--run_daemon("ntpd")

--local pids = get_pidinfo()

--local bash = pids.exe["/usr/bin/bash"]
--for _,p in ipairs(bash) do
--	print("PID="..p)
--end

daemon["ntpd"] = {
	["binary"] = "/home/essele/dev/netcamel/lua/pretend_ntp",
	["args"] = { "-g", "-p", "/var/run/ntpd.pid" },
	["name"] = "pretend_ntp",
	["pidfile"] = "/var/run/ntpd.pid",
	["generate_pidfile"] = true,
	
	["start"] = start_as_daemon,
	["stop"] = kill_by_name,
}

local name = "ntpd"
local args = daemon[name].args




start("ntpd")
p.sleep(2)
stop("ntpd")

--start("ntpd")






#!luajit

package.cpath = "/usr/lib/lua/5.1/?.so;./lib/?.so"

local ffi = require("ffi")
require("lfs")

ffi.cdef[[
	typedef int 			pid_t;
	typedef int				ssize_t;
	typedef unsigned short 	mode_t;

	pid_t 	fork(void);
	pid_t 	setsid(void);
	mode_t	umask(mode_t mask);
	int		chdir(const char *path);
	int		open(const char *pathname, int flags);
	int		close(int fd);
	int 	execv(const char *path, const char *argv[]);
	void 	exit(int status);
	pid_t	wait(int *status);
	pid_t	waitpid(pid_t pid, int *status, int options);
	int		getdtablesize(void);
	int		dup(int oldfd);
	ssize_t	readlink(const char *path, char *buf, size_t bufsiz);

	enum { O_RDWR = 2 };
]]


local p = require("posix_c")

local daemon = {}

local killpid

function kill_by_name(v)
	local info = daemon[v]
	local pidinfo = get_pidinfo()
	local pids = pidinfo.name[info.name]

	print("would kill " .. table.concat(pids, ", "))
end

function kill_by_binary(v)
	local info = daemon[v]
	local pidinfo = get_pidinfo()
	local pids = pidinfo.exe[info.binary]

	print("would kill " .. table.concat(pids, ", "))
end

function kill_by_pidfile(v)
end


daemon["ntpd"] = {
	["binary"] = "/home/essele/dev/netcamel/lua/pretend_ntp",
	["args"] = { "-g", "-p", "/var/run/ntpd.pid" },
	["name"] = "pretend_ntp",
	["pidfile"] = "/var/run/ntpd.pid",
	["generate_pidfile"] = true,
	
	["start"] = start_as_daemon,
	["stop"] = kill_by_name,
}

function killpid(name)
end

function run_daemon(name)
	if not daemon[name] then
		print("unknown daemon")
		return false
	end

	print("would run: " .. tostring(daemon[name].start))

	local cpid = ffi.C.fork()
	if cpid == 0 then -- child

		ffi.C.umask(0)
		if(ffi.C.setsid() < 0) then exit(1) end
	
--		if(ffi.C.chdir("/") < 0) then exit(1) end
		ffi.C.close(0)
		ffi.C.close(1)
		ffi.C.close(2)

		local fdnull = ffi.C.open("/dev/null", ffi.C.O_RDWR)	-- stdin
		ffi.C.dup(fdnull)	-- stdout
		ffi.C.dup(fdnull)	-- stderr

		local npid = ffi.C.fork()
		if npid == 0 then -- child
			
			local exec_str = ffi.new("const char *", daemon[name].start)	
			local argv_type = ffi.typeof("const char *[?]")
			local argv = argv_type(#daemon[name].args, daemon[name].args)
			argv[#daemon[name].args] = nil

			ffi.C.execv(daemon[name].start, argv)

			--
			-- if we get here then the exec has failed
			--
			ffi.C.exit(20)
		else 
			ffi.C.exit(0)
		end
--		p.exec(daemon[name].start, daemon[name].args)
--		ffi.C.execv(exec_str)
	else
		-- parent
		print("we just forked, our pid is "..tostring(cpid))
		local st = ffi.new("int [1]", 0)
		 
		local rc = ffi.C.waitpid(cpid, st, 0)
		print("rc = "..tostring(rc).." status=" .. st[1])
	end

end

--
-- Interface to the C readlink call... returns a lua string
--
function readlink(path)
	local buf = ffi.new("char [?]", 1024)
	local rc = ffi.C.readlink(path, buf, 1024)
	if(rc > 0) then return ffi.string(buf) end
	return nil
end

--
-- Read the name from the proc stat file
--
function readname(pid)
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
function get_pidinfo()
	local rc = { ["pid"] = {}, ["exe"] = {}, ["name"] = {} }

	for pid in lfs.dir("/proc") do
		if pid:match("^%d+") then
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


--run_daemon("ntpd")

local pids = get_pidinfo()

local bash = pids.exe["/usr/bin/bash"]
for _,p in ipairs(bash) do
	print("PID="..p)
end





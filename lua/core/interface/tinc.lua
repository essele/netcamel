#!./luajit
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

--require("lib.log")

local TINCD = "/usr/sbin/tincd"
local TINC = "/usr/sbin/tinc"

--
-- Start a tinc instance... build all the config files and then
-- start the service.
--
local function start_tinc(ifname, cf)
	--
	-- Build a set of information to pass into the ppp script so that
	-- it can be a bit more clever
	--
	local vars = {
		["ip"]					= cf["ip"],
		["logfile"] 			= "/tmp/tinc/"..ifname.."/script.log",
		["no-defaultroute"] 	= cf["no-defaultroute"],
		["no-resolv"]			= cf["no-resolv"],
		["resolver-pri"] 		= cf["resolver-pri"],
		["defaultroute-pri"] 	= cf["defaultroute-pri"]
	}

	--
	-- Build the command line args. For ppp it's just simply a call with a logfile
	-- so that we can get the output of the daemon.
	--
	local args = { 	"--config=/tmp/tinc/"..ifname,
					"--net="..ifname,
					"--pidfile=/tmp/tinc/"..ifname.."/tinc.pid",
					"--logfile=/tmp/tinc/"..ifname.."/tinc.log" }

	local stop_args = {  "--config=/tmp/tinc/..ifname",	
						 "--net="..ifname,
						 "--pidfile=/tmp/tinc/"..ifname.."/tinc.pid",
						 "stop" }

	--
	-- Use the service framework to start the service so we can track it properly
	-- later
	--
	lib.service.define("tinc."..ifname, {
		["binary"] = TINCD,
		["args"] = args,
		["vars"] = vars,
		["maxkilltime"] = 2500,

		["start"] = "ASDAEMON",
		["stop"] = "BYCOMMAND",
		["stop_binary"] = TINC,
		["stop_args"] = stop_args,
	})

	lib.log.log("info", "starting tinc for net "..ifname)

	local rc, err = lib.service.start("tinc."..ifname)
	print("rc="..tostring(rc).." err="..tostring(err))

	--if not rc then return false, "DHCP start failed: "..err end
	return true
end
local function stop_pppoe(ifname)
	lib.log.log("info", "stopping tinc for net "..ifname)

	local rc, err = lib.service.stop("tinc."..ifname)
	print("rc="..tostring(rc).." err="..tostring(err))

	--
	-- Remove the definition
	--
	lib.service.remove("tinc."..ifname)
end

--
-- Stop a tinc instance... stop the daemon and then delete all the
-- config files.
--
local function stop_tinc()
end


--
-- We need to build the config for a given tinc instance,so we make
-- sure the main tinc directory is present and then create a subdir
-- for our instance.
--
local function configure_instance(net)
	local idir = "/tmp/tinc/"..net

	lib.file.create_directory("/tmp/tinc")
	
	--
	-- Clean out any old directory...
	--
	lib.file.remove_directory(idir)
	lib.file.create_directory(idir)

	local cf = node_vars("/interface/tinc/*"..net, CF_new)
	local tinccf = [[
		#
		# <automatically generated tinc.conf - do not edit>
		#
		Name = {{hostname}}

		ConnectTo = {{connect-to}}
	]]

	create_config_file(idir.."/tinc.conf", tinccf, cf)
	lib.file.create_symlink(idir.."/tinc-up", "/netcamel/scripts/tinc.script")
	lib.file.create_symlink(idir.."/tinc-down", "/netcamel/scripts/tinc.script")
	lib.file.create_symlink(idir.."/host-up", "/netcamel/scripts/tinc.script")
	lib.file.create_symlink(idir.."/host-down", "/netcamel/scripts/tinc.script")
	lib.file.create_symlink(idir.."/subnet-up", "/netcamel/scripts/tinc.script")
	lib.file.create_symlink(idir.."/subnet-down", "/netcamel/scripts/tinc.script")

	--
	-- Write out the private keys
	--
	if cf["key-rsa-private"] then 
		lib.file.create_with_data(idir.."/rsa_key.priv", cf["key-rsa-private"], 400) 
	end
	if cf["key-ed25519-private"] then 
		lib.file.create_with_data(idir.."/ed25519_key.priv", cf["key-ed25519-private"], 400) 
	end

	--
	-- Now process each of the hosts
	--
	lib.file.create_directory(idir.."/hosts")
	for hnode in each(node_list("/interface/tinc/*"..net.."/host", CF_new, true)) do
		local host = hnode:sub(2)
		print("host="..host.." hnode="..hnode)
		local hcf = node_vars("/interface/tinc/*"..net.."/host/"..hnode, CF_new)
		local tinchcf = [[
			#
			# <automatically generated tinc host file - do not edit>
			#
			Address = {{ip}}
			Port = {{port}}
			Subnet = {{subnet}}

			{{key-rsa-public}}

			{{key-ed25519-public}}
		]]
		create_config_file(idir.."/hosts/"..host, tinchcf, hcf)
	end

end



local function tinc_precommit(changes)
	--
	--    -- Do the interface level precommit
	--
	local rc, err = interface_precommit(changes)
	if not rc then return false, err end

	return true
end

local function tinc_commit(changes)
	configure_instance("tnet")
	local cf = node_vars("/interface/tinc/*tnet", CF_new)

	start_tinc("tnet", cf)	

	return true
end

--
-- If we set the key-generate item then we will actually generate the private keys
--
local function action_key_generate(v, mp, kp)
	local undo = { delete = {}, add = {} }

	kp = kp:gsub("/[^/]+$", "")
	kp_hostname = kp .. "/hostname"

	local cf = node_vars(kp, CF_new)
	print("HOSTNAME: "..tostring(cf.hostname))

	local hostname = cf.hostname
	if not hostname then
		print("unable to determin hostname to use for local node")
		return
	end

	if CF_new[kp_hostname] ~= hostname then
		-- Prepare undo for any hostname change
		prep_undo(undo, CF_new, kp_hostname)

		CF_new[kp_hostname] = hostname
	end

	--
	-- Create the keys in a temp dir and then clean up...
	--
	local tmpdir = lib.file.create_directory()
	if v == "rsa" or v == "both" then
		lib.runtime.execute("/usr/sbin/tinc", { "--config", tmpdir.dirname, "--batch", "generate-rsa-keys" })
	
		local rsa_public = lib.file.read(tmpdir.dirname.."/rsa_key.pub") or "FAILED"
		local rsa_private = lib.file.read(tmpdir.dirname.."/rsa_key.priv") or "FAILED"
	
		prep_undo(undo, CF_new, kp.."/key-rsa-private")
		prep_undo(undo, CF_new, kp.."/host/*"..hostname.."/key-rsa-public")
		CF_new[kp.."/key-rsa-private"] = rsa_private
		CF_new[kp.."/host/*"..hostname.."/key-rsa-public"] = rsa_public
	end
	if v == "ed25519" or v == "both" then
		lib.runtime.execute("/usr/sbin/tinc", { "--config", tmpdir.dirname, "--batch", "generate-ed25519-keys" })
	
		local ed_public = lib.file.read(tmpdir.dirname.."/ed25519_key.pub") or "FAILED"
		local ed_private = lib.file.read(tmpdir.dirname.."/ed25519_key.priv") or "FAILED"

		prep_undo(undo, CF_new, kp.."/key-ed25519-private")
		prep_undo(undo, CF_new, kp.."/host/*"..hostname.."/key-ed25519-public")
		CF_new[kp.."/key-ed25519-private"] = ed_private
		CF_new[kp.."/host/*"..hostname.."/key-ed25519-public"] = ed_public
	end
	tmpdir:cleanup()
	return true, undo
end

--
-- Work out the default hostname for tinc ... this will be the
-- hostname defined in system (or that default)
--
-- node_vars will fill in the default for them...
--
local function tinc_hostname(mp, kp, kv)
	local syscf = node_vars("/system", kv)
	return syscf.hostname
end


--
-- tinc vpn interfaces...
--
master["/interface/tinc"] = {
	["commit"] = tinc_commit,
	["precommit"] = tinc_precommit,
	["with_children"] = 1,
}

master["/interface/tinc/*"] =							{ ["style"] = "tinc_if" }
master["/interface/tinc/*/ip"] =						{ ["type"] = "ipv4_nm" }
master["/interface/tinc/*/hostname"] =					{ ["type"] = "OK",
														  ["default"] = tinc_hostname, }
master["/interface/tinc/*/key-rsa-private"] =			{ ["type"] = "file/text" }
master["/interface/tinc/*/key-ed25519-private"] =		{ ["type"] = "file/text" }
master["/interface/tinc/*/connect-to"] =				{ ["type"] = "OK", ["list"] = true }
master["/interface/tinc/*/key-generate"] =				{ ["type"] = "select", 
														  ["options"] = { "rsa", "ed25519", "both" },
														  ["action"] = action_key_generate }
master["/interface/tinc/*/host"] =						{}
master["/interface/tinc/*/host/*"] =					{ ["style"] = "OK" }
master["/interface/tinc/*/host/*/ip"] =					{ ["type"] = "ipv4" }
master["/interface/tinc/*/host/*/port"] =				{ ["type"] = "OK" }
master["/interface/tinc/*/host/*/subnet"] =				{ ["type"] = "ipv4_nm", ["list"] = true }
master["/interface/tinc/*/host/*/key-rsa-public"] =		{ ["type"] = "file/text" }
master["/interface/tinc/*/host/*/key-ed25519-public"] =	{ ["type"] = "file/text" }

--
-- Deal with triggers and depdencies
--
function interface_tinc_init()
	--
	-- Tell the interface module we are here
	--
	interface_register({ module = "tinc", path = "/interface/tinc", 
						if_numeric = "tinc%", if_alpha = "%", 
						classes = { "all", "vpn" } })
end

return {
	init = interface_tinc_init
}


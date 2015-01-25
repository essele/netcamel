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

require("log")
require("file")
local runtime = require("runtime")
local service = require("service")


--
-- Start a tinc instance... build all the config files and then
-- start the service.
--
local function start_tinc()
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

	create_directory("/tmp/tinc")
	create_directory(idir)

	local cf = node_vars("/interface/tinc/*"..net, CF_new)
	local tinccf = [[
		#
		# <automatically generated tinc.conf - do not edit>
		#
		Name = {{hostname}}

		blah
	]]

	create_config_file(idir.."/tinc.conf", tinccf, cf)

	--
	-- Now process each of the hosts
	--
	create_directory(idir.."/hosts")
	for hnode in each(node_list("/interface/tinc/*"..net.."/host", CF_new, true)) do
		local host = hnode:sub(2)
		print("host="..host.." hnode="..hnode)
		local hcf = node_vars("/interface/tinc/*"..net.."/host/"..hnode, CF_new)
		local tinchcf = [[
			#
			# <automatically generated tinc host file - do not edit>
			#
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
	configure_instance("obnet")
	


	return true
end

--
--
--
VALIDATOR["tinc_if"] = interface_validate_number_and_alpha

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
	local tmpdir = create_directory()
	if v == "rsa" or v == "both" then
		runtime.execute("/usr/sbin/tinc", { "--config", tmpdir.dirname, "--batch", "generate-rsa-keys" })
	
		local rsa_public = read_file(tmpdir.dirname.."/rsa_key.pub") or "FAILED"
		local rsa_private = read_file(tmpdir.dirname.."/rsa_key.priv") or "FAILED"
	
		prep_undo(undo, CF_new, kp.."/key-rsa-private")
		prep_undo(undo, CF_new, kp.."/host/*"..hostname.."/key-rsa-public")
		CF_new[kp.."/key-rsa-private"] = rsa_private
		CF_new[kp.."/host/*"..hostname.."/key-rsa-public"] = rsa_public
	end
	if v == "ed25519" or v == "both" then
		runtime.execute("/usr/sbin/tinc", { "--config", tmpdir.dirname, "--batch", "generate-ed25519-keys" })
	
		local ed_public = read_file(tmpdir.dirname.."/ed25519_key.pub") or "FAILED"
		local ed_private = read_file(tmpdir.dirname.."/ed25519_key.priv") or "FAILED"

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


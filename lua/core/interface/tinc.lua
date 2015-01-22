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
local runtime = require("runtime")
local service = require("service")

local function tinc_precommit(changes)
end

local function tinc_commit(changes)
end

--
--
--
VALIDATOR["tinc_if"] = function(v, kp)
	local err = "interface numbers should be [nnn] only"
	if v:len() == 0 then return PARTIAL end
	if v:match("^%d+$") then return OK end
	return FAIL, err
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
	if v == "rsa" or v == "both" then
		prep_undo(undo, CF_new, kp.."/key-rsa-private")
		prep_undo(undo, CF_new, kp.."/host/*"..hostname.."/key-rsa-public")
		CF_new[kp.."/key-rsa-private"] = "a private key rsa"
		CF_new[kp.."/host/*"..hostname.."/key-rsa-public"] = "a public key rsa"
	end
	if v == "ed25519" or v == "both" then
		prep_undo(undo, CF_new, kp.."/key-ed25519-private")
		prep_undo(undo, CF_new, kp.."/host/*"..hostname.."/key-ed25519-public")
		CF_new[kp.."/key-ed25519-private"] = "a private key ed25519"
		CF_new[kp.."/host/*"..hostname.."/key-ed25519-public"] = "a public key ed25519"
	end
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
master["/interface/tinc/*/key-rsa-private"] =			{ ["type"] = "OK" }
master["/interface/tinc/*/key-ed25519-private"] =		{ ["type"] = "OK" }
master["/interface/tinc/*/connect-to"] =				{ ["type"] = "OK", ["list"] = true }
master["/interface/tinc/*/key-generate"] =				{ ["type"] = "select", 
														  ["options"] = { "rsa", "ed25519", "both" },
														  ["action"] = action_key_generate }
master["/interface/tinc/*/host"] =						{}
master["/interface/tinc/*/host/*"] =					{ ["style"] = "OK" }
master["/interface/tinc/*/host/*/ip"] =					{ ["type"] = "ipv4" }
master["/interface/tinc/*/host/*/key-rsa-public"] =		{ ["type"] = "OK" }
master["/interface/tinc/*/host/*/key-ed25519-public"] =	{ ["type"] = "OK" }

--
-- Deal with triggers and depdencies
--
function interface_tinc_init()
	--
	-- Tell the interface module we are here
	--
	interface_register("tinc", "tinc")
end


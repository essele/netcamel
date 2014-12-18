#!./luajit
--------------------------------------------------------------------------------
--  This file is part of OpenTik
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


--
-- Take a prefix and build a hash of elements and values (using the
-- defaults it provided in the master config)
--
--[[
function config_vars(prefix, kv)
	local rc = {}

	for k in each(node_list(prefix, master)) do
		local kp = prefix .. "/" .. k
		if master[kp].default then rc[k] = master[kp].default end
	end
	for k in each(node_list(prefix, kv)) do rc[k] = kv[prefix .. "/" .. k] end
	return rc
end
]]--

--
-- Output build a string that's a format output once for each
-- value of a list
--
function sprintf_list(format, list)
	local rc = ""
	for v in each(list) do
		rc = rc .. string.format(format, v)
	end
	return rc
end

--
-- DNSMASQ is fairly simple since we don't really process any changes,
-- we will completely re-write the config any time there is a change
-- and restart (or start or stop) the daemon as needed.
--
local function dnsmasq_commit(changes)
	print("Hello From DNSMASQ")

	--
	-- Check to see if we have a config at all!
	--
	if not node_exists("dns", CF_new) and not node_exists("dhcp", CF_new) then
		print("No DNSMASQ config required, stopping daemon")
		return true
	end

	--
	-- First process the forwarding section
	--
	if node_exists("dns/forwarding", CF_new) then
		local forwarding = node_vars("dns/forwarding", CF_new)
		io.write("# -- forwarding --\n\n")
		io.write(string.format("cache-size %s\n", forwarding["cache-size"]))
		io.write(sprintf_list("interface %s\n", forwarding["listen-on"] or {}))
		io.write(sprintf_list("server %s\n", forwarding.server or {}))
		io.write(sprintf_list("options %s\n", forwarding.options or {}))
		io.write("\n")
	end

	--
	-- Domain-Match
	--
	if node_exists("dns/domain-match", CF_new) then
		io.write("# -- domain-match --\n\n")
		for v in each(node_list("dns/domain-match", CF_new)) do
			local dmatch = node_vars("dns/domain-match/"..v, CF_new)
			if dmatch.group then
				io.write("# ("..v:sub(2)..")\n")
				io.write(sprintf_list("ipset /%s/"..dmatch.group.."\n", dmatch.domain or {}))
			end
		end
		io.write("\n")
	end
	return true
end

--
-- The precommit function must ensure that anything we reference
-- exists in the new config so that we know we will reference valid
-- items and hence ensure the commit is as likely as possible to 
-- succeed in one go.
-- 
-- For dnsmasq this means checking any referenced interfaces and
-- ipsets
--
local function dnsmasq_precommit(changes)
	--
	-- dns/forwarding has a 'listen-on' interface list
	--
	if CF_new["dns/forwarding/listen-on"] then
		for interface in each(CF_new["dns/forwarding/listen-on"]) do
			if not node_exists(interface_path(interface), CF_new) then
				return false, string.format("dns/forwarding/listen-on interface not valid: %s", interface)
			end
		end
	end
	--
	-- dns/domain-match has an ipset reference
	--
	if node_exists("dns/domain-match", CF_new) then
		print("DOMAINMATCH")
		for node in each(matching_list("dns/domain-match/%/group", CF_new)) do
			local set = CF_new[node]
			if not node_exists("iptables/set/*"..set, CF_new) then
				return false, string.format("%s ipset not valid: %s", node, set)
			end
		end
	end
	return true
end


VALIDATOR["text_label"] = function(v, kp)
	return OK
end

VALIDATOR["ipset"] = function(v, kp)
	return OK
end

--
-- Main interface config definition
--
master["dns"] = { ["commit"] = dnsmasq_commit,
				  ["precommit"] = dnsmasq_precommit }

master["dns/forwarding"] = {}
master["dns/forwarding/cache-size"] = { ["type"] = "OK", ["default"] = 200 }
master["dns/forwarding/listen-on"] = { ["type"] = "OK", ["list"] = 1 }
master["dns/forwarding/server"] = { ["type"] = "OK", ["list"] = 1 }
master["dns/forwarding/options"] = { ["type"] = "OK", ["list"] = 1 }

master["dns/domain-match"] = {}
master["dns/domain-match/*"] = { ["style"] = "text_label" }
master["dns/domain-match/*/domain"] = { ["type"] = "OK", ["list"] = 1 }
master["dns/domain-match/*/group"] = { ["type"] = "ipset" }


master["dns/file"] = { ["type"] = "file/text" }

master["dhcp"] = {  ["delegate"] = "dns" }
master["dhcp/flag"] = { ["type"] = "string" }



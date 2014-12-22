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
-- NTP has a number of configuration options which we need to worry about,
-- also, if we are running the server as a server we need to trigger the
-- (input-standard-services) iptable macro
--
local function ntp_commit(changes)
	print("Hello From NTP")

	--
	-- Check to see if we have a config at all!
	--
	if not node_exists("service/ntp", CF_new) then
		print("No NTP config required, stopping daemon")
		return true
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
local function ntp_precommit(changes)
	--
	-- dns/forwarding has a 'listen-on' interface list
	--
--[[
	if CF_new["dns/forwarding/listen-on"] then
		for interface in each(CF_new["dns/forwarding/listen-on"]) do
			if not node_exists(interface_path(interface), CF_new) then
				return false, string.format("dns/forwarding/listen-on interface not valid: %s", interface)
			end
		end
	end
]]--
	return true
end


--
-- Main interface config definition
--
master["service"] = {}
master["service/ntp"] = { 
	["commit"] = ntp_commit,
	["precommit"] = ntp_precommit 
}

master["service/ntp/enable"] = { ["type"] = "bool" }


function ntp_init()
	--
	-- If we change the settings we will need to adjust the iptables
	-- macro
	--
	add_trigger("service/ntp/enable", "iptables/*joe/@blahblahblah")
end


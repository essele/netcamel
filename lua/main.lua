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

package.path = "/usr/share/lua/5.1/?.lua;./lib/?.lua"
package.cpath = "/usr/lib/lua/5.1/?.so;./lib/?.so"

-- global level packages
--require("lfs")
require("utils")
require("config")
require("execute")
--require("api")

-- different namespace packages
base64 	= require("base64")
ffi 	= require("ffi")
service = require("service")
posix   = require("posix")

--
-- global configuration spaces
--
master={}
current={}
new={}

--
-- work out which are all of the core modules
--
local core_modules = {}
--for m in lfs.dir("core") do
for _,m in ipairs(posix.glob("core/*.lua")) do
	local mname = m:match("^core/(.*)%.lua$")
	if mname then table.insert(core_modules, mname) end
end
table.sort(core_modules)

--
-- Import each of the modules...
--
for module in each(core_modules) do
	dofile("core/" .. module .. ".lua")
end

--
-- If the module has a <modname>_init() function then we call it, the
-- intent of this is to initialise the depends and triggers once we know
-- that all the structures are initialised.
--
for module in each(core_modules) do
	local funcname = string.format("%s_init", module)
	if _G[funcname] then
		-- TODO: return code (assert)
		local ok, err = pcall(_G[funcname])
		if not ok then assert(false, string.format("[%s]: %s code error: %s", key, funcname, err)) end
	end
end



function other() 
	print("other: dummy function called")
end


master["test"] = { ["commit"] = other }
master["test/lee"] = { ["type"] = "name" }



--current["interface/ethernet/*0/ip"] = "192.168.95.1/24"
current["interface/ethernet/*1/ip"] = "192.168.95.2/24"
current["interface/ethernet/*2/ip"] = "192.168.95.33"
current["interface/ethernet/*2/mtu"] = 1500
--current["interface/ethernet/*0/mtu"] = 1500

current["dns/file"] = "afgljksdhfglkjsdhf glsjdfgsdfg\nsdfgkjsdfkljg\nsdfgsdg\nsdfgsdfg\n"

current["interface/pppoe/*0/user-id"] = "lee"
current["interface/pppoe/*0/attach"] = "eth0"
current["interface/pppoe/*0/password"] = "hidden"
current["interface/pppoe/*0/default-route"] = "auto"
current["interface/pppoe/*0/mtu"] = 1492
current["interface/pppoe/*0/disabled"] = true

new = copy_table(current)
new["interface/ethernet/*1/ip"] = "192.168.95.4/24"
new["interface/ethernet/*1/disabled"] = true
new["interface/ethernet/*0/ip"] = "192.168.98.44/24"
new["interface/ethernet/*0/ip"] = nil
--new["interface/ethernet/*0/disabled"] = true
new["interface/ethernet/*0/mtu"] = 1492
--current["interface/ethernet/bill"] = "nope"

new["iptables/*filter/*INPUT/rule/*0001"] = "(stateful-firewall)"
new["iptables/*filter/*INPUT/rule/*0002"] = "(input-allowed-services)"
new["iptables/*filter/*FORWARD/policy"] = "ACCEPT"
new["iptables/*filter/*FORWARD/rule/*10"] = "-s 12.3.4 -p {{fred}} -j ACCEPT"
new["iptables/*filter/*FORWARD/rule/*20"] = "-d -a {{bill}} -b {{fred}} 2.3.4.5 -j DROP"
new["iptables/*filter/*FORWARD/rule/*30"] = "-d 2.3.4.5 -j DROP"
new["iptables/*filter/*FORWARD/rule/*40"] = "-d 2.3.4.5 -j another-chain -m fred"

new["iptables/*filter/*custom-chain/rule/*10"] = "-d 2.3.4.5 -j another-chain -m fred"
new["iptables/*filter/*another-chain/rule/*10"] = "-d 2.3.4.5 -j ACCEPT -m fred"
--new["iptables/*filter/*another-chain/rule/*20"] = "-d 2.3.4.5 -j custom-chain -m fred"

new["service/ntp/enable"] = true
new["service/ntp/provide-service"] = true
new["service/ntp/listen-on"] = { "ethernet/0", "pppoe/0" }
new["service/ntp/server"] = { "0.pool.ntp.org", "1.pool.ntp.org" }

--
--
current["iptables/set/*vpn-dst/type"] = "hash:ip"
current["iptables/set/*vpn-dst/item"] = { "1.2.3.4", "2.2.2.2", "8.8.8.8" }

new["iptables/set/*vpn-dst/type"] = "hash:ip"
new["iptables/set/*vpn-dst/item"] = { "2.2.2.2", "8.8.8.8" }

new["iptables/variable/*fred/value"] = { "fred-one", "fred-two" }
new["iptables/variable/*bill/value"] = { "billX" }

new["dns/forwarding/server"] = { "one", "three", "four" }
new["dns/forwarding/cache-size"] =150
new["dns/forwarding/listen-on"] = { "ethernet/0" }
--new["dns/forwarding/listen-on"] = { "pppoe4" }
--new["dns/forwarding/options"] = { "no-resolv", "other-stuff" }

new["dns/domain-match/*xbox/domain"] = { "XBOXLIVE.COM", "xboxlive.com", "live.com" }
new["dns/domain-match/*xbox/group"] = "vpn-dst"
new["dns/domain-match/*iplayer/domain"] = { "bbc.co.uk", "bbci.co.uk" }
new["dns/domain-match/*iplayer/group"] = "vpn-dst"

new["dhcp/flag"] = "hello"


new = nil
current = nil

CF_new = new
CF_current = current


--[[
--rc, err = set(new, "interface/ethernet/0/mtu", "1234")
--if not rc then print("ERROR: " .. err) end
rc, err = set(new, "iptables/filter/INPUT/rule/0030", "-a -b -c")
if not rc then print("ERROR: " .. err) end

rc, err = set(new, "iptables/nat/PREROUTING/rule/0010", "-a -b -c")
rc, err = set(new, "iptables/mangle/PREROUTING/rule/0010", "-a -b -x {{fred}} -c")
rc, err = set(new, "iptables/nat/POSTROUTING/rule/0020", "-a -b -c")


--delete(new, "iptables")
delete(new, "interface/ethernet/2")
--delete(new, "dns")
--delete(new, "dhcp")

show(current, new)
--dump(new)

--os.exit(0)

--dump(new)
----local xx = import("sample")
--
----show(xx, xx)
--

--print("\n\n")

]]--


--
-- INIT (commit)
--
-- current = empty (i.e. no config)
-- new = saved_config (i.e. the last properly saved)
-- execute, then write out current.
--
-- OTHER OPS (commit)
--
-- current = current
-- new = based on changes
-- execute, then write out current.
--
-- SAVE (save)
--
-- take current and write it out as saved.
--

CF_current = {}
CF_new = {}

while true do
	io.write("> ")
	local cmdline = io.read("*l")
	if not cmdline then break end

	local cmd = cmdline:match("^%s*([^%s]+)")
	if cmd == "show" then
		show(CF_current, CF_new)
	elseif cmd == "commit" then
		local rc, err = commit(CF_current, CF_new)
		if not rc then 
			print("Error: " .. err)
			goto continue
		end
		CF_current = copy_table(CF_new)
	elseif cmd == "set" then
		local item, value = cmdline:match("set%s+([^%s]+)%s+([^%s]+)")
		if not item then
			print("syntax error")
			goto continue
		end
		print("Would set ["..item.."] to ["..value.."]")
		local rc, err = set(CF_new, item, value)
		if not rc then print("Error: " .. err) end
	end
::continue::
end

os.exit(0)

CF_current = {}
CF_new = import("etc/current.cf")

rc, err = commit(CF_current, CF_new)
if not rc then print(err) os.exit(1) end


--
-- If we are successful then we can write out the new current list
--


--service.start("ntpd")
--service.restart("ntpd")

--print("ST="..tostring(service.status("ntpd")))



--dump("etc/current.cf", CF_new)



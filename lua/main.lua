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

package.path = "./lib/?.lua"
package.cpath = "./lib/?.so"

-- global level packages
--require("lfs")
require("utils")
require("config")
--require("api")

-- different namespace packages
local base64 = require("base64")

--
-- global configuration spaces
--
master={}
current={}
new={}

--
-- import all of the core modules
--
dofile("core/interface.lua")
dofile("core/iptables.lua")
dofile("core/dnsmasq.lua")


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

new["iptables/*filter/*FORWARD/policy"] = "ACCEPT"
new["iptables/*filter/*FORWARD/rule/*10"] = "-s 12.3.4 -p [fred] -j ACCEPT"
new["iptables/*filter/*FORWARD/rule/*20"] = "-d -a [bill] -b [fred] 2.3.4.5 -j DROP"
new["iptables/*filter/*FORWARD/rule/*30"] = "-d 2.3.4.5 -j DROP"
--
--
current["iptables/set/*vpn-dst/type"] = "hash:ip"
current["iptables/set/*vpn-dst/item"] = { "1.2.3.4", "2.2.2.2", "8.8.8.8" }

new["iptables/set/*vpn-dst/type"] = "hash:ip"
new["iptables/set/*vpn-dst/item"] = { "2.2.2.2", "8.8.8.8" }

new["iptables/variable/*fred/value"] = { "one", "rwo" }

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


CF_new = new
CF_current = current



--rc, err = set(new, "interface/ethernet/0/mtu", "1234")
--if not rc then print("ERROR: " .. err) end
rc, err = set(new, "iptables/filter/INPUT/rule/0030", "-a -b -c")
if not rc then print("ERROR: " .. err) end

rc, err = set(new, "iptables/nat/PREROUTING/rule/0010", "-a -b -c")
rc, err = set(new, "iptables/mangle/PREROUTING/rule/0010", "-a -b -x [fred] -c")
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
--
-- Now run through and check the dependencies
--
function execute_work_using_func(funcname, work_list)
	while next(work_list) do
		local activity = false

		for key, fields in pairs(work_list) do
			print("Work: " .. key)
			for v in each(fields) do
				print("\t" .. v)
			end
			for depend in each(master[key]["depends"]) do
				print("\tDEPEND: " .. depend)
				if work_list[depend] then
					print("\tSKIP THIS ONE DUE TO DEPENDS")
					goto continue
				end
			end
			print("DOING " .. funcname .. " WORK for ["..key.."]\n")
			local func = master[key][funcname]
			if func then
				local work_hash = values_to_keys(work_list[key])

				local ok, rc, err = pcall(func, work_hash)
				if not ok then return false, string.format("[%s]: %s code error: %s", key, funcname, rc) end
				if not rc then return false, string.format("[%s]: %s failed: %s", key, funcname, err) end

			end
			work_list[key] = nil
			activity = true
		::continue::
		end

		if not activity then return false, "some kind of dependency loop" end
	end
	return true
end

--
-- Build the work list
--
work_list = build_work_list(current, new)

--
-- Copy worklist and run precommit
--
pre_work_list = copy_table(work_list)
local rc, err = execute_work_using_func("precommit", pre_work_list)
if not rc then print(err) os.exit(1) end

--
-- Now the main event
--
local rc, err = execute_work_using_func("commit", work_list)
if not rc then print(err) os.exit(1) end

#!/usr/bin/luajit
--------------------------------------------------------------------------------
--  This file is part of NetCamel
--  Copyright (C) 2014,15 Lee Essen <lee.essen@nowonline.co.uk>
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
package.path = "./lib/?.lua;" .. package.path

local db = require("db")

TABLE["resolvers"] = { 
	schema = { key="string key", priority="integer", value="sring" },
	priority_resolvers = "select * from resolvers where priority = (select min(priority) from resolvers)",
	remove_with_key = "delete from resolvers where key = :key"
}
TABLE["defaultroutes"] = {
	schema = { key="string key", priority="integer", value="sring" },
	priority_defaultroutes = "select * from defaultroutes where priority = (select min(priority) from defaultroutes)",
	remove_with_key = "delete from defaultroutes where key = :key"
}

local rc, err = db.init()

local rc, err = db.create("resolvers")
if not rc then print("INSERT ERR: " .. err ) os.exit(1) end
local rc, err = db.create("defaultroutes")
if not rc then print("INSERT ERR: " .. err ) os.exit(1) end

--local rc, err = db.insert("resolvers", { key = "mykey", priority = 34, value = "myval" })
--if not rc then print("INSERT ERR: " .. err ) os.exit(1) end

--local rc, err = query("resolvers", "remove_with_key", "mykey")


local resolvers, err = db.query("resolvers", "priority_resolvers")
if not resolvers then print("QFAIL: "..err) end
print("resolvers = "..tostring(resolvers))
print("Rcount = "..#resolvers)

print("V="..resolvers[1].value)


--for row in db:nrows("SELECT * FROM resolvers where priority = (select min(priority) from resolvers)") do
--	print("key="..row.key.." pri="..row.priority.." value="..row.value)
--end

db.close()



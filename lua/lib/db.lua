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

--
-- TRANSIENT STORAGE using Sqlite3, this will be created at boot time
-- but then used by various systems to facilitate concurrent updates
-- and communication.
--

TABLE = {}

local sqlite3 = require("lsqlite3")

--
-- Open the database and allow us 2000ms for busy timeouts, we shouldn't get
-- anywhere near that, but we do have multiple processes accessing the same
-- tables so there are conflicts.
--
local db = sqlite3.open("/tmp/netcamel_t.sqlite3")
db:busy_timeout(2000)

--
-- Create a table given the spec from the TABLE table.
--
local function create_table(name)
	local sql, rc
	local tabdef = TABLE[name] and TABLE[name].schema
	if not tabdef then return false, "unknown table" end

	--
	-- Prepare the fields for the table
	--
	local fields = {}
	for k,v in pairs(tabdef) do table.insert(fields, "'"..k.."' "..v) end

	--
	-- Drop the old one if it exists
	--
	rc = db:exec("drop table if exists '"..name.."'")
	if rc ~= 0 then return false, "unable to drop table" end

	--
	-- Create the new table
	--
	rc = db:exec(string.format("create table '%s' (%s)", name, table.concat(fields, ", ")))
	if rc ~= 0 then return false, "unable to create table "..name..": "..db:errmsg() end

	--
	-- Populate the queries
	--
	rc = db:exec("delete from __queries where name = '"..name.."'")
	if rc ~= 0 then return false, "unable to delete old queries for table "..name..": "..db:errmsg() end
	local stmt = db:prepare("insert into __queries values (?, ?, ?)")
	if not stmt then return false, "queryadd: "..db:errmsg() end
	for k, v in pairs(TABLE[name]) do
		if k ~= "schema" then
			stmt:reset()
			stmt:bind_values(name, k, v)
			stmt:step()
		end
	end
	stmt:finalize()

	return true
end

--
-- Insert items into a table based on the fields provided in a hash
--
local function insert_into_table(name, item)
	local vals, args = "", ""
	local rc, stmt

	--
	-- Prepare the fields and values strings
	--
	for k,_ in pairs(item) do
		vals = vals .. ((vals == "" and "") or ", ") .. "'"..k.."'"
		args = args .. ((args == "" and "") or ", ") .. ":" .. k
	end

	--
	-- Preapre the sql and bind
	--
	stmt = db:prepare("insert into '"..name.."' ("..vals..") VALUES ("..args..")")
	if not stmt then return false, "insert prepare failed: "..db:errmsg() end
	rc = stmt:bind_names(item)
	if rc ~= sqlite3.OK then 
		stmt:finalize()
		return false, "insert bind failed: "..db:errmsg() 
	end

	--
	-- Execute the insert
	--
	rc = stmt:step()
	if rc ~= sqlite3.DONE then 
		stmt:finalize()
		return false, "insert step failed: "..db:errmsg() 
	end

	stmt:finalize()
	return true
end

local function custom_query(sql)
	local rc = {}
	for row in db:nrows(sql) do
		table.insert(rc, row)
	end
	return rc
end

--
-- Return a list of all the results of a query that is pre-populated in the
-- TABLE list
--
local function query(name, qname, ...)
	--
	-- Find the query from the __queries table...
	--
	local sql = "select sql from __queries where name = ? and query = ?"
	local stmt = db:prepare(sql)
	if not stmt then return false, "pre-query prep failed: "..db:errmsg() end
	if stmt:bind_values(name, qname) ~= sqlite3.OK then 
		stmt:finalize()
		return false, "pre-bind failed: "..db:errmsg() 
	end
	local res = (stmt:nrows()(stmt))
	if not res or not res.sql then 
		stmt:finalize()
		return false, "unable to find query: "..db:errmsg() 
	end
	stmt:finalize()

	--
	-- Prepare and execute the query
	--
	sql = res.sql
	local stmt = db:prepare(sql)
	if not stmt then return false, "query failed: "..db:errmsg() end

	if select('#', ...) > 0 then
		if type(select(1, ...)) == "table" then
			if stmt:bind_names(select(1, ...)) ~= sqlite3.OK then 
				stmt:finalize()
				return false, "bind failed: "..db:errmsg() 
			end
		else
			if stmt:bind_values(...) ~= sqlite3.OK then 
				stmt:finalize()
				return false, "bind failed: "..db:errmsg() 
			end
		end
	end

	--
	-- Build the results
	--
	local rc = {}
	for row in stmt:nrows(sql) do table.insert(rc, row) end
	stmt:finalize()
	return rc
end

local function close()
	db:close()
end


local function init()
	--
	-- Create the __queries table
	--
--		pragma journal_mode=WAL;
	local rc = db:exec[[
		drop table if exists __queries;
		create table __queries ( name string, query string, sql string );
	]]

	--
	-- Create each table from the TABLE hash
	--
	for name, tabdef in pairs(TABLE) do
		print("Creating table: "..name)
		local rc, err = create_table(name)
		if not rc then print("err="..err) end
	end

	return true
end

return {
	init = init,
	create = create_table,
	query = query,
	insert = insert_into_table,
	close = close,
}

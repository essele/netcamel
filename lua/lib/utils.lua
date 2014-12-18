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
-- Create a copy of the key/value list (or table)
--
function copy_table(t)
	local rc = {}
	for k, v in pairs(t) do
		if(type(v) == "table") then rc[k] = copy_table(v)
		else rc[k] = v end
	end
	return rc
end

--
-- Create a hash of all the values of a list
--
function values_to_keys(t)
	local rc = {}
	for _, k in ipairs(t) do rc[k] = 1 end
	return rc
end
function keys_to_values(t)
	local rc = {}
	for k, _ in pairs(t) do table.insert(rc, k) end
	return rc
end

--
-- Return the uniq sorted valies from a table (or two)
--
function sorted_values(kv1, kv2)
	local list = {}
	local uniq = {}

	if kv1 ~= nil then for _,v in pairs(kv1) do uniq[v] = 1 end end
	if kv2 ~= nil then for _,v in pairs(kv2) do uniq[v] = 1 end end
	for k,_ in pairs(uniq) do table.insert(list, k) end
	table.sort(list)
	return list
end

--
-- Return the uniq sorted keys from a table (or two)
--
function sorted_keys(kv1, kv2)
	local list = {}
	local uniq = {}

	if kv1 ~= nil then for k,_ in pairs(kv1) do uniq[k] = 1 end end
	if kv2 ~= nil then for k,_ in pairs(kv2) do uniq[k] = 1 end end
	for k,_ in pairs(uniq) do table.insert(list, k) end
	table.sort(list)
	return list
end

--
-- Add the second list to the first (updating the first)
--
function add_to_list(l1, l2)
	for _,v in ipairs(l2 or {}) do
		table.insert(l1, v)
	end
end

--
-- Find a given element within a list (cope with nil)
--
function in_list(list, item)
	list = list or {}

	for _,k in ipairs(list) do
		if k == item then return true end
	end
	return false
end

--
-- Return only the uniq items in a list (keep order)
--
function uniq(t)
	local rc, u = {}, {}
	
	for _,v in ipairs(t) do
		if not u[v] then
			table.insert(rc, v)
			u[v] = 1
		end
	end
	return rc
end

--
-- Utility each() iterator
--
function each(t)
	t = t or {}
	local i = 0

	return function()
		i = i + 1
		return t[i]
	end
end

--
-- Check to see if the prefix of line matches token, but where
-- the next char is either eol or the sep
--
function prefix_match(line, token, sep)
	if #token == 0 then return true end
	if line:sub(1, #token) == token then
		local c = line:sub(#token+1, #token+1)
		if c == "" or c == sep then return true end
	end
	return false
end


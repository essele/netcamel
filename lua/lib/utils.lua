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
-- Run a function for each element in a list, if true then
-- add the element to the results
--
function ifilter(list, func)
	local rc = {}
	for i, v in ipairs(list) do
		if func(v) then table.insert(rc, v) end
	end
	return rc
end

--
-- For a given list, run a function against each element
-- and replace the list element with the return from the func
--
function imap(list, func)
	for i, v in ipairs(list) do
		list[i] = func(v)
	end
end

--
-- Find an item within a list and insert items from a second list
--
function ireplace(list, item, new)
	for i, v in ipairs(list) do
		if v == item then
			table.remove(list, i)
			for _,n in ipairs(new) do
				table.insert(list, i, n)
				i = i + 1
			end
			return
		end
	end
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
-- Each, but backwards
--
function back_each(t)
	t = t or {}
	local i = #t

	return function()
		i = i - 1
		return t[i+1]
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

--
-- Split a string into a list, given a specific separator
--
function split(str, sep)
	local t = {}
	local function helper(line) table.insert(t, line) return "" end

	helper((str:gsub("(.-)"..sep, helper)))
	return t
end


--
-- Create a configuration file
--
-- We work out what the leading space is on the first line
-- and remove that from every subsequent line.
--
-- Also we replace [value] where value appears in dict.
-- If [value] is followed by newline, then it's considered part of
-- the value.
--
-- TODO: probably move somewhere else
--
function create_config_file(name, template, dict)
	local input = split(template, "\n")
	local output = {}

	-- work out leading space
	local lead = input[1]:match("^(%s+)") or ""

	-- now process each line
	for line in each(input) do
		local out = line:gsub("^"..lead, "")		-- remove leading space
		local var = out:match("{{([^}]+)}}")

		if var and dict[var] then
			if type(dict[var]) == "table" then
				for v in each(dict[var]) do
					table.insert(output, (out:gsub("{{"..var.."}}", v)))
				end
			else
				table.insert(output, (out:gsub("{{"..var.."}}", dict[var])))
			end
		else
			table.insert(output, out)
		end
	end

	-- remove the last line if it's just whitespace
	if output[#output]:match("^%s+$") then
		table.remove(output, #output)
	end

	local file = io.open(name, "w+")
	if not file then return nil end

	for line in each(output) do
		file:write(line .. "\n")
	end
	file:close()
	return true
end



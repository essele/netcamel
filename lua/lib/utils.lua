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

function string_insert(src, extra, pos)
	return src:sub(1, pos-1) .. extra .. src:sub(pos)
end
function string_remove(src, pos, count)
	return src:sub(1, pos-1) .. src:sub(pos+count)
end

--
-- Create a copy of the item, including handling tables and
-- nested tables
--
function copy(t)
	if type(t) == "table" then
		local rc = {}
		for k,v in pairs(t) do rc[k] = copy(v) end
		return rc
	else
		return t
	end
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
-- Return the uniq sorted values from a table (or two)
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
-- Run a function for each element in a list, if not true then
-- remove the element from the list
--
function ifilter(list, func)
	local i = 1
	while list[i] do
		if not func(list[i]) then
			table.remove(list, i)
		else
			i = i + 1
		end
	end
end
function filter(list, func)
	for k,v in list do
		if not func(k) then list[k] = nil end
	end
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
-- Find a common prefix from a list or keys
--
function icommon_prefix(t)
	local str = t[1] or ""
	local n = str:len()

	for _,s in ipairs(t) do
		while s:sub(1, n) ~= str and n > 0 do
			n = n - 1
			str=str:sub(1, n)
		end
	end
	return str
end
function common_prefix(t)
	local str = next(t) or ""
	local n = str:len()
	for s,_ in pairs(t) do
		while s:sub(1, n) ~= str and n > 0 do
			n = n - 1
			str=str:sub(1, n)
		end
	end
	return str
end

--
-- Find if a table contains any items matching the given prefix
--
function iprefixmatches(list, prefix)
	local rc = {}
	for _,v in ipairs(list) do
		if v:sub(1,#prefix) == prefix then table.insert(rc, v) end
	end
	return rc
end
function prefixmatches(list, prefix)
	local rc = {}
	for k,v in pairs(list) do
		if k:sub(1,#prefix) == prefix then rc[k]=v end
	end
	return rc
end
function count(hash)
	local i = 0
	for k,v in pairs(hash) do i = i + 1 end
	return i
end

--
-- Compare items a and b, if they are tables then do a table
-- comparison
--
function are_the_same(a, b)
	if type(a) == "table" and type(b) == "table" then
		for k,v in pairs(a) do if not are_the_same(b[k], v) then return false end end
		for k,v in pairs(b) do if not are_the_same(a[k], v) then return false end end
		return true
	else
		return a == b
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
-- Push .. because table.insert is horrible
--
function push(t, ...)
	for _,v in ipairs({...}) do
		table.insert(t, v)
	end
end

--
-- Check to see if the prefix of line matches token, but where
-- the next char is either eol or the sep
--
function prefix_match(line, token, sep)
	if #token == 0 then return true end
	if token == sep then return true end			-- / case
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
	local rc = {}
	for tok in string.gmatch(str, "([^"..sep.."]+)") do
		table.insert(rc, tok)
	end
	return rc
end

--
-- Split a string into lines
--
function lines(str)
	local rc = {}
	for line in string.gmatch(str, "(.-)\n") do table.insert(rc, line) end
	return rc
end

--
-- Simple serialisation routine, will take any variable type and
-- return a string that represents it.
--
function serialise(t)
	local rc

	if type(t) == "table" then
		rc = "{"
		for k,v in pairs(t) do
			rc = rc .. ("["..serialise(k).."]="..serialise(v)..",")
		end
		return rc .. "}"
	elseif type(t) == "string" then
		return "\"".. t:gsub("([\"\'])", "\\%1") .."\""
	else
		return tostring(t)
	end
end

--
-- Unserialise will take the string representation and work it back
-- into the original variable.
--
function unserialise(v)
	local code = load("return "..v)
	return code()
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
	local input = lines(template, "\n")

	-- work out leading space
	local lead = input[1]:match("^(%s+)") or ""

	local i = 1
	while input[i] do
		local out = input[i]
		local var = out:match("{{([^}]+)}}")

		if var and dict[var] then
			if type(dict[var]) == "table" then
				for v = 1, #dict[var] do
					table.insert(input, i+v, (out:gsub("{{"..var.."}}", dict[var][v])))
				end
				table.remove(input, i) 
			else
				input[i] = out:gsub("{{"..var.."}}", dict[var])
			end
		else
			input[i] = out
			i = i + 1
		end
	end

	-- remove the last line if it's just whitespace
	if input[#input]:match("^%s+$") then
		table.remove(input, #input)
	end
	
	local file = io.open(name, "w+")
	if not file then return nil end

	for line in each(input) do
		file:write(line:gsub("^"..lead,"") .. "\n")
	end
	file:close()
	return true
end


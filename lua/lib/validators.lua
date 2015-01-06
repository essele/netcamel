#!luajit
----------------------------------------------------------------------------
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
-----------------------------------------------------------------------------

require("utils")

--
-- For TYPEOPTS we support fixed entries or function calls using @type
--
setmetatable(TYPEOPTS, TYPEOPTS)
TYPEOPTS["__index"] = function(t, k)
	local func = rawget(t, "@"..k)
	if func then
		return func(k)
	else
		return nil
	end
end

--
-- Standard validator and type options for boolean
--
VALIDATOR["boolean"] = function(v,kp)
	local partials = { "true", "false", "yes", "no" }

	if v == "true" or v == "yes" or v == "1" then return OK, true end
	if v == "false" or v == "no" or v == "0" then return OK, false end

	for _, item in ipairs(partials) do	
		if item:sub(1, v:len()) == v then return PARTIAL end
	end
	return FAIL, "boolean can be true or false"
end
TYPEOPTS["boolean"] = { "true", "false" }

--
-- 2-digits ... needed for priority etc
--
VALIDATOR["2-digit"] = function(v,kp)
	local err = "require two digits (nn)"
	local a, b = v:match("^(%d)(%d?)$")
	if not a then return FAIL, err end
	if b == "" then return PARTIAL, err end
	return OK
end


--
-- Validator for an ipv4 address
--
VALIDATOR["ipv4"] = function(v, kp)
	local err = "ipv4 must be nnn.nnn.nnn.nnn"

	if not v:match("^[%d%.]+$") then return FAIL, err end
	local nums = split(v, "%.")
	if #nums > 4 then return FAIL, err end

	for i,num in ipairs(nums) do
		if num == "" then
			if i ~= #nums then return FAIL, err end
		else
			num = tonumber(num)
			if i == 1 and num == 0 then return FAIL, err end
			if num > 255 then return FAIL, err end
		end
	end
	if #nums < 4 then return PARTIAL, err end
	return OK
end
--
-- Validator for ipv4 with a /netmask on the end
--
VALIDATOR["ipv4_nm"] = function(v, kp)
	local err = "ipv4_nm must be nnn.nnn.nnn.nnn/nn"
	local ipv4, slash, n = v:match("^([%d%.]+)(/?)(%d-)$")
	local rc

	if(not ipv4) then return FAIL, err end
	rc = VALIDATOR["ipv4"](ipv4, kp)
	if rc == FAIL then return FAIL, err end
	if rc == PARTIAL then if n=="" and slash=="" then return PARTIAL, err else return FAIL, err end end
	if slash == "" or n == "" then return PARTIAL, err end
		
	n = tonumber(n)
	if n < 1 or n > 32 then return FAIL end
	return OK
end




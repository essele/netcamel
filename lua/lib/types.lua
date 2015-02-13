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

-- ------------------------------------------------------------------------------
--
-- MAIN TYPES MODULE
--
-- This provides functions for validating and getting options for a type
-- as well as a set of commonly used types.
--
-- ------------------------------------------------------------------------------
local TYPE = {}

--
-- Return OK, PARTIAL or FAIL if we match one of the items in the list
--
local function partial_match(v, list)
	for _,l in ipairs(list) do
		if v == l then return OK end
		if l:sub(1,#v) == v then return PARTIAL, "unfinished option" end
	end
	return FAIL, "not one of the allowed options"
end

--
-- Used for any type that has a list of options
--
local function validate_std(value, mp, kp, tokens, t)
	return partial_match(value, TYPE[t].options)
end

--
-- Main type routine: validate a value is correct (or partial)
--
local function validate(value, mp, kp, tokens)
	local t = master[mp]["type"] or master[mp]["style"]
	return TYPE[t].validator(mp, kp, value, tokens, t)
end

--
-- Get the list of suitable options for this type
--
local function options(mp)
	local t = master[mp]["type"] or master[mp]["style"]
	local o = TYPE[t].options

	if type(o) == "function" then return o(mp) end
	return o
end

-- ------------------------------------------------------------------------------
-- BOOLEAN
-- ------------------------------------------------------------------------------
TYPE["boolean"] = {
	validator = validate_bool,
	options = { "true", "false" },
}
TYPE["boolean"].validator = function(value, mp, kp, tokens, t)
	if v == "true" or v == "yes" or v == "1" then return OK, true end
	if v == "false" or v == "no" or v == "0" then return OK, false end
	return partial_match(value, {"true", "false", "yes", "no"})
end

-- ------------------------------------------------------------------------------
-- 2-digit
-- ------------------------------------------------------------------------------
TYPE["2-digit"] = {}
TYPE["2-digit"].validator = function(value, mp, kp, tokens, t)
	local err = "require two digits (nn)"
	local a, b = v:match("^(%d)(%d?)$")
	if not a then return FAIL, err end
	if b == "" then return PARTIAL, err end
	return OK
end

-- ------------------------------------------------------------------------------
-- Normal ipv4 address
-- ------------------------------------------------------------------------------
TYPE["ipv4"] = {}
TYPE["ipv4"].validator = function(value, mp, kp, tokens, t)
	local nc, err = 0, "ipv4 must be standard dotted quad"
	if not value:match("^[%d%.]+$") then return FAIL, err end
	while value:len() > 0 do
		local dig = value:match("^(%d+)")
		if not dig or tonumber(dig) > 255 then return FAIL, err end
		nc = nc + 1
		value = value:sub(#dig + 2)
	end
	if nc ~= 4 then return (nc < 4 and PARTIAL) or FAIL, err end
	return OK
end

-- ------------------------------------------------------------------------------
-- ipv4 address with a netmask number on the end
-- ------------------------------------------------------------------------------
TYPE["ipv4_nm"] = {}
TYPE["ipv4_nm"].validator = function(value, mp, kp, tokens, t)
	local err = "ipv4nm must be standard dotted quad with /netmask"
	local ipv4, slash, n = value:match("^([%d%.]+)(/?)(%d-)$")
	if not ipv4 then return FAIL, err end
	local rc = TYPE["ipv4"].validator(ipv4, mp, kp, tokens, t)
	if rc == FAIL then return FAIL, err end
	if rc == PARTIAL then if n=="" and slash=="" then return PARTIAL, err else return FAIL, err end end
	if slash == "" or n == "" then return PARTIAL, err end
	if tonumber(n) > 32 then return FAIL, err end
	return OK
end

-- ------------------------------------------------------------------------------
-- ipv4_nm with an optional "default"
-- ------------------------------------------------------------------------------
TYPE["ipv4_nm_default"] = {}
TYPE["ipv4_nm_default"].validator = function(value, mp, kp, tokens, t)
	local err = "must be ip address with netmask or 'default'"
	local rc = partial_match(value, {"default"})
	if rc ~= FAIL then return rc, (rc ~= OK and err) or nil end
	rc = TYPE["ipv4_nm"].validator(value, mp, kp, tokens, t)
	return rc, (rc ~= OK and err) or nil
end



return {
	validate = validate,
	options = options,
	T = TYPE,
}


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
-- The validator code must return OK, PARTIAL or FAIL. For PARTIAL or FAIL is
-- must also return a descriptive error. For OK it can optionally return a reworked
-- value (boolean from text to bool for example)
--
-- ------------------------------------------------------------------------------

local TYPE = {}

--
-- Return OK, PARTIAL or FAIL if we match one of the items in the list
--
local function partial_match(v, list)
	for l,_ in pairs(list) do
		if v == l then return OK end
		if l:sub(1,#v) == v then return PARTIAL, "unfinished option" end
	end
	return FAIL, "not one of the valid options"
end

--
-- Get the list of suitable options for this type: use mp to find type
-- or force it's mp is nil
--
local function options(mp, t)
	local t = (mp and (master[mp]["type"] or master[mp]["style"])) or t
	local o = TYPE[t].options

	if type(o) == "function" then return o(mp) end
	return o
end

--
-- Used for any type that has a list of options
--
local function validate_std(value, mp, kp, token, t)
	return partial_match(value, token and token.options or options(mp, t) or {})
end

--
-- Main type routine: validate a value is correct (or partial)
--
local function validate(value, mp, kp, token)
	local t = master[mp]["type"] or master[mp]["style"]

	if token and not token.options then token.options = options(mp) or {} end
	assert(TYPE[t].validator, "no validator for type ["..t.."]")
	return TYPE[t].validator(value, mp, kp, token, t)
end

--
-- Allow support for calling specific validators by type, there is no
-- kp or mp support here, we also won't call options() so you will have to
-- do that manually if you want them.
--
local function validate_type(value, t)
	return TYPE[t].validator(value, nil, nil, nil, t)
end


--
-- Generic case for simple positive number range validation
--
local function validate_number(value, min, max)
	if not value:match("^%d+$") then return FAIL end
	if tonumber(value) < min then return PARTIAL end
	if tonumber(value) > max then return FAIL end
	return OK
end


-- ------------------------------------------------------------------------------
-- BOOLEAN
-- ------------------------------------------------------------------------------
TYPE["boolean"] = {
	validator = validate_bool,
	options = { ["true"]=1, ["false"]=1 },
}
TYPE["boolean"].validator = function(value, mp, kp, token, t)
	if value == "true" or value == "yes" or value == "1" then return OK, true end
	if value == "false" or value == "no" or value == "0" then return OK, false end
	return partial_match(value, {["true"]=1, ["false"]=1, ["yes"]=1, ["no"]=1})
end

-- ------------------------------------------------------------------------------
-- 2-digit
-- ------------------------------------------------------------------------------
TYPE["2-digit"] = {}
TYPE["2-digit"].validator = function(value, mp, kp, token, t)
	local err = "require two digits (nn)"
	local a, b = value:match("^(%d)(%d?)$")
	if not a then return FAIL, err end
	if b == "" then return PARTIAL, err end
	return OK
end

-- ------------------------------------------------------------------------------
-- Simple label (alphas and underscore, do we allow minus?)
-- ------------------------------------------------------------------------------
TYPE["label"] = {}
TYPE["label"].validator = function(value, mp, kp, token, t)
	local err = "a label can be alphanumberic plus underscore and minus"
	local a = value:match("^%w?[%w%-_]*$")
	if not a then return FAIL, err end
	return OK
end

-- ------------------------------------------------------------------------------
-- Normal ipv4 address
-- ------------------------------------------------------------------------------
TYPE["ipv4"] = {}
TYPE["ipv4"].validator = function(value, mp, kp, token, t)
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
TYPE["ipv4_nm"].validator = function(value, mp, kp, token, t)
	local err = "ipv4nm must be standard dotted quad with /netmask"
	local ipv4, slash, n = value:match("^([%d%.]+)(/?)(%d-)$")
	if not ipv4 then return FAIL, err end
	local rc = TYPE["ipv4"].validator(ipv4, mp, kp, token, t)
	if rc == FAIL then return FAIL, err end
	if rc == PARTIAL then if n=="" and slash=="" then return PARTIAL, err else return FAIL, err end end
	if slash == "" or n == "" then return PARTIAL, err end
	if tonumber(n) > 32 then return FAIL, err end
	return OK
end
TYPE["ipv4_nm"].options = { text = 1, [1] = TEXT[[
		Use a standard ip dotted quad address with a /netmask
	
		eg. 192.168.95.1/24 or 10.1.0.5/16
	]] 
}

-- ------------------------------------------------------------------------------
-- ipv4_nm with an optional "default"
-- ------------------------------------------------------------------------------
TYPE["ipv4_nm_default"] = {}
TYPE["ipv4_nm_default"].validator = function(value, mp, kp, token, t)
	local err = "must be ip address with netmask or 'default'"
	local rc = partial_match(value, {["default"]=1})
	if rc ~= FAIL then return rc, (rc ~= OK and err) or nil end
	rc = TYPE["ipv4_nm"].validator(value, mp, kp, token, t)
	return rc, (rc ~= OK and err) or nil
end


local function validator_for_list_or_type(list, ort, err)
	local matches = lib.utils.values_to_keys(list)

	return function(value, mp, kp, token, t) 
		local rc = partial_match(value, matches)
		if rc ~= FAIL then return rc, (rc ~= OK and err) or nil end
		rc = TYPE[ort].validator(value, mp, kp, token, ort)
		return rc, (rc ~= OK and err) or nil
	end
end


return {
	validate = validate,
	options = options,
	DB = TYPE,
	validate_number = validate_number,
	validate_std = validate_std,
	validate_type = validate_type,
	validator_for_list_or_type = validator_for_list_or_type,
	partial_match = partial_match,
}


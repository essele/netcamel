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
-- Simple 2-digit field
--
local function validate_2digit(value, mp, kp, tokens, t)
	local err = "require two digits (nn)"
	local a, b = v:match("^(%d)(%d?)$")
	if not a then return FAIL, err end
	if b == "" then return PARTIAL, err end
	return OK
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



TYPE["boolean"] = {
	validator = validate_std,
	options = { "true", "false" },
}
TYPE["2-digit"] = {
	validator = validate_2digit,
}

return {
	validate = validate,
	options = options,
	T = TYPE,
}


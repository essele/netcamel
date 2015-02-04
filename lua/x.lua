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

dofile("lib/lib.lua")

--
-- TEST CODE ONLY
--
function process_cfpath(state)
	-- pull the token, return if unchanged
	local path = lib.readline2.get_token(state, "%s")

	if not path or path.samevalue then return end

	-- update accordingly
	lib.readline2.reset_state(path)

	while true do
		local elem = lib.readline2.get_token(path, "/")
		if not elem then break end


		if elem.valid and elem.samevalue then
--			print("no check needed")
		else
--			print("processing")
			elem.valid = true
		end
	end	
end

--
-- TEST CODE ONLY
--
function completeCB(tokens, line, pos)
	local i = which_token(tokens, pos)

	if i==2 then
		local j = which_subtoken(tokens, i, pos)
		print("j="..j)
	end
end


--
-- TEST CODE ONLY
--
function processCB(state) 
	local cmd = lib.readline2.get_token(state, "%s")

	if cmd then
		if cmd.value == "set" then
			cmd.color = "green"
			process_cfpath(state)
			if state.tokens and state.tokens[2] and state.tokens[2].tokens and state.tokens[2].tokens[2] then
				state.tokens[2].tokens[2].color = "green"
			end
		else
			cmd.color = "red"
		end
	end

	local rest = lib.readline2.get_token(state)
	if rest then
			print("rest: ["..rest.value.."]")
--			print("rsame: " .. tostring(rest.samevalue))
	end
end

local prompt = { value = "prompt > ", len = 9 }
local history = { "fred", "one two thre", "set /abc/def/ghi" }

lib.readline2.read_command(prompt, history, processCB, completeCB)


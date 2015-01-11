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
--
--
__log = {}
__logfd = nil
__logfile = "/tmp/nc.log"

function log(t, section, msg, ...)
	--
	-- Ensure we want these messages
	--
	if not __log[t] then return end

	--
	-- Make sure we have opened our logfile
	--
	if not __logfd then
		__logfd = io.open(__logfile, "a+")
		if not __logfd then
			print("FATAL: unable to open logfile: "..__logfile)
			os.exit(1)
		end
	end

	--
	-- Output the message
	--
	__logfd:write(string.format("%s [%-20.20s] %s\n", os.date("%b %d %X"), t.."/"..section,
			string.format(msg, ...)))
	__logfd:flush()
end


__log["error"] = true
__log["info"] = true
__log["debug"] = true
__log["warn"] = true
__log["cmd"] = true



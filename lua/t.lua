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
package.path = "/usr/share/lua/5.1/?.lua"
package.cpath = "/usr/lib/lua/5.1/?.so;/usr/lib64/lua/5.1/?.so;./lib/?.so;./c/?.so"

ffi = require("ffi")
bit = require("bit")
posix = require("posix")

-- ------------------------------------------------------------------------------
-- TERMINFO Bits...
-- ------------------------------------------------------------------------------

local ti = {}

ffi.cdef[[
	char *boolnames[], *boolcodes[], *boolfnames[];
	char *numnames[], *numcodes[], *numfnames[];
	char *strnames[], *strcodes[], *strfnames[];

	int setupterm(char *term, int fildes, int *errret);
	char *tigetstr(const char *capname);
	int tigetflag(const char *capname);
	int tigetnum(const char *capname);
	const char *tparm(const char *str, ...);
	int putp(const char *str);
]]


local __libtinfo = ffi.load("ncurses")
local ti = {}
local keymap = {}

function ti.init()
	local rc = __libtinfo.setupterm(nil, 1, nil)
	print("rc="..rc)

	local i = 0
	while true do
		local cap = __libtinfo.strnames[i]
		if cap == nil then break end
		local fname = ffi.string(__libtinfo.strfnames[i])
		local value = __libtinfo.tigetstr(cap)
		if value ~= nil then ti[fname] = value end
		i = i + 1
	end
	i = 0
	while true do
		local cap = __libtinfo.boolnames[i]
		if cap == nil then break end
		local fname = ffi.string(__libtinfo.boolfnames[i])
		local value = __libtinfo.tigetflag(cap)
		if value == 1 then ti[fname] = true end
		i = i + 1
	end
	i = 0
	while true do
		local cap = __libtinfo.numnames[i]
		if cap == nil then break end
		local fname = ffi.string(__libtinfo.numfnames[i])
		local value = __libtinfo.tigetnum(cap)
		if value >= 0 then ti[fname] = value end
		i = i + 1
	end

	if ti.parm_up_cursor and ti.parm_down_cursor and ti.parm_left_cursor and ti.parm_right_cursor then
		ti.have_multi_move = true
	end

	--
	-- We can also build the keymap here
	--
	keymap = {
		[ffi.string(ti.key_left)] = 		"LEFT",
		[ffi.string(ti.key_right)] = 		"RIGHT",
		[ffi.string(ti.key_up)] = 			"UP",
		[ffi.string(ti.key_down)] = 		"DOWN",
		["\009"] =							"TAB",
		["\127"] =							"DELETE",
	}
end

--
-- Equivalent of putp(tparm(...)) but we need to convert any numbers
-- into proper ints.
--
function ti.out(str, ...)
	if not ... then
		__libtinfo.putp(str)
		return
	end
	local args = {...}
	for i,arg in ipairs(args) do
		if type(arg) == "number" then args[i] = ffi.new("int", arg) end
	end
	__libtinfo.putp(__libtinfo.tparm(str, unpack(args)))
end
function ti.tparm(str, ...)
	local args = {...}
	for i,arg in ipairs(args) do
		if type(arg) == "number" then args[i] = ffi.new("int", arg) end
	end
	return ffi.string(__libtinfo.tparm(str, unpack(args)))
end


-- ------------------------------------------------------------------------------
-- SIMPLE TOKENISER
-- ------------------------------------------------------------------------------

function tokenise(tokens, input, sep, offset)
	offset = offset or 0
	local token = nil
	local inquote, backslash = false, false
	local allow_inherit = true
	local token_n = 0

	for i=1, input:len()+1 do
		local ch = input:sub(i,i)

		--
		-- If we get a space outside of backslash or quote then
		-- we have found a token
		--
		if ch == "" or (ch == sep and not backslash and not inquote) then
			if token and token.value ~= "" then
			
				-- do we need?
				if ch == "" then token.sep = nil else token.sep = ch end

				if tokens[token_n] then
					if tokens[token_n].value ~= token.value then
						tokens[token_n].status = nil
						tokens[token_n].value = token.value
					end
					tokens[token_n].start = token.start
					tokens[token_n].finish = token.finish
				else
					tokens[token_n] = token
				end
				token = nil
			end
		else
			--
			-- Any other character now is part of the token
			--
			if not token then
				token = {}
				token.value = ""
				token.start = i + offset
				token_n = token_n + 1
			end
			token.value = token.value .. ch
			token.finish = i + offset

			--
			-- If we get a quote, then it's either in our out of
			-- quoted mode (unless its after a backslash)
			--
			if ch == "\"" and not backslash then
				inquote = not inquote
			end

			if backslash then
				backslash = false
			end

			if ch == "\\" then backslash = true end
		end
	end

	--
	-- Tidy up if we used to have more tokens...
	--
	while #tokens > token_n do table.remove(tokens) end

	--
	-- If we have nothing, or something with a trailing space then we add
	-- a dummy token so that we can use it for 'next token' completion
	--
	if token_n == 0 or input:sub(-1) == sep then
		table.insert(tokens, { value = "", start = offset+input:len()+1, finish = offset+input:len()+1 })
	end

	return tokens
end

-- ------------------------------------------------------------------------------
-- For supporting save and restore of termios
-- ------------------------------------------------------------------------------
--
local __saved_tios
local __sigfd

function init()
	--
	-- Make the required changes to the termios struct...
	--
	__saved_tios = posix.tcgetattr(0)
	local tios = posix.tcgetattr(0)
	tios.lflag = bit.band(tios.lflag, bit.bnot(posix.ECHO))
	tios.lflag = bit.band(tios.lflag, bit.bnot(posix.ICANON))
	posix.tcsetattr(0, posix.TCSANOW, tios)

	--
	--
	-- Setup the signal filehandle so we can receive
	-- the window size change signal and adjust accordingly
	--
	-- SIGWINCH
	posix.signal(28, function() winch_handler() end)

end
function finish()
	posix.tcsetattr(0, posix.TCSANOW, __saved_tios)
end


--
-- Wait up to a maximum time for a character, return the char
-- and how much time is left (or nil if we didn't get one)
--
function getchar(ms)
	local fds = {
		[0] = { events = { IN = true }},
	}

	local before = posix.gettimeofday()
	local rc, err = posix.poll(fds, ms)

	if not rc then
		-- Interrupted system call probably, most likely
		-- a window resize, so if we return nil then we will
		-- cause a redraw
		return nil, 0
	end

	if rc < 1 then return nil, 0 end
	local after = posix.gettimeofday()

	local beforems = before.sec * 1000 + math.floor(before.usec/1000)
	local afterms = after.sec * 1000 + math.floor(after.usec/1000)

	ms = ms - (afterms - beforems)
	ms = (ms < 0 and 0) or ms

	--
	-- If we get here it will be a key...
	--
	if fds[0].revents.IN then
		local char, err = posix.read(0, 1)
		if not char then
			print("Error reading char: " .. err)
			return nil
		end
		return char, ms
	end
	return nil
end

--
-- Read a character (or escape sequence) from stdin
--
function read_key()
	local buf = ""
	local remaining = 0
	
	local c, time = getchar(-1)
	if c ~= "\027" then return keymap[c] or c end

	buf = c
	remaining = 300
	while true do
		local c, time = getchar(remaining)
		if not c then return keymap[buf] or buf end

		remaining = time

		buf = buf .. c
		if #buf == 2 and c == "[" then goto continue end
		if #buf == 2 and c == "O" then goto continue end

		local b = string.byte(c)
		if string.byte(c) >= 64 and string.byte(c) <= 126 then 
			return keymap[buf] or buf
		end
::continue::
	end
end


function hex(s) 
	for i=1,s:len() do
		io.write(string.format("%02x ", string.byte(s,i)))
	end
	io.write("\n")
end


--
-- Initialise the terminal and make sure we are in app mode so
-- the cursor keys work as expected.
--
ti.init()
init()
--ti.out(ti.init_2string)
ti.out(ti.keypad_xmit)

--
-- We need to track our position relative to the start of the line
-- where the input started.
--
local __row = 0
local __col = 0
local __srow = 0
local __scol = 0
local __width = ti.columns
local __height = ti.lines
local __line = ""
local __pos = 1

function move_back()
	if __col == 0 then
		ti.out(ti.cursor_up)
		if ti.have_multi_move then ti.out(ti.parm_right_cursor, __width-1)
		else for i=1,#width-1 do ti.out(ti.cursor_right) end end
		__col = __width - 1
		__row = __row - 1
	else
		ti.out(ti.cursor_left)
		__col = __col -1
	end
end

--
-- If just n is specified then move right that amount (using ti.cursor right)
-- If string is specified with n, then output the string and move right n.
-- (That allows for embedded colour etc.)
-- If nothing is specified then move right one.
--
function move_on(n, str)
	n = n or 1

	if not str then
		if ti.have_multi_move then ti.out(ti.parm_right_cursor, n) else
		ti.out(string.rep(ffi.string(ti.cursor_right), n)) end
	else
		ti.out(str)
	end

	local npos = __col + n
	local extra_rows = math.floor(npos/__width)
	local final_col = npos % __width

	__col = final_col
	__row = __row + extra_rows

	if (n > 0 and __col == 0) and ti.auto_right_margin then
		if ti.eat_newline_glitch then ti.out(ti.carriage_return) end
		ti.out(ti.carriage_return)
		ti.out(ti.cursor_down)
	end
end

--
-- Output the list of tokens with relevant colour highlighting
-- (make sure we re-create any whitespace gaps)
--

local FAIL = 0
local OK = 1
local PARTIAL = 2

local __color = {
	[OK] = 2,
	[PARTIAL] = 3,
	[FAIL] = 1
}

--
-- Output each token in turn, making sure to recreate the appropriate
-- amount of whitespace... we also handle subtokens recursively.
--
function show_line(tokens, input)
	function show_token(token, pos, master)
		local rc = ""

		--
		-- Use colors if we can, and if the status is set
		--
		local color = ti.set_a_foreground and token.status and 
									ti.tparm(ti.set_a_foreground, __color[token.status])
		local stdcolor = (color and ti.tparm(ti.set_a_foreground, 9)) or ""
		color = color or ""

		if pos < token.start then
			-- this will be the sepator for the next token so should coloured
			rc = color .. string.sub(master, pos, token.start-1) .. stdcolor
			pos = token.start
		end
		if token.subtokens then
			for i,t in ipairs(token.subtokens) do
				local nrc
				nrc, pos = show_token(t, pos, master)
				rc = rc .. nrc
			end
		else
			rc = rc .. color .. token.value .. stdcolor
			pos = pos + token.value:len()
		end
		return rc, pos
	end

	local token = { start=1, finish=input:len(), subtokens=tokens }
	local out, pos = show_token(token, 1, input)

	if out:len() > 0 then move_on(input:len(), out) end
end

function move_to(r, c)
	if ti.have_multi_move then
		if r > __row then ti.out(ti.parm_down_cursor, r-__row) end
		if r < __row then ti.out(ti.parm_up_cursor, __row-r) end
		if c > __col then ti.out(ti.parm_right_cursor, c-__col) end
		if c < __col then ti.out(ti.parm_left_cursor, __col-c) end
		__row, __col = r, c
	else
		while r > __row do ti.out(ti.cursor_down) __row = __row + 1 end
		while r < __row do ti.out(ti.cursor_up) __row = __row - 1 end
		if math.abs(__col - c) then ti.out(ti.carriage_return) __col = 0 end
		while c > __col do ti.out(ti.cursor_right) __col = __col + 1 end
		while c < __col do ti.out(ti.cursor_left) __col = __col - 1 end
	end
end
function save_pos()
	__srow, __scol = __row, __col
end
function restore_pos()
	move_to(__srow, __scol)
end

function redraw_line(tokens, input)
	save_pos()
	move_to(0,0)
	show_line(tokens, input)
	ti.out(ti.clr_eol)
	restore_pos()
end

function string_insert(src, extra, pos)
	return src:sub(1, pos-1) .. extra .. src:sub(pos)
end
function string_remove(src, pos, count)
	return src:sub(1, pos-1) .. src:sub(pos+count)
end

--
-- If we get a window resize event then we need to do something sensible
-- to redraw the line. We'll re-call setupterm so that we get the size
-- adjusted accordingly
--
function winch_handler()
	--
	-- Re-setup and update the ti database accordingly
	--
	local rc = __libtinfo.setupterm(nil, 1, nil)
	assert(rc == 0, "unable to re-setupterm in winch_handler")

	ti.columns = __libtinfo.tigetnum("cols")
	ti.lines = __libtinfo.tigetnum("lines")

	--
	-- Update our view of the size
	--
	__width = ti.columns
	__height = ti.lines

	--
	-- TODO: we can do better than clear the screen, perhaps work out
	-- how many rows down we were, move back up clear to eos, then redraw.
	--
--	ti.out(ti.clear_screen)
	ti.out(ti.carriage_return)
	__row, __col = 0, 0
--	redraw_line()
	move_to(math.floor((__pos-1)/__width), (__pos-1)%__width)
end


--
-- Sample initial tab completer
-- 
-- We need to continuously determin if the token is OK, PARTIAL or FAIL
-- and if it's OK then we need to return a next tokens completer.
--
-- The token will always be anything up to (and including) a space
-- (quoted stuff tbd)
--
local __cmds = {
	["set"] = { desc = "blah blah" },
	["aabbcc"] = {},
	["aabdef"] = {},
	["aabxxx"] = {},
	["show"] = {},
	["delete"] = {},
	["commit"] = {},
	["save"] = {},
	["revert"] = {},
}
function match_list(list, t)
	local rc = {}
	for k,v in pairs(list) do
		if k:sub(1, t:len()) == t then table.insert(rc, k) end
	end
	table.sort(rc)
	return rc
end
--
-- Given a list work out what the common prefix
-- is (if any)
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
-- Given a set of tokens and a position return the index and
-- prefix for the token
--
function which_token(tokens, pos)
	for i,token in ipairs(tokens) do
		if pos >= token.start and pos <= (token.finish+1) then
			return i, token.value:sub(1, pos - token.start)
		end
	end
	assert(false, "cant figure out which token (pos="..pos..")")
end

--
-- We handle the token containing paths, so we first need to
-- work out which subtoken we are being referenced from.
--
function cfpath_completer(tokens, n, prefix)
	local mtoken = tokens[1]
	local token = tokens[n]
	local value = token.value
	local pos = token.start + prefix:len()

	--
	-- Remap the values to the subtokens...
	--
	tokens = token.subtokens
	n, prefix = which_token(tokens, pos)
	token = tokens[n]
	value = token.value

	--
	-- Get our values of mp and kp
	--
	local kp, mp, slash
	if n==1 then kp, mp, slash = "", "", ""
	else kp, mp, slash = tokens[n-1].kp, tokens[n-1].mp, "/" end

	--
	-- Retrieve matches from our pre-cached list...
	--
	local matches = prefixmatches(token.options, prefix)

	--
	-- If we have multiple matches then find the common prefix
	--
	if count(matches) > 1 then
		local cp = common_prefix(matches)
		if cp ~= prefix then return cp:sub(#prefix+1) else return keys_to_values(matches) end
	end

	--
	-- If we have zero or one match but are not in the original options list
	-- then we are a wildcard. 
	--
	local node = matches[next(matches)]
	if not node then
		if token.status ~= OK then return nil end
		node = { mp = "*", kp = "*"..value }
	end

	--
	-- Find out if we have more after this one
	--
	local more = {}
	if mtoken.use_master then add_to_list(more, node_list(mp..slash..node.mp, master)) end
	if mtoken.use_new then add_to_list(more, node_list(kp..slash..node.kp, CF_new)) end

	return ((next(matches) and next(matches):sub(#prefix+1)) or "") .. ((#more > 0 and "/") or " ")
end

function cfsetitem_completer(tokens, n, prefix)
	local token = tokens[n]
	local pos = token.start + prefix:len()
	local mp = tokens[2].mp

	--
	-- Remap the values to the subtokens...
	--
	tokens = token.subtokens
	n, prefix = which_token(tokens, pos)
	local value = token.value

	if n == 1 then
		--
		-- Get a list of possible items
		--
		local matches = matching_list(mp.."/"..prefix.."%", master)
		imap(matches, function(v) return v:sub(#mp+2) end)
		if #matches == 0 then return nil end
		if #matches == 1 then return matches[1]:sub(#prefix+1).."=" end
		local cp = icommon_prefix(matches)
		if cp ~= prefix then return cp:sub(#prefix+1) end
		return matches
	else
	end
end

--
-- We get called for the path token (usually token 2) so we can 
-- re-tokenise and then run through each token that needs validating
--
function cfpath_validator(tokens, n, input)
	function populate_options_m(options, mp)
		local slash = (mp == "" and "") or "/"
		for item in each(node_list(mp, master)) do
			if item == "*" then
				for item in each(master[mp..slash.."*"]["options"] or {}) do
					options[item] = { mp = "*", kp = "*"..item }
				end
			else
				options[item] = { mp = item, kp = item }
			end
		end
	end
	function populate_options_n(options, kp)
		for item in each(node_list(kp, CF_new)) do
			local wc, nitem = item:match("^(%*?)(.-)$")
			options[nitem] = { mp = (wc == "" and item) or "*", kp = item }
		end
	end

	local ptoken = tokens[n]
	local value = ptoken.value
	local allfail = false
	local mp, kp, slash = "", "", ""

	if not ptoken.subtokens then ptoken.subtokens = {} end
	tokenise(ptoken.subtokens, value, "/", ptoken.start-1)

	for i,token in ipairs(ptoken.subtokens) do
		local value = token.value
		if allfail then token.status = FAIL goto continue end
		if token.status == OK then mp, kp = token.mp, token.kp goto continue end

		--
		-- Build a list of the options we know about and add in the provided options
		-- for a wildcard
		--
		if not token.options then
			token.options = {}
			if tokens[1].use_master then populate_options_m(token.options, mp) end
			if tokens[1].use_new then populate_options_n(token.options, kp) end
		end

		--
		-- * is not allowed, so instant fail.
		--
		if value:sub(1,1) == "*" then token.status = FAIL goto done end
		--
		-- try match against full values
		--
		if token.options[value] then
			mp = mp..slash..token.options[value].mp
			kp = kp..slash..token.options[value].kp
			token.status = OK
			goto done
		end
		--
		-- try wildcard match (only if we are matching possibles from the
		-- master list)
		--
		if tokens[1].use_master then
			if master[mp..slash.."*"] then
				mp = mp..slash.."*"
				kp = kp..slash.."*"..value
				local rc, err = VALIDATOR[master[mp].style](value, kp)
				if rc ~= FAIL then token.status = rc goto done end
			end
		end
		--
		-- if we are still failed, then try partial matches
		--
		if next(prefixmatches(token.options, value)) then
			token.status = PARTIAL
			goto done
		end
		token.status = FAIL

::done::
		-- We can only be PARTIAL if we are the last of the subtokens
		if token.status == PARTIAL then
			if i ~= #ptoken.subtokens then token.status = FAIL end
		end

		if token.status == FAIL then allfail = true end
		if token.status == OK then token.mp, token.kp = mp, kp end

::continue::
		slash = "/"
	end
	-- make sure we end on a typed node, otherwise we are all partial
	-- TODO???? REally ... how should we do this?
--[[
	if ptoken.subtokens[#ptoken.subtokens].status == OK then
		if master[mp] and master[mp]["type"] == nil then
			mark_all(ptoken.subtokens, 1, PARTIAL)
			print("NOPE")
		end
	end
]]--

	-- propogate the status, mp and kp back from the last subtoken
	tokens[n].status = ptoken.subtokens[#ptoken.subtokens].status
	tokens[n].kp = ptoken.subtokens[#ptoken.subtokens].kp
	tokens[n].mp = ptoken.subtokens[#ptoken.subtokens].mp
end

function tv2(tokens, n, input)
	local ptoken = tokens[n]
	local value = ptoken.value
	local mp = tokens[2].mp
	local kp = tokens[2].kp

	if not ptoken.subtokens then ptoken.subtokens = {} end

	tokenise(ptoken.subtokens, value, "=", ptoken.start-1)

	--
	-- Left hand side of the equals (valid item?)
	-- TODO: check master [type]
	--
	local token = ptoken.subtokens[1]
	local v1 = token.value

	if master[mp.."/"..v1] then
		token.status = OK
	else
		local matches = matching_list(mp.."/"..v1.."%", master)
		token.status = (#matches > 0 and PARTIAL) or FAIL
	end
	ptoken.status = token.status

	--
	-- Right hand side, need to run the validator
	--
	local token = ptoken.subtokens[2]
	local v2 = token and token.value
	if not token then return end

	if ptoken.status ~= OK then
		token.status = FAIL
	elseif #ptoken.subtokens > 2 then
		mark_all(ptoken.subtokens, 2, FAIL)
	else
		local m = master[mp.."/"..v1]
		local mtype = m["type"]
		kp = kp .. "/" .. v1

		print("type="..mtype)
		token.status = VALIDATOR[mtype](v2, kp)
		print("st="..token.status)
	end
	ptoken.status = token.status
end

--
-- Flag all following as failed, also clear the subtokens since
-- they won't be valid unless we know what we are doing.
--
function mark_all(tokens, n, value)
	while tokens[n] do
		tokens[n].status = value
		tokens[n].subtokens = nil
		tokens[n].completer = nil
		n =n + 1
	end
end


function syntax_set(tokens)
	--
	-- Only allow the cfpath completer unless the cfpath
	-- gets properly validated
	--
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = true
	tokens[1].use_new = true

	--
	-- Make sure the cfpath is ok
	--
	if tokens[2].status ~= OK then cfpath_validator(tokens, 2) end
	if tokens[2].status ~= OK then mark_all(tokens, 3, FAIL) return end

	--
	-- Setup the completer for all other fields
	--
	tokens[1].default_completer = cfsetitem_completer
	--
	-- Check all other fields are correct
	--
	n = 3
	while tokens[n] do
		tv2(tokens, n)
		n = n + 1
	end
end

function syntax_delete(tokens)
	tokens[2].completer = cfpath_completer
	tokens[1].default_completer = nil
	tokens[1].use_master = false
	tokens[1].use_new = true

	if tokens[2].status ~= OK then cfpath_validator(tokens, 2) end
	if tokens[2].status ~= OK then mark_all(tokens, 3, FAIL) return end
	-- TODO: others
end



function syntax_level1(tokens)
	local token = tokens[1]
	local value = token.value
	local status

	if __cmds[value] then 
		token.status = OK
		if value == "set" and tokens[2] then
			syntax_set(tokens, input)
		elseif value == "delete" and tokens[2] then
			syntax_delete(tokens, input)
		end
	elseif tokens[2] then
		token.status = FAIL
	else
		local matches = match_list(__cmds, value)
		if #matches > 0 then token.status = PARTIAL 
		else token.status = FAIL end
	end
	if token.status == FAIL then mark_all(tokens, 2, FAIL) end
end

--
-- The syntax checker needs to put a status on each token so that
-- we can incorporate colour as we print the line out for syntax
-- highlighting
--
-- Keep the previous setting if we have one since nothing would have
-- changed. If we need to recalc then do so.
--
function syntax_checker(tokens, input)
	local allfail = false

	syntax_level1(tokens)
	return
end

--
-- Provide completion information against the system commands.
--
-- Completion routines can return a string where there is a full match
-- or a partial common-prefix.
--
-- Or a list that will be output to the screen (and not used in any other
-- way so the format is free)
--
function system_completer(tokens, n, prefix)
	local matches = match_list(__cmds, prefix)
	local ppos = prefix:len() + 1

	if #matches == 0 then return nil end

	if #matches == 1 then return matches[1]:sub(ppos) .. " " end

	if #matches > 1 then
		local cp = icommon_prefix(matches)
		if cp ~= prefix then
			return cp:sub(ppos)
		end
	end
	for i, m in ipairs(matches) do
		matches[i] = string.format("%-20.20s %s", m, __cmds[m].desc or "-")
	end

	return matches
end

--
-- The completer will work out which function to call
-- to provide completion information
--
function initial_completer(tokens, input, pos)
	local n, prefix = which_token(tokens, pos)

	if n == 1 then
		return system_completer(tokens, n, prefix)
	else
		if tokens[n].completer then return tokens[n].completer(tokens, n, prefix) end
		if tokens[1].default_completer then return tokens[1].default_completer(tokens, n, prefix) end
		return nil
	end
end


--
--
--
--

local __tokens = {}
local needs_redraw = true

function readline()
	while true do
		local c = read_key()
		if c == nil then 
			needs_redraw = true
			goto continue 
		end

		if c:len() == 1 then
			if c == "q" then break end
			__line = string_insert(__line, c, __pos)
			__pos = __pos + 1
			move_on()
			needs_redraw = true
		elseif c == "UP" then
		elseif c == "LEFT" then 
			if __pos > 1 then
				move_back()
				__pos = __pos - 1
			end
		elseif c == "RIGHT" then 
			if __pos <= __line:len() then
				move_on()
				__pos = __pos + 1
			end
		elseif c == "DOWN" then print("DOWN") 
		elseif c == "DELETE" then
			if __pos > 1 then
				__line = string_remove(__line, __pos-1, 1)
				__pos = __pos - 1
				move_back()
				needs_redraw = true
			end
		elseif c == "TAB" then
			--
			-- TODO: tab completion here
			--
			local rc = initial_completer(__tokens, __line, __pos)
			if type(rc) == "string" then
				__line = string_insert(__line, rc, __pos)
				__pos = __pos + rc:len()
				move_on(rc:len())
				needs_redraw = true
			elseif rc then
				save_pos()
				ti.out(ti.carriage_return)
				ti.out(ti.cursor_down)
				__col, __row = 0, 0
				for _,m in ipairs(rc) do
					ti.out(m .. "\n")
				end
				restore_pos()
				needs_redraw = true
			end
		elseif c == "SIGWINCH" then
			winch_handler()
		end

	::continue::
		if needs_redraw then
			--
			-- Build list of tokens
			--
			tokenise(__tokens, __line, " ")
			syntax_checker(__tokens, __line)

			redraw_line(__tokens, __line)
			needs_redraw = false
		end
		io.flush()
	end

	finish()
end


--readline()

#!luajit


function tokenise(tokens, input)
	local tokens = {}
	local token = nil
	local inquote, backslash = false, false
	local allow_inherit = true
	local token_n = 1

	for i=1, input:len()+1 do
		local ch = input:sub(i,i)

		--
		-- If we get a space outside of backslash or quote then
		-- we have found a token
		--
		if ch == "" or (ch == " " and not backslash and not inquote) then
			if token and token.value ~= "" then
				print("TOKEN FOUND: [" .. token.value .. "]")

				if allow_inherit and tokens[token_n] and 
								tokens[token_n].value == token.value then
					tokens[token_n].start = token.start
					tokens[token_n].finish = token.finish
				else
					allow_inherit = false
					tokens[token_n] = token
				end
				token_n = token_n + 1
				token = nil
			end
		else
			--
			-- Any other character now is part of the token
			--
			if not token then
				token = {}
				token.value = ""
				token.start = i
			end
			token.value = token.value .. ch
			token.finish = i

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

	return tokens
end


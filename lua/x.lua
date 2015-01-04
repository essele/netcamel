#!luajit
package.path = "/usr/share/lua/5.1/?.lua;./lib/?.lua"
package.cpath = "/usr/lib/lua/5.1/?.so;/usr/lib64/lua/5.1/?.so;./lib/?.so;./c/?.so"

require("utils")

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

function fred()
	rc = {"abv"}
	return rc
end

list = { "one", "two", "three", "four" }


ifilter(list, function(v) return v~="two" and v~="three" end)

----for k,v in pairs(list) do
--	if v == "two" then table.remove(list, k) end
--	if v == "three" then table.remove(list, k) end
--end
--

--ireplace(list, "two", { "a", "b", "c" })
--
s = "1.2.3.4"

fred = split(s, "%.")
print("c="..#fred.."  v="..table.concat(fred, ", "))

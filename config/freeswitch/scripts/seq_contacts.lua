local user = argv[1]
local domain = argv[2]
local api = freeswitch.API()

local contacts = api:executeString("sofia_contact internal/" .. user .. "@" .. domain)
contacts = contacts:gsub(",", "|")
stream:write(contacts)
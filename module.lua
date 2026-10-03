local Players = game:GetService("Players")
local LocalPlayer = (function()
	local LocalPlayer = Players.LocalPlayer or (function()
		repeat task.wait() until Players.LocalPlayer
		return Players.LocalPlayer
	end)()
	return LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("MenuScreenGui", 9e9) and LocalPlayer
end)()

local Method, ns__require = "Unknown", nil
if typeof(getrenv or get_renv) == "function" then
	local Success, Environment = pcall(getrenv or get_renv)
	ns__require = Success and Environment.shared and Environment.shared.require
	Method = "shared.require"
end

local ModuleCache, ExecutorName = nil, identifyexecutor and identifyexecutor() or (getexecutorname and getexecutorname())
if typeof(ns__require) ~= "function" then
	local ns__Count = 0
	while true do
		if ns__Count >= 10 then
			break
		end

		local ReplicationInterface = ModuleCache and ModuleCache.ReplicationInterface
		if ReplicationInterface and ReplicationInterface.operateOnAllEntries then
			break
		end

		for _,Value in next, (getgc or get_gc)(true) do
			if type(Value) == "table" and rawget(Value, "ScreenCull") and rawget(Value, "NetworkClient") then
				ModuleCache = {}
				for Name, Data in next, Value do
					ModuleCache[Name] = type(Data) == "table" and Data.module or Data
				end
			end
		end

		ns__Count += 1
		task.wait(0.5)
	end

	if not ModuleCache  then
		getgenv().ns__PhantomWare__Executed = false
		pcall(setfflag or set_fflag, "DebugRunParallelLuaOnMainThread", "True")
		LocalPlayer:Kick("Error while accessing Game Modules, try rejoining through the desktop app, if this issue persists, please make a ticket in the discord server immediately.\ndiscord.gg/DwRT2nH93D" .. (ExecutorName and (" | " .. ExecutorName) or ""))
		return nil
	end

	ns__require = function(Name)
		return ModuleCache[Name]
	end

	Method = "fenv.getgc"
elseif not ns__require then
	getgenv().ns__PhantomWare__Executed = false
	pcall(setfflag or set_fflag, "DebugRunParallelLuaOnMainThread", "True")
	LocalPlayer:Kick("Error while accessing Game Modules, try rejoining through the desktop app, if this issue persists, please make a ticket in the discord server immediately.\ndiscord.gg/DwRT2nH93D" .. (ExecutorName and (" | " .. ExecutorName) or ""))
	return nil
end

return {Players = Players, LocalPlayer = LocalPlayer, Method = Method, ExecutorName = ExecutorName, __get = function(Module)
	local function __internal()
		local Success, Result = pcall(ns__require, Module)
		if Success then
			return Result
		end

		if string.find(tostring(Result), "Reciprocal") then
			return
		end

		return LocalPlayer:Kick("Failed to require Module '" .. Module .. " ', error[" .. Result .. "]\nPlease make a ticket in the discord server immediately.\ndiscord.gg/DwRT2nH93D")
	end

	local Source = __internal()
	if not Source then
		local StartTime = os.clock()
		while true do
			if os.clock() - StartTime >= 5 then
				LocalPlayer:Kick("Module Access Timeout, please make a ticket in the discord server immediately.\ndiscord.gg/DwRT2nH93D\nDebug Info: " .. tostring(ExecutorName) .. " | " .. Module .. ": " .. (ModuleCache and "fenv.getgc" or "shared.require"))
				pcall(setclipboard, "discord.gg/DwRT2nH93D")
				break
			end

			Source = __internal()
			if Source then
				break
			end

			task.wait(0.5)
		end
	end
	return Source
end}

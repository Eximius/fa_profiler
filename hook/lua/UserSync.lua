
local baseOnSync = OnSync
function OnSync()
	baseOnSync()
	if Sync.profilerReport then
		import('/profiler.lua').SendReport(Sync.profilerReport)
	end
end
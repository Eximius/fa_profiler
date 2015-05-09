local baseOnSync = OnSync
function OnSync()
	baseOnSync()
	if Sync.profilerReport then
		import('/lua/profiler.lua').SendReport(Sync.profilerReport)
	end
end

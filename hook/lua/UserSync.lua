local baseOnSync = OnSync
function OnSync()
	baseOnSync()
	if Sync.profilerReport then
		ForkThread(
			import('/mods/profiler/lua/profiler.lua').SendReport, Sync.profilerReport
		)
	end
end

local baseOnSync = OnSync
function OnSync()
	baseOnSync()
    if Sync.profilerStarted then
        import('/mods/profiler/lua/profiler.lua').UIProfilerStarted(Sync.profilerStarted)
    end
    if Sync.profilerChunk then
        ForkThread(
			import('/mods/profiler/lua/profiler.lua').SendChunk, Sync.profilerChunk
        )
    end
	if Sync.profilerReport then
		ForkThread(
			import('/mods/profiler/lua/profiler.lua').SendReport, Sync.profilerReport
		)
	end
end

local baseBeginSession = BeginSession
function BeginSession()
	baseBeginSession()
	import('/mods/profiler/lua/profiler.lua').Start()
end

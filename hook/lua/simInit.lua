local baseBeginSession = BeginSession
function BeginSession()
	baseBeginSession()
	import('/lua/profiler.lua').Start()
end

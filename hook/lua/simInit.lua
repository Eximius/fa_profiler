local baseBeginSession = BeginSession
function BeginSession()
	baseBeginSession()
	import('/profiler.lua').Start()
end

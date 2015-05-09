local baseBeginSession = BeginSession
function BeginSession()
	baseBeginSession()
	local Profiler = import('/mods/profiler/lua/profiler.lua')
	Profiler.Start()
end

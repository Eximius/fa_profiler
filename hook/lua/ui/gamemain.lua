local baseOnFirstUpdate = OnFirstUpdate
function OnFirstUpdate()
	if not CheatsEnabled() then
		WARN('You have to have cheats enabled to use the profiler.')
	else
		ConExecute("IN_BindKey Ctrl-P SimLua import('/lua/profiler.lua').Toggle()")
	end
end

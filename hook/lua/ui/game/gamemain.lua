local baseOnFirstUpdate = OnFirstUpdate
function OnFirstUpdate()
	baseOnFirstUpdate()
	ConExecute("IN_BindKey Ctrl-P SimLua import('/mods/profiler/lua/profiler.lua').Toggle()")
	ConExecute("IN_BindKey Ctrl-R UI_Lua RestartSession()")
end

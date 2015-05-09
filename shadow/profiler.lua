
-- This is the lua profiler

local running = false

local time = GetSystemTimeSecondsOnlyForProfileUse

local start_time = 0
local stop_time  = 0
local methodId_counter = 1
local methodIds = {}
local report = {}

local function _profiler_hook(event)

	local func_info = debug.getinfo(2, 'nS')

	local thread_id = 1


	local methodId = methods[func_info.func]
	if not methodId then
		methodId = methodId_counter
		methods[func_info.func] = methodId
		methodId_counter = methodId_counter + 1
	end

	-- action: Call = 0, Return = 1
	local action = (event != 'return') and 0 or 1

	local time_delta = (time() - start_time) * 1000000

end

function Start()

	LOG('Starting profiler at '+tostring(time()))

	debug.sethook(_profiler_hook, 'cr')

	start_time = time()
end

function Stop()
	stop_time = time()

	Sync.profilerReport = report
end

function Toggle()
	if running then
		Stop()
	else
		Start()
	end
end

FORMAT_FUNCNAME = 'L%03d:%s'
local function PrettyName(funcInfo)
	local name = funcInfo.name or 'anonymous'
	local source = funcInfo.short_src or funcInfo.namewhat
	local line = funcInfo.linedefined

	return source, string.format(FORMAT_FUNCNAME, line, name)
end

function SendReport()

end
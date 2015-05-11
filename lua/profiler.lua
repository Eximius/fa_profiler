-- This is the lua profiler

local running = false

local methodMap
local methodInfoMap
local methodIdCounter
local recordBuffer

local startTime

-- Avoid profiling the profiler
local blacklist = {}

-- Maps toplevel functions to thread identifiers.
local threads
local thread_id_counter

-- Maps thread ids to clock drifts.
local thread_drifts
local thread_yield_times
local thread_stacks

local current_thread

local global_drift

--- Used to reset the profiler state for a new run.
function Reset()
    methodMap = {}
    methodInfoMap = {}
    methodIdCounter = 0
    recordBuffer = {}

    threads = {}
    thread_id_counter = 1

    thread_drifts = {}
    thread_yield_times = {}
    thread_stacks = {}

    global_drift = 0
end

local function InitCurrentThread(thread_handle)
    current_thread = thread_id_counter
    thread_id_counter = thread_id_counter + 1
    threads[thread_handle] = current_thread
    thread_drifts[current_thread] = 0
    thread_stacks[current_thread] = {}
end

local function ResolveCurrentThreadId()
    local status, err = pcall(CurrentThread)
    if status then
        current_thread = threads[err]
        if not current_thread then
            InitCurrentThread(err)
        end
    else
        current_thread = 1
    end
end

local function PutRecord(method_id, action, event_time)
    table.insert(recordBuffer, current_thread)
    table.insert(recordBuffer, method_id)
    table.insert(recordBuffer, action)
    table.insert(recordBuffer, event_time - thread_drifts[current_thread])
    table.insert(recordBuffer, event_time)
end

local time = nil

local function _profiler_hook(action)
    local eventTime = time()
    -- Output format:
    -- Method id, Method action, delta since start.

    -- Since we can obtain the 'function' for the item we've had call us, we
    -- can use that...
    local caller_info = debug.getinfo(2, 'nSf')

    -- Don't profile the profiler.
    if blacklist[caller_info.func] then
        return
    end

    ResolveCurrentThreadId()

    if caller_info.func == coroutine.yield then
        if action == 'call' then
            thread_yield_times[current_thread] = eventTime
        else
            thread_drifts[current_thread] =
                thread_drifts[current_thread] + eventTime - thread_yield_times[current_thread]
        end
        global_drift = global_drift + time() - eventTime
        return
    end

    local thread_stack = thread_stacks[current_thread]

    -- Find or generate function id for this function.
    local methodId = methodMap[caller_info.func]
    if not methodId then
        methodId = methodIdCounter + 1
        methodIdCounter = methodId
        methodMap[caller_info.func] = methodId
        methodInfoMap[caller_info.func] = caller_info
    end

    if action == 'call' then
        table.insert(thread_stack, methodId)
        PutRecord(methodId, 0, eventTime)
    elseif action == 'return' or action == 'tail return' then
        if table.getn(thread_stack) > 0 then
            methodId = table.remove(thread_stack)
            PutRecord(methodId, 1, eventTime)
        end
    else
        WARN('Unknown action: '..action)
    end
    global_drift = global_drift + time() - eventTime
end

function Start()
    if running then
        WARN('Profiler already running.')
        return
    end

    running = true

    -- Reinitialize all data structures so we can be reused.
    Reset()

    -- Fairly hacky, but these need to be sim-side
    time = GetSystemTimeSecondsOnlyForProfileUse
    blacklist[GetSystemTimeSecondsOnlyForProfileUse] = true

	LOG('Starting profiler at ' .. tostring(time()))

    InitCurrentThread('main')
    startTime = time()

	debug.sethook(_profiler_hook, 'cr')
end

function Stop()
    running = false
    debug.sethook(nil)

    WARN("Stopped profiler after " .. tostring(time() - startTime))
    -- Remove the references to func objects: this kills the Sync table.
    local stringMethodMap = {}
    for k, v in methodMap do
        stringMethodMap[v] = PrettyName(methodInfoMap[k])
    end

    -- Add output to sync table.
    Sync.profilerReport = {
        methodMap = stringMethodMap,
        outputBuffer = recordBuffer,
        startTime = startTime,
        global_drift = global_drift
    }

    -- Clean up so we don't use unnecessary memory.
    Reset()
end

function Toggle()
	if running then
		Stop()
	else
		Start()
	end
end

local FORMAT_FUNCNAME = '%s\tL%03d:%s'
function PrettyName(func)
    local className
    if func.what == "C" then
        return "Native\t"..( func.name or '?' )
    else
        local src = func.source
        if src then
            local crap_pos = src:find('\\lua')
            if crap_pos then
                className = src:sub(crap_pos):gsub('\\','/')
            else
                className = src
            end
        else
            className = '?'
        end
    end

    -- Return className followed by the name and line number
    return string.format(FORMAT_FUNCNAME, className, func.linedefined, func.name or "anonymous")
end

function CreateProgressBar()
    local UIUtil = import('/lua/ui/uiutil.lua')
    local Group = import('/lua/maui/group.lua').Group
    local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
    local StatusBar = import('/lua/maui/statusbar.lua').StatusBar

    local group = Group(GetFrame(0), 'Profiler')

    local title = UIUtil.CreateText(group, "Dumping profiler data.", 24)
    LayoutHelpers.AtTopIn(title, GetFrame(0), 100)
    LayoutHelpers.AtHorizontalCenterIn(title, GetFrame(0))

    local progressBar = StatusBar(group, 0, 100, false, false,
        UIUtil.UIFile('/game/resource-mini-bars/mini-energy-bar-back_bmp.dds'),
        UIUtil.UIFile('/game/resource-mini-bars/mini-energy-bar_bmp.dds'), false)

    progressBar.Width:Set(300)

    LayoutHelpers.Below(progressBar, title)
    LayoutHelpers.AtHorizontalCenterIn(progressBar, GetFrame(0))

    -- LayoutHelpers.AtCenterIn(group, GetFrame(0))

    return group, progressBar
end

-- Write the profile... to the preferences file. Sanity not included.
function SendReport(report)
    LOG("Writing profiler output (this may take some time)")
    LOG('Profiler global_drift: '..tostring(report.global_drift))

    GpgNetSend('FOpen', 1, 'keyfile.dat')
    -- Fire the name map at GpgNet.
    for k, v in report.methodMap do
        -- k is a method-info record, v is the associated identifier.
        GpgNetSend('FWrite', 1, k, v)
    end
    GpgNetSend('FClose', 1)

    GpgNetSend('FOpen', 2, 'profile.dat')

    local v = report.outputBuffer

    -- Fire the profiler records at GpgNet
    local length = table.getn(report.outputBuffer)

    -- Convert timestamps to integers.
    for i = 4, length, 5 do
        v[i] = math.floor((v[i] - report.startTime) * 1000000)
        v[i+1] = math.floor((v[i+1] - report.startTime) * 1000000)
    end

    local i = 1
    local lastProgress = 0
    local progressGroup, progressBar = CreateProgressBar()

    while i < length - 12 do
        GpgNetSend('FWrite', 2,
            v[i], v[i + 1], v[i + 2],
            v[i + 3], v[i + 4], v[i + 5],
            v[i + 6], v[i + 7], v[i + 8],
            v[i + 9], v[i + 10], v[i + 11]
        )

        i = i + 12

        if lastProgress < math.floor(i / (length / 300)) then
            lastProgress = lastProgress + 1
            progressBar:SetValue(lastProgress)
            WaitSeconds(0)
        end
    end

    for i = i, length do
        GpgNetSend('FWrite', 2, v[i])
    end

    GpgNetSend('FClose', 2)

    progressGroup:Destroy()

    LOG("Output complete")

end

-- Blacklist self
blacklist[_profiler_hook] = true
blacklist[debug.sethook] = true
blacklist[debug.getinfo] = true

blacklist[Start] = true
blacklist[Stop] = true
blacklist[Toggle] = true
blacklist[InitCurrentThread] = true
blacklist[PutRecord] = true
blacklist[ResolveCurrentThreadId] = true

-- Native functions
blacklist[next] = true
blacklist[type] = true
blacklist[table.getn] = true
blacklist[coroutine.resume] = true
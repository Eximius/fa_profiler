-- This is the lua profiler

local running = false

local methodMap
local methodIdCounter
local recordBuffer

local startTime

-- Avoid profiling the profiler
local blacklist = {}

-- Yielding function set
local yielding = {}

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
    thread_yield_times[current_thread] = 0
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
    local func = debug.getinfo(2, 'f').func

    -- Don't profile the profiler.
    if blacklist[func] then
        return
    end

    local eventTime = time()

    local status, err = pcall(CurrentThread)
    if status then
        current_thread = threads[err]
        if not current_thread then
            InitCurrentThread(err)
        end
    else
        current_thread = 1
    end

    if yielding[func] then
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
    local methodId = methodMap[func]
    if not methodId then
        methodId = methodIdCounter + 1
        methodIdCounter = methodId
        methodMap[func] = methodId
    end

    if action == 'call' then
        table.insert(thread_stack, methodId)
        PutRecord(methodId, 0, eventTime)
    else --if action == 'return' or action == 'tail return' then
        if table.getn(thread_stack) > 0 then
            methodId = table.remove(thread_stack)
            PutRecord(methodId, 1, eventTime)
        end
    end
    global_drift = global_drift + time() - eventTime
end

local function DontRunOutOfMemory()
    while running do
        local length = table.getn(recordBuffer)
        if length > 1000000 then
            LOG('Profiler: Chunked at '..tostring(length / 5)..' records.')
            Sync.profilerChunk = recordBuffer
            recordBuffer = {}
        end
        WaitTicks(20)
    end
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

    Sync.profilerStarted = startTime

	debug.sethook(_profiler_hook, 'cr')

    ForkThread(DontRunOutOfMemory)
end

function Stop()
    running = false
    debug.sethook(nil)

    WARN("Stopped profiler after " .. tostring(time() - startTime))
    -- Remove the references to func objects: this kills the Sync table.
    local stringMethodMap = {}
    for func, k in methodMap do
        stringMethodMap[k] = PrettyName(debug.getinfo(func))
    end

    Sync.profilerChunk = recordBuffer
    -- Add output to sync table.
    Sync.profilerReport = {
        methodMap = stringMethodMap,
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

    local title = UIUtil.CreateText(group, "Streaming profiler data.", 24)
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

local profile_send_report_thread
local profile_sender
local profiler_chunks = {}

local profile_length = 0
local profile_written = 0

local function ProfileSender()
    GpgNetSend('FOpen', 2, 'profile.dat')

    -- Show stream progress
    local lastProgress = 0
    local progressGroup, progressBar = CreateProgressBar()

    local last_chunk_checked
    while true do
        local continue_length_check
        for _, chunk in profiler_chunks do
            if chunk == last_chunk_checked then
                continue_length_check = true
            elseif continue_length_check then
                profile_length = profile_length + table.getn(chunk)
            end
        end
        last_chunk_checked = profiler_chunks[table.getn(profiler_chunks)]

        if table.getn(profiler_chunks) > 0 then
            local chunk = table.remove(profiler_chunks)
            local length = table.getn(chunk)
            local v = chunk

            LOG('Profiler: sending '..tostring(length / 5)..' records.')

                -- Convert timestamps to integers.
            for i = 4, length, 5 do
                v[i] = math.floor((v[i] - startTime) * 1000000)
                v[i+1] = math.floor((v[i+1] - startTime) * 1000000)
            end

            local i = 1
            while i < length - 12 do
                GpgNetSend('FWrite', 2,
                    v[i], v[i + 1], v[i + 2],
                    v[i + 3], v[i + 4], v[i + 5],
                    v[i + 6], v[i + 7], v[i + 8],
                    v[i + 9], v[i + 10], v[i + 11]
                )

                i = i + 12
                profile_written = profile_written + 12
            end

            for i = i, length do
                GpgNetSend('FWrite', 2, v[i])
            end
        end
        if profile_send_report_thread and table.getn(profiler_chunks) == 0 then
            break
        end
        progressBar:SetValue(math.floor(profile_written / (profile_length / 300)))

        WaitSeconds(2)
    end
    ResumeThread(profile_send_report_thread)
    progressGroup:Destroy()
end

-- Send profile.dat chunk
function SendChunk(chunk)
    if not profile_sender then
        profile_sender = ForkThread(ProfileSender)
    end
    table.insert(profiler_chunks, chunk)
end

-- Send/finish dumping profile data
function SendReport(report)
    LOG("Writing profiler output (this may take some time)")
    LOG('Profiler global_drift: '..tostring(report.global_drift))

    profile_send_report_thread = CurrentThread()

    GpgNetSend('FOpen', 1, 'keyfile.dat')
    -- Fire the name map at GpgNet.
    for k, v in report.methodMap do
        -- k is a method-info record, v is the associated identifier.
        GpgNetSend('FWrite', 1, k, v)
    end
    GpgNetSend('FClose', 1)

    SuspendCurrentThread()

    GpgNetSend('FClose', 2)

    LOG("Output complete")

end

function UIProfilerStarted(time_start)
    startTime = time_start
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
local blacklist_libs = {
    string, math, table
}
for _, lib in moho do
    table.insert(blacklist_libs, lib)
end

for _, lib in blacklist_libs do
    for _, func in lib do
        blacklist[func] = true
    end
end

blacklist[next] = true
blacklist[type] = true
blacklist[unpack] = true
blacklist[ipairs] = true
blacklist[assert] = true
blacklist[setmetatable] = true
blacklist[getmetatable] = true

-- Yielding functions
yielding[coroutine.yield] = true
yielding[WaitSeconds] = true
yielding[WaitFor] = true
yielding[SuspendCurrentThread] = true
yielding[coroutine.resume] = true
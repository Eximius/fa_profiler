-- This is the lua profiler

local running = false

local methodMap = {}
local methodInfoMap = {}
local methodIdCounter = 0
local recordBuffer = {}

local startTime

-- Avoid profiling the profiler
local blacklist = { }

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

    -- Find or generate function id for this function.
    local methodId = methodMap[caller_info.func]
    if not methodId then
        methodId = methodIdCounter + 1
        methodIdCounter = methodId
        methodMap[caller_info.func] = methodId
        methodInfoMap[caller_info.func] = caller_info
    end

    -- 0 for call, 1 for return, as per traceview.
    local actionCode = 1
    if action ~= "return" then
        actionCode = 0
    end

    -- Insert a traceview-ish record for this event into the output buffer.
    -- Linked-list used to further reduce overhead. Muwhaha.
    table.insert(recordBuffer, methodId)
    table.insert(recordBuffer, actionCode)
    table.insert(recordBuffer, eventTime)
end

function Start()
    -- Fairly hacky, but these need to be sim-side
    time = GetSystemTimeSecondsOnlyForProfileUse
    blacklist[GetSystemTimeSecondsOnlyForProfileUse] = true

	LOG('Starting profiler at ' .. tostring(time()))

    startTime = time()
	debug.sethook(_profiler_hook, 'cr')
    running = true
end

function Stop()
    running = false
    debug.sethook(nil)

    WARN("Stopped profiler after at " .. tostring(time() - startTime))
    -- Remove the references to func objects: this kills the Sync table.
    local stringMethodMap = {}
    for k, v in methodMap do
        stringMethodMap[v] = PrettyName(methodInfoMap[k])
    end

    -- Add output to sync table.
    Sync.profilerReport = {
        methodMap = stringMethodMap,
        outputBuffer = recordBuffer,
        startTime = startTime
    }
end

function Toggle()
	if running then
		Stop()
	else
		Start()
	end
end

local FORMAT_FUNCNAME = '%s	L%03d:%s'
function PrettyName(func)
    local className
    if func.what == "C" then
        className = "Native"
    else
        className = func.short_src or "?"
    end

    -- Return className followed by the name and line number
    return string.format(FORMAT_FUNCNAME, className, func.linedefined, func.name or "anonymous")
end

function CreateProgressBar()
    local Popup = import('/mods/profiler/lua/popup.lua').Popup
    local Group = import('/lua/maui/group.lua').Group
    local StatusBar = import('/lua/maui/statusbar.lua').StatusBar
    local LayoutHelpers = import('/lua/maui/layouthelpers.lua')
    local UIUtil = import('/lua/ui/uiutil.lua')

    local dialogContent = Group(GetFrame(0))
    dialogContent.Width:Set(600)
    dialogContent.Height:Set(100)

    -- Make an uncloseable popup.
    local popup = Popup(GetFrame(0), dialogContent)
    popup.Close = function() end

    local title = UIUtil.CreateText(dialogContent, "Saving profiler data...", 16, UIUtil.bodyFont)
    LayoutHelpers.AtTopIn(title, dialogContent)
    LayoutHelpers.AtHorizontalCenterIn(title, dialogContent)
    group.Height:Set(function() return group.title.Height() + 4 end)

    local progressBar = StatusBar(dialogContent, 0, 100, false, false,
        UIUtil.UIFile('/game/resource-mini-bars/mini-energy-bar-back_bmp.dds'),
        UIUtil.UIFile('/game/resource-mini-bars/mini-energy-bar_bmp.dds'), false)

    progressBar.Width:Set(function() return dialogContent.Width() - 20 end)

    LayoutHelpers.AtCenterIn(progressBar, dialogContent)

    return progressBar
end

-- Write the profile... to the preferences file. Sanity not included.
function SendReport(report)
    WARN("Writing profiler output (this may take some time)")

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
    for i = 3, length, 3 do
        v[i] = math.floor((v[i] - report.startTime) * 1000000)
    end

    local i = 1
    local lastProgress = 0
    local progressBar = CreateProgressBar()

    while i < length - 12 do
        GpgNetSend('FWrite', 2,
            v[i], v[i + 1], v[i + 2],
            v[i + 3], v[i + 4], v[i + 5],
            v[i + 6], v[i + 7], v[i + 8],
            v[i + 9], v[i + 10], v[i + 11]
        )

        i = i + 12

        if lastProgress < math.floor(i / (length / 100)) then
            lastProgress = lastProgress + 1
            progressBar:SetValue(lastProgress)
            WaitSeconds(0)
        end
    end

    for i = i, length do
        GpgNetSend('FWrite', 2, v[i])
    end

    GpgNetSend('FClose', 2)

    WARN("Output complete")
end

blacklist[Start] = true
blacklist[Stop] = true
blacklist[_profiler_hook] = true
blacklist[SendReport] = true
blacklist[PrettyName] = true
blacklist[debug.sethook] = true
blacklist[debug.getinfo] = true
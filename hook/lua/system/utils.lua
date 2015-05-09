
local thread_counter = 2

baseForkThread = ForkThread
function ForkThread(foo, ...)
	local foo = foo
	local args = arg

	local function bar()
		foo(unpack(args))
	end
	return baseForkThread(bar)
end
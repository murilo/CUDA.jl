# Initialization

export device!, device_reset!

const thread_contexts = Union{Nothing,CuContext}[]

# FIXME: support for flags (see `cudaSetDeviceFlags`)

# API calls that are allowed without lazily initializing the CUDA library
#
# this list isn't meant to be complete (ie. many other API calls are actually allowed
# without setting-up a context), and only serves to make multi-device applications possible.
#
# feel free to open a PR adding additional API calls, if you have a specific use for them.
const preinit_apicalls = Set{Symbol}([
    :cuInit,
    # error getters
    :cuGetErrorString,
    :cuGetErrorName,
    # version getter
    :cuDriverGetVersion,
    # device querying
    :cuDeviceGet,
    :cuDeviceGetCount,
    :cuDeviceGetName,
    :cuDeviceGetUuid,
    :cuDeviceTotalMem,
    :cuDeviceGetAttribute,
    :cuDeviceGetProperties,
    :cuDeviceComputeCapability,
    # context management
    :cuCtxGetCurrent,
    :cuCtxPushCurrent,
    :cuDevicePrimaryCtxRetain,
])

function maybe_initialize(apicall)
    tid = Threads.threadid()
    if @inbounds thread_contexts[tid] !== nothing || in(apicall, preinit_apicalls)
        return
    end

    initialize(apicall)
end

@noinline function initialize(apicall)
    @debug "Initializing CUDA on thread $(Threads.threadid()) after call to $apicall"
    device!(CuDevice(0))
end

const device!_listeners = Set{Function}()

"""
    device!(dev)

Sets `dev` as the current active device for the calling host thread. Devices can be
specified by integer id, or as a `CuDevice`. This is intended to be a low-cost operation,
only performing significant work when calling it for the first time for each device.

If your library or code needs to perform an action when the active device changes, add a
callback of the signature `(::CuDevice, ::CuContext)` to the `device!_listeners` set.
"""
function device!(dev::CuDevice)
    tid = Threads.threadid()

    # get the primary context
    pctx = CuPrimaryContext(dev)
    ctx = CuContext(pctx)

    # update the thread-local state
    @inbounds thread_contexts[tid] = ctx
    activate(ctx)

    foreach(listener->listener(dev, ctx), device!_listeners)
end
device!(dev::Integer) = device!(CuDevice(dev))

const device_reset!_listeners = Set{Function}()

"""
    device_reset!(dev::CuDevice=device())

Reset the CUDA state associated with a device. This call with release the underlying
context, at which point any objects allocated in that context will be invalidated.

If your library or code needs to perform an action when a device is reset, add a
callback of the signature `(::CuDevice, ::CuContext)` to the `device_reset!_listeners` set.
"""
function device_reset!(dev::CuDevice=device())
    pctx = CuPrimaryContext(dev)
    ctx = CuContext(pctx)
    foreach(listener->listener(dev, ctx), device_reset!_listeners)

    # unconditionally reset the primary context (don't just release it),
    # as there might be users outside of CUDAnative.jl
    unsafe_reset!(pctx)

    for (tid, thread_ctx) in enumerate(thread_contexts)
        if thread_ctx == ctx
            thread_contexts[tid] = nothing
        end
    end

    return
end

"""
    device!(f, dev)

Sets the active device for the duration of `f`.
"""
function device!(f::Function, dev::CuDevice)
    # FIXME: should use Push/Pop
    old_ctx = CuCurrentContext()
    try
        device!(dev)
        f()
    finally
        if old_ctx != nothing
            activate(old_ctx)
        end
    end
end
device!(f::Function, dev::Integer) = device!(f, CuDevice(dev))

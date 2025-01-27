# Utilities for working with HSA signals

mutable struct ROCSignal
    signal::Ref{HSA.Signal}
end

function ROCSignal(init::Integer=1; interrupt=true, ipc=true)
    signal = ROCSignal(Ref{HSA.Signal}())
    if interrupt || ipc
        attrs = UInt32(0)
        if ipc
            attrs |= HSA.AMD_SIGNAL_IPC
        end
        HSA.amd_signal_create(Int64(init), 0, C_NULL, attrs, signal.signal) |> check
    else
        HSA.signal_create(Int64(init), 0, C_NULL, signal.signal) |> check
    end
    AMDGPU.hsaref!()
    finalizer(signal) do signal
        HSA.signal_destroy(signal.signal[]) |> check
        AMDGPU.hsaunref!()
    end
    return signal
end
ROCSignal(signal::HSA.Signal) = ROCSignal(Ref(signal))

Base.show(io::IO, signal::ROCSignal) =
    print(io, "ROCSignal($(signal.signal[]))")

Adapt.adapt_structure(::Adaptor, sig::ROCSignal) = sig.signal[]

const DEFAULT_SIGNAL_TIMEOUT = Ref{Union{Float64, Nothing}}(nothing)
const SIGNAL_TIMEOUT_KILL_QUEUE = Ref{Bool}(true)

struct SignalTimeoutException <: Exception
    signal::ROCSignal
end

"""
    Base.wait(signal::ROCSignal; soft=true, minlat=0.000001, timeout=DEFAULT_SIGNAL_TIMEOUT[])

Waits on an `ROCSignal` to decrease below 1. If `soft=true` (default), uses
sleep polling; otherwise uses HSA's signal waiter. `minlat` sets the minimum
latency for the software waiter; lower values can decrease latency at the cost
of increased polling load. `timeout`, if not `nothing`, sets the timeout for
software waiting, after which the call will error with a
`SignalTimeoutException`.
"""
function Base.wait(signal::ROCSignal; soft=true, minlat=0.000001, timeout=DEFAULT_SIGNAL_TIMEOUT[])
    if soft
        start_time = time_ns()
        while !RT_EXITING[]
            value = HSA.signal_load_scacquire(signal.signal[])
            if value < 1
                return
            end
            now_time = time_ns()
            diff_time = (now_time - start_time) / 10^9
            if timeout !== nothing && diff_time > timeout
                throw(SignalTimeoutException(signal))
            end
            if minlat < 0.001 && diff_time < 10^3
                # Use Libc.systemsleep for higher precision in the microsecond range
                Libc.systemsleep(minlat)
                yield()
            else
                sleep(minlat)
            end
        end
    else
        # Wait on the dispatch completion signal until the kernel is finished
        HSA.signal_wait_acquire(signal.signal[],
                                HSA.SIGNAL_CONDITION_LT, 1, typemax(UInt64),
                                HSA.WAIT_STATE_BLOCKED)
    end
end
Base.wait(signal::HSA.Signal; kwargs...) = wait(ROCSignal(signal); kwargs...)

Base.notify(signal::ROCSignal) = HSA.signal_store_screlease(signal.signal[], 0)

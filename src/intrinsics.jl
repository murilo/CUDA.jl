# Native intrinsics

export
    # Indexing and dimensions
    threadIdx, blockDim, blockIdx, gridDim,
    warpsize, nearest_warpsize,

    # Memory management
    sync_threads,
    @cuStaticSharedMem, @cuDynamicSharedMem


#
# Support functionality
#

const llvmtypes = Dict{Type,Symbol}(
    Void    => :void,
    Int32   => :i32,
    Int64   => :i64,
    Float32 => :float,
    Float64 => :double
)

const jltypes = Dict{Symbol,Type}(v => k for (k,v) in llvmtypes)

"""
Decode an expression of the form:

   function(arg::arg_type, arg::arg_type, ... arg::arg_type)::return_type

Returns a tuple containing the function name, a vector of argument, a vector of argument
types and the return type (all in symbolic form).
"""
function decode_call(e)
    @assert e.head == :(::)
    rettype = e.args[2]::Symbol

    call = e.args[1]
    @assert call.head == :call

    fn = Symbol(call.args[1])
    args = Symbol[arg.args[1] for arg in call.args[2:end]]
    argtypes = Symbol[arg.args[2] for arg in call.args[2:end]]

    return fn, args, argtypes, rettype
end

"""
Generate a `llvmcall` statement calling an intrinsic specified as follows:

    intrinsic(arg::arg_type, arg::arg_type, ... arg::arg_type)::return_type [attr]

The argument types should be valid LLVM type identifiers (eg. i32, float, double).
Conversions to the corresponding Julia type are automatically generated; make sure the
actual arguments are of the same type to make these conversions no-ops. The optional
argument `attr` indicates which LLVM function attributes (such as `readnone` or `nounwind`)
to add to the intrinsic declaration.

For example, the following call:
    @wrap __somme__intr(x::float, y::double)::float

will yield the following `llvmcall`:

    Base.llvmcall(("declare float @__somme__intr(float, double)",
                   "%3 = call float @__somme__intr(float %0, double %1)
                    ret float %3"),
                  Float32, Tuple{Float32,Float64},
                  convert(Float32,x), convert(Float64,y))
"""
macro wrap(call, attrs="")
    intrinsic, args, argtypes, rettype = decode_call(call)

    llvm_args = String["%$i" for i in 0:length(argtypes)]
    if rettype == :void
        llvm_ret_asgn = ""
        llvm_ret = "void"
    else
        llvm_ret_var = "%$(length(argtypes)+1)"
        llvm_ret_asgn = "$llvm_ret_var = "
        llvm_ret = "$rettype $llvm_ret_var"
    end
    llvm_declargs = join(argtypes, ", ")
    llvm_defargs = join(("$t $arg" for (t,arg) in zip(argtypes, llvm_args)), ", ")

    julia_argtypes = (jltypes[t] for t in argtypes)
    julia_args = (:(convert($argtype, $arg)) for (arg, argtype) in zip(args, julia_argtypes))

    return quote
        Base.llvmcall(
            ($"""declare $rettype @$intrinsic($llvm_declargs)""",
             $"""$llvm_ret_asgn call $rettype @$intrinsic($llvm_defargs)
                 ret $llvm_ret"""),
            $(jltypes[rettype]), Tuple{$(julia_argtypes...)}, $(julia_args...))
    end
end


#
# Indexing and dimensions
#

for dim in (:x, :y, :z)
    # Thread index
    fn = Symbol("threadIdx_$dim")
    @eval @inline @target ptx $fn() = (@wrap llvm.nvvm.read.ptx.sreg.tid.$dim()::i32    "readnone nounwind")+Int32(1)

    # Block size (#threads per block)
    fn = Symbol("blockDim_$dim")
    @eval @inline @target ptx $fn() =  @wrap llvm.nvvm.read.ptx.sreg.ntid.$dim()::i32   "readnone nounwind"

    # Block index
    fn = Symbol("blockIdx_$dim")
    @eval @inline @target ptx $fn() = (@wrap llvm.nvvm.read.ptx.sreg.ctaid.$dim()::i32  "readnone nounwind")+Int32(1)

    # Grid size (#blocks per grid)
    fn = Symbol("gridDim_$dim")
    @eval @inline @target ptx $fn() =  @wrap llvm.nvvm.read.ptx.sreg.nctaid.$dim()::i32 "readnone nounwind"
end

# Tuple accessors
@inline @target ptx threadIdx() = CUDAdrv.CuDim3(threadIdx_x(), threadIdx_y(), threadIdx_z())
@inline @target ptx blockDim() =  CUDAdrv.CuDim3(blockDim_x(),  blockDim_y(),  blockDim_z())
@inline @target ptx blockIdx() =  CUDAdrv.CuDim3(blockIdx_x(),  blockIdx_y(),  blockIdx_z())
@inline @target ptx gridDim() =   CUDAdrv.CuDim3(gridDim_x(),   gridDim_y(),   gridDim_z())

# NOTE: we often need a const warpsize (eg. for shared memory), sp keep this fixed for now
# @inline @target ptx warpsize() = @wrap llvm.nvvm.read.ptx.sreg.warpsize()::i32 "readnone nounwind"
const warpsize = Int32(32)

"Return the nearest multiple of a warpsize, a common requirement for the amount of threads."
@inline nearest_warpsize(threads) =  threads + (warpsize - threads % warpsize) % warpsize



#
# Thread management
#

# Synchronization
# TODO: rename to syncthreads
@inline @target ptx sync_threads() = @wrap llvm.nvvm.barrier0()::void "readnone nounwind"


#
# Shared memory
#

# FIXME: this adds module-scope declarations by means of `llvmcall`, which is unsupported
# TODO: return an Array-like object (containing the number of elements) instead of a raw pointer
# TODO: downcasting pointers to global AS might be inefficient
#       -> check if AS propagation resolves this
#       -> Ptr{AS}, ASPtr{AS}, ...?
# BUG: calling a device function referencing a static-memory @cuSharedMem will reference
#      the same memory -- how does this work in CUDA?

shmem_id = 0

# TODO: shape instead of len

"""
    @cuStaticSharedMem(typ::Type, nel::Integer) -> CuDeviceArray{typ}

Get an array pointing to a statically-allocated piece of shared memory. The type `typ` and
number of elements `nel` should be statically known after type inference, or a (currently
unreported) error will be thrown resulting in a runtime generic call to an internal
generator function.
"""
macro cuStaticSharedMem(typ, nel)
    return esc(:(CUDAnative.generate_static_shmem($typ, Val{$nel})))
end

@generated function generate_static_shmem{T,N}(::Type{T}, ::Type{Val{N}})
    return emit_static_shmem(T, N)
end

function emit_static_shmem(jltyp::Type, nel::Integer)
    if !haskey(llvmtypes, jltyp)
        error("cuStaticSharedMem: unsupported type '$jltyp'")
    end
    llvmtyp = llvmtypes[jltyp]

    global shmem_id
    var = "shmem$(shmem_id::Int += 1)"

    return quote
        CuDeviceArray($nel, Base.llvmcall(
            ($"""@$var = internal addrspace(3) global [$nel x $llvmtyp] zeroinitializer, align 4""",
             $"""%1 = getelementptr inbounds [$nel x $llvmtyp], [$nel x $llvmtyp] addrspace(3)* @$var, i64 0, i64 0
                 %2 = addrspacecast $llvmtyp addrspace(3)* %1 to $llvmtyp addrspace(0)*
                 ret $llvmtyp* %2"""),
            Ptr{$jltyp}, Tuple{}))
    end
end


"""
    @cuDynamicSharedMem(typ::Type, nel::Integer, [offset::Integer=0]) -> CuDeviceArray{typ}

Get an array pointing to a dynamically-allocated piece of shared memory. The type `typ`
should be statically known after type inference, or a (currently unreported) error will be
thrown resulting in a runtime generic call to an internal generator function. The necessary
memory needs to be allocated when calling the kernel.

Optionally, an offset parameter indicating how many bytes to add to the base shared memory
pointer can be specified. This is useful when dealing with a heterogeneous buffer of dynamic
shared memory; in the case of a homogeneous multi-part buffer it is preferred to use `view`.
"""
macro cuDynamicSharedMem(typ, nel, offset=0)
    return esc(:(CUDAnative.generate_dynamic_shmem($typ, $nel, $offset)))
end

@generated function generate_dynamic_shmem{T}(::Type{T}, nel, offset)
    return emit_dynamic_shmem(T, :(nel), :(offset))
end

# TODO: boundscheck against %dynamic_smem_size (currently unsupported by LLVM)
function emit_dynamic_shmem(jltyp::Type, nel::Symbol, offset::Symbol)
    if !haskey(llvmtypes, jltyp)
        error("cuDynamicSharedMem: unsupported type '$jltyp'")
    end
    llvmtyp = llvmtypes[jltyp]

    global shmem_id
    var = "shmem$(shmem_id::Int += 1)"

    return quote
        CuDeviceArray($nel, Base.llvmcall(
            ($"""@$var = external addrspace(3) global [0 x $llvmtyp]""",
             $"""%1 = getelementptr inbounds [0 x $llvmtyp], [0 x $llvmtyp] addrspace(3)* @$var, i64 0, i64 0
                 %2 = addrspacecast $llvmtyp addrspace(3)* %1 to $llvmtyp addrspace(0)*
                 ret $llvmtyp* %2"""),
            Ptr{$jltyp}, Tuple{}) + $offset)
    end
end

# NOTE: this might be a neater approach (with a user-end macro for hiding the `Val{N}`):

# for typ in ((Int64,   :i64),
#             (Float32, :float),
#             (Float64, :double))
#     T, U = typ
#     @eval begin
#         cuSharedMem{T}(::Type{$T}) = Base.llvmcall(
#             ($"""@shmem_$U = external addrspace(3) global [0 x $U]""",
#              $"""%1 = getelementptr inbounds [0 x $U], [0 x $U] addrspace(3)* @shmem_$U, i64 0, i64 0
#                  %2 = addrspacecast $U addrspace(3)* %1 to $U addrspace(0)*
#                  ret $U* %2"""),
#             Ptr{$T}, Tuple{})
#         cuSharedMem{T,N}(::Type{$T}, ::Val{N}) = Base.llvmcall(
#             ($"""@shmem_$U = internal addrspace(3) global [$N x $llvmtyp] zeroinitializer, align 4""",
#              $"""%1 = getelementptr inbounds [$N x $U], [$N x $U] addrspace(3)* @shmem_$U, i64 0, i64 0
#                  %2 = addrspacecast $U addrspace(3)* %1 to $U addrspace(0)*
#                  ret $U* %2"""),
#             Ptr{$T}, Tuple{})
#     end
# end

# However, it requires a change to `llvmcall`, as now calling the static case twice results in
#          a reference to the same memory


#
# Shuffling
#

# TODO: should shfl_idx conform to 1-based indexing?

## narrow

for typ in ((Int32,   :i32, :i32),
            (UInt32,  :i32, :i32),
            (Float32, :f32, :float))
    jl, intr, llvm = typ

    for op in ((:up,   Int32(0x00)),
               (:down, Int32(0x1f)),
               (:bfly, Int32(0x1f)),
               (:idx,  Int32(0x1f)))
        mode, mask = op
        fname = Symbol("shfl_$mode")
        pack_expr = :(((warpsize - Int32(width)) << 8) | $mask)
        @static if VersionNumber(Base.libllvm_version) >= v"3.9-"
            intrinsic = Symbol("llvm.nvvm.shfl.$mode.$intr")
            @eval begin
                export $fname
                @inline $fname(val::$jl, srclane::Integer, width::Integer=warpsize) = Base.llvmcall(
                        ($"""declare $llvm @$intrinsic($llvm, i32, i32)""",
                         $"""%4 = call $llvm @$intrinsic($llvm %0, i32 %1, i32 %2)
                             ret $llvm %4"""),
                        $jl, Tuple{$jl, Int32, Int32}, val, Int32(srclane),
                        $pack_expr)
            end
        else
            instruction = Symbol("shfl.$mode.b32")  # NOTE: only b32 available, no i32/f32
            @eval begin
                export $fname
                @inline $fname(val::$jl, srclane::Integer, width::Integer=warpsize) = Base.llvmcall(
                        $"""%4 = call $llvm asm sideeffect "$instruction \$0, \$1, \$2, \$3;", "=r,r,r,r"($llvm %0, i32 %1, i32 %2)
                            ret $llvm %4""",    # "
                        $jl, Tuple{$jl, Int32, Int32}, val, Int32(srclane),
                        $pack_expr)
            end
        end
    end
end


## wide

@inline decode(val::UInt64) = trunc(UInt32,  val & 0x00000000ffffffff),
                              trunc(UInt32, (val & 0xffffffff00000000)>>32)

@inline encode(x::UInt32, y::UInt32) = UInt64(x) | UInt64(y)<<32

# NOTE: we only reuse the i32 shuffle, does it make any difference using eg. f32 shuffle for f64 values?
for typ in (Int64, UInt64, Float64)
    for mode in (:up, :down, :bfly, :idx)
        fname = Symbol("shfl_$mode")
        @eval begin
            export $fname
            @inline function $fname(val::$typ, srclane::Integer, width::Integer=warpsize)
                x,y = decode(reinterpret(UInt64, val))
                x = $fname(x, srclane, width)
                y = $fname(y, srclane, width)
                reinterpret($typ, encode(x,y))
            end
        end
    end
end


#
# Math
#

@inline @target ptx sin(x::Float32) = @wrap __nv_sinf(x::float)::float
@inline @target ptx sin(x::Float64) = @wrap __nv_sin(x::double)::double

@inline @target ptx cos(x::Float32) = @wrap __nv_cosf(x::float)::float
@inline @target ptx cos(x::Float64) = @wrap __nv_cos(x::double)::double

@inline @target ptx floor(x::Float32) = @wrap __nv_floorf(x::float)::float
@inline @target ptx floor(x::Float64) = @wrap __nv_floor(x::double)::double

@inline @target ptx ceil(x::Float32) = @wrap __nv_ceilf(x::float)::float
@inline @target ptx ceil(x::Float64) = @wrap __nv_ceil(x::double)::double

@inline @target ptx abs(x::Int32) =   @wrap __nv_abs(x::i32)::i32
@inline @target ptx abs(x::Int64) =   @wrap __nv_llabs(x::i64)::i64
@inline @target ptx abs(x::Float32) = @wrap __nv_fabsf(x::double)::double
@inline @target ptx abs(x::Float64) = @wrap __nv_fabs(x::double)::double

@inline @target ptx sqrt(x::Float32) = @wrap __nv_sqrtf(x::float)::float
@inline @target ptx sqrt(x::Float64) = @wrap __nv_sqrt(x::double)::double

@inline @target ptx exp(x::Float32) = @wrap __nv_expf(x::float)::float
@inline @target ptx exp(x::Float64) = @wrap __nv_exp(x::double)::double

@inline @target ptx log(x::Float32) = @wrap __nv_logf(x::float)::float
@inline @target ptx log(x::Float64) = @wrap __nv_log(x::double)::double

@inline @target ptx log10(x::Float32) = @wrap __nv_log10f(x::float)::float
@inline @target ptx log10(x::Float64) = @wrap __nv_log10(x::double)::double

@inline @target ptx erf(x::Float32) = @wrap __nv_erff(x::float)::float
@inline @target ptx erf(x::Float64) = @wrap __nv_erf(x::double)::double

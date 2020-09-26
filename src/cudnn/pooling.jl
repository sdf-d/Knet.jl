using AutoGrad: AutoGrad, @primitive1, value

using CUDA.CUDNN:
    #cudnnPoolingForward,
    cudnnPoolingBackward,
    cudnnGetPoolingNdForwardOutputDim,
    cudnnPoolingDescriptor_t,
        cudnnCreatePoolingDescriptor,
        cudnnSetPoolingNdDescriptor,
        cudnnDestroyPoolingDescriptor,
        cudnnPoolingMode_t,
            CUDNN_POOLING_MAX,                           # 0,
            CUDNN_POOLING_AVERAGE_COUNT_INCLUDE_PADDING, # 1, /* count for average includes padded values */
            CUDNN_POOLING_AVERAGE_COUNT_EXCLUDE_PADDING, # 2, /* count for average does not include padded values */
            CUDNN_POOLING_MAX_DETERMINISTIC,             # 3
        cudnnNanPropagation_t,
            CUDNN_NOT_PROPAGATE_NAN, # 0
            CUDNN_PROPAGATE_NAN      # 1


"""
    cudnnPoolingForward(x; mode, maxpoolingNanOpt, window, padding, stride, alpha, xDesc)
    cudnnPoolingForward(x, d::cudnnPoolingDescriptor; alpha, xDesc)
    cudnnPoolingForward!(y, x; mode, maxpoolingNanOpt, window, padding, stride, alpha, beta, xDesc, yDesc)
    cudnnPoolingForward!(y, x, d::cudnnPoolingDescriptor; alpha, beta, xDesc, yDesc)

Return pooled `x`, overwriting `y` if provided, according to keyword arguments or the
pooling descriptor `d`. Please see the [cuDNN
docs](https://docs.nvidia.com/deeplearning/cudnn/api/index.html#cudnnPoolingForward) for
details.

The dimensions of `x,y` tensors that are less than 4-D are assumed to be padded on the left
with 1's. The first `n-2` are spatial dimensions, the last two are always assumed to be
channel and batch.

The arguments `window`, `padding`, and `stride` can be specified as `n-2` dimensional
vectors, tuples or a single integer which is assumed to be repeated `n-2` times. If any of
the entries is larger than the corresponding `x` dimension, the `x` dimension is used
instead.

Arguments:
* `format = CUDNN_TENSOR_NCHW`
* `mode = CUDNN_POOLING_MAX`
* `maxpoolingNanOpt = CUDNN_NOT_PROPAGATE_NAN`
* `window = 2`
* `padding = 0`
* `stride = window`
* `alpha = 1`
* `beta = 0`
* `xDesc = cudnnTensorDescriptor(x)`
* `yDesc = cudnnTensorDescriptor(y)`

"""
cudnnPoolingForward, cudnnPoolingForward!


cudnnPoolingForward(x; o...) = cudnnPoolingForwardWithDefaults(x; o...)
cudnnPoolingForward(x, poolingDesc; o...) = cudnnPoolingForwardWithDefaults(x; poolingDesc, o...)
cudnnPoolingForward!(y, x; o...) = cudnnPoolingForwardWithDefaults(x; y, o...)
cudnnPoolingForward!(y, x, poolingDesc; o...) = cudnnPoolingForwardWithDefaults(x; y, poolingDesc, o...)


# This non-public function is used so that we can declare default values for kwargs only once.
function cudnnPoolingForwardWithDefaults(
    x;                          # no type for x, could be AutoGrad.Value
    format::cudnnTensorFormat_t = CUDNN_TENSOR_NCHW,
    mode::cudnnPoolingMode_t = CUDNN_POOLING_MAX,
    maxpoolingNanOpt::cudnnNanPropagation_t = CUDNN_NOT_PROPAGATE_NAN,
    window::Union{Integer,Vector{<:Integer},Tuple{<:Integer,Vararg{Int}}} = 2,
    padding::Union{Integer,Vector{<:Integer},Tuple{<:Integer,Vararg{Int}}} = 0,
    stride::Union{Integer,Vector{<:Integer},Tuple{<:Integer,Vararg{Int}}} = window,
    poolingDesc::cudnnPoolingDescriptor = cudnnPoolingDescriptor(mode, maxpoolingNanOpt, Cint(max(2,ndims(x)-2)), pooldims(window,size(x)), pooldims(padding,size(x)), pooldims(stride,size(x))),
    xDesc::cudnnTensorDescriptor = cudnnTensorDescriptor(x; format),
    y = cudnnPoolingForwardOutput(x, xDesc, poolingDesc),
    yDesc::cudnnTensorDescriptor = cudnnTensorDescriptor(y; format),
    alpha::Real = 1,
    beta::Real = 0
)
    alpha, beta = scalr(alpha,x), scalr(beta,x)
    cudnnPoolingForwardAutoGrad(x; poolingDesc, alpha, beta, xDesc, yDesc, y)
end


# This non-public function is used to define gradients: The only main args are gradient
# args, keyword args are mandatory and shared with the backward function.
function cudnnPoolingForwardAutoGrad(x; poolingDesc, alpha, beta, xDesc, yDesc, y)
    CUDA.CUDNN.cudnnPoolingForward(handle(), poolingDesc, alpha, xDesc, x, beta, yDesc, y)
    return y
end


# Define gradients
@primitive1((cudnnPoolingForwardAutoGrad(x; poolingDesc, alpha, beta, xDesc, yDesc, y),
             _dy,_y),
            ((x,y,dy,dx) = (value(x),value(_y),value(_dy),similar(x));
             cudnnPoolingBackward(handle(), poolingDesc, alpha, yDesc, y, yDesc, dy, xDesc, x, beta, xDesc, dx);
             dx))


# Convert the integer, tuple or array to pooling dims compatible with array size
function pooldims(d, s::Dims{N}) where N
    if d isa Integer || length(d) == N-2
        Cint[reverse(min.(d,s[1:N-2]))...]
    else
        throw(DimensionMismatch("Cannot pool $(Base.dims2string(s)) array with $d pooldims."))
    end
end

pooldims(d, s::Dims{3}) = pooldims(d, (1,s...))
pooldims(d, s::Dims{2}) = pooldims(d, (1,1,s...))
pooldims(d, s::Dims{1}) = pooldims(d, (1,1,1,s...))
pooldims(d, s::Dims{0}) = pooldims(d, (1,1,1,1))


function cudnnPoolingForwardOutput(x, xDesc, poolingDesc)
    d = Array{Cint}(undef, max(4, ndims(x)))
    cudnnGetPoolingNdForwardOutputDim(poolingDesc, xDesc, length(d), d)
    if length(d) > ndims(x) # This happens when x is (X,C,N), its TD is [N,C,X,1]
        @assert all(d[ndims(x)+1:end] .== 1)
        d = d[1:ndims(x)]
    end
    return similar(x, reverse(d)...)
end

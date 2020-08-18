module Train20

import Base: IteratorSize, IteratorEltype, length, size, iterate, eltype, rand, repeat, summary, show
using Base: @propagate_inbounds, tail, haslength, SizeUnknown
using Base.Iterators: Cycle
using Random: randn, rand, randperm
using Printf: @sprintf
using AutoGrad: AutoGrad, Param, @diff, full, recording
using LinearAlgebra: norm, lmul!, axpy!

include("data.jl"); export minibatch, Data, array_type
include("distributions.jl"); export gaussian, xavier, xavier_uniform, xavier_normal, bilinear
include("hyperopt.jl"); export goldensection, hyperband
include("param.jl"); export param, param0, atype, array_type
include("progress.jl"); export progress, progress!
include("train.jl"); export minimize, minimize!, converge, converge!, train!, training
include("update.jl"); export update!, clone, optimizers, SGD, Sgd, sgd, sgd!, Momentum, momentum, momentum!, Nesterov, nesterov, nesterov!, Adagrad, adagrad, adagrad!, Rmsprop, rmsprop, rmsprop!, Adadelta, adadelta, adadelta!, Adam, adam, adam!
include("train_ka.jl") # defines param, update!, _optimizers for KnetArray

end # module

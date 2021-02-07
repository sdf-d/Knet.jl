import Knet, AutoGrad
using Knet.Layers21: Conv, BatchNorm, Linear, Sequential, Residual
using Knet.Ops20: pool, softmax # TODO: add pool to ops21
using Knet.Ops21: relu # TODO: define activation layer?
using Images, FileIO, Artifacts, Base.Threads


resnet18() = setweights!(ResNet(2,2,2,2; block=ResNetBasic),
                         joinpath(artifact"resnet18","resnet18.jld2"))

resnet34() = setweights!(ResNet(3,4,6,3; block=ResNetBasic),
                         joinpath(artifact"resnet34","resnet34.jld2"))

resnet50() = setweights!(ResNet(3,4,6,3; block=ResNetBottleneck),
                         joinpath(artifact"resnet50","resnet50.jld2"))

resnet101() = setweights!(ResNet(3,4,23,3; block=ResNetBottleneck),
                          joinpath(artifact"resnet101","resnet101.jld2"))

resnet152() = setweights!(ResNet(3,8,36,3; block=ResNetBottleneck),
                          joinpath(artifact"resnet152","resnet152.jld2"))


function ResNet(nblocks...; block = ResNetBasic, classes = 1000)
    s = Sequential(ResNetInput(); name="$block$nblocks")
    x, y = 64, (block === ResNetBasic ? 64 : 256)
    for (layer, nblock) in enumerate(nblocks)
        if layer > 1; y *= 2; end
        blocks = Sequential(; name="Layer$layer")
        for iblock in 1:nblock
            stride = (layer > 1 && iblock == 1) ? 2 : 1
            push!(blocks, block(x, y; stride))
            x = y
        end
        push!(s, blocks)
    end
    push!(s, ResNetOutput(y, classes))
    resnetinit(s)
end


function ResNetBasic(x, y; stride=1, padding=1, activation=relu)
    Residual(
        Sequential(
            ConvBN(3, 3, x, y; activation, stride, padding),
            ConvBN(3, 3, y, y; padding),
        ),
        (x != y ? ConvBN(1, 1, x, y; stride) : identity);
        activation)
end


function ResNetBottleneck(x, y, b = y ÷ 4; stride=1, padding=1, activation=relu)
    Residual(
        Sequential(
            ConvBN(1, 1, x, b; activation),
            ConvBN(3, 3, b, b; activation, stride, padding),
            ConvBN(1, 1, b, y),
        ),
        (x != y ? ConvBN(1, 1, x, y; stride) : identity);
        activation)
end


function ResNetInput()
    Sequential(
        resnetprep,
        ConvBN(7, 7, 3, 64; stride=2, padding=3, activation=relu),
        x->pool(x; window=3, stride=2, padding=1);
        name = "Input"
    )
end


function ResNetOutput(xchannels, classes)
    Sequential(
        x->pool(x; mode=1, window=(size(x,1),size(x,2))),
        x->reshape(x, :, size(x,4)),
        Linear(xchannels, classes; binit=zeros); # TODO: rethink how to specify bias in Linear/Conv
        name = "Output"
    )
end

ConvBN(x...; o...) = Conv(x...; o..., normalization=BatchNorm())


# Run a single image so weights get initialized
resnetinit(m) = (m(convert(Knet.atype(),zeros(Float32,224,224,3,1))); m)


# Preprocessing - accept image, file or url as input, pass any other input through assuming tensor
resnetprep(x) = Knet.atype(x)

function resnetprep(file::String)
    img = occursin(r"^http", file) ? mktemp() do fn,io
        load(download(file,fn))
    end : load(file)
    resnetprep(img)
end


function resnetprep(img::Matrix{<:Gray})
    resnetprep(RGB.(img))
end


function resnetprep(img::Matrix{<:RGB})
    img = imresize(img, ratio=256/minimum(size(img))) # min(h,w)=256
    hcenter,vcenter = size(img) .>> 1
    img = img[hcenter-111:hcenter+112, vcenter-111:vcenter+112] # h,w=224,224
    img = channelview(img)                                      # c,h,w=3,224,224
    μ,σ = [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]
    img = (img .- μ) ./ σ
    img = permutedims(img, (3,2,1)) # 224,224,3
    img = reshape(img, (size(img)..., 1)) # 224,224,3,1
    Knet.atype(img)
end


# Apply model to all images in a directory and return top-1 predictions
# TODO: join with resnetpred, recursive directory walk, output filenames and classnames as well


# Human readable predictions from tensors, images, files, directories
function resnetpred(model, path; o...)
    isdir(path) && return resnetdir(model, path; o...)
    cls = convert(Array, softmax(vec(model(path))))
    idx = sortperm(cls, rev=true)
    [ idx cls[idx] imagenet_labels()[idx] ]
end


function resnetdir(model, dir; n=typemax(Int), b=32)
    files = []
    for (root, dirs, fs) in walkdir(dir)
        for f in fs
            push!(files, joinpath(root, f))
            length(files) > n && break
        end
        length(files) > n && break
    end
    n = min(n, length(files))
    images = Array{Any}(undef, b)
    preds = []
    for i in Knet.progress(1:b:n)
        j = min(n, i+b-1)
        @threads for k in 0:j-i
            images[1+k] = resnetprep(files[i+k])
        end
        batch = cat(images[1:j-i+1]...; dims=4)
        p = convert(Array, model(batch))
        append!(preds, vec((i->i[1]).(argmax(p; dims=1))))
    end
    [ preds imagenet_labels()[preds] files[1:n] ]
end


function resnettop1(model, path; o...)
    pred = resnetpred(model, path; o...)
    error = 0
    for i in 1:size(pred,1)
        image = match(r"ILSVRC2012_val_\d+", pred[i,3]).match
        if pred[i,1] != imagenet_val()[image]
            error += 1
        end
    end
    return error / size(pred,1)
end


function imagenet_labels()
    global _imagenet_labels
    if !@isdefined(_imagenet_labels)
        _imagenet_labels = [ replace(x, r"\S+ ([^,]+).*"=>s"\1") for x in
                             readlines(joinpath(artifact"imagenet_labels","LOC_synset_mapping.txt")) ]
    end
    _imagenet_labels
end

function imagenet_synsets()
    global _imagenet_synsets
    if !@isdefined(_imagenet_synsets)
        _imagenet_synsets = [ split(s)[1] for s in
                              readlines(joinpath(artifact"imagenet_labels", "LOC_synset_mapping.txt")) ]
    end
    _imagenet_synsets
end

function imagenet_val()
    global _imagenet_val
    if !@isdefined(_imagenet_val)
        synset2index = Dict(s=>i for (i,s) in enumerate(imagenet_synsets()))
        _imagenet_val = Dict(x=>synset2index[y] for (x,y) in (z->split(z,[',',' '])[1:2]).(
            readlines(joinpath(artifact"imagenet_labels", "LOC_val_solution.csv"))[2:end]))
    end
    _imagenet_val
end



import Base.MathConstants: e
import Random: rand!
import Distributions: cdf, Normal, MvNormal
import Statistics: mean

include("utils.jl")
include("parameter.jl")


function record_current(io, i, j, estimate, estimates)
    if io != nothing
        prop = j/((i-1)*ne+j)
        est = (1-prop)*estimates + (prop)*mean(estimates[1:j])
        println(io, string(mean(est)))
        flush(io)
    end
end


"""
    simple_mc(parameter::Parameter, sample_size::Tuple{Number, Number})

Naive Monte Carlo Sampling for computing default probability: P(L ⩾ l).
Returns the Monte Carlo estimate of default probability

    `sample_size` represents `(nZ, nE)`, number of samples for
        systematic risk factor `Z` and idiosyncratic risk factor `ϵ`
"""
function simple_mc(parameter::Parameter, sample_size::Tuple{Int64, Int64}, io::Union{IO, Nothing}=nothing)
    nz, ne = sample_size
    (N, C, S, l, cmm, ead, lgc, cn, β, H, denom, weights) = unpack(parameter)

    Z = zeros(S)
    E = zeros(N)
    Y = zeros(N)
    ind = zeros(N)
    losses = zeros(N)

    Zdist = MvNormal(S, 1)
    Edist = MvNormal(N, 1)

    estimate = 0
    estimates = zeros(Int8, ne)
    for i = 1:nz
        rand!(Zdist, Z)
        for j = 1:ne
            rand!(Edist, E)
            @. Y = $(β*Z) + denom*E
            @. ind = Y <= H[:,1]
            @. losses = weights[:,1] * ind
            estimates[j] = (sum(losses) >= l)
            (i*ne + j) % 500 == 0 &&
                record_current(io, i, j, estimate, estimates)
        end
        estimate = (1-1/i)*estimate + (1/i)*mean(estimates)
    end
    return mean(estimates)
end



"""
    bernoulli_mc(parameter::Parameter, sample_size::Tuple{Number, Number})

Monte Carlo Sampling for computing default probability: P(L ⩾ l), where
inner level sampling of `ε` is replaced with sampling of bernoulli random variables

W[n] := weights[n],    p[n]
     := 0         ,    1 - p[n]

where p[n] is a function of outer level sample `Z`

    `sample_size` represents `(nZ, nE)`, number of samples for
        systematic risk factor `Z` and idiosyncratic risk factor `ϵ`

For n=2500, (nz,ne) = (1000,1000), ~10s
"""
function bernoulli_mc(parameter::Parameter, sample_size::Tuple{Int64, Int64}, io::Union{IO, Nothing}=nothing)
    nz, ne = sample_size
    (N, C, S, l, cmm, ead, lgc, cn, β, H, denom, weights) = unpack(parameter)

    Z = zeros(S)
    phi0 = zeros(N, C+1)
    phi  = @view phi0[:,2:end]
    pnc = zeros(N, C)
    pn1 = @view pnc[:,1]
    u = zeros(N)
    W = zeros(N)
    losses = zeros(N)

    Φ = Normal()
    normcdf(x) = cdf(Φ, x)
    Zdist = MvNormal(S, 1)

    estimate = 0
    estimates = zeros(Int8, ne)
    for i = 1:nz
        rand!(Zdist, Z)
        @. phi = normcdf((H - $(β*Z)) / denom)
        diff!(pnc, phi0; dims=2)
        for j = 1:ne
            rand!(u)
            @. W = (pn1 >= u)
            @. losses = weights[:,1] * W
            estimates[j] = (sum(losses) >= l)
            (i*ne + j) % 500 == 0 &&
                record_current(io, i, j, estimate, estimates)
        end
        estimate = (1-1/i)*estimate + (1/i)*mean(estimates)
    end
    return mean(estimates)
end



" Computes Ψ = Σ_n ln( Σ_c p⋅e^{θ⋅w_n} ) "
Ψ(θ, p, w) = sum(log.(sum(@. p*e^(θ*w); dims=2)))

" Minimizatinon objective function for inner level twisting "
innerlevel_objective(θ, p, w, l) = Ψ(θ, p, w) - θ*l

function outerlevel_twisting!(μ)
	fill!(μ, 0)
end

" Computes θ = argmin_θ { -θl + Ψ(θ, Z) } "
function innerlevel_twisting(p, w, l)
	if sum(w .* p) > l
        return 1
    else
        return 0
    end
end

" Given twisting parameter θ, compute twisted bernoulli probability q from p
    q = p * e^{θ⋅w} / Σ_c p * e^{θ⋅w} "
function twisted_bernoulli!(q, θ, p, w)
    twist = @. p*e^(θ*w)
    mgf = sum(twist; dims=2)
    @. q = twist / mgf
end

"""
    glassermanli_mc(parameter::Parameter, sample_size::Tuple{Int64, Int64}, io::IO=Union{IO, Nothing}=nothing)

    Monte Carlo Sampling for computing default probability: P(L ⩾ l), with importance sampling
        of Z and weights w
       ⋅ Z ∼ N(μ, I) where μ is shifted mean that minimizes variance
       ⋅ W ∼ q       where q is shifted bernoulli probability that minimizes upper bound on the variance
"""
function glassermanli_mc(parameter::Parameter, sample_size::Tuple{Int64, Int64}, extra_params=(nothing, nothing), io::Union{IO, Nothing}=nothing)
    nz, ne = sample_size
    (N, C, S, l, cmm, ead, lgc, cn, β, H, denom, weights) = unpack(parameter)
    (μ_, θ_) = extra_params

    μ = zeros(S)
    Z = zeros(S)
    phi0 = zeros(N, C+1)
    phi  = @view phi0[:,2:end]
    pnc = zeros(N, C)
    qnc = zeros(N, C)
    qn1 = @view qnc[:,1]
    u = zeros(N)
    W = zeros(N)
    losses = zeros(N)

    Φ = Normal()
	normcdf(x) = cdf(Φ, x)

    estimate = 0
    estimates = zeros(Int8, ne)
    for i = 1:nz
        if μ_ == nothing
            outerlevel_twisting!(μ)
        else
            μ = μ_
        end
        rand!(MvNormal(μ, 1), Z)
        @. phi = normcdf((H - $(β*Z)) / denom)
        diff!(pnc, phi0; dims=2)
        for j = 1:ne
            if θ_ == nothing
                θ = innerlevel_twisting(pnc, weights, l)
            else
                θ = θ_
            end
            twisted_bernoulli!(qnc, θ, pnc, weights)
            rand!(u)
            @. W = (qn1 >= u)
            L = sum(weights[:,1] .* W)
            lr = e^(-μ'Z + 0.5μ'μ -θ*L + Ψ(θ, pnc, weights))
            estimates[j] = (L >= l)*lr
            (i*ne + j) % 500 == 0 &&
                record_current(io, i, j, estimate, estimates)
        end
        estimate = (1-1/i)*estimate + (1/i)*mean(estimates)
    end
    return estimate
end

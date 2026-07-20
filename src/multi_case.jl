# Multi-case merge: parse N PowerModels dicts into one union structure where each
# leaf field is a length-N vector (one slot per case). Components are unioned by
# source_id; presence is explicit; nested `ext` dicts are flattened.
#
# Field-set policy: import_all=false + union-with-missing (a safety net for the
# small residual per-file field variation) + flatten nested `ext` into `ext.<k>`.

"Normalize a source_id vector into a stable String key (unifies e.g. 72 and \"72\")."
_normkey(source_id)::String =
    join((x isa AbstractString ? strip(String(x)) : string(x) for x in source_id), '|')

"Storage element type: keep concrete when possible, promote numerics, else Any."
_storetype(a::Type, b::Type)::Type =
    a === b ? a : (a <: Real && b <: Real ? promote_type(a, b) : Any)

"Copy one parsed component's fields into `dest`, dropping index/source_id and flattening nested dicts."
function _flatten_component!(dest::Dict{String, Any}, comp)
    for (f, v) in comp
        (f == "index" || f == "source_id") && continue
        if v isa AbstractDict
            for (sk, sv) in v
                dest[string(f, '.', sk)] = sv
            end
        else
            dest[f] = v
        end
    end
    return dest
end

"""
One parsed case, re-keyed by `source_id` with components flattened. Component
dicts are freshly built (not aliased into the source parse).
"""
struct CaseView
    name::String
    components::Dict{String, Dict{String, Dict{String, Any}}}  # section -> key -> flattened fields
    scalars::Dict{String, Any}                                 # scalars + empty sections + Sets
end

function _case_view(name::AbstractString, raw::Dict{String, Any})
    components = Dict{String, Dict{String, Dict{String, Any}}}()
    scalars = Dict{String, Any}()
    for (sec, v) in raw
        if v isa AbstractDict && !isempty(v) && first(values(v)) isa AbstractDict
            keyed = Dict{String, Dict{String, Any}}()
            for comp in values(v)
                key = if haskey(comp, "source_id")
                    _normkey(comp["source_id"])
                else
                    @warn "component in section '$sec' has no source_id; keying by index (unstable across cases)" maxlog =
                        1
                    string("idx:", get(comp, "index", "?"))
                end
                fields = Dict{String, Any}()
                _flatten_component!(fields, comp)
                keyed[key] = fields
            end
            components[sec] = keyed
        else
            scalars[sec] = v
        end
    end
    return CaseView(String(name), components, scalars)
end

"""
Merged multi-case structure. Each section entry holds `present::BitVector` of
length N (which cases contain the component) and, per field, a
`Vector{Union{Missing,T}}` of length N aligned to `cases`.
"""
struct MultiCase
    cases::Vector{String}
    sections::Dict{String, Dict{String, Dict{String, Any}}}
    scalars::Dict{String, Vector{Any}}
end

Base.length(mc::MultiCase) = length(mc.cases)

"Merge pre-built `CaseView`s into a `MultiCase` (the core; independent of parsing)."
function merge_views(views::Vector{CaseView})
    N = length(views)
    # phase 1: discover the union of keys per section and a storage type per field
    seckeys = Dict{String, Set{String}}()
    secfieldtypes = Dict{String, Dict{String, Type}}()
    for v in views
        for (sec, keyed) in v.components
            ks = get!(() -> Set{String}(), seckeys, sec)
            ft = get!(() -> Dict{String, Type}(), secfieldtypes, sec)
            for (k, comp) in keyed
                push!(ks, k)
                for (f, val) in comp
                    T = typeof(val)
                    ft[f] = haskey(ft, f) ? _storetype(ft[f], T) : T
                end
            end
        end
    end
    # phase 2: allocate exactly-sized typed vectors (missing-filled), then fill by case index
    sections = Dict{String, Dict{String, Dict{String, Any}}}()
    for (sec, ks) in seckeys
        ft = secfieldtypes[sec]
        secout = Dict{String, Dict{String, Any}}()
        for k in ks
            entry = Dict{String, Any}("present" => falses(N))
            for (f, T) in ft
                entry[f] = Vector{Union{Missing, T}}(missing, N)
            end
            secout[k] = entry
        end
        sections[sec] = secout
    end
    for (i, v) in enumerate(views)
        for (sec, keyed) in v.components
            secout = sections[sec]
            for (k, comp) in keyed
                entry = secout[k]
                (entry["present"]::BitVector)[i] = true
                for (f, val) in comp
                    entry[f][i] = val
                end
            end
        end
    end
    # scalars: union of scalar keys -> length-N vectors (missing where a case lacks it)
    scalars = Dict{String, Vector{Any}}()
    for v in views, k in keys(v.scalars)
        haskey(scalars, k) || (scalars[k] = Vector{Any}(missing, N))
    end
    for (i, v) in enumerate(views), (k, val) in v.scalars
        scalars[k][i] = val
    end
    return MultiCase([v.name for v in views], sections, scalars)
end

"""
    merge_multi_case(paths; import_all=false, validate=true, correct_branch_rating=true)

Parse each file in `paths` (in parallel) and merge them into a [`MultiCase`](@ref),
a PowerModels-style dictionary in which every component is unioned across cases by
`source_id` and every leaf field is a length-N vector aligned to `paths`.
"""
function merge_multi_case(
    paths::Vector{<:AbstractString};
    import_all = false,
    validate = true,
    correct_branch_rating = true,
)
    N = length(paths)
    raws = Vector{Dict{String, Any}}(undef, N)
    Threads.@threads for i in 1:N
        raws[i] = parse_file(
            String(paths[i]);
            import_all = import_all,
            validate = validate,
            correct_branch_rating = correct_branch_rating,
        )
    end
    views = Vector{CaseView}(undef, N)
    for i in 1:N
        views[i] = _case_view(basename(paths[i]), raws[i])
    end
    return merge_views(views)
end

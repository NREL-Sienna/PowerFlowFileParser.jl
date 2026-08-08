# Entry point for the emit layer. Mirrors PowerTableDataParser's `build_openapi_system`
# orchestration shape: readers run in the dependency order the plan lays out
# (`.claude/plans/2026-08-05-pffp-openapi-emit-layer.md`, Phase 3) — topology, then
# load, generation/cost, branch, transformer_3w, dc_branch, shunt, attributes.
#
# This sub-task implements only the topology stage. Every later stage gets a same-named
# stub below that errors unconditionally, so a caller who reaches for one directly gets a
# named "not implemented" error rather than a silent no-op. `build_openapi_system` itself
# calls only the implemented stages — calling a stub from the normal pipeline would make
# it impossible to build a document from any real case, since every real case has loads
# and generators. The returned document is honest about the gap: real ACBus/Area/
# LoadZone/Arc components, and empty buckets for everything else.

function read_loads!(::OpenAPISystem, ::Dict; kwargs...)
    error(
        "reader not implemented: PowerLoad/StandardLoad/InterruptibleStandardLoad (load stage)",
    )
end

function read_generation!(::OpenAPISystem, ::Dict; kwargs...)
    error(
        "reader not implemented: generator and cost curve components (generation/cost stage)",
    )
end

function read_branches!(::OpenAPISystem, ::Dict; kwargs...)
    error("reader not implemented: Line/TwoWindingTransformer branches (branch stage)")
end

function read_3w_transformers!(::OpenAPISystem, ::Dict; kwargs...)
    error("reader not implemented: ThreeWindingTransformer (transformer_3w stage)")
end

function read_dc_branches!(::OpenAPISystem, ::Dict; kwargs...)
    error(
        "reader not implemented: TwoTerminalGenericHVDCLine/TwoTerminalLCCLine/TwoTerminalVSCLine (dc_branch stage)",
    )
end

function read_shunts!(::OpenAPISystem, ::Dict; kwargs...)
    error(
        "reader not implemented: FixedAdmittance/SwitchedAdmittance/FACTSControlDevice (shunt stage)",
    )
end

function read_attributes!(::OpenAPISystem, ::Dict; kwargs...)
    error(
        "reader not implemented: GeographicInfo/ImpedanceCorrectionData (attributes stage)",
    )
end

"""
pm dict section names `build_openapi_system` fully consumes today.

Every other top-level key whose value is itself a `Dict` (a pm dict "section": a keyed
collection of records, as opposed to a scalar like `baseMVA` or `source_type`) is a
component category no reader has touched yet. As sub-tasks 13b-13d land, each newly
consumed section's name joins this tuple and leaves [`_warn_unconsumed_sections`](@ref)'s
warning. Once every dict-valued pm section is accounted for here, that warning should
become an `error()`: at that point a name this tuple doesn't list is a genuinely
unrecognized pm-dict shape, not a known, tracked gap.
"""
const _CONSUMED_PM_SECTIONS = ("bus",)

"""
Warn once, naming every non-empty pm dict section [`build_openapi_system`](@ref) did not
read, so a document missing whole categories of components is never mistaken for a
complete one. Scalar/metadata keys (`baseMVA`, `name`, `source_type`, `source_version`,
`per_unit`, `has_isolated_type_buses`) are not sections; they are excluded by checking
`isa AbstractDict` rather than by listing them.
"""
function _warn_unconsumed_sections(data::Dict)
    unconsumed = Tuple{String, Int}[]
    for (key, value) in data
        if key in _CONSUMED_PM_SECTIONS || !(value isa AbstractDict) || isempty(value)
            continue
        end
        push!(unconsumed, (String(key), length(value)))
    end
    if isempty(unconsumed)
        return
    end
    sort!(unconsumed; by = first)
    named = join(("$key ($count)" for (key, count) in unconsumed), ", ")
    @warn "build_openapi_system did not read $(length(unconsumed)) non-empty pm dict section(s); their components are absent from the emitted document, not merely empty: $named"
    return
end

"""
Assemble an `OpenAPISystem` from `pm_data`.

Runs [`read_loadzones!`](@ref) then [`read_bus!`](@ref) — in that order, because a bus
resolves its load zone by id — and stops there. Every later stage in the Phase 3 plan
has a same-named stub above; none is called from here yet. Before returning, warns about
every non-empty pm dict section neither reader touched (see
[`_warn_unconsumed_sections`](@ref)), so a caller never mistakes a partial document for a
complete one.

`unit_system` selects the convention the values are stored in, same as
[`OpenAPISystem`](@ref). Keyword arguments are threaded through to every reader
unconsumed, so the 11 name-formatter kwargs the PSS/E metadata reimport path needs
(`bus_name_formatter`, `area_name_formatter`, `loadzone_name_formatter`, and the eight
more later stages will read) are already accepted here, even though only the first
three do anything today.
"""
function build_openapi_system(
    pm_data::PowerModelsData;
    unit_system::AbstractString = "NATURAL_UNITS",
    kwargs...,
)
    data = pm_data.data
    if isempty(data["bus"])
        throw(IS.DataFormatError("pm_data has no buses"))
    end
    sys = OpenAPISystem(Float64(data["baseMVA"]); unit_system = unit_system)

    read_loadzones!(sys, data; kwargs...)
    read_bus!(sys, data; kwargs...)

    _warn_unconsumed_sections(data)
    return sys
end

# Entry point for the emit layer. Mirrors PowerTableDataParser's `build_openapi_system`
# orchestration shape: readers run in the dependency order the plan lays out
# (`.claude/plans/2026-08-05-pffp-openapi-emit-layer.md`, Phase 3) — topology, then
# load, generation/cost, branch, transformer_3w, dc_branch, shunt, attributes.
#
# This sub-task adds the branch, transformer_3w, dc_branch, and shunt stages
# (`read_branches!`/`read_3w_transformers!` in branch.jl, `read_dc_branches!` in
# dc_branch.jl, `read_shunts!` in shunt.jl); topology and load/generation/cost landed in
# the prior two sub-tasks. Only the "attributes" stage (GeographicInfo,
# ImpedanceCorrectionData — both supplemental-attribute shapes, out of this sub-task's
# scope per the brief) still gets a stub below, so a caller who reaches for it directly
# gets a named "not implemented" error rather than a silent no-op.

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

`"load"` and `"distributed_generation"` are listed even though a distributed-generation
entry with no matching load is now an error rather than a component: both sections are
fully read by `read_loads!`, which is what this tuple tracks — not whether every row
becomes a component (topology.jl's `read_loadzones!` reads `"load"` too, for the same
reason).

`"switch"`/`"breaker"`/`"generic_connector"` (PSCB's `read_switch_breaker!`, a distinct
pm section from the zero-impedance-branch-to-switch conversion `read_branches!` performs)
and `"impedance_correction"` (supplemental-attribute shape) are NOT in this tuple —
neither is this sub-task's scope; they remain for a future "attributes"-stage sub-task.
"""
const _CONSUMED_PM_SECTIONS = (
    "bus", "load", "distributed_generation", "gen", "storage",
    "branch", "3w_transformer", "dcline", "vscline", "interarea_transfer",
    "shunt", "switched_shunt", "facts",
)

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

Runs [`read_loadzones!`](@ref), [`read_bus!`](@ref), [`read_loads!`](@ref),
[`read_generation!`](@ref), [`read_branches!`](@ref), [`read_3w_transformers!`](@ref),
[`read_dc_branches!`](@ref), then [`read_shunts!`](@ref) — buses before every reader that
resolves a bus by id, and buses/loadzones before branches so `add_arc!` has both
endpoints registered. Only the "attributes" stage in this file still has a same-named
stub. Before returning, warns about every non-empty pm dict section no reader touched
(see [`_warn_unconsumed_sections`](@ref)), so a caller never mistakes a partial document
for a complete one.

`unit_system` selects the convention the values are stored in, same as
[`OpenAPISystem`](@ref). Keyword arguments are threaded through to every reader
unconsumed, so the name-formatter kwargs the PSS/E metadata reimport path needs
(`bus_name_formatter`, `area_name_formatter`, `loadzone_name_formatter`,
`branch_name_formatter`, `xfrm_3w_name_formatter`, `dcline_name_formatter`,
`vsc_line_name_formatter`, `shunt_name_formatter`, `switched_shunt_name_formatter`) are
already accepted here.
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
    read_loads!(sys, data; kwargs...)
    read_generation!(sys, data; kwargs...)
    read_branches!(sys, data; kwargs...)
    read_3w_transformers!(sys, data; kwargs...)
    read_dc_branches!(sys, data; kwargs...)
    read_shunts!(sys, data; kwargs...)

    _warn_unconsumed_sections(data)
    return sys
end

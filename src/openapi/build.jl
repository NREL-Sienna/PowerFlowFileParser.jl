# Entry point for the emit layer. Mirrors PowerTableDataParser's `build_openapi_system`
# orchestration shape: readers run in the dependency order the plan lays out
# (`.claude/plans/2026-08-05-pffp-openapi-emit-layer.md`, Phase 3) — topology, then
# load, generation/cost, branch, transformer_3w, switch/breaker, dc_branch, shunt,
# attributes.
#
# This sub-task (13d, the last of the "PFFP readers" phase) adds the switch/breaker and
# attributes stages (`read_switch_breaker!` in switch_breaker.jl, `read_attributes!` in
# attributes.jl) and closes the pm-dict-section disposition ledger: every dict-valued
# section the readers see is now either consumed into a component/attribute, or named on
# `KNOWN_UNCONSUMED_PM_SECTIONS` with a reason. `_check_unconsumed_sections` below
# replaces the prior sub-tasks' `_warn_unconsumed_sections`: it now `error()`s, since a
# name it doesn't recognize is no longer a tracked, in-progress gap.

"""
pm dict section names `build_openapi_system` fully consumes into components or
supplemental attributes.

Every other top-level key whose value is itself a `Dict` (a pm dict "section": a keyed
collection of records, as opposed to a scalar like `baseMVA` or `source_type`) is either
named on [`KNOWN_UNCONSUMED_PM_SECTIONS`](@ref) or, if it is neither, an error from
[`_check_unconsumed_sections`](@ref).

`"load"` and `"distributed_generation"` are listed even though a distributed-generation
entry with no matching load is an error rather than a component: both sections are fully
read by `read_loads!`, which is what this tuple tracks — not whether every row becomes a
component (topology.jl's `read_loadzones!` reads `"load"` too, for the same reason).

`"switch"`/`"breaker"`/`"generic_connector"` (`read_switch_breaker!`, switch_breaker.jl —
a distinct pm section from the zero-impedance-branch-to-switch conversion
`read_branches!` performs), `"impedance_correction"` (`read_attributes!`, attributes.jl —
a supplemental-attribute shape), and `"area_interchange"` (topology.jl's
`_area_interchange_ext`, folded into each `Area`'s `ext` at creation, not a component of
its own) join this tuple in this sub-task.
"""
const _CONSUMED_PM_SECTIONS = (
    "bus", "load", "distributed_generation", "gen", "storage",
    "branch", "3w_transformer", "dcline", "vscline", "interarea_transfer",
    "shunt", "switched_shunt", "facts",
    "switch", "breaker", "generic_connector", "impedance_correction",
    "area_interchange",
)

"""
pm dict sections `build_openapi_system` deliberately does not read, each with the reason
it is safe to ignore rather than a tracked gap. This is the only sanctioned form of
silent skip — every entry states why the oracle (PSCB's `power_models_data.jl`) either
never produces a component from the section, or why doing so is out of this emit layer's
current reach; see the task-13d report for the full disposition ledger.
"""
const KNOWN_UNCONSUMED_PM_SECTIONS = Dict(
    "substation" =>
        "drives PSCB's own GeographicInfo bus attachment (`add_geographic_info_to_buses!`); " *
        "reproducing it (including its node-breaker `ext[\"nb_substation\"]` fallback for " *
        "split buses) needs `ext` threaded through `read_bus!` first, which this emit layer " *
        "does not yet do — a real gap, deferred to a future attributes-stage sub-task, not a " *
        "silent drop.",
    "areas" =>
        "MATPOWER's native `mpc.areas` table; PSCB's own `read_area!` for it is commented out " *
        "(\"not all matpower files define areas even when bus definitions contain area " *
        "references\") — the oracle itself never consumes this section.",
    "owner" =>
        "PSS/E OWNER records (generator/branch ownership shares); PSCB's oracle never reads " *
        "this section and no PSY/schema field represents ownership.",
    "zone" =>
        "PSS/E ZONE name records; PSCB's oracle only cross-checks it for an empty-zone " *
        "warning (`read_loadzones!`) — LoadZone identity and peaks come from each bus's own " *
        "`zone` number, never from this section's `zone_name`.",
)

"""
Error, naming every non-empty pm dict section [`build_openapi_system`](@ref) neither
reads nor has allow-listed, so a document missing whole categories of components is never
mistaken for a complete one. Scalar/metadata keys (`baseMVA`, `name`, `source_type`,
`source_version`, `per_unit`, `has_isolated_type_buses`) are not sections; they are
excluded by checking `isa AbstractDict` rather than by listing them.
"""
function _check_unconsumed_sections(data::Dict)
    unconsumed = Tuple{String, Int}[]
    for (key, value) in data
        if key in _CONSUMED_PM_SECTIONS || haskey(KNOWN_UNCONSUMED_PM_SECTIONS, key) ||
           !(value isa AbstractDict) || isempty(value)
            continue
        end
        push!(unconsumed, (String(key), length(value)))
    end
    if isempty(unconsumed)
        return
    end
    sort!(unconsumed; by = first)
    named = join(("$key ($count)" for (key, count) in unconsumed), ", ")
    throw(
        IS.DataFormatError(
            "build_openapi_system cannot read $(length(unconsumed)) non-empty pm dict " *
            "section(s), and none is on KNOWN_UNCONSUMED_PM_SECTIONS: $named",
        ),
    )
end

"""
Assemble an `OpenAPISystem` from `pm_data`.

Runs [`read_loadzones!`](@ref), [`read_bus!`](@ref), [`read_loads!`](@ref),
[`read_generation!`](@ref), [`read_branches!`](@ref), [`read_3w_transformers!`](@ref),
[`read_switch_breaker!`](@ref), [`read_dc_branches!`](@ref), [`read_shunts!`](@ref), then
[`read_attributes!`](@ref) — buses before every reader that resolves a bus by id,
buses/loadzones before branches so `add_arc!` has both endpoints registered, and
`read_attributes!` last since it looks up already-registered `TwoWindingTransformer`/
`ThreeWindingTransformer` ids by name. Before returning, errors on every non-empty pm
dict section no reader touched and no entry on `KNOWN_UNCONSUMED_PM_SECTIONS` excuses
(see [`_check_unconsumed_sections`](@ref)), so a caller never mistakes a partial document
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
    read_switch_breaker!(sys, data; kwargs...)
    read_dc_branches!(sys, data; kwargs...)
    read_shunts!(sys, data; kwargs...)
    read_attributes!(sys, data; kwargs...)

    _check_unconsumed_sections(data)
    return sys
end

"""
pm dict section names `build_openapi_system` fully consumes.

This tracks whether a section is *read*, not whether every row becomes a component:
`"load"`/`"distributed_generation"` are listed even though an unmatched
distributed-generation entry is an error, and `"area_interchange"` is folded into each
`Area`'s `ext` rather than emitted as its own component.
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
it is safe to ignore rather than a tracked gap. The only sanctioned form of silent skip.
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
mistaken for a complete one. Scalar keys (`baseMVA`, `source_type`, ...) are excluded by
the `AbstractDict` test rather than by an explicit list.
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

Reader order is a dependency order: load zones before buses, buses before every reader
that resolves a bus by id, and [`read_attributes!`](@ref) last since it looks up
already-registered transformer ids by name. Before returning, errors on every non-empty
pm dict section no reader touched and `KNOWN_UNCONSUMED_PM_SECTIONS` does not excuse, so
a caller never mistakes a partial document for a complete one.

`unit_system` selects the convention the values are stored in, same as
[`OpenAPISystem`](@ref). Keyword arguments — the `*_name_formatter`s the PSS/E metadata
reimport path needs — are threaded through to every reader unconsumed.
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

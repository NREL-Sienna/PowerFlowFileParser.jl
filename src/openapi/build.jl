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
Assemble an `OpenAPISystem` from `pm_data`.

Runs [`read_loadzones!`](@ref) then [`read_bus!`](@ref) — in that order, because a bus
resolves its load zone by id — and stops there. Every later stage in the Phase 3 plan
has a same-named stub above; none is called from here yet.

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

    return sys
end

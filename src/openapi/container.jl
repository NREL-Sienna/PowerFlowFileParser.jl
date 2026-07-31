"""
The document PowerFlowFileParser emits: components grouped by type, the association
tables, and the time series destined for the HDF5 sidecar.

`components` values are concrete `Vector{T}`, so per-type iteration stays
inferable behind a function barrier even though the field is untyped.

`registry` is build-time scaffolding and is not serialized: every id it holds is
recoverable from the emitted components.

`unit_system` records which convention the stored values follow. It is set once at
construction and emitted verbatim into the document; no code reads it back, so it is a
declaration a builder is trusted to honor rather than an enforced invariant.
"""
struct OpenAPISystem
    base_power::Float64
    unit_system::String
    components::Dict{String, Vector}
    supplemental_attributes::Vector{OpenAPI.APIModel}
    supplemental_attribute_associations::Vector{PC.SupplementalAttributeAssociation}
    time_series_associations::Vector{PC.TimeSeriesAssociation}
    time_series::Vector{IS.TimeSeriesData}
    registry::IdRegistry
end

"""
Unit conventions a document may declare, a subset of the schemas' `UnitSystem`.

`SYSTEM_BASE` is absent on purpose: the input descriptors target device base for
injectors and system base only where they say so, so there is no single
system-base reading of a parsed table.

`NATURAL_UNITS` and `DEVICE_BASE` currently emit identical numbers. Every property
whose basis is device-relative already declares `pu` as its `x-unit` — those are
exactly the five `x-unit-base` properties — and no property declaring a natural
unit carries a base to divide by. Annotating power properties with `x-unit-base` would
not by itself make the two diverge: no code here converts on `unit_system` — `set_value!`
converts from the caller's unit into the declared one and has no notion of the mode — and
its base path only completes when a property and its base share a quantity, which an `MW`
property on an `MVA` `base_power` does not. Divergence needs both a schema change and
emit-time work here; see `.claude/plans/2026-07-31-schema-proposal-device-base.md`.
"""
const UNIT_SYSTEMS = ("NATURAL_UNITS", "DEVICE_BASE")

function OpenAPISystem(
    base_power::Float64;
    unit_system::AbstractString = "NATURAL_UNITS",
)
    if !(unit_system in UNIT_SYSTEMS)
        throw(
            IS.DataFormatError(
                "unit_system must be one of $(join(UNIT_SYSTEMS, ", ")); got $unit_system",
            ),
        )
    end
    return OpenAPISystem(
        base_power,
        String(unit_system),
        Dict{String, Vector}(),
        Vector{OpenAPI.APIModel}(),
        Vector{PC.SupplementalAttributeAssociation}(),
        Vector{PC.TimeSeriesAssociation}(),
        Vector{IS.TimeSeriesData}(),
        IdRegistry(),
    )
end

get_base_power(sys::OpenAPISystem) = sys.base_power
get_registry(sys::OpenAPISystem) = sys.registry

get_unit_system(sys::OpenAPISystem) = sys.unit_system

"""
Whether the document declares the per-unit convention rather than natural units.

Read by builders to decide which convention to write in. It does not currently
change any emitted number — see the note on [`UNIT_SYSTEMS`](@ref).
"""
uses_per_unit(sys::OpenAPISystem) = sys.unit_system == "DEVICE_BASE"

function add_component!(sys::OpenAPISystem, component::T) where {T <: OpenAPI.APIModel}
    bucket = get!(sys.components, string(nameof(T))) do
        return Vector{T}()
    end
    push!(bucket, component)
    return
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return get(sys.components, String(type_name), Vector{OpenAPI.APIModel}())
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = sort!(collect(keys(sys.components)))

"""
Link a supplemental attribute to the entity it describes.

Both ids are resolved through the entity registry rather than duplicated here,
matching GridDB's `supplemental_attributes_association` table.
"""
function add_supplemental_attribute_association!(
    sys::OpenAPISystem,
    attribute_id::Int,
    entity_id::Int,
)
    association = PC.SupplementalAttributeAssociation()
    set_value!(association, :attribute_id, attribute_id)
    set_value!(association, :entity_id, entity_id)
    push!(sys.supplemental_attribute_associations, association)
    return association
end

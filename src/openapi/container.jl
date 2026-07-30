"""
Links a supplemental attribute to the entity it describes.

SiennaSchemas has no schema for this record, so it is hand-written here using
GridDB's `supplemental_attributes_association` column names.
"""
struct SupplementalAttributeAssociation
    attribute_id::Int
    entity_id::Int
end

"""
The document PTDP emits: components grouped by type, the association tables, and
the time series destined for the HDF5 sidecar.

`components` values are concrete `Vector{T}`, so per-type iteration stays
inferable behind a function barrier even though the field is untyped.

`registry` is build-time scaffolding and is not serialized: every id it holds is
recoverable from the emitted components.
"""
struct OpenAPISystem
    base_power::Float64
    components::Dict{String, Vector}
    supplemental_attributes::Vector{OpenAPI.APIModel}
    supplemental_attribute_associations::Vector{SupplementalAttributeAssociation}
    time_series_associations::Vector{PC.TimeSeriesAssociation}
    time_series::Vector{IS.TimeSeriesData}
    registry::IdRegistry
end

function OpenAPISystem(base_power::Float64)
    return OpenAPISystem(
        base_power,
        Dict{String, Vector}(),
        Vector{OpenAPI.APIModel}(),
        Vector{SupplementalAttributeAssociation}(),
        Vector{PC.TimeSeriesAssociation}(),
        Vector{IS.TimeSeriesData}(),
        IdRegistry(),
    )
end

get_base_power(sys::OpenAPISystem) = sys.base_power
get_registry(sys::OpenAPISystem) = sys.registry

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

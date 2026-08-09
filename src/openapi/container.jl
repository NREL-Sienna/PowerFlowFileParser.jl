"""
The document PowerFlowFileParser emits, a thin wrapper over `PC.SystemDocument`.

`document` is the only serialized artifact: components, the association tables, `ext`
and the unit convention all live on it. `registry` is build-time scaffolding, holding
only the lookup indices (by name, bus number, arc) the document has no use for once
built.

`time_series` mirrors PowerTableDataParser's field shape for a consistent
`OpenAPISystem` API across parsers, but stays permanently empty here — PSS/E and
Matpower carry no time series.
"""
struct OpenAPISystem
    document::PC.SystemDocument
    registry::IdRegistry
    time_series::Vector{IS.TimeSeriesData}
end

"""
Unit conventions a document may be written in, from the schemas' `UnitSystem`.

The schemas offer no system-base option: per-unit data historically on the system
base records that base in the component's own `base_power` and rides as
`DEVICE_BASE`.
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
    document = PC.SystemDocument(base_power; unit_system = unit_system)
    return OpenAPISystem(document, IdRegistry(document), Vector{IS.TimeSeriesData}())
end

get_document(sys::OpenAPISystem) = sys.document

"""
Record the table columns the data model has no field for, against a component.

Kept beside the components rather than inside them: the schemas describe what a
component is, and this is whatever else the source data happened to state.
"""
function set_ext!(sys::OpenAPISystem, component_id::Int, extras::Dict{String, Any})
    PC.set_ext!(get_document(sys), component_id, extras)
    return
end

"""
Record `extras` against `component`, skipping the `ext` entry entirely when there is
nothing to record. The shape every reader uses for a pm dict entry's own `"ext"` blob.
"""
function set_component_ext!(sys::OpenAPISystem, component, extras::Dict{String, Any})
    if !isempty(extras)
        set_ext!(sys, get_value(component, :id), extras)
    end
    return
end

get_ext(sys::OpenAPISystem, component_id::Int) = PC.get_ext(get_document(sys), component_id)

get_base_power(sys::OpenAPISystem) = PC.get_base_power(get_document(sys))
get_registry(sys::OpenAPISystem) = sys.registry

get_unit_system(sys::OpenAPISystem) = PC.get_unit_system(get_document(sys))

"""
Whether values are stored per unit rather than in the schemas' natural units.

`DEVICE_BASE` reproduces PowerSystems' storage convention. The `x-unit` annotations
still name the natural unit either way, so a per-unit document is for comparison
against PowerSystems rather than for a consumer that reads the annotations — which is
why the document states the convention it was written in.
"""
uses_per_unit(sys::OpenAPISystem) = PC.uses_per_unit(get_document(sys))

function add_component!(sys::OpenAPISystem, component::T) where {T <: OpenAPI.APIModel}
    PC.add_component!(get_document(sys), component)
    return
end

"""
Record a supplemental attribute and the entity it describes.

`group_index`/`role` are left at their `nothing` default: they exist for plant-family
groupings and service memberships, neither of which this parser emits.
"""
function add_supplemental_attribute!(
    sys::OpenAPISystem,
    attribute::OpenAPI.APIModel,
    entity_id::Int,
)
    PC.add_supplemental_attribute!(get_document(sys), attribute, entity_id)
    return
end

"""
Record that `entity_id` contributes to the service `service_id`.

A membership is a row in the same unified `supplemental_attribute_associations` table as
every other attribute link: `service_id` rides as `attribute_id`, so a reader tells
a membership from a plain attribute by looking that id up as a component. There is no
model object to hand `PC.add_supplemental_attribute!` — the "attribute" is a component
that already exists — so the row is appended directly, which `PC.validate_document`
accounts for.

Duplicate pairs are rejected rather than collapsed: eligibility rules overlap, so the
same device matching one reserve twice means a malformed rule set.
"""
function add_service_association!(
    sys::OpenAPISystem,
    service_id::Int,
    entity_id::Int,
    attribute_type::AbstractString,
)
    associations = get_document(sys).supplemental_attribute_associations
    for existing in associations
        if get_value(existing, :attribute_id) == service_id &&
           get_value(existing, :entity_id) == entity_id
            throw(
                IS.DataFormatError(
                    "duplicate service membership: service_id=$service_id entity_id=$entity_id",
                ),
            )
        end
    end
    push!(
        associations,
        PC.SupplementalAttributeAssociation(;
            attribute_id = service_id,
            entity_id = entity_id,
            attribute_type = String(attribute_type),
        ),
    )
    return
end

"""Attributes of one type, in the order they were added."""
function get_supplemental_attributes(sys::OpenAPISystem, type_name::AbstractString)
    return PC.get_supplemental_attributes(get_document(sys), type_name)
end

function get_components(sys::OpenAPISystem, type_name::AbstractString)
    return PC.get_components(get_document(sys), type_name)
end

"""Type names in sorted order, so serialized output is deterministic."""
component_type_names(sys::OpenAPISystem) = PC.component_type_names(get_document(sys))

"""
The JSON document an `OpenAPISystem` serializes to.

`SortedDict` everywhere so key order — and therefore the output bytes — is deterministic.
"""
function openapi_document(sys::OpenAPISystem)
    components = SortedDict{String, Any}()
    for type_name in component_type_names(sys)
        components[type_name] = _lower_all(get_components(sys, type_name))
    end
    document = SortedDict{String, Any}()
    document["base_power"] = get_base_power(sys)
    # NATURAL_UNITS is not one unit: each field keeps whatever unit the power
    # flow source data model gives it, a mixture the x-unit annotations name
    # per field regardless of unit_system.
    document["unit_system"] = get_unit_system(sys)
    document["components"] = components
    document["supplemental_attributes"] = _lower_all(sys.supplemental_attributes)
    document["supplemental_attribute_associations"] =
        _lower_all(sys.supplemental_attribute_associations)
    document["time_series_associations"] = _lower_all(sys.time_series_associations)
    # PSS/E carries no time series, so this package writes no HDF5 sidecar;
    # unlike PTDP, there is no `time_series_storage_file` to name.
    document["time_series"] = Any[]
    return document
end

"""
Lower a concretely-typed bucket behind a function barrier.

`OpenAPISystem.components` is untyped, so its buckets arrive as `Vector` at the call site;
dispatching on the element type here keeps the loop inferable.
"""
function _lower_all(bucket::Vector{T}) where {T <: OpenAPI.APIModel}
    return [JSON.lower(component) for component in bucket]
end

"""
Write `sys` to `filename` as the OpenAPI JSON document. Returns `filename`.

Properties left unset are absent from the output rather than null: `JSON.lower` on a
generated model returns an `OpenAPI.JSONWrapper`, which skips `nothing` properties.

`unit_system` on `sys` is written into the document as the convention its numbers
follow. `NATURAL_UNITS`, the default, preserves the power flow source data's
native mixture — MW, per-unit, degrees, and more depending on the field; see
`.claude/plans/2026-07-30-report-pm-dict-unit-inventory.md` for the
field-by-field record. `DEVICE_BASE` currently produces the same numbers; see the
note on `UNIT_SYSTEMS` in `container.jl`.

`force = false` refuses to overwrite an existing `filename`. `pretty = true`
indents the output; the default is compact.
"""
function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force = false,
    pretty = false,
)
    if !force && isfile(filename)
        error("$filename already exists. Set force = true to overwrite.")
    end
    open(filename, "w") do io
        if pretty
            JSON.print(io, openapi_document(sys), 2)
        else
            JSON.print(io, openapi_document(sys))
        end
    end
    return filename
end

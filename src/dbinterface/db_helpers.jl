# =============================================================================
# Per-row / per-attribute DB write helpers.
#
# Duplicated from `SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl` — only
# the writer helpers that operate on `OpenAPI.APIModel` structs are kept.
# The PSY-typed `get_row(::PSY.Component)` variants, the sys2db!/db2sys!
# orchestrators, and the HydroReservoir _ignoreattribute specialization
# are dropped (PFFP never emits PSY components or HydroReservoirs).
# =============================================================================

import DBInterface
import JSON
using Tables
import OpenAPI

"""
Fetch column `col_name` from the OpenAPI struct `c`, honoring the
(table, db_column) → openapi_field renames in `DB_TO_OPENAPI_FIELDS` and
JSON-serializing any column listed in `JSON_COLUMNS` (except the
`thermal_generators.fuel` FK, which is a plain string).
Returns `nothing` for missing properties.
"""
function get_row_field(c::OpenAPI.APIModel, table_name::AbstractString, col_name::Symbol)
    col_str = string(col_name)
    k = Symbol(get(DB_TO_OPENAPI_FIELDS, (table_name, col_str), col_name))

    if !hasproperty(c, k)
        return nothing
    end

    val = getproperty(c, k)

    # Serialize JSON columns (skip fuel for thermal_generators — plain FK, not JSON).
    if col_str in JSON_COLUMNS && val !== nothing
        if col_str == "fuel" && table_name == "thermal_generators"
            return val
        end
        return JSON.json(val)
    end

    return val
end

"""
Return `true` if OpenAPI field `k` for type `T` (table `table_name`)
already maps to a typed column in `schema` — meaning it should be
skipped when walking the JSON representation to populate the generic
`attributes` table.
"""
function _ignoreattribute(
    ::Type{T},
    table_name::AbstractString,
    schema::Tables.Schema,
    k::AbstractString,
) where {T <: OpenAPI.APIModel}
    col_name = get(OPENAPI_FIELDS_TO_DB, (table_name, k), k)
    return in(Symbol(col_name), schema.names)
end

"""
Write every OpenAPI field of `c` that doesn't already live in a typed
column of `table_name` into the generic `attributes` table
(`entity_id`, `type='FromSienna'`, `name`, `value` as JSON).
"""
function insert_attributes!(
    ::Type{T},
    table_name::AbstractString,
    schema::Tables.Schema,
    attribute_statement,
    c::OpenAPI.APIModel,
) where {T <: OpenAPI.APIModel}
    for (k, v) in JSON.parse(OpenAPI.to_json(c))
        if !_ignoreattribute(T, table_name, schema, k)
            DBInterface.execute(attribute_statement, (c.id, "FromSienna", k, JSON.json(v)))
        end
    end
end

"""
Record the round-trip UUID for a row by writing an `attributes` row with
`name='uuid'` and a JSON-serialized UUID string.
"""
function insert_uuid!(attribute_statement, table_name, id, uuid)
    DBInterface.execute(
        attribute_statement,
        (id, table_name, "uuid", JSON.json(string(uuid))),
    )
end

function prepare_schema_insert(db, table_name::AbstractString, schema::Tables.Schema)
    return DBInterface.prepare(
        db,
        """INSERT INTO $table_name ($(join(schema.names, ", ")))
          VALUES ($(join(repeat("?", length(schema.names)), ", ")))""",
    )
end

function prepare_entity_insert(db, table_name::AbstractString, obj_type::AbstractString)
    return DBInterface.prepare(
        db,
        "INSERT INTO entities (id, entity_table, entity_type) VALUES (?, '$table_name', '$obj_type')",
    )
end

function prepare_attributes_insert(db)
    return DBInterface.prepare(
        db,
        "INSERT INTO attributes (entity_id, type, name, value) VALUES (?, ?, ?, json(?))",
    )
end

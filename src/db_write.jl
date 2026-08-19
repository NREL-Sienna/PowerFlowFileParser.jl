# =============================================================================
# Parser-agnostic DB-write layer.
# Materializes OpenAPI structs from our dicts and inserts them into an
# SQLite database whose schema is created by `make_sqlite!` (see
# `dbinterface/db_schema.jl`).
#
# Most of the heavy lifting is delegated to helpers duplicated from
# `SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl` (`get_row_field`,
# `insert_attributes!`, `insert_uuid!`, `prepare_*_insert`, `TABLE_SCHEMAS`)
# — they operate purely on `OpenAPI.APIModel` structs, so they work
# equally well against `PowerOperationsOpenAPIModels` structs. We only
# contribute a thin loop that supplies OpenAPI structs in place of the
# PSY components SOM's `sys2db!` flow expects. The type → table map is
# kept local (`_POAM_TYPE_TO_TABLE`) so the DB writers key off POM
# structs rather than a PSY-keyed dict.
#
# Where PSY writes `IS.get_uuid(component)` to record the round-trip UUID,
# we synthesize via `UUIDs.uuid4()` — the dict pipeline has no PSY UUID to
# preserve. This forfeits round-trip-to-PSY ability in the DB but is a
# one-way parser → DB workflow concern documented in HANDOFF.md (open
# question #11).
# =============================================================================

import SQLite
import DBInterface
import JSON
import UUIDs
using Tables
import OpenAPI
import PowerOperationsOpenAPIModels

# Local POM-keyed type→table map. Mirrors the SOM-keyed `TYPE_TO_TABLE` at
# `SiennaOpenAPIModels.jl/src/dbinterface/translation_constants.jl:19-57`
# but keyed by `PowerOperationsOpenAPIModels` structs so the DB writers
# don't depend on SOM's PSY-keyed dict. Only the entries used by our
# `_MAKE_DATABASE_TYPE_ORDER` walk are included.
const _POAM_TYPE_TO_TABLE = Dict{DataType, String}(
    PowerOperationsOpenAPIModels.Area => "planning_regions",
    PowerOperationsOpenAPIModels.LoadZone => "balancing_topologies",
    PowerOperationsOpenAPIModels.ACBus => "balancing_topologies",
    PowerOperationsOpenAPIModels.AreaInterchange => "transmission_interchanges",
    PowerOperationsOpenAPIModels.Line => "transmission_lines",
    PowerOperationsOpenAPIModels.TransformerCircuit => "transformer_circuits",
    PowerOperationsOpenAPIModels.TwoWindingTransformer => "two_winding_transformers",
    PowerOperationsOpenAPIModels.TwoTerminalGenericHVDCLine => "transmission_lines",
    PowerOperationsOpenAPIModels.ThreeWindingTransformer => "three_winding_transformers",
    PowerOperationsOpenAPIModels.PowerLoad => "loads",
    PowerOperationsOpenAPIModels.StandardLoad => "loads",
    PowerOperationsOpenAPIModels.FixedAdmittance => "loads",
    PowerOperationsOpenAPIModels.ThermalStandard => "thermal_generators",
    PowerOperationsOpenAPIModels.RenewableDispatch => "renewable_generators",
    PowerOperationsOpenAPIModels.RenewableNonDispatch => "renewable_generators",
    PowerOperationsOpenAPIModels.HydroDispatch => "hydro_generators",
    PowerOperationsOpenAPIModels.EnergyReservoirStorage => "storage_units",
    # Subtypes that ride along on the parent's table. Concrete OpenAPI type
    # fields land in typed columns where names match; everything else falls
    # through to the generic `attributes` table via `insert_attributes!`.
    # `entities.entity_type` records the concrete OpenAPI type name, so
    # readback via `db2openapi_json` can reconstruct the right struct.
    PowerOperationsOpenAPIModels.DiscreteControlledACBranch => "transmission_lines",
    PowerOperationsOpenAPIModels.TwoTerminalLCCLine => "transmission_lines",
    PowerOperationsOpenAPIModels.TwoTerminalVSCLine => "transmission_lines",
    PowerOperationsOpenAPIModels.FACTSControlDevice => "loads",
    PowerOperationsOpenAPIModels.SwitchedAdmittance => "loads",
    PowerOperationsOpenAPIModels.SynchronousCondenser => "loads",
    PowerOperationsOpenAPIModels.InterruptibleStandardLoad => "loads",
)

"""
Per-type generic DB writer. Materializes a row from each OpenAPI struct
via `get_row_field` (pure OpenAPI struct access — no PSY needed) and runs
the entity / table / attribute / uuid inserts in the same order PSY's
`add_components_to_tables!` does.

Mirrors `add_components_to_tables!` at
`SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl:106-133`, with the
PSY-specific lines (`IS.get_uuid(component)` and
`sienna2openapi(component, ids)`) removed: components are already OpenAPI
structs, and the UUID is synthesized.
"""
function _add_openapi_components_to_tables!(
    ::Type{T},
    table_name::AbstractString,
    schema::Tables.Schema,
    table_statement::DBInterface.Statement,
    entity_statement::DBInterface.Statement,
    attribute_statement::DBInterface.Statement,
    components,
) where {T <: OpenAPI.APIModel}
    for c in components
        row = tuple(
            (get_row_field(c, table_name, col_name) for col_name in schema.names)...,
        )
        try
            DBInterface.execute(entity_statement, (c.id,))
            DBInterface.execute(table_statement, row)
        catch e
            if isa(e, SQLite.SQLiteException)
                error("Failed to insert into $(table_name): $(e.msg) with values $(row)")
            else
                rethrow(e)
            end
        end
        insert_attributes!(T, table_name, schema, attribute_statement, c)
        insert_uuid!(attribute_statement, table_name, c.id, UUIDs.uuid4())
    end
end

"""
Write every component of OpenAPI type `T` to its corresponding DB table.
Resolves the table name via `_POAM_TYPE_TO_TABLE[T]` and the schema via
`TABLE_SCHEMAS[table_name]`, then dispatches to
[`_add_openapi_components_to_tables!`].

Mirrors `send_table_to_db!` at
`SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl:240-254`.
"""
function send_openapi_table_to_db!(
    ::Type{T},
    db,
    components,
) where {T <: OpenAPI.APIModel}
    table_name = _POAM_TYPE_TO_TABLE[T]
    obj_type = string(nameof(T))
    schema = TABLE_SCHEMAS[table_name]
    _add_openapi_components_to_tables!(
        T,
        table_name,
        schema,
        prepare_schema_insert(db, table_name, schema),
        prepare_entity_insert(db, table_name, obj_type),
        prepare_attributes_insert(db),
        components,
    )
end

"""
Specialization for `AreaInterchange` — the DB row references an arc id
that's synthesized at write time (PSY's AreaInterchange holds
from_area/to_area Area refs, and a fresh arc per interchange is created
inline). Mirrors the same logic in
`SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl:157-179`, with `IS.get_uuid`
removed.
"""
function send_openapi_table_to_db!(
    ::Type{PowerOperationsOpenAPIModels.AreaInterchange},
    db,
    components,
)
    table_name = "transmission_interchanges"
    obj_type = "AreaInterchange"
    schema = TABLE_SCHEMAS[table_name]
    table_statement = prepare_schema_insert(db, table_name, schema)
    arc_statement = prepare_schema_insert(db, "arcs", TABLE_SCHEMAS["arcs"])
    arc_entity_statement = prepare_entity_insert(db, "arcs", "Arc")
    attribute_statement = prepare_attributes_insert(db)
    entity_statement = prepare_entity_insert(db, table_name, obj_type)

    for c in components
        # PSY's `getid!(ids, UUIDs.uuid4())` minted a fresh int id from a
        # random UUID. Here we just take the int id directly from a fresh
        # uuid4 hash; the only constraint is uniqueness within the DB.
        new_arc_id = Int(rand(Int32))
        DBInterface.execute(arc_entity_statement, (new_arc_id,))
        DBInterface.execute(arc_statement, (new_arc_id, c.from_area, c.to_area))
        row = (c.id, c.name, new_arc_id, c.flow_limits.to_from, c.flow_limits.from_to)
        DBInterface.execute(entity_statement, (c.id,))
        DBInterface.execute(table_statement, row)
        insert_attributes!(
            PowerOperationsOpenAPIModels.AreaInterchange,
            table_name,
            schema,
            attribute_statement,
            c,
        )
        insert_uuid!(attribute_statement, table_name, c.id, UUIDs.uuid4())
    end
end

"""
Write every Arc struct in `arcs` to the `arcs` table. Each Arc carries
`id`/`from`/`to` fields populated upstream by `_get_or_mint_arc_id!`. Each
Arc gets an `entities` row tagged `(entity_table='arcs', entity_type='Arc')`.

Accepts any iterable of `PowerOperationsOpenAPIModels.Arc` structs.

Run this **before** any branch-like type that references arc ids
(`Line`, `TwoWindingTransformer`, `TapTransformer`, `PhaseShiftingTransformer`,
`DiscreteControlledACBranch`, `TwoTerminalLCCLine`,
`TwoTerminalGenericHVDCLine`, `TwoTerminalVSCLine`, etc.) so the FK
references the existing arc row.
"""
function write_arcs_to_db!(db, arcs)
    schema = TABLE_SCHEMAS["arcs"]
    arc_statement = prepare_schema_insert(db, "arcs", schema)
    entity_statement = prepare_entity_insert(db, "arcs", "Arc")
    for arc in arcs
        DBInterface.execute(entity_statement, (arc.id,))
        DBInterface.execute(arc_statement, (arc.id, arc.from_id, arc.to_id))
    end
end

"""
Write a homogeneous collection of supplemental-attribute structs to the
`supplemental_attributes` table. Mirrors
`SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl:256-287` (`serialize_supplemental_attributes!`),
with PSY-iteration replaced by direct iteration over our typed Vector.

Currently used for `ImpedanceCorrectionData` (PSS/E only). Generalizes
trivially to other supplemental-attribute types by passing a different
`T` and a different `Vector{T}` collection.
"""
function write_supplemental_attributes_to_db!(
    ::Type{T},
    db,
    sa_objects,
) where {T <: OpenAPI.APIModel}
    type_name = string(nameof(T))
    entity_stmt = DBInterface.prepare(
        db,
        "INSERT INTO entities (id, entity_table, entity_type) VALUES (?, 'supplemental_attributes', ?)",
    )
    sa_stmt = DBInterface.prepare(
        db,
        "INSERT INTO supplemental_attributes (id, TYPE, value) VALUES (?, ?, json(?))",
    )
    attr_stmt = prepare_attributes_insert(db)

    for sa in sa_objects
        DBInterface.execute(entity_stmt, (sa.id, type_name))
        DBInterface.execute(sa_stmt, (sa.id, type_name, JSON.json(sa)))
        insert_uuid!(attr_stmt, "supplemental_attributes", sa.id, UUIDs.uuid4())
    end
end

"""
Write the `supplemental_attribute_associations` table from the accumulator
of `{"attribute_id", "entity_id"}` dicts collected during the parse.
Mirrors `serialize_supplemental_attribute_associations!` at
`SiennaOpenAPIModels.jl/src/dbinterface/sqlite.jl:289-310`.

Run this **after** both the referenced supplemental attribute rows and the
referenced component rows are in the DB (so the FK references exist).
"""
function write_supplemental_attribute_associations_to_db!(
    db,
    associations::Vector{Dict{String, Any}},
)
    stmt = DBInterface.prepare(
        db,
        "INSERT INTO supplemental_attributes_association (attribute_id, entity_id) VALUES (?, ?)",
    )
    for assoc in associations
        DBInterface.execute(stmt, (assoc["attribute_id"], assoc["entity_id"]))
    end
end

"""
Copy an open SQLite database to a self-contained file at `path` using
SQLite's `VACUUM INTO` command. Works for both in-memory and file-backed
source databases; the resulting file is a complete, ready-to-share SQLite
database (no WAL or journal companions needed).

Useful as the second half of the "build in-memory, persist later" workflow:

```julia
db = make_database(pm_data)               # in-memory, default
# …inspect, query, mutate in-process…
save_database(db, "case_30bus.db")        # writes a portable file
```

# Arguments

- `db`: an open `SQLite.DB` connection (in-memory or file-backed).
- `path::AbstractString`: destination file path.

# Keyword Arguments

- `overwrite::Bool = false`: if `true`, remove an existing file at `path`
  before writing. SQLite's `VACUUM INTO` itself refuses to overwrite, so
  without this we'd surface the raw "output file already exists" error.

# Returns

The destination `path` (for chaining).

# Throws

`ArgumentError` if `path` already exists and `overwrite=false`.
Whatever `SQLite.SQLiteException` `VACUUM INTO` raises on permission,
disk-full, or invalid-path errors.
"""
function save_database(db::SQLite.DB, path::AbstractString; overwrite::Bool = false)
    if isfile(path)
        overwrite || throw(
            ArgumentError(
                "File $path already exists; pass `overwrite=true` to replace it.",
            ),
        )
        rm(path)
    end
    # SQL string literal: escape single quotes by doubling them, per SQL92.
    # The path is part of the VACUUM INTO statement itself, not a bind
    # parameter, so we can't use DBInterface parameter binding here.
    escaped = replace(String(path), "'" => "''")
    DBInterface.execute(db, "VACUUM INTO '$escaped'")
    return path
end

"""
Container for data parsed by PowerModels.
"""
struct PowerModelsData
    data::Dict{String, Any}
end

"""
Constructs PowerModelsData from a raw file.
Currently Supports MATPOWER and PSSE data files parsed by PowerModels.
"""
function PowerModelsData(file::Union{String, IO}; kwargs...)
    validate = get(kwargs, :pm_data_corrections, true)
    import_all = get(kwargs, :import_all, false)
    correct_branch_rating = get(kwargs, :correct_branch_rating, true)
    pm_dict = parse_file(
        file;
        import_all = import_all,
        validate = validate,
        correct_branch_rating = correct_branch_rating,
    )
    pm_data = PowerModelsData(pm_dict)
    correct_pm_transformer_status!(pm_data)
    return pm_data
end

"""
Container holding every output collection produced by a single
[`parse_to_openapi_dicts`] run.

# Fields — homogeneous reader outputs

- `bus_dicts::Dict{Int, Dict{String, Any}}` — keyed by bus number
- `area_dicts::Dict{Int, Dict{String, Any}}` — keyed by area number
- `area_interchange_dicts::Dict{String, Dict{String, Any}}` — keyed by name
- `loadzone_dicts::Dict{Int, Dict{String, Any}}` — keyed by zone number
- `switched_shunt_dicts::Dict{String, Dict{String, Any}}` — keyed by name
- `shunt_dicts::Dict{String, Dict{String, Any}}` — keyed by name
- `storage_dicts::Dict{String, Dict{String, Any}}` — keyed by name
- `switch_dicts::Dict{String, Dict{String, Any}}` — from `data["switch"]`
- `breaker_dicts::Dict{String, Dict{String, Any}}` — from `data["breaker"]`
- `vscline_dicts::Dict{String, Dict{String, Any}}` — keyed by name
- `facts_dicts::Dict{String, Dict{String, Any}}` — keyed by `"<bus>_<name>"`
- `ict_instances::Dict{Tuple{Int, String}, Dict{String, Any}}` — keyed by
  `(table_number, transformer_winding)`

# Fields — heterogeneous reader outputs (NamedTuples per OpenAPI type)

- `loads`     — `(; power_load, standard_load, interruptible_standard_load)`
- `gens`      — `(; thermal_standard, hydro_dispatch, renewable_dispatch,
                    renewable_non_dispatch, synchronous_condenser)`
- `branches`  — `(; line, two_winding_transformer, discrete_controlled_ac_branch)`
- `xfrm_3w`   — `(; three_winding_transformer,)`
- `dclines`   — `(; two_terminal_lcc_line, two_terminal_generic_hvdc_line)`

# Fields — accumulators shared across readers

- `arcs::Dict{Int, Dict{String, Any}}` — Arc dicts referenced by every
  2-terminal branch + 3W star arc + DC/VSC line + switch/breaker.
- `supplemental_attribute_associations::Vector{Dict{String, Any}}` —
  `{"attribute_id", "entity_id"}` rows linking transformers to their
  attached ImpedanceCorrectionData.
- `ids::IDGenerator` — the id minter threaded through every reader.
  Retained so callers can mint additional ids consistent with the parsed
  output.
"""
struct ParsedOpenAPIDicts
    bus_dicts::Dict{Int, Dict{String, Any}}
    area_dicts::Dict{Int, Dict{String, Any}}
    area_interchange_dicts::Dict{String, Dict{String, Any}}
    loadzone_dicts::Dict{Int, Dict{String, Any}}
    loads::NamedTuple
    switched_shunt_dicts::Dict{String, Dict{String, Any}}
    shunt_dicts::Dict{String, Dict{String, Any}}
    gens::NamedTuple
    storage_dicts::Dict{String, Dict{String, Any}}
    branches::NamedTuple
    xfrm_3w::NamedTuple
    transformer_circuits::Dict{Int, Dict{String, Any}}
    switch_dicts::Dict{String, Dict{String, Any}}
    breaker_dicts::Dict{String, Dict{String, Any}}
    dclines::NamedTuple
    vscline_dicts::Dict{String, Dict{String, Any}}
    facts_dicts::Dict{String, Dict{String, Any}}
    ict_instances::Dict{Tuple{Int, String}, Dict{String, Any}}
    arcs::Dict{Int, Dict{String, Any}}
    supplemental_attribute_associations::Vector{Dict{String, Any}}
    ids::IDGenerator
end

"""
Parse a [`PowerModelsData`] into OpenAPI-shaped dicts in one call.
Bundles the 16 `read_*!` calls behind a single entry point.

Output is a [`ParsedOpenAPIDicts`] holding every collection plus the three
shared accumulators (`arcs`, `ict_instances`,
`supplemental_attribute_associations`) and the `IDGenerator` used.
Heterogeneous reader outputs (`loads`, `gens`, `branches`, `xfrm_3w`,
`dclines`) are NamedTuples of per-OpenAPI-type sub-collections.

# Arguments

- `pm_data::PowerModelsData`: parsed PowerModels data.

# Keyword Arguments

All kwargs are forwarded to every underlying reader. Each reader silently
ignores kwargs it doesn't recognize, so callers can pass any subset of the
following:

- `bus_name_formatter::Function`
- `load_name_formatter::Function`
- `loadzone_name_formatter::Function`
- `area_name_formatter::Function`
- `gen_name_formatter::Function`
- `generator_mapping::Union{AbstractString, Dict}` — override the YAML
  dispatch table path or the prebuilt mapping
- `branch_name_formatter::Function`
- `xfrm_3w_name_formatter::Function`
- `transformer_control_objective_formatter::Function`
- `dcline_name_formatter::Function`
- `vsc_line_name_formatter::Function`
- `switched_shunt_name_formatter::Function`
- `shunt_name_formatter::Function`

# Throws

`DataFormatError` if `pm_data` has no buses.

# Example

```julia
pm_data = PowerModelsData("test/path/to/case.raw")
parsed = parse_to_openapi_dicts(
    pm_data;
    bus_name_formatter = b -> "BUS_" * string(b["bus_i"]),
    gen_name_formatter = g -> strip(join(g["source_id"], "_")),
)

parsed.bus_dicts                     # Dict{Int, Dict{String, Any}}
parsed.loads.power_load              # Dict{String, Dict{String, Any}}
parsed.gens.thermal_standard         # ...
parsed.branches.line                 # ...
parsed.arcs                          # Arc accumulator
parsed.ict_instances                 # ICT dicts (PSS/E only)
parsed.supplemental_attribute_associations
```
"""
function parse_to_openapi_dicts(pm_data::PowerModelsData; kwargs...)
    data = pm_data.data
    if !haskey(data, "bus") || isempty(data["bus"])
        throw(DataFormatError("There are no buses in this file."))
    end

    @info "Building OpenAPI dicts from PowerModelsData" source_type =
        get(data, "source_type", "<unknown>")

    ids = IDGenerator()
    arcs = Dict{Int, Dict{String, Any}}()
    transformer_circuits = Dict{Int, Dict{String, Any}}()
    supplemental_attribute_associations = Dict{String, Any}[]

    # ICT lookup is built first so it's available to read_branch! /
    # read_3w_transformer! (PSS/E-only; empty for MATPOWER files).
    # read_impedance_correction! has no kwargs.
    ict_instances = read_impedance_correction!(pm_data, ids)

    bus_dicts = read_bus!(pm_data, ids; kwargs...)
    area_dicts = read_area!(pm_data, ids; kwargs...)
    area_interchange_dicts =
        read_area_interchange!(pm_data, ids, area_dicts; kwargs...)
    loadzone_dicts = read_loadzones!(pm_data, ids; kwargs...)
    loads = read_loads!(pm_data, ids; kwargs...)
    switched_shunt_dicts = read_switched_shunt!(pm_data, ids; kwargs...)
    shunt_dicts = read_shunt!(pm_data, ids; kwargs...)
    gens = read_gen!(pm_data, ids; kwargs...)
    storage_dicts = read_storage!(pm_data, ids, bus_dicts; kwargs...)
    branches = read_branch!(
        pm_data,
        ids,
        bus_dicts,
        arcs,
        transformer_circuits;
        ict_instances = ict_instances,
        supplemental_attribute_associations = supplemental_attribute_associations,
        kwargs...,
    )
    xfrm_3w = read_3w_transformer!(
        pm_data,
        ids,
        bus_dicts,
        arcs,
        transformer_circuits;
        ict_instances = ict_instances,
        supplemental_attribute_associations = supplemental_attribute_associations,
        kwargs...,
    )
    switch_dicts =
        read_switch_breaker!(pm_data, ids, bus_dicts, arcs, "switch"; kwargs...)
    breaker_dicts =
        read_switch_breaker!(pm_data, ids, bus_dicts, arcs, "breaker"; kwargs...)
    dclines = read_dcline!(pm_data, ids, bus_dicts, arcs; kwargs...)
    vscline_dicts = read_vscline!(pm_data, ids, bus_dicts, arcs; kwargs...)
    facts_dicts = read_facts!(pm_data, ids, bus_dicts; kwargs...)

    return ParsedOpenAPIDicts(
        bus_dicts,
        area_dicts,
        area_interchange_dicts,
        loadzone_dicts,
        loads,
        switched_shunt_dicts,
        shunt_dicts,
        gens,
        storage_dicts,
        branches,
        xfrm_3w,
        transformer_circuits,
        switch_dicts,
        breaker_dicts,
        dclines,
        vscline_dicts,
        facts_dicts,
        ict_instances,
        arcs,
        supplemental_attribute_associations,
        ids,
    )
end

"""
Parse `pm_data` and write everything into a fresh SQLite database whose
schema is initialized by [`make_sqlite!`]. Returns the DB connection.
Parallels PSY's depreciated `System(pm_data::PowerModelsData)`, instead
of returning an in-memory typed System, it lands a populated database
directly.

The internal flow is:
1. Open an SQLite DB (in-memory by default, or at `path`).
2. Initialize the full schema via [`make_sqlite!`]`(db)`.
3. Call [`parse_to_openapi_dicts(pm_data; kwargs...)`](@ref) to get the
   OpenAPI-shaped dicts.
4. Write Arcs first (every branch-like row references an arc id).
5. Write ImpedanceCorrectionData supplemental attributes (rows must exist
   before the transformer↔ICT association rows are inserted).
6. Walk [`_MAKE_DATABASE_TYPE_ORDER`] — for each OpenAPI type, materialize
   structs via `OpenAPI.from_json` and call [`send_openapi_table_to_db!`].
   Insertion order matches `ALL_DESERIALIZABLE_TYPES` so FK references
   (e.g. `ThermalStandard.bus` → `ACBus.id`) resolve in order.
7. Write the transformer↔ICT associations into
   `supplemental_attributes_association`.

The synthesized UUIDs written into the `attributes` table at the
`get_uuid` slot are random (`UUIDs.uuid4()`); this DB is one-way (parser →
DB) and cannot round-trip back to PSY components without an additional
mapping layer.

# Arguments

- `pm_data::PowerModelsData`: parsed PowerModels data.

# Keyword Arguments

- `path::AbstractString = ":memory:"` — SQLite destination. `":memory:"`
  yields an in-memory DB; any other string opens a file at that path
  (created if absent, truncated if present).

# Returns

`SQLite.DB` — the open connection. The caller is responsible for closing
it (`SQLite.close!` / `DBInterface.close!`) if the database needs to be
flushed to disk and reopened in another process.

# Example

```julia
pm_data = PowerModelsData("test/path/to/case.raw")
db = make_database(pm_data; path = "/tmp/case.db",
    bus_name_formatter = b -> "BUS_" * string(b["bus_i"]),
)
# inspect:
DBInterface.execute(db, "SELECT COUNT(*) FROM buses") |> first
```
"""
function make_database(
    pm_data::PowerModelsData;
    path::AbstractString = ":memory:",
    kwargs...,
)
    parsed = parse_to_openapi_objects(pm_data; kwargs...)

    db = SQLite.DB(String(path))
    make_sqlite!(db)

    # Split the type-order walk in half: topology types (Area / LoadZone /
    # ACBus) go first so their `entities` rows exist before we insert
    # arcs (whose `from_id`/`to_id` FK back into `entities`). Then arcs,
    # then ICT supplemental attributes, then everything else.
    _TOPOLOGY = (:Area, :LoadZone, :ACBus)
    _is_topology(t::Symbol) = t in _TOPOLOGY

    for type_sym in _MAKE_DATABASE_TYPE_ORDER
        _is_topology(type_sym) || continue
        T = getfield(PowerOperationsOpenAPIModels, type_sym)
        components = _extract_type_objects(parsed, type_sym)
        isempty(components) && continue
        if !haskey(_POAM_TYPE_TO_TABLE, T) &&
           T !== PowerOperationsOpenAPIModels.AreaInterchange
            # Types not yet mapped to a table (TwoTerminalLCCLine,
            # DiscreteControlledACBranch, FACTSControlDevice, etc.) are
            # parsed but not persisted. Log and skip.
            @debug "No DB table mapped for $type_sym; skipping ($(length(components)) objects dropped)"
            continue
        end
        send_openapi_table_to_db!(T, db, components)
    end

    # Arcs after topology so `from_id`/`to_id` FKs resolve.
    write_arcs_to_db!(db, parsed.arcs)

    # Supplemental attributes (ICTs) must exist before the transformer↔ICT
    # association rows reference them. ICT dicts are materialized to typed
    # structs here rather than up-front in `_dicts_to_objects` so schema
    # validation happens right before the DB write.
    if !isempty(parsed.ict_instances)
        ict_structs = [
            OpenAPI.from_json(ImpedanceCorrectionData, d) for d in parsed.ict_instances
        ]
        write_supplemental_attributes_to_db!(ImpedanceCorrectionData, db, ict_structs)
    end

    # Everything else (branches, transformers, loads, gens, …). Order in
    # `_MAKE_DATABASE_TYPE_ORDER` still governs FK dependencies among these.
    for type_sym in _MAKE_DATABASE_TYPE_ORDER
        _is_topology(type_sym) && continue
        T = getfield(PowerOperationsOpenAPIModels, type_sym)
        components = _extract_type_objects(parsed, type_sym)
        isempty(components) && continue
        if !haskey(_POAM_TYPE_TO_TABLE, T) &&
           T !== PowerOperationsOpenAPIModels.AreaInterchange
            # Types not yet mapped to a table (TwoTerminalLCCLine,
            # DiscreteControlledACBranch, FACTSControlDevice, etc.) are
            # parsed but not persisted. Log and skip.
            @debug "No DB table mapped for $type_sym; skipping ($(length(components)) objects dropped)"
            continue
        end
        send_openapi_table_to_db!(T, db, components)
    end

    # Transformer↔ICT association rows last, after both ICTs and Transformer
    # rows are in the DB.
    write_supplemental_attribute_associations_to_db!(
        db,
        parsed.supplemental_attribute_associations,
    )

    return db
end

"""
Map an OpenAPI type Symbol to its corresponding sub-collection inside a
[`ParsedOpenAPIDicts`]. Encapsulates the heterogeneous-reader unwrapping
(`parsed.gens.thermal_standard` for `:ThermalStandard`, etc.) plus the
`DiscreteControlledACBranch` three-source merge.

Returns an `AbstractDict` — could be an alias to one of the existing
sub-collections, or a freshly-merged dict (the DCAB case).
"""
function _extract_type_dicts(parsed::ParsedOpenAPIDicts, type_sym::Symbol)
    if type_sym === :ACBus
        return parsed.bus_dicts
    elseif type_sym === :Area
        return parsed.area_dicts
    elseif type_sym === :AreaInterchange
        return parsed.area_interchange_dicts
    elseif type_sym === :LoadZone
        return parsed.loadzone_dicts
    elseif type_sym === :PowerLoad
        return parsed.loads.power_load
    elseif type_sym === :StandardLoad
        return parsed.loads.standard_load
    elseif type_sym === :InterruptibleStandardLoad
        return parsed.loads.interruptible_standard_load
    elseif type_sym === :SwitchedAdmittance
        return parsed.switched_shunt_dicts
    elseif type_sym === :FixedAdmittance
        return parsed.shunt_dicts
    elseif type_sym === :ThermalStandard
        return parsed.gens.thermal_standard
    elseif type_sym === :HydroDispatch
        return parsed.gens.hydro_dispatch
    elseif type_sym === :RenewableDispatch
        return parsed.gens.renewable_dispatch
    elseif type_sym === :RenewableNonDispatch
        return parsed.gens.renewable_non_dispatch
    elseif type_sym === :SynchronousCondenser
        return parsed.gens.synchronous_condenser
    elseif type_sym === :EnergyReservoirStorage
        return parsed.storage_dicts
    elseif type_sym === :Line
        return parsed.branches.line
    elseif type_sym === :TransformerCircuit
        return parsed.transformer_circuits
    elseif type_sym === :TwoWindingTransformer
        return parsed.branches.two_winding_transformer
    elseif type_sym === :ThreeWindingTransformer
        return parsed.xfrm_3w.three_winding_transformer
    elseif type_sym === :DiscreteControlledACBranch
        # Three sources (zero-impedance branches + switches + breakers)
        # collapse to one OpenAPI type. Composite id keys prevent
        # collisions, so the merge is safe.
        return merge(
            parsed.branches.discrete_controlled_ac_branch,
            parsed.switch_dicts,
            parsed.breaker_dicts,
        )
    elseif type_sym === :TwoTerminalLCCLine
        return parsed.dclines.two_terminal_lcc_line
    elseif type_sym === :TwoTerminalGenericHVDCLine
        return parsed.dclines.two_terminal_generic_hvdc_line
    elseif type_sym === :TwoTerminalVSCLine
        return parsed.vscline_dicts
    elseif type_sym === :FACTSControlDevice
        return parsed.facts_dicts
    else
        error("Unknown OpenAPI type symbol: $type_sym")
    end
end

# =============================================================================
# Typed OpenAPI objects — public end-user entry point.
#
# The `ParsedOpenAPIObjects` container holds *materialized* OpenAPI structs
# (validated via `OpenAPI.from_json`) instead of the raw dicts. This is the
# shape downstream consumers want — both [`make_database`] (which writes
# them directly into SQLite) and any external PSY-System constructor that
# wants to consume OpenAPI structs (e.g.
# `SiennaOpenAPIModels.jl/src/json_to_sienna/`).
#
# `ParsedOpenAPIDicts` is kept as the under-the-hood intermediate
# representation — readers still produce dicts, then `_dicts_to_objects`
# converts. Direct dict access remains available via
# `PowerFlowFileParser.parse_to_openapi_dicts(pm_data)` (qualified, not
# exported).
# =============================================================================

"""
Container holding every output collection produced by a single
[`parse_to_openapi_objects`] run, with each collection holding
**materialized** OpenAPI structs (validated by `OpenAPI.from_json`)
rather than the dicts that come out of the readers.

# Fields — homogeneous reader outputs (`Vector{T}` for the corresponding T)

- `buses::Vector{PowerOperationsOpenAPIModels.ACBus}`
- `areas::Vector{PowerOperationsOpenAPIModels.Area}`
- `area_interchanges::Vector{PowerOperationsOpenAPIModels.AreaInterchange}`
- `loadzones::Vector{PowerOperationsOpenAPIModels.LoadZone}`
- `switched_shunts::Vector{PowerOperationsOpenAPIModels.SwitchedAdmittance}`
- `shunts::Vector{PowerOperationsOpenAPIModels.FixedAdmittance}`
- `storage::Vector{PowerOperationsOpenAPIModels.EnergyReservoirStorage}`
- `switches::Vector{PowerOperationsOpenAPIModels.DiscreteControlledACBranch}` — from
  `data["switch"]`
- `breakers::Vector{PowerOperationsOpenAPIModels.DiscreteControlledACBranch}` —
  from `data["breaker"]`
- `vsclines::Vector{PowerOperationsOpenAPIModels.TwoTerminalVSCLine}`
- `facts::Vector{PowerOperationsOpenAPIModels.FACTSControlDevice}`
- `ict_instances::Vector{Dict{String, Any}}` — raw ICT dicts, not
  materialized here. [`make_database`] materializes them to
  `PowerOperationsOpenAPIModels.ImpedanceCorrectionData` structs at write
  time.

# Fields — heterogeneous reader outputs (NamedTuples per OpenAPI type)

- `loads`     — `(; power_load, standard_load, interruptible_standard_load)`,
                each a `Vector` of its corresponding OpenAPI type
- `gens`      — `(; thermal_standard, hydro_dispatch, renewable_dispatch,
                    renewable_non_dispatch, synchronous_condenser)`
- `branches`  — `(; line, two_winding_transformer, discrete_controlled_ac_branch)`
- `xfrm_3w`   — `(; three_winding_transformer,)`
- `dclines`   — `(; two_terminal_lcc_line, two_terminal_generic_hvdc_line)`

# Fields — accumulators

- `arcs::Vector{PowerOperationsOpenAPIModels.Arc}` — Arc structs referenced by
  every 2-terminal branch + 3W star arc + DC/VSC line + switch/breaker.
- `supplemental_attribute_associations::Vector{Dict{String, Any}}` —
  `{"attribute_id", "entity_id"}` rows linking transformers to their
  attached ImpedanceCorrectionData. Kept as Dicts — they're FK edges, not
  OpenAPI components.
- `ids::IDGenerator` — the id minter threaded through every reader.
"""
struct ParsedOpenAPIObjects
    buses::Vector{PowerOperationsOpenAPIModels.ACBus}
    areas::Vector{PowerOperationsOpenAPIModels.Area}
    area_interchanges::Vector{PowerOperationsOpenAPIModels.AreaInterchange}
    loadzones::Vector{PowerOperationsOpenAPIModels.LoadZone}
    loads::NamedTuple
    switched_shunts::Vector{PowerOperationsOpenAPIModels.SwitchedAdmittance}
    shunts::Vector{PowerOperationsOpenAPIModels.FixedAdmittance}
    gens::NamedTuple
    storage::Vector{PowerOperationsOpenAPIModels.EnergyReservoirStorage}
    branches::NamedTuple
    xfrm_3w::NamedTuple
    transformer_circuits::Vector{PowerOperationsOpenAPIModels.TransformerCircuit}
    switches::Vector{PowerOperationsOpenAPIModels.DiscreteControlledACBranch}
    breakers::Vector{PowerOperationsOpenAPIModels.DiscreteControlledACBranch}
    dclines::NamedTuple
    vsclines::Vector{PowerOperationsOpenAPIModels.TwoTerminalVSCLine}
    facts::Vector{PowerOperationsOpenAPIModels.FACTSControlDevice}
    ict_instances::Vector{Dict{String, Any}}
    arcs::Vector{PowerOperationsOpenAPIModels.Arc}
    supplemental_attribute_associations::Vector{Dict{String, Any}}
    ids::IDGenerator
end

"""
Convert a homogeneous collection of OpenAPI-shaped dicts to a typed
`Vector{T}`. Each dict is passed through `OpenAPI.from_json(T, d)`, which
validates required fields and enum values per the schema.

Accepts any iterable of dicts (Dict-of-dicts and NamedTuple sub-fields
both work — we call `values(…)` to drop keys uniformly).
"""
_convert_dicts(::Type{T}, dicts) where {T <: OpenAPI.APIModel} =
    T[OpenAPI.from_json(T, d) for d in values(dicts)]

"""
Convert a [`ParsedOpenAPIDicts`] into a [`ParsedOpenAPIObjects`] by
calling `OpenAPI.from_json` once per dict per OpenAPI type. Centralizes
all the from_json work in one place so failures (required-field misses,
enum mismatches) surface here rather than during a downstream loop.

Heterogeneous reader outputs are converted in lockstep — each NamedTuple
sub-field becomes a typed Vector under the same name.
"""
function _dicts_to_objects(parsed::ParsedOpenAPIDicts)
    POAM = PowerOperationsOpenAPIModels  # local alias for brevity

    loads = (;
        power_load = _convert_dicts(POAM.PowerLoad, parsed.loads.power_load),
        standard_load = _convert_dicts(POAM.StandardLoad, parsed.loads.standard_load),
        interruptible_standard_load = _convert_dicts(
            POAM.InterruptibleStandardLoad,
            parsed.loads.interruptible_standard_load,
        ),
    )
    gens = (;
        thermal_standard = _convert_dicts(
            POAM.ThermalStandard,
            parsed.gens.thermal_standard,
        ),
        hydro_dispatch = _convert_dicts(POAM.HydroDispatch, parsed.gens.hydro_dispatch),
        renewable_dispatch = _convert_dicts(
            POAM.RenewableDispatch,
            parsed.gens.renewable_dispatch,
        ),
        renewable_non_dispatch = _convert_dicts(
            POAM.RenewableNonDispatch,
            parsed.gens.renewable_non_dispatch,
        ),
        synchronous_condenser = _convert_dicts(
            POAM.SynchronousCondenser,
            parsed.gens.synchronous_condenser,
        ),
    )
    branches = (;
        line = _convert_dicts(POAM.Line, parsed.branches.line),
        two_winding_transformer = _convert_dicts(
            POAM.TwoWindingTransformer,
            parsed.branches.two_winding_transformer,
        ),
        discrete_controlled_ac_branch = _convert_dicts(
            POAM.DiscreteControlledACBranch,
            parsed.branches.discrete_controlled_ac_branch,
        ),
    )
    xfrm_3w = (;
        three_winding_transformer = _convert_dicts(
            POAM.ThreeWindingTransformer,
            parsed.xfrm_3w.three_winding_transformer,
        ),
    )
    dclines = (;
        two_terminal_lcc_line = _convert_dicts(
            POAM.TwoTerminalLCCLine,
            parsed.dclines.two_terminal_lcc_line,
        ),
        two_terminal_generic_hvdc_line = _convert_dicts(
            POAM.TwoTerminalGenericHVDCLine,
            parsed.dclines.two_terminal_generic_hvdc_line,
        ),
    )

    return ParsedOpenAPIObjects(
        _convert_dicts(POAM.ACBus, parsed.bus_dicts),
        _convert_dicts(POAM.Area, parsed.area_dicts),
        _convert_dicts(POAM.AreaInterchange, parsed.area_interchange_dicts),
        _convert_dicts(POAM.LoadZone, parsed.loadzone_dicts),
        loads,
        _convert_dicts(POAM.SwitchedAdmittance, parsed.switched_shunt_dicts),
        _convert_dicts(POAM.FixedAdmittance, parsed.shunt_dicts),
        gens,
        _convert_dicts(POAM.EnergyReservoirStorage, parsed.storage_dicts),
        branches,
        xfrm_3w,
        _convert_dicts(POAM.TransformerCircuit, parsed.transformer_circuits),
        _convert_dicts(POAM.DiscreteControlledACBranch, parsed.switch_dicts),
        _convert_dicts(POAM.DiscreteControlledACBranch, parsed.breaker_dicts),
        dclines,
        _convert_dicts(POAM.TwoTerminalVSCLine, parsed.vscline_dicts),
        _convert_dicts(POAM.FACTSControlDevice, parsed.facts_dicts),
        # ICT dicts pass through untouched; `make_database` materializes them
        # to `PowerOperationsOpenAPIModels.ImpedanceCorrectionData` at write
        # time, right before the DB insert.
        collect(values(parsed.ict_instances)),
        _convert_dicts(POAM.Arc, parsed.arcs),
        parsed.supplemental_attribute_associations,
        parsed.ids,
    )
end

"""
Parse a [`PowerModelsData`] into materialized OpenAPI objects in one call.
This is the public end-user entry point for the dict-to-objects pipeline;
the underlying [`ParsedOpenAPIDicts`] representation is kept as an
implementation detail.

Internally: `_dicts_to_objects(parse_to_openapi_dicts(pm_data; kwargs...))`.
Calling this is strictly more work than `parse_to_openapi_dicts` — it adds
one `OpenAPI.from_json` call per output dict. The benefit is that
schema validation (required fields + enum membership) happens up front,
and the result is ready to hand to either [`make_database`] or a
downstream PSY-System constructor (e.g. SiennaOpenAPIModels'
`json_to_sienna/`, which lives in a separate package).

# Arguments
- `pm_data::PowerModelsData`: parsed PowerModels data.

# Keyword Arguments

Same as [`parse_to_openapi_dicts`]: all kwargs are forwarded to the
underlying readers. Each reader silently ignores kwargs it doesn't
recognize (`bus_name_formatter`, `gen_name_formatter`, etc.).

# Throws

`DataFormatError` if `pm_data` has no buses (from `parse_to_openapi_dicts`).
Whatever `OpenAPI.ValidationException` / `MethodError` `from_json` raises
if a dict fails schema validation.

# Returns

[`ParsedOpenAPIObjects`].

# Example

```julia
pm_data = PowerModelsData("test/path/to/case.raw")
parsed  = parse_to_openapi_objects(pm_data)

parsed.buses                          # Vector{ACBus}
parsed.loads.power_load               # Vector{PowerLoad}
parsed.gens.thermal_standard          # Vector{ThermalStandard}
parsed.branches.line                  # Vector{Line}
parsed.arcs                           # Vector{Arc}
parsed.ict_instances                  # Vector{ImpedanceCorrectionData}

# Pass downstream — e.g., to a PSY-System constructor (a separate package
# like SiennaOpenAPIModels' json_to_sienna/, not provided here).
```
"""
function parse_to_openapi_objects(pm_data::PowerModelsData; kwargs...)
    return _dicts_to_objects(parse_to_openapi_dicts(pm_data; kwargs...))
end

"""
Object-side counterpart of [`_extract_type_dicts`]: selects the right
sub-collection from a [`ParsedOpenAPIObjects`] for a given OpenAPI type
Symbol. Used by [`make_database`] when writing tables in dependency
order. Handles the `:DiscreteControlledACBranch` three-source merge
(zero-impedance + switches + breakers concatenated into one Vector).
"""
function _extract_type_objects(parsed::ParsedOpenAPIObjects, type_sym::Symbol)
    if type_sym === :ACBus
        return parsed.buses
    elseif type_sym === :Area
        return parsed.areas
    elseif type_sym === :AreaInterchange
        return parsed.area_interchanges
    elseif type_sym === :LoadZone
        return parsed.loadzones
    elseif type_sym === :PowerLoad
        return parsed.loads.power_load
    elseif type_sym === :StandardLoad
        return parsed.loads.standard_load
    elseif type_sym === :InterruptibleStandardLoad
        return parsed.loads.interruptible_standard_load
    elseif type_sym === :SwitchedAdmittance
        return parsed.switched_shunts
    elseif type_sym === :FixedAdmittance
        return parsed.shunts
    elseif type_sym === :ThermalStandard
        return parsed.gens.thermal_standard
    elseif type_sym === :HydroDispatch
        return parsed.gens.hydro_dispatch
    elseif type_sym === :RenewableDispatch
        return parsed.gens.renewable_dispatch
    elseif type_sym === :RenewableNonDispatch
        return parsed.gens.renewable_non_dispatch
    elseif type_sym === :SynchronousCondenser
        return parsed.gens.synchronous_condenser
    elseif type_sym === :EnergyReservoirStorage
        return parsed.storage
    elseif type_sym === :Line
        return parsed.branches.line
    elseif type_sym === :TransformerCircuit
        return parsed.transformer_circuits
    elseif type_sym === :TwoWindingTransformer
        return parsed.branches.two_winding_transformer
    elseif type_sym === :ThreeWindingTransformer
        return parsed.xfrm_3w.three_winding_transformer
    elseif type_sym === :DiscreteControlledACBranch
        # Three sources concatenated. Composite id keys (from the dict
        # stage) prevented collisions, so the result is a flat Vector
        # with unique ids.
        return vcat(
            parsed.branches.discrete_controlled_ac_branch,
            parsed.switches,
            parsed.breakers,
        )
    elseif type_sym === :TwoTerminalLCCLine
        return parsed.dclines.two_terminal_lcc_line
    elseif type_sym === :TwoTerminalGenericHVDCLine
        return parsed.dclines.two_terminal_generic_hvdc_line
    elseif type_sym === :TwoTerminalVSCLine
        return parsed.vsclines
    elseif type_sym === :FACTSControlDevice
        return parsed.facts
    else
        error("Unknown OpenAPI type symbol: $type_sym")
    end
end

# ===================================================================================

"""
Corrects transformer status in PowerModelsData based on bus voltage differences.
"""
function correct_pm_transformer_status!(pm_data::PowerModelsData)
    for (k, branch) in pm_data.data["branch"]
        f_bus_bvolt = pm_data.data["bus"][branch["f_bus"]]["base_kv"]
        t_bus_bvolt = pm_data.data["bus"][branch["t_bus"]]["base_kv"]
        percent_difference =
            abs(f_bus_bvolt - t_bus_bvolt) / ((f_bus_bvolt + t_bus_bvolt) / 2)
        if !branch["transformer"] &&
           percent_difference > BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL
            branch["transformer"] = true
            branch["base_power"] = pm_data.data["baseMVA"]
            branch["ext"] = Dict{String, Any}()
            @warn "Branch $(branch["f_bus"]) - $(branch["t_bus"]) has different voltage levels
            endpoints (from: $(f_bus_bvolt)kV, to: $(t_bus_bvolt)kV) which exceed the
            $(BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL*100)% threshold; converting to transformer."
            if !haskey(branch, "base_voltage_from")
                branch["base_voltage_from"] = f_bus_bvolt
                branch["base_voltage_to"] = t_bus_bvolt
            end
        end
    end
end

"""
Names generic PowerModels device dict, falling back to source_id
or numeric index if no name is set.
"""
function _get_pm_dict_name(device_dict::Dict)::String
    if haskey(device_dict, "shunt_bus")
        # Shunt names must be qualified by bus number to avoid collisions
        # between FixedAdmittance and SwitchedAdmittance attached to the same bus.
        return join(strip.(string.((device_dict["shunt_bus"], device_dict["name"]))), "-")
    elseif haskey(device_dict, "name")
        return string(device_dict["name"])
    elseif haskey(device_dict, "source_id")
        return strip(join(string.(device_dict["source_id"]), "-"))
    else
        return string(device_dict["index"])
    end
end

"""
Resolve a bus name from a PowerModels bus dict. When `unique_names` is false,
the bus number is appended to disambiguate duplicates (a PSS/E quirk).
"""
function _get_pm_bus_name(device_dict::Dict, unique_names::Bool)
    if haskey(device_dict, "name")
        base = strip(device_dict["name"])
        return unique_names ? base : base * "_" * string(device_dict["bus_i"])
    else
        return strip(join(string.(device_dict["source_id"]), "-"))
    end
end

"""
Translate one PowerModels bus row into an ACBus-shaped `Dict{String, Any}`.
The resulting dict is ready to hand to `OpenAPI.from_json(PowerOperationsOpenAPIModels.ACBus, d)`.
"""
function make_bus(bus_name::AbstractString, bus_number::Int, d::Dict, ids::IDGenerator)
    return Dict{String, Any}(
        "id" => getid!(ids, :ACBus, bus_number),
        "number" => bus_number,
        "name" => String(bus_name),
        "available" => get(d, "bus_status", true),
        "bustype" => _PM_BUS_TYPE_ENUM[d["bus_type"]],
        "angle" => d["va"],
        "magnitude" => d["vm"],
        "voltage_limits" =>
            Dict{String, Any}("min" => d["vmin"], "max" => d["vmax"]),
        "base_voltage" => d["base_kv"],
        "area" => getid!(ids, :Area, d["area"]),
        "load_zone" => getid!(ids, :LoadZone, get(d, "zone", nothing)),
    )
end

"""
Walk every bus in `pm_data` and return a `Dict{Int, Dict{String, Any}}` mapping
each bus number to an ACBus-shaped dict ready for `OpenAPI.from_json`.
"""
function read_bus!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading bus data"
    data = pm_data.data
    bus_number_to_bus = Dict{Int, Dict{String, Any}}()

    # PSSE doesn't enforce bus-name uniqueness. Detect duplicates up front so
    # we can fall back to a number-suffixed naming scheme without forcing the
    # caller to pass a custom formatter.
    unique_bus_names = true
    bus_data = SortedDict{Int, Any}()
    bus_names = Set{String}()
    for (_, b) in data["bus"]
        if unique_bus_names && haskey(b, "name")
            b["name"] ∈ bus_names && (unique_bus_names = false)
            push!(bus_names, b["name"])
        end
        bus_data[Int(b["bus_i"])] = b
    end
    isempty(bus_data) && @error "No bus data found"

    default_bus_naming = x -> _get_pm_bus_name(x, unique_bus_names)
    _get_name = get(kwargs, :bus_name_formatter, default_bus_naming)

    for (_, d) in bus_data
        bus_name = String(strip(_get_name(d)))
        bus_number = Int(d["bus_i"])
        if !haskey(d, "bus_status")
            d["bus_status"] = true
        end
        bus = make_bus(bus_name, bus_number, d, ids)
        haskey(bus_number_to_bus, bus_number) && throw(
            DataFormatError(
                "Found duplicate bus number $bus_number for bus $bus_name",
            ),
        )
        bus_number_to_bus[bus_number] = bus
    end

    return bus_number_to_bus
end

"""
Build the dict equivalent of `LoadCost(variable = zero(CostCurve), fixed = 0.0)`.
"""
function _zero_loadcost_dict()
    zero_io_curve = Dict{String, Any}(
        "curve_type" => "INPUT_OUTPUT",
        "function_data" => Dict{String, Any}(
            "function_type" => "LINEAR",
            "proportional_term" => 0.0,
            "constant_term" => 0.0,
        ),
    )
    return Dict{String, Any}(
        "cost_type" => "LOAD",
        "fixed" => 0.0,
        "variable" => Dict{String, Any}(
            "power_units" => "NATURAL_UNITS",
            "variable_cost_type" => "COST",
            "value_curve" => zero_io_curve,
            "vom_cost" => deepcopy(zero_io_curve),
        ),
    )
end

"""
Translate one PowerModels load row into an InterruptiblePowerLoad-shaped dict.
"""
function make_interruptible_powerload(
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator;
    kwargs...,
)
    _get_name = get(kwargs, :load_name_formatter, x -> strip(join(x["source_id"])))
    return Dict{String, Any}(
        "id" => getid!(ids, :InterruptiblePowerLoad, d["index"]),
        "name" => String(_get_name(d)),
        "available" => d["status"],
        "bus" => getid!(ids, :ACBus, d["load_bus"]),
        "active_power" => d["pd"],
        "reactive_power" => d["qd"],
        "max_active_power" => d["pd"],
        "max_reactive_power" => d["qd"],
        "base_power" => sys_mbase,
        "operation_cost" => _zero_loadcost_dict(),
    )
end

"""
Translate one PowerModels load row into an InterruptibleStandardLoad-shaped dict.
"""
function make_interruptible_standardload(
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator;
    kwargs...,
)
    _get_name = get(kwargs, :load_name_formatter, x -> strip(join(x["source_id"])))
    return Dict{String, Any}(
        "id" => getid!(ids, :InterruptibleStandardLoad, d["index"]),
        "name" => String(_get_name(d)),
        "available" => d["status"],
        "bus" => getid!(ids, :ACBus, d["load_bus"]),
        "base_power" => sys_mbase,
        "operation_cost" => _zero_loadcost_dict(),
        "conformity" => _loadconformity_string(d["conformity"]),
        "constant_active_power" => d["pd"],
        "constant_reactive_power" => d["qd"],
        "current_active_power" => d["pi"],
        "current_reactive_power" => d["qi"],
        "impedance_active_power" => d["py"],
        "impedance_reactive_power" => d["qy"],
        "max_constant_active_power" => d["pd"],
        "max_constant_reactive_power" => d["qd"],
        "max_current_active_power" => d["pi"],
        "max_current_reactive_power" => d["qi"],
        "max_impedance_active_power" => d["py"],
        "max_impedance_reactive_power" => d["qy"],
    )
end

"""
Translate one PowerModels load row into a PowerLoad-shaped dict.
"""
function make_power_load(d::Dict, sys_mbase::Float64, ids::IDGenerator; kwargs...)
    _get_name = get(kwargs, :load_name_formatter, x -> strip(join(x["source_id"])))
    return Dict{String, Any}(
        "id" => getid!(ids, :PowerLoad, d["index"]),
        "name" => String(_get_name(d)),
        "available" => d["status"],
        "bus" => getid!(ids, :ACBus, d["load_bus"]),
        "active_power" => d["pd"],
        "reactive_power" => d["qd"],
        "max_active_power" => d["pd"],
        "max_reactive_power" => d["qd"],
        "base_power" => sys_mbase,
        "conformity" => _loadconformity_string(d["conformity"]),
    )
end

"""
Translate one PowerModels load row into a StandardLoad-shaped dict.
"""
function make_standard_load(d::Dict, sys_mbase::Float64, ids::IDGenerator; kwargs...)
    _get_name = get(kwargs, :load_name_formatter, x -> strip(join(x["source_id"])))
    return Dict{String, Any}(
        "id" => getid!(ids, :StandardLoad, d["index"]),
        "name" => String(_get_name(d)),
        "available" => d["status"],
        "bus" => getid!(ids, :ACBus, d["load_bus"]),
        "base_power" => sys_mbase,
        "conformity" => _loadconformity_string(d["conformity"]),
        "constant_active_power" => d["pd"],
        "constant_reactive_power" => d["qd"],
        "current_active_power" => d["pi"],
        "current_reactive_power" => d["qi"],
        "impedance_active_power" => d["py"],
        "impedance_reactive_power" => d["qy"],
        "max_constant_active_power" => d["pd"],
        "max_constant_reactive_power" => d["qd"],
        "max_current_active_power" => d["pi"],
        "max_current_reactive_power" => d["qi"],
        "max_impedance_active_power" => d["py"],
        "max_impedance_reactive_power" => d["qy"],
    )
end

"""
Walk every load in `pm_data` and return a NamedTuple of per-OpenAPI-type
sub-collections.

    PTI + has `interruptible` field + value != 1  → StandardLoad
    PTI + has `interruptible` field + value == 1  → InterruptibleStandardLoad
    otherwise (MATPOWER, or PTI without flag)     → PowerLoad
"""
function read_loads!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading load data"
    data = pm_data.data
    power_load = Dict{String, Dict{String, Any}}()
    standard_load = Dict{String, Dict{String, Any}}()
    interruptible_standard_load = Dict{String, Dict{String, Any}}()

    if !haskey(data, "load")
        @error "There are no loads in this file"
        return (; power_load, standard_load, interruptible_standard_load)
    end

    sys_mbase = data["baseMVA"]
    is_pti = data["source_type"] == "pti"
    for d_key in keys(data["load"])
        d = data["load"][d_key]
        is_interruptible = haskey(d, "interruptible")
        if is_pti && is_interruptible && d["interruptible"] != 1
            load = make_standard_load(d, sys_mbase, ids; kwargs...)
            bucket = standard_load
        elseif is_pti && is_interruptible && d["interruptible"] == 1
            load = make_interruptible_standardload(d, sys_mbase, ids; kwargs...)
            bucket = interruptible_standard_load
        else
            load = make_power_load(d, sys_mbase, ids; kwargs...)
            bucket = power_load
        end
        load_name = load["name"]
        haskey(bucket, load_name) && throw(
            DataFormatError(
                "Found duplicate load name $load_name; consider passing a `load_name_formatter` kwarg",
            ),
        )
        bucket[load_name] = load
    end

    return (; power_load, standard_load, interruptible_standard_load)
end

"""
Build a LoadZone-shaped `Dict{String, Any}` from precomputed aggregate values.
"""
function make_loadzone(
    name::AbstractString,
    zone_number::Int,
    active_power::Float64,
    reactive_power::Float64,
    ids::IDGenerator;
    kwargs...,
)
    return Dict{String, Any}(
        "id" => getid!(ids, :LoadZone, zone_number),
        "name" => String(name),
        "peak_active_power" => active_power,
        "peak_reactive_power" => reactive_power,
    )
end

"""
Walk every load zone referenced by buses and return a `Dict{Int, Dict{String, Any}}` 
mapping each zone number to a LoadZone-shaped dict ready for `OpenAPI.from_json`.
"""
function read_loadzones!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading load zone data"
    data = pm_data.data

    zones = Set{Int}()
    for (_, bus) in data["bus"]
        push!(zones, bus["zone"])
    end

    load_zone_map = Dict{Int, Dict{String, Float64}}(
        i => Dict("pd" => 0.0, "qd" => 0.0) for i in zones
    )
    for (_, load) in data["load"]
        zone = data["bus"][load["load_bus"]]["zone"]
        load_zone_map[zone]["pd"] += load["pd"]
        load_zone_map[zone]["qd"] += load["qd"]
        # MATPOWER loads don't carry current/impedance components; PSS/E does.
        load_zone_map[zone]["pd"] += get(load, "pi", 0.0)
        load_zone_map[zone]["qd"] += get(load, "qi", 0.0)
        load_zone_map[zone]["pd"] += get(load, "py", 0.0)
        load_zone_map[zone]["qd"] += get(load, "qy", 0.0)
    end

    _get_name = get(kwargs, :loadzone_name_formatter, string)

    @info "Reading Zone data"
    if !haskey(data, "zone")
        @info "There is no Zone data in this file"
    else
        for (_, v) in data["zone"]
            zone_number = v["zone_number"]
            if !(zone_number in zones)
                @warn "Skipping empty LoadZone $(zone_number)-$(v["zone_name"])"
            end
        end
    end

    load_zones = Dict{Int, Dict{String, Any}}()
    for zone in zones
        load_zones[zone] = make_loadzone(
            _get_name(zone),
            zone,
            load_zone_map[zone]["pd"],
            load_zone_map[zone]["qd"],
            ids;
            kwargs...,
        )
    end
    return load_zones
end

"""
Translate one PowerModels switched-shunt row into a SwitchedAdmittance-shaped
dict.
"""
function make_switched_shunt(name::AbstractString, d::Dict, ids::IDGenerator)
    out = Dict{String, Any}(
        "id" => getid!(ids, :SwitchedAdmittance, d["index"]),
        "name" => String(name),
        "available" => Bool(d["status"]),
        "bus" => getid!(ids, :ACBus, d["shunt_bus"]),
        "Y" => _complex_to_dict(d["gs"] + d["bs"] * im),
        "number_of_steps" => d["step_number"],
        "Y_increase" => [_complex_to_dict(y) for y in d["y_increment"]],
        "admittance_limits" => Dict{String, Any}(
            "min" => d["admittance_limits"][1],
            "max" => d["admittance_limits"][2],
        ),
    )
    if haskey(d, "initial_status")
        out["initial_status"] = d["initial_status"]
    end
    return out
end

"""
For each switched shunt, return a `Dict{String, Dict{String, Any}}` mapping 
each shunt name to a SwitchedAdmittance-shaped dict ready for `OpenAPI.from_json`. 

Switched shunts are PSS/E-only; MATPOWER files have no `data["switched_shunt"]`
section and this function returns an empty dict for them.
"""
function read_switched_shunt!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading switched shunt data"
    shunts = Dict{String, Dict{String, Any}}()
    data = pm_data.data
    if !haskey(data, "switched_shunt")
        @info "There is no switched shunt data in this file"
        return shunts
    end

    _get_name = get(kwargs, :switched_shunt_name_formatter, _get_pm_dict_name)

    for (d_key, d) in data["switched_shunt"]
        d["name"] = get(d, "name", d_key)
        name = String(_get_name(d))
        shunt = make_switched_shunt(name, d, ids)
        haskey(shunts, name) && throw(
            DataFormatError(
                "Found duplicate switched shunt name $name; consider passing a `switched_shunt_name_formatter` kwarg",
            ),
        )
        shunts[name] = shunt
    end
    return shunts
end

"""
Translate one PowerModels fixed shunt row into a FixedAdmittance-shaped dict.
"""
function make_shunt(name::AbstractString, d::Dict, ids::IDGenerator)
    return Dict{String, Any}(
        "id" => getid!(ids, :FixedAdmittance, d["index"]),
        "name" => String(name),
        "available" => Bool(d["status"]),
        "bus" => getid!(ids, :ACBus, d["shunt_bus"]),
        "Y" => _complex_to_dict(d["gs"] + d["bs"] * im),
    )
end

"""
For each fixed shunt, return a `Dict{String, Dict{String, Any}}` mapping each 
shunt name to a FixedAdmittance-shaped dict ready for `OpenAPI.from_json`. 

MATPOWER's `pm_io/matpower.jl:_split_loads_shunts!` synthesizes `data["shunt"]`
from bus rows; PSS/E exposes its `FIXED SHUNT DATA` section directly. 
"""
function read_shunt!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading shunt data"
    shunts = Dict{String, Dict{String, Any}}()
    data = pm_data.data
    if !haskey(data, "shunt")
        @info "There is no shunt data in this file"
        return shunts
    end

    _get_name = get(kwargs, :shunt_name_formatter, _get_pm_dict_name)

    for (d_key, d) in data["shunt"]
        d["name"] = get(d, "name", d_key)
        name = String(_get_name(d))
        shunt = make_shunt(name, d, ids)
        haskey(shunts, name) && throw(
            DataFormatError(
                "Found duplicate shunt name $name; consider passing a `shunt_name_formatter` kwarg",
            ),
        )
        shunts[name] = shunt
    end
    return shunts
end

# =============================================================================
# Generators
# =============================================================================

"""
Build the dict equivalent of `HydroGenerationCost(zero(CostCurve), 0.0)`.
"""
function _zero_hydro_generation_cost_dict()
    zero_io_curve = Dict{String, Any}(
        "curve_type" => "INPUT_OUTPUT",
        "function_data" => Dict{String, Any}(
            "function_type" => "LINEAR",
            "proportional_term" => 0.0,
            "constant_term" => 0.0,
        ),
    )
    return Dict{String, Any}(
        "cost_type" => "HYDRO_GEN",
        "fixed" => 0.0,
        "variable" => Dict{String, Any}(
            "variable_cost_type" => "COST",
            "power_units" => "NATURAL_UNITS",
            "value_curve" => zero_io_curve,
            "vom_cost" => deepcopy(zero_io_curve),
        ),
    )
end

"""
Build the dict equivalent of `RenewableGenerationCost(zero(CostCurve))`.
"""
function _zero_renewable_generation_cost_dict()
    zero_io_curve = Dict{String, Any}(
        "curve_type" => "INPUT_OUTPUT",
        "function_data" => Dict{String, Any}(
            "function_type" => "LINEAR",
            "proportional_term" => 0.0,
            "constant_term" => 0.0,
        ),
    )
    return Dict{String, Any}(
        "cost_type" => "RENEWABLE",
        "fixed" => 0.0,
        "variable" => Dict{String, Any}(
            "variable_cost_type" => "COST",
            "power_units" => "NATURAL_UNITS",
            "value_curve" => zero_io_curve,
            "vom_cost" => deepcopy(zero_io_curve),
        ),
        "curtailment_cost" => Dict{String, Any}(
            "variable_cost_type" => "COST",
            "power_units" => "NATURAL_UNITS",
            "value_curve" => deepcopy(zero_io_curve),
            "vom_cost" => deepcopy(zero_io_curve),
        ),
    )
end

"""
Build an all-zero `ThermalGenerationCost` dict.
"""
function _zero_thermal_generation_cost_dict()
    zero_io_curve = Dict{String, Any}(
        "curve_type" => "INPUT_OUTPUT",
        "function_data" => Dict{String, Any}(
            "function_type" => "LINEAR",
            "proportional_term" => 0.0,
            "constant_term" => 0.0,
        ),
    )
    return Dict{String, Any}(
        "cost_type" => "THERMAL",
        "fixed" => 0.0,
        "start_up" => 0.0,
        "shut_down" => 0.0,
        "variable" => Dict{String, Any}(
            "variable_cost_type" => "COST",
            # FLAG: NATURAL_UNITS here — see the matching FLAG in
            # _thermal_variable_cost_and_fixed for why the real-data path
            # uses DEVICE_BASE instead. The all-zero placeholder has no
            # scaling to honor, so NATURAL_UNITS is harmless; keep this in
            # sync if the DEVICE_BASE decision is ever revisited.
            "power_units" => "NATURAL_UNITS",
            "value_curve" => zero_io_curve,
            "vom_cost" => deepcopy(zero_io_curve),
        ),
    )
end

"""
Translate one PowerModels generator row tagged for hydro-dispatch into a
HydroDispatch-shaped dict.
"""
function make_hydro_dispatch(
    gen_name::AbstractString,
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator,
)
    mbase = _resolve_mbase(d, sys_mbase, gen_name)
    base_conversion = sys_mbase / mbase
    return Dict{String, Any}(
        "id" => getid!(ids, :HydroDispatch, d["index"]),
        "name" => String(gen_name),
        "available" => Bool(d["gen_status"]),
        "bus" => getid!(ids, :ACBus, d["gen_bus"]),
        "active_power" => d["pg"] * base_conversion,
        "reactive_power" => d["qg"] * base_conversion,
        "rating" => _calculate_gen_rating(d["pmax"], d["qmax"], base_conversion),
        "prime_mover_type" => _normalize_prime_mover(d["type"]),
        "active_power_limits" =>
            _min_max_dict(d["pmin"] * base_conversion, d["pmax"] * base_conversion),
        "reactive_power_limits" =>
            _min_max_dict(d["qmin"] * base_conversion, d["qmax"] * base_conversion),
        "ramp_limits" => _calculate_ramp_limit_dict(d, gen_name),
        "time_limits" => nothing,
        "operation_cost" => _zero_hydro_generation_cost_dict(),
        "base_power" => mbase,
    )
end

"""
Translate one PowerModels generator row tagged for hydro-turbine (YAML 
target `HydroTurbine`) into a HydroDispatch-shaped dict.

PowerModels has no way to define storage parameters for generators, 
so even hydro-turbine entries can only be built as a HydroDispatch.
"""
function make_hydro_reservoir(
    gen_name::AbstractString,
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator,
)
    mbase = _resolve_mbase(d, sys_mbase, gen_name)
    base_conversion = sys_mbase / mbase
    return Dict{String, Any}(
        "id" => getid!(ids, :HydroDispatch, d["index"]),
        "name" => String(gen_name),
        "available" => Bool(d["gen_status"]),
        "bus" => getid!(ids, :ACBus, d["gen_bus"]),
        "active_power" => d["pg"] * base_conversion,
        "reactive_power" => d["qg"] * base_conversion,
        "rating" => _calculate_gen_rating(d["pmax"], d["qmax"], base_conversion),
        "prime_mover_type" => _normalize_prime_mover(d["type"]),
        "active_power_limits" =>
            _min_max_dict(d["pmin"] * base_conversion, d["pmax"] * base_conversion),
        "reactive_power_limits" =>
            _min_max_dict(d["qmin"] * base_conversion, d["qmax"] * base_conversion),
        "ramp_limits" => _calculate_ramp_limit_dict(d, gen_name),
        "time_limits" => nothing,
        "operation_cost" => _zero_hydro_generation_cost_dict(),
        "base_power" => mbase,
    )
end

"""
Translate one PowerModels generator row tagged for renewable-dispatch into
a RenewableDispatch-shaped dict. Computed rating capped at `mbase`.
"""
function make_renewable_dispatch(
    gen_name::AbstractString,
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator,
)
    mbase = _resolve_mbase(d, sys_mbase, gen_name)
    base_conversion = sys_mbase / mbase
    rating = _calculate_gen_rating(d["pmax"], d["qmax"], base_conversion)
    if rating > mbase
        @warn "rating is larger than base power for $gen_name, setting to $mbase"
        rating = mbase
    end
    return Dict{String, Any}(
        "id" => getid!(ids, :RenewableDispatch, d["index"]),
        "name" => String(gen_name),
        "available" => Bool(d["gen_status"]),
        "bus" => getid!(ids, :ACBus, d["gen_bus"]),
        "active_power" => d["pg"] * base_conversion,
        "reactive_power" => d["qg"] * base_conversion,
        "rating" => rating * base_conversion,
        "prime_mover_type" => _normalize_prime_mover(d["type"]),
        "reactive_power_limits" =>
            _min_max_dict(d["qmin"] * base_conversion, d["qmax"] * base_conversion),
        "power_factor" => 1.0,
        "operation_cost" => _zero_renewable_generation_cost_dict(),
        "base_power" => mbase,
    )
end

"""
Translate one PowerModels generator row tagged for renewable-non-dispatch
into a RenewableNonDispatch-shaped dict.
"""
function make_renewable_non_dispatch(
    gen_name::AbstractString,
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator,
)
    mbase = _resolve_mbase(d, sys_mbase, gen_name)
    base_conversion = sys_mbase / mbase
    return Dict{String, Any}(
        "id" => getid!(ids, :RenewableNonDispatch, d["index"]),
        "name" => String(gen_name),
        "available" => Bool(d["gen_status"]),
        "bus" => getid!(ids, :ACBus, d["gen_bus"]),
        "active_power" => d["pg"] * base_conversion,
        "reactive_power" => d["qg"] * base_conversion,
        "rating" => float(d["pmax"]) * base_conversion,
        "prime_mover_type" => _normalize_prime_mover(d["type"]),
        "power_factor" => 1.0,
        "base_power" => mbase,
    )
end

"""
Emit warnings for generator rows whose `pmin`/`pmax`/`pg` values look more
like a motor load than a generator. Mirrors PSY's depreciated helper
`_is_likely_motor_load`.

This is purely diagnostic — the row still gets parsed as a ThermalStandard-
shaped dict with negative active-power limits. The warning text tells the
user they can convert the entry to a MotorLoad-shaped dict downstream if
more accurate motor modeling is desired.
"""
function _is_likely_motor_load(d::Dict, gen_name::AbstractString)
    if d["pmin"] < 0 && d["pmax"] < 0 && d["pg"] < 0
        @warn "Generator $gen_name is likely a motor load with negative active power: $(d["pg"]) and negative power limits: (min = $(d["pmin"]), max = $(d["pmax"])) \
        this component will be parsed as a thermal generator with negative active power limits. You can convert the device to a MotorLoad for more accurate modeling."
    end
    if d["pmin"] == 0 && d["pmax"] == 0 && d["pg"] < 0
        @warn "Generator $gen_name is likely a motor load with negative active power: $(d["pg"]) and undefined active power limits \
        this component will be parsed as a thermal generator with negative active power injection. You can convert the device to a MotorLoad for more accurate modeling."
    end
    if d["pmin"] < 0 && d["pmax"] == 0
        @warn "Generator $gen_name is likely something that is not a ThermalGenerators with negative power limits: (min = $(d["pmin"]), max = $(d["pmax"])) \
        this component will be parsed as a thermal generator with negative active power limits. Check this entry for more accurate modeling."
    end
    return nothing
end

"""
Translate the `mpc.gencost` attachment on a thermal generator row into a
`(variable_cost_dict, fixed_cost)` pair.

Output dict shapes mirror `sienna_to_json/common.jl`:
  - `get_variable_cost(::CostCurve)` for the outer `CostCurve` dict,
  - `get_value_curve(::InputOutputCurve)` for the `value_curve` wrapper,
  - `get_function_data(::PiecewiseLinearData|::QuadraticFunctionData)` for
    the `function_data` payload.

Two MATPOWER cost models are supported:
  - `model == 1` → piecewise-linear cost. `d["cost"]` is the interleaved
    `[p1, c1, p2, c2, ...]` MATPOWER layout.
  - `model == 2` → polynomial cost with the highest-degree coefficient
    first.
"""
function _thermal_variable_cost_and_fixed(d::Dict, sys_mbase::Float64)
    model = Int(d["model"])
    if model == 1
        cost_component = d["cost"]
        power_p = [v for (i, v) in enumerate(cost_component) if isodd(i)]
        cost_p = [v for (i, v) in enumerate(cost_component) if iseven(i)]
        points = collect(zip(float.(power_p), float.(cost_p)))
        # FLAG: single-point piecewise will BoundsError on points[2] below.
        first_x, first_y = points[1]
        second_x, second_y = points[2]
        first_slope = (second_y - first_y) / (second_x - first_x)
        fixed = max(0.0, first_y - first_slope * first_x)
        adjusted_points =
            [Dict{String, Any}("x" => x, "y" => y - fixed) for (x, y) in points]
        function_data = Dict{String, Any}(
            "function_type" => "PIECEWISE_LINEAR",
            "points" => adjusted_points,
        )
    elseif model == 2
        coeffs = Dict{Int, Float64}()
        for (i, c) in enumerate(reverse(float.(d["cost"][1:(end - 1)])))
            coeffs[i] = c / sys_mbase^i
        end
        if !(keys(coeffs) ⊆ Set((0, 1, 2)))
            throw(
                ArgumentError(
                    "Can only handle polynomials up to degree two; given coefficients $coeffs",
                ),
            )
        end
        function_data = Dict{String, Any}(
            "function_type" => "QUADRATIC",
            "quadratic_term" => get(coeffs, 2, 0.0),
            "proportional_term" => get(coeffs, 1, 0.0),
            "constant_term" => get(coeffs, 0, 0.0),
        )
        fixed = (get(d, "ncost", 0) >= 1) ? float(last(d["cost"])) : 0.0
    else
        throw(ArgumentError("Unrecognized mpc.gencost model code: $model"))
    end

    # FLAG: power_units = "DEVICE_BASE" intentionally diverges from the
    # placeholder dicts, which use "NATURAL_UNITS". DEVICE_BASE matches PSY
    # 997 (`CostCurve(InputOutputCurve(...), UnitSystem.DEVICE_BASE)`); the
    # divisor (sys_mbase^i for polynomial, implicit p.u. axis for piecewise)
    # is what makes DEVICE_BASE the right tag for real data. If the parser
    # ever produces NATURAL_UNITS-scaled coefficients here, this string must
    # change in lockstep.
    variable_dict = Dict{String, Any}(
        "variable_cost_type" => "COST",
        "power_units" => "DEVICE_BASE",
        "value_curve" => Dict{String, Any}(
            "curve_type" => "INPUT_OUTPUT",
            "function_data" => function_data,
        ),
    )
    return variable_dict, fixed
end

"""
Translate one PowerModels generator row tagged for thermal into a
ThermalStandard-shaped dict.

The PSY-side `ext` fields (`r`/`x`/`rt`/`xt` source impedances) have no
home in the OpenAPI `ThermalStandard` schema and are dropped.
"""
function make_thermal_gen(
    gen_name::AbstractString,
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator,
)
    mbase = _resolve_mbase(d, sys_mbase, gen_name)
    base_conversion = sys_mbase / mbase
    _is_likely_motor_load(d, gen_name)

    if haskey(d, "model")
        variable_dict, fixed = _thermal_variable_cost_and_fixed(d, sys_mbase)
        # FLAG: d["startup"]/d["shutdown"] are assumed to be scalar floats —
        # true for MATPOWER's mpc.gencost (table B-4). PSS/E may not carry
        # these on generator rows; if a PTI test case throws KeyError here,
        # add a defensive `get(d, "startup", 0.0)` (and same for shutdown).
        startup = float(d["startup"])
        shutdn = float(d["shutdown"])
    else
        @warn "Generator cost data not included for Generator: $gen_name"
        placeholder = _zero_thermal_generation_cost_dict()
        variable_dict = placeholder["variable"]
        fixed = placeholder["fixed"]
        startup = placeholder["start_up"]
        shutdn = placeholder["shut_down"]
    end

    operation_cost = Dict{String, Any}(
        "cost_type" => "THERMAL",
        "variable" => variable_dict,
        "fixed" => fixed,
        "start_up" => startup,
        "shut_down" => shutdn,
    )

    return Dict{String, Any}(
        "id" => getid!(ids, :ThermalStandard, d["index"]),
        "name" => String(gen_name),
        "status" => Bool(d["gen_status"]),
        "available" => Bool(d["gen_status"]),
        "bus" => getid!(ids, :ACBus, d["gen_bus"]),
        "active_power" => d["pg"] * base_conversion,
        "reactive_power" => d["qg"] * base_conversion,
        "rating" => _calculate_gen_rating(d["pmax"], d["qmax"], base_conversion),
        "prime_mover_type" => _normalize_prime_mover(d["type"]),
        "fuel_type" => _normalize_fuel(d["fuel"]),
        "active_power_limits" =>
            _min_max_dict(d["pmin"] * base_conversion, d["pmax"] * base_conversion),
        "reactive_power_limits" =>
            _min_max_dict(d["qmin"] * base_conversion, d["qmax"] * base_conversion),
        "ramp_limits" => _calculate_ramp_limit_dict(d, gen_name),
        "time_limits" => nothing,
        "operation_cost" => operation_cost,
        "base_power" => mbase,
    )
end

"""
Translate one PowerModels generator row tagged for synchronous-condenser
into a SynchronousCondenser-shaped dict.

The PSY-side `ext` (`r`/`x`/`rt`/`xt`) is dropped.
"""
function make_synchronous_condenser(
    gen_name::AbstractString,
    d::Dict,
    sys_mbase::Float64,
    ids::IDGenerator,
)
    mbase = _resolve_mbase(d, sys_mbase, gen_name)
    base_conversion = sys_mbase / mbase
    return Dict{String, Any}(
        "id" => getid!(ids, :SynchronousCondenser, d["index"]),
        "name" => String(gen_name),
        "available" => Bool(d["gen_status"]),
        "bus" => getid!(ids, :ACBus, d["gen_bus"]),
        "reactive_power" => d["qg"] * base_conversion,
        "rating" => max(abs(d["qmax"]), abs(d["qmin"])) * base_conversion,
        "reactive_power_limits" =>
            _min_max_dict(d["qmin"] * base_conversion, d["qmax"] * base_conversion),
        "base_power" => mbase,
    )
end

"""
For each generator, return a NamedTuple of per-OpenAPI-type sub-collections.

Dispatch is driven by `generator_mapping_pm.yaml`, storage is handled by `read_storage!`.

# Returns

`(; thermal_standard, hydro_dispatch, renewable_dispatch, renewable_non_dispatch,
synchronous_condenser)` — each field is a homogeneous `Dict{String,
Dict{String, Any}}` keyed by generator name.
"""
function read_gen!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading generator data"
    data = pm_data.data
    thermal_standard = Dict{String, Dict{String, Any}}()
    hydro_dispatch = Dict{String, Dict{String, Any}}()
    renewable_dispatch = Dict{String, Dict{String, Any}}()
    renewable_non_dispatch = Dict{String, Dict{String, Any}}()
    synchronous_condenser = Dict{String, Dict{String, Any}}()
    if !haskey(data, "gen")
        @error "There are no Generators in this file"
        return (;
            thermal_standard,
            hydro_dispatch,
            renewable_dispatch,
            renewable_non_dispatch,
            synchronous_condenser,
        )
    end

    raw_mapping = get(kwargs, :generator_mapping, _GENERATOR_MAPPING_FILE)
    mapping = if raw_mapping isa AbstractString
        try
            _get_generator_mapping(String(raw_mapping))
        catch e
            @error "Error loading generator mapping $(raw_mapping)"
            rethrow(e)
        end
    else
        raw_mapping
    end

    sys_mbase = float(data["baseMVA"])
    _get_name = get(kwargs, :gen_name_formatter, _get_pm_dict_name)

    for (_, pm_gen) in data["gen"]
        gen_name = String(_get_name(pm_gen))
        pm_gen["fuel"] = get(pm_gen, "fuel", "OTHER")
        pm_gen["type"] = get(pm_gen, "type", "OT")

        gen_type = _get_generator_type(pm_gen["fuel"], pm_gen["type"], mapping)
        generator, bucket = if gen_type === :ThermalStandard
            make_thermal_gen(gen_name, pm_gen, sys_mbase, ids), thermal_standard
        elseif gen_type === :HydroDispatch
            make_hydro_dispatch(gen_name, pm_gen, sys_mbase, ids), hydro_dispatch
        elseif gen_type === :HydroTurbine
            make_hydro_reservoir(gen_name, pm_gen, sys_mbase, ids), hydro_dispatch
        elseif gen_type === :RenewableDispatch
            make_renewable_dispatch(gen_name, pm_gen, sys_mbase, ids), renewable_dispatch
        elseif gen_type === :RenewableNonDispatch
            make_renewable_non_dispatch(gen_name, pm_gen, sys_mbase, ids),
            renewable_non_dispatch
        elseif gen_type === :SynchronousCondenser
            make_synchronous_condenser(gen_name, pm_gen, sys_mbase, ids),
            synchronous_condenser
        elseif gen_type === :EnergyReservoirStorage
            @warn "EnergyReservoirStorage should be defined as a PowerModels storage... Skipping"
            continue
        else
            @error "Skipping unsupported generator" gen_type
            continue
        end

        haskey(bucket, gen_name) && throw(
            DataFormatError(
                "Found duplicate generator name $gen_name; consider passing a `gen_name_formatter` kwarg",
            ),
        )
        bucket[gen_name] = generator
    end
    return (;
        thermal_standard,
        hydro_dispatch,
        renewable_dispatch,
        renewable_non_dispatch,
        synchronous_condenser,
    )
end

# =============================================================================
# Branches
# =============================================================================

"""
Set `d[group_key]` to the canonical OpenAPI `winding_group_number` 
string for the phase-shift angle (in radians) stored at `d[angle_key]`.
"""
function _add_vector_control_group!(d::Dict, angle_key::AbstractString, group_key::AbstractString)
    angle = d[angle_key]
    for (deg, group) in _SHIFT_TO_GROUP_MAP
        if isapprox(rad2deg(angle), deg)
            d[group_key] = group
            return
        end
    end
    d[group_key] = "UNDEFINED"
    return
end

"""
Map PSS/E `COD1`/`COD2`/`COD3` control codes to a
`(is_tap_controllable, is_alpha_controllable)` pair.
"""
function _determine_control_modes(d::Dict, control_flag::AbstractString, tap_key::AbstractString)
    control_code = get(d, control_flag, -99)
    tap = d[tap_key]

    is_tap_controllable = false
    is_alpha_controllable = false

    if control_code == 0
        # No control
    elseif control_code ∈ (1, -1, 2, -2)
        # Reactive Power Control / Voltage Control
        is_tap_controllable = true
    elseif control_code ∈ (3, -3, 4, -4, 5, -5)
        # Active Power / DC-Line / Asymmetric-Active-Power Control
        is_tap_controllable = true
        is_alpha_controllable = true
    elseif control_code == -99
        @warn "Can't determine control objective for the transformer from the $(control_flag) field for $d"
        if d["shift"] != 0.0
            is_alpha_controllable = true
        elseif (tap != 0.0) || (tap != 1.0)
            is_tap_controllable = true
        else
            @warn "Can't determine control objective for the other fields. Will return a TwoWindingTransformer"
        end
    else
        error(d)
    end
    return is_tap_controllable, is_alpha_controllable
end

"""
Build the canonical PowerModels branch name.
"""
function _get_pm_branch_name(device_dict::Dict, bus_f_dict::Dict, bus_t_dict::Dict)
    if haskey(device_dict, "name")
        index = device_dict["name"]
    elseif device_dict["source_id"][1] == "branch" &&
           length(device_dict["source_id"]) > 2
        index = strip(device_dict["source_id"][4])
    elseif (
        device_dict["source_id"][1] == "switch" ||
        device_dict["source_id"][1] == "breaker"
    ) && length(device_dict["source_id"]) > 2
        index = string(device_dict["source_id"][4][2])
    elseif device_dict["source_id"][1] == "transformer" &&
           length(device_dict["source_id"]) > 3
        index = strip(device_dict["source_id"][5])
    else
        index = device_dict["index"]
    end
    return "$(bus_f_dict["name"])-$(bus_t_dict["name"])-i_$index"
end

"""
Return `true` if `device_dict` was synthesized from a PSS/E branch-shaped
section (branch/switch/breaker/transformer).
"""
function _is_psse_branch_source_id(device_dict::Dict)
    if !haskey(device_dict, "source_id") || isempty(device_dict["source_id"])
        return false
    end
    return device_dict["source_id"][1] in ("branch", "switch", "breaker", "transformer")
end

"""
PSS/E-specific branch naming that disambiguates parallel branches between
the same bus pair with a per-pair counter.
"""
function _get_pm_branch_name_with_counter!(
    device_dict::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    branch_pair_counts::Dict{Tuple{String, String}, Int},
)
    if _is_psse_branch_source_id(device_dict)
        pair_key = (String(bus_f_dict["name"]), String(bus_t_dict["name"]))
        branch_pair_counts[pair_key] = get(branch_pair_counts, pair_key, 0) + 1
        index = branch_pair_counts[pair_key]
        return "$(pair_key[1])-$(pair_key[2])-i_$index"
    end
    return _get_pm_branch_name(device_dict, bus_f_dict, bus_t_dict)
end

"""
Resolve a branch rating field.
"""
function _get_rating(
    branch_type::AbstractString,
    name::AbstractString,
    line_data::Dict,
    key::AbstractString,
)
    haskey(line_data, key) || return key == "rate_a" ? INFINITE_BOUND : nothing
    if isapprox(line_data[key], 0.0)
        @info "$branch_type $name rating value: $(line_data[key]). Unbounded value implied as per PSSe Manual"
        return INFINITE_BOUND
    end
    return line_data[key]
end

"""
MATPOWER branch-type dispatcher.
"""
function get_branch_type_matpower(d::Dict)
    tap = d["tap"]
    shift = d["shift"]
    is_transformer = d["transformer"]
    if !is_transformer
        is_transformer = (tap != 0.0) && (tap != 1.0) || (shift != 0.0)
    end
    is_transformer || return :Line

    _add_vector_control_group!(d, "shift", "group_number")
    if d["group_number"] == "UNDEFINED"
        return :PhaseShiftingTransformer
    elseif tap != 1.0
        return :TapTransformer
    else
        return :TwoWindingTransformer
    end
end

"""
PSS/E branch-type dispatcher.
"""
function get_branch_type_psse(d::Dict)
    if d["br_r"] == 0.0 && d["br_x"] == 0.0
        return :DiscreteControlledACBranch
    end

    is_transformer = d["transformer"]
    tap = d["tap"]
    if !is_transformer
        if (tap != 0.0) && (tap != 1.0)
            @warn "Transformer $d has tap ratio $tap, which is not 0.0 or 1.0; this is not a valid value for a Line. Parsing entry as a Transformer"
            is_transformer = true
            _add_vector_control_group!(d, "shift", "group_number")
        else
            return :Line
        end
    end

    _add_vector_control_group!(d, "shift", "group_number")
    is_tap_controllable, is_alpha_controllable = _determine_control_modes(d, "COD1", "tap")
    if d["group_number"] == "UNDEFINED" || is_alpha_controllable
        return :PhaseShiftingTransformer
    elseif (is_tap_controllable || (tap != 1.0)) && d["group_number"] != "UNDEFINED"
        return :TapTransformer
    elseif !is_tap_controllable && d["group_number"] != "UNDEFINED"
        return :TwoWindingTransformer
    else
        error("Couldn't infer the branch type for branch $d")
    end
end

"""
Look up (or mint) the Arc id for an ordered bus pair, populating the
`arcs` accumulator on first sight. Parallel branches between the same
buses share an Arc id.
"""
function _get_or_mint_arc_id!(
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    bus_f_id::Int,
    bus_t_id::Int,
)
    arc_id = getid!(ids, :Arc, (bus_f_id, bus_t_id))
    if !haskey(arcs, arc_id)
        arcs[arc_id] = Dict{String, Any}(
            "id" => arc_id,
            "from_id" => bus_f_id,
            "to_id" => bus_t_id,
        )
    end
    return arc_id
end

"""
Resolve the `control_objective` field for a 2-winding transformer dict.
Supports formatters that return a plain integer COD code or a string
already in the OpenAPI enum vocabulary. Integer returns are normalized 
via [`_normalize_control_objective`].
"""
function _resolve_control_objective(d::Dict, name::AbstractString, formatter)
    if formatter !== nothing
        result = formatter(name)
        if result !== nothing
            return result isa AbstractString ? String(result) :
                   _normalize_control_objective(result)
        end
    end
    return _normalize_control_objective(get(d, "COD1", -99))
end

"""
Translate one PowerModels branch row into a Line-shaped dict.
The PSY-side `ext` field is dropped: OpenAPI's Line schema has no `ext`.
"""
function make_line(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    pf = get(d, "pf", 0.0)
    qf = get(d, "qf", 0.0)
    available_value = d["br_status"] == 1
    # PSY checks `get_bustype(bus) == ACBusTypes.ISOLATED` against the PSY
    # enum; we compare against the canonical string emitted by `read_bus!`.
    if bus_f_dict["bustype"] == "ISOLATED" || bus_t_dict["bustype"] == "ISOLATED"
        available_value = false
    end

    arc_id =
        _get_or_mint_arc_id!(ids, arcs, Int(bus_f_dict["id"]), Int(bus_t_dict["id"]))

    return Dict{String, Any}(
        "id" => getid!(ids, :Line, d["index"]),
        "name" => String(name),
        "available" => available_value,
        "active_power_flow" => pf,
        "reactive_power_flow" => qf,
        "arc" => arc_id,
        "r" => d["br_r"],
        "x" => d["br_x"],
        "b" => Dict{String, Any}("from" => d["b_fr"], "to" => d["b_to"]),
        "rating" => _get_rating("Line", name, d, "rate_a"),
        "rating_b" => _get_rating("Line", name, d, "rate_b"),
        "rating_c" => _get_rating("Line", name, d, "rate_c"),
        "angle_limits" => _min_max_dict(d["angmin"], d["angmax"]),
    )
end

"""
Translate one PowerModels switch/breaker row into a DiscreteControlledACBranch-
shaped dict.

Called by [`read_switch_breaker!`] when explicit switch/breaker sections
are present in PSS/E. The zero-impedance fallback path for plain branches
is handled by [`_make_switch_from_zero_impedance_line`] instead.
"""
function make_switch_breaker(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    section::AbstractString,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    arc_id =
        _get_or_mint_arc_id!(ids, arcs, Int(bus_f_dict["id"]), Int(bus_t_dict["id"]))
    state = Int(d["state"])
    return Dict{String, Any}(
        "id" => getid!(ids, :DiscreteControlledACBranch, (String(section), d["index"])),
        "name" => String(name),
        "available" => Bool(state),
        "active_power_flow" => d["active_power_flow"],
        "reactive_power_flow" => d["reactive_power_flow"],
        "arc" => arc_id,
        "r" => d["r"],
        "x" => d["x"],
        "rating" => d["rating"],
        "discrete_branch_type" =>
            _DISCRETE_BRANCH_TYPE_MAP[Int(d["discrete_branch_type"])],
        "branch_status" => _BRANCH_STATUS_MAP[state],
    )
end

"""
Translate a zero-impedance branch row (PSS/E `br_r == 0 && br_x == 0`) into
a DiscreteControlledACBranch-shaped dict tagged as a SWITCH.
"""
function _make_switch_from_zero_impedance_line(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    pf = get(d, "pf", 0.0)
    qf = get(d, "qf", 0.0)
    available_value = d["br_status"] == 1
    if bus_f_dict["bustype"] == "ISOLATED" || bus_t_dict["bustype"] == "ISOLATED"
        available_value = false
    end
    status_value = available_value ? "CLOSED" : "OPEN"

    @warn "Branch $name has zero impedance and available = $available_value; converting 
        to a DiscreteControlledACBranch of type SWITCH with available = $available_value 
        and branch_status = $status_value"

    arc_id =
        _get_or_mint_arc_id!(ids, arcs, Int(bus_f_dict["id"]), Int(bus_t_dict["id"]))
    return Dict{String, Any}(
        # Tag the section as "branch" so the id can't collide with switches
        # or breakers parsed by `read_switch_breaker!`.
        "id" => getid!(ids, :DiscreteControlledACBranch, ("branch", d["index"])),
        "name" => String(name),
        "available" => Bool(available_value),
        "active_power_flow" => pf,
        "reactive_power_flow" => qf,
        "arc" => arc_id,
        "r" => d["br_r"],
        "x" => d["br_x"],
        "rating" => _get_rating("Line", name, d, "rate_a"),
        "discrete_branch_type" => "SWITCH",
        "branch_status" => status_value,
    )
end

"""
Build the TransformerCircuit dict shared by all three 2W transformer
variants. `tap`, `alpha`, and `control_objective` are optional; the caller
sets them via keyword args when the variant needs them.
"""
function _make_transformer_2w_circuit(
    d::Dict,
    arc_id::Int,
    available_value::Bool,
    circuit_id::Int;
    tap::Union{Float64, Nothing} = nothing,
    alpha::Union{Float64, Nothing} = nothing,
    control_objective::Union{String, Nothing} = nothing,
    rating_label::AbstractString = "TransformerCircuit",
    name::AbstractString = "",
)
    return Dict{String, Any}(
        "id" => circuit_id,
        "available" => available_value,
        "arc" => arc_id,
        "tap" => tap,
        "alpha" => alpha,
        "r" => d["br_r"],
        "x" => d["br_x"],
        "control_objective" => control_objective,
        "rating" => _get_rating(rating_label, name, d, "rate_a"),
        "rating_b" => _get_rating(rating_label, name, d, "rate_b"),
        "rating_c" => _get_rating(rating_label, name, d, "rate_c"),
        "active_power_flow" => get(d, "pf", 0.0),
        "reactive_power_flow" => get(d, "qf", 0.0),
        "base_power" => d["base_power"],
        # PSS/E base voltages may differ from each bus's nominal base_kv —
        # the upstream parser pulls these from the transformer winding
        # records, not the bus rows.
        "base_voltage_primary" => d["base_voltage_from"],
        "base_voltage_secondary" => d["base_voltage_to"],
    )
end

"""
Build the TwoWindingTransformer holder dict. `magnetizing_shunt` carries
the shunt originally attached to the "from" side of the branch (PSY's
`primary_shunt` field). `winding_group_number` still travels here for
downstream consumers that need it; POM's schema ignores unknown keys.
"""
function _make_two_winding_transformer_holder(
    xfrm_id::Int,
    name::AbstractString,
    circuit_id::Int,
    d::Dict,
)
    return Dict{String, Any}(
        "id" => xfrm_id,
        "name" => String(name),
        "circuit" => circuit_id,
        "magnetizing_shunt" => _complex_to_dict(d["g_fr"] + d["b_fr"] * im),
        "winding_group_number" => d["group_number"],
    )
end

"""
Common preamble for every 2W emitter: resolve availability, mint the arc,
mint the circuit id, push the TransformerCircuit dict into the accumulator,
and mint the holder id. Returns `(xfrm_id, circuit_id, arc_id, available_value)`.
"""
function _prepare_2w_ids!(
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    available_value = d["br_status"] == 1
    if bus_f_dict["bustype"] == "ISOLATED" || bus_t_dict["bustype"] == "ISOLATED"
        available_value = false
    end
    arc_id =
        _get_or_mint_arc_id!(ids, arcs, Int(bus_f_dict["id"]), Int(bus_t_dict["id"]))
    xfrm_id = getid!(ids, :TwoWindingTransformer, d["index"])
    circuit_id = getid!(ids, :TransformerCircuit, (:TwoWinding, d["index"]))
    return xfrm_id, circuit_id, arc_id, available_value
end

"""
Translate one PowerModels branch row into a `(holder_dict, circuit_dict)`
pair — a TwoWindingTransformer + its TransformerCircuit. The circuit
carries r/x, ratings, and flows; the holder is the named entity that owns
the electricals via FK.
"""
function make_transformer_2w(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    xfrm_id, circuit_id, arc_id, available_value =
        _prepare_2w_ids!(d, bus_f_dict, bus_t_dict, ids, arcs)

    circuit = _make_transformer_2w_circuit(
        d,
        arc_id,
        available_value,
        circuit_id;
        rating_label = "TwoWindingTransformer",
        name = name,
    )
    transformer_circuits[circuit_id] = circuit

    return _make_two_winding_transformer_holder(xfrm_id, name, circuit_id, d)
end

"""
Translate one PowerModels branch row into a `(holder, circuit)` pair for
the tap-controlled variant — same shape as [`make_transformer_2w`] but
with `tap` and `control_objective` populated on the circuit.
"""
function make_tap_transformer(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    xfrm_id, circuit_id, arc_id, available_value =
        _prepare_2w_ids!(d, bus_f_dict, bus_t_dict, ids, arcs)

    control_objective = _resolve_control_objective(
        d,
        name,
        get(kwargs, :transformer_control_objective_formatter, nothing),
    )

    circuit = _make_transformer_2w_circuit(
        d,
        arc_id,
        available_value,
        circuit_id;
        tap = d["tap"],
        control_objective = control_objective,
        rating_label = "TapTransformer",
        name = name,
    )
    transformer_circuits[circuit_id] = circuit

    return _make_two_winding_transformer_holder(xfrm_id, name, circuit_id, d)
end

"""
Translate one PowerModels branch row into a `(holder, circuit)` pair for
the phase-shifting variant — `tap`, `alpha` (from `d["shift"]`), and
`control_objective` all populated on the circuit.
"""
function make_phase_shifting_transformer(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    xfrm_id, circuit_id, arc_id, available_value =
        _prepare_2w_ids!(d, bus_f_dict, bus_t_dict, ids, arcs)

    control_objective = _resolve_control_objective(
        d,
        name,
        get(kwargs, :transformer_control_objective_formatter, nothing),
    )

    circuit = _make_transformer_2w_circuit(
        d,
        arc_id,
        available_value,
        circuit_id;
        tap = d["tap"],
        alpha = d["shift"],
        control_objective = control_objective,
        rating_label = "PhaseShiftingTransformer",
        name = name,
    )
    transformer_circuits[circuit_id] = circuit

    return _make_two_winding_transformer_holder(xfrm_id, name, circuit_id, d)
end

"""
Branch dict constructor. The `branch_type` Symbol is resolved upstream
(`read_branch!`) so the caller can use the same value to gate the ICT
attachment loop.

The three 2W transformer variants (`:TwoWindingTransformer`,
`:TapTransformer`, `:PhaseShiftingTransformer`) all return a
`TwoWindingTransformer` holder dict and push their `TransformerCircuit`
into `transformer_circuits` — the variant determines which circuit fields
(tap, alpha, control_objective) get populated, not which OpenAPI type the
holder is.
"""
function make_branch(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    branch_type::Symbol,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    if branch_type === :Line
        return make_line(name, d, bus_f_dict, bus_t_dict, ids, arcs)
    elseif branch_type === :TwoWindingTransformer
        return make_transformer_2w(
            name, d, bus_f_dict, bus_t_dict, ids, arcs, transformer_circuits; kwargs...,
        )
    elseif branch_type === :TapTransformer
        return make_tap_transformer(
            name, d, bus_f_dict, bus_t_dict, ids, arcs, transformer_circuits; kwargs...,
        )
    elseif branch_type === :PhaseShiftingTransformer
        return make_phase_shifting_transformer(
            name, d, bus_f_dict, bus_t_dict, ids, arcs, transformer_circuits; kwargs...,
        )
    elseif branch_type === :DiscreteControlledACBranch
        return _make_switch_from_zero_impedance_line(
            name,
            d,
            bus_f_dict,
            bus_t_dict,
            ids,
            arcs,
        )
    end

    @error "Skipping branch $name: type $branch_type not yet implemented"
    return nothing
end

"""
For each branch return a NamedTuple of per-OpenAPI-type sub-collections.
Populates `arcs` with one Arc dict per unique ordered bus pair that
appears as a branch endpoint; parallel branches share the same Arc id.
Populates `transformer_circuits` with one TransformerCircuit dict per 2W
transformer holder (all three 2W variants — plain, tap, phase-shifting —
share this table).

# Returns

`(; line, two_winding_transformer, discrete_controlled_ac_branch)` — each
field is a homogeneous `Dict{String, Dict{String, Any}}` keyed by branch
name. All 2W transformer variants collapse into `two_winding_transformer`;
their electricals live on the separately-accumulated
`transformer_circuits`. `discrete_controlled_ac_branch` captures only the
zero-impedance switch path emitted from `read_branch!`; switches and
breakers parsed by [`read_switch_breaker!`] live in their own separate
collections.

**ICT attachment**: when called with non-empty `ict_instances` (from
[`read_impedance_correction!`]) and a
`supplemental_attribute_associations` accumulator, each 2W transformer
gets one ICT association row appended. The accumulator is mutated in
place; pass the same Vector to [`read_3w_transformer!`] so all
transformer↔ICT links collect into one collection.
"""
function read_branch!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}},
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}};
    ict_instances::Dict{Tuple{Int, String}, Dict{String, Any}} =
        Dict{Tuple{Int, String}, Dict{String, Any}}(),
    supplemental_attribute_associations::Vector{Dict{String, Any}} =
        Dict{String, Any}[],
    kwargs...,
)
    @info "Reading branch data"
    data = pm_data.data
    line = Dict{String, Dict{String, Any}}()
    two_winding_transformer = Dict{String, Dict{String, Any}}()
    discrete_controlled_ac_branch = Dict{String, Dict{String, Any}}()
    if !haskey(data, "branch")
        @info "There is no Branch data in this file"
        return (; line, two_winding_transformer, discrete_controlled_ac_branch)
    end

    _get_name = get(kwargs, :branch_name_formatter, nothing)
    branch_pair_counts = Dict{Tuple{String, String}, Int}()
    source_type = data["source_type"]

    # All three 2W variants share this bucket. TransformerCircuit fields
    # differ by variant, but the holder dict shape is the same.
    _is_2w_variant(t::Symbol) =
        t === :TwoWindingTransformer ||
        t === :TapTransformer ||
        t === :PhaseShiftingTransformer

    for d in values(data["branch"])
        bus_f_dict = bus_dicts[d["f_bus"]]
        bus_t_dict = bus_dicts[d["t_bus"]]
        name = if isnothing(_get_name)
            if source_type == "pti"
                _get_pm_branch_name_with_counter!(
                    d,
                    bus_f_dict,
                    bus_t_dict,
                    branch_pair_counts,
                )
            else
                _get_pm_branch_name(d, bus_f_dict, bus_t_dict)
            end
        else
            _get_name(d, bus_f_dict, bus_t_dict)
        end
        name = String(name)

        branch_type = if source_type == "matpower"
            get_branch_type_matpower(d)
        elseif source_type == "pti"
            get_branch_type_psse(d)
        else
            error("Source Type $source_type not supported")
        end
        if d["transformer"] && branch_type === :Line
            throw(
                DataFormatError(
                    "Branch data mismatched, cannot build the branch correctly for $d",
                ),
            )
        end

        branch = make_branch(
            name,
            d,
            bus_f_dict,
            bus_t_dict,
            branch_type,
            ids,
            arcs,
            transformer_circuits;
            kwargs...,
        )
        isnothing(branch) && continue

        bucket = if branch_type === :Line
            line
        elseif _is_2w_variant(branch_type)
            two_winding_transformer
        elseif branch_type === :DiscreteControlledACBranch
            discrete_controlled_ac_branch
        else
            error("Unexpected branch_type $branch_type produced a non-nothing dict")
        end

        haskey(bucket, name) && throw(
            DataFormatError(
                "Found duplicate branch name $name; consider passing a `branch_name_formatter` kwarg",
            ),
        )
        bucket[name] = branch

        if _is_2w_variant(branch_type)
            _attach_impedance_correction_tables!(
                branch,
                d,
                ict_instances,
                supplemental_attribute_associations;
                is_3w = false,
            )
        end
    end
    return (; line, two_winding_transformer, discrete_controlled_ac_branch)
end

# =============================================================================
# 3-Winding Transformers
# =============================================================================

"""
Build the canonical 3W transformer name
"""
function _get_pm_3w_name(
    device_dict::Dict,
    bus_primary_dict::Dict,
    bus_secondary_dict::Dict,
    bus_tertiary_dict::Dict,
)
    ckt = device_dict["circuit"]
    return "$(bus_primary_dict["name"])-$(bus_secondary_dict["name"])-$(bus_tertiary_dict["name"])-i_$ckt"
end

"""
Dispatcher returns `:ThreeWindingTransformer` or `:PhaseShiftingTransformer3W`.
"""
function get_three_winding_transformer_type(d::Dict)
    _add_vector_control_group!(d, "primary_phase_shift_angle", "primary_group_number")
    _add_vector_control_group!(d, "secondary_phase_shift_angle", "secondary_group_number")
    _add_vector_control_group!(d, "tertiary_phase_shift_angle", "tertiary_group_number")
    _, primary_is_alpha_controllable =
        _determine_control_modes(d, "COD1", "primary_turns_ratio")
    _, secondary_is_alpha_controllable =
        _determine_control_modes(d, "COD2", "secondary_turns_ratio")
    _, tertiary_is_alpha_controllable =
        _determine_control_modes(d, "COD3", "tertiary_turns_ratio")
    if d["primary_group_number"] == "UNDEFINED" ||
       d["secondary_group_number"] == "UNDEFINED" ||
       d["tertiary_group_number"] == "UNDEFINED" ||
       primary_is_alpha_controllable ||
       secondary_is_alpha_controllable ||
       tertiary_is_alpha_controllable
        return :PhaseShiftingTransformer3W
    else
        return :ThreeWindingTransformer
    end
end

"""
Mint the three primary-↔-star, secondary-↔-star, tertiary-↔-star Arc ids
for a 3W transformer and append the new arcs into the accumulator.
"""
function _mint_3w_star_arcs!(
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    primary_id::Int,
    secondary_id::Int,
    tertiary_id::Int,
    star_id::Int,
)
    return (
        _get_or_mint_arc_id!(ids, arcs, primary_id, star_id),
        _get_or_mint_arc_id!(ids, arcs, secondary_id, star_id),
        _get_or_mint_arc_id!(ids, arcs, tertiary_id, star_id),
    )
end

"""
Build a per-winding TransformerCircuit dict for one leg of a 3W
transformer. `alpha` populates only on the phase-shifting variant.
"""
function _make_3w_winding_circuit(
    d::Dict,
    name::AbstractString,
    arc_id::Int,
    circuit_id::Int,
    winding::AbstractString,  # "primary" | "secondary" | "tertiary"
    rating_label::AbstractString;
    alpha::Union{Float64, Nothing} = nothing,
)
    cod_key = winding == "primary" ? "COD1" : winding == "secondary" ? "COD2" : "COD3"
    return Dict{String, Any}(
        "id" => circuit_id,
        "available" => d["available_$winding"],
        "arc" => arc_id,
        "tap" => d["$(winding)_turns_ratio"],
        "alpha" => alpha,
        "r" => d["r_$winding"],
        "x" => d["x_$winding"],
        "control_objective" => _normalize_control_objective(get(d, cod_key, -99)),
        "rating" => _get_rating(rating_label, name, d, "rating_$winding"),
        "active_power_flow" => get(d, "pf", 0.0),
        "reactive_power_flow" => get(d, "qf", 0.0),
        "base_voltage_primary" => d["base_voltage_$winding"],
    )
end

"""
Build the ThreeWindingTransformer holder dict — pairwise mutual impedances
+ base powers + star bus + three TransformerCircuit FKs. Field names track
POM's ThreeWindingTransformer struct (note: POM uses `r_31`/`x_31`, not
`r_13`/`x_13`).
"""
function _make_three_winding_transformer_holder(
    xfrm_id::Int,
    name::AbstractString,
    primary_circuit_id::Int,
    secondary_circuit_id::Int,
    tertiary_circuit_id::Int,
    star_id::Int,
    d::Dict,
)
    return Dict{String, Any}(
        "id" => xfrm_id,
        "name" => String(name),
        "primary_circuit" => primary_circuit_id,
        "secondary_circuit" => secondary_circuit_id,
        "tertiary_circuit" => tertiary_circuit_id,
        "star_bus" => star_id,
        "r_12" => d["r_12"],
        "x_12" => d["x_12"],
        "r_23" => d["r_23"],
        "x_23" => d["x_23"],
        "r_31" => d["r_13"],
        "x_31" => d["x_13"],
        "base_power_12" => d["base_power_12"],
        "base_power_23" => d["base_power_23"],
        "base_power_31" => d["base_power_13"],
        # Extra fields useful downstream; POM's from_json will ignore any
        # that aren't in its struct.
        "magnetizing_shunt" => _complex_to_dict(d["g"] + d["b"] * im),
        "primary_group_number" => get(d, "primary_group_number", nothing),
        "secondary_group_number" => get(d, "secondary_group_number", nothing),
        "tertiary_group_number" => get(d, "tertiary_group_number", nothing),
    )
end

"""
Common preamble for every 3W emitter: resolve star arcs and mint holder +
three circuit ids. Returns
`(xfrm_id, (primary_circuit_id, secondary_circuit_id, tertiary_circuit_id),
(primary_arc, secondary_arc, tertiary_arc), star_id)`.
"""
function _prepare_3w_ids!(
    d::Dict,
    bus_primary_dict::Dict,
    bus_secondary_dict::Dict,
    bus_tertiary_dict::Dict,
    star_bus_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    primary_id = Int(bus_primary_dict["id"])
    secondary_id = Int(bus_secondary_dict["id"])
    tertiary_id = Int(bus_tertiary_dict["id"])
    star_id = Int(star_bus_dict["id"])

    star_arcs =
        _mint_3w_star_arcs!(ids, arcs, primary_id, secondary_id, tertiary_id, star_id)

    xfrm_id = getid!(ids, :ThreeWindingTransformer, d["index"])
    circuit_ids = (
        getid!(ids, :TransformerCircuit, (:ThreeWinding, d["index"], :primary)),
        getid!(ids, :TransformerCircuit, (:ThreeWinding, d["index"], :secondary)),
        getid!(ids, :TransformerCircuit, (:ThreeWinding, d["index"], :tertiary)),
    )
    return xfrm_id, circuit_ids, star_arcs, star_id
end

"""
Translate one PowerModels 3W transformer row into a `(holder_dict,
[primary_circuit_dict, secondary_circuit_dict, tertiary_circuit_dict])`
pair. The four dicts are pushed into caller-owned collections; the
returned holder is the ThreeWindingTransformer entity keyed by name.
"""
function make_3w_transformer(
    name::AbstractString,
    d::Dict,
    bus_primary_dict::Dict,
    bus_secondary_dict::Dict,
    bus_tertiary_dict::Dict,
    star_bus_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}},
)
    xfrm_id, (primary_cid, secondary_cid, tertiary_cid),
    (primary_arc, secondary_arc, tertiary_arc), star_id = _prepare_3w_ids!(
        d,
        bus_primary_dict,
        bus_secondary_dict,
        bus_tertiary_dict,
        star_bus_dict,
        ids,
        arcs,
    )

    transformer_circuits[primary_cid] = _make_3w_winding_circuit(
        d, name, primary_arc, primary_cid, "primary", "ThreeWindingTransformer",
    )
    transformer_circuits[secondary_cid] = _make_3w_winding_circuit(
        d, name, secondary_arc, secondary_cid, "secondary", "ThreeWindingTransformer",
    )
    transformer_circuits[tertiary_cid] = _make_3w_winding_circuit(
        d, name, tertiary_arc, tertiary_cid, "tertiary", "ThreeWindingTransformer",
    )

    return _make_three_winding_transformer_holder(
        xfrm_id, name, primary_cid, secondary_cid, tertiary_cid, star_id, d,
    )
end

"""
Phase-shifting 3W variant. Same holder shape as [`make_3w_transformer`];
each per-winding TransformerCircuit gets its `alpha` populated from
`d["<winding>_phase_shift_angle"]`.
"""
function make_3w_phase_shifting_transformer(
    name::AbstractString,
    d::Dict,
    bus_primary_dict::Dict,
    bus_secondary_dict::Dict,
    bus_tertiary_dict::Dict,
    star_bus_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}},
)
    xfrm_id, (primary_cid, secondary_cid, tertiary_cid),
    (primary_arc, secondary_arc, tertiary_arc), star_id = _prepare_3w_ids!(
        d,
        bus_primary_dict,
        bus_secondary_dict,
        bus_tertiary_dict,
        star_bus_dict,
        ids,
        arcs,
    )

    transformer_circuits[primary_cid] = _make_3w_winding_circuit(
        d, name, primary_arc, primary_cid, "primary", "PhaseShiftingTransformer3W";
        alpha = d["primary_phase_shift_angle"],
    )
    transformer_circuits[secondary_cid] = _make_3w_winding_circuit(
        d, name, secondary_arc, secondary_cid, "secondary", "PhaseShiftingTransformer3W";
        alpha = d["secondary_phase_shift_angle"],
    )
    transformer_circuits[tertiary_cid] = _make_3w_winding_circuit(
        d, name, tertiary_arc, tertiary_cid, "tertiary", "PhaseShiftingTransformer3W";
        alpha = d["tertiary_phase_shift_angle"],
    )

    return _make_three_winding_transformer_holder(
        xfrm_id, name, primary_cid, secondary_cid, tertiary_cid, star_id, d,
    )
end

"""
For each 3-winding transformer return a NamedTuple with one field.
Populates `transformer_circuits` with three TransformerCircuit dicts per
3W transformer (one per winding). Both plain and phase-shifting variants
share the ThreeWindingTransformer holder collection; the variant
determines whether the per-winding circuits carry an `alpha`.

# Returns

`(; three_winding_transformer,)` — a homogeneous
`Dict{String, Dict{String, Any}}` keyed by transformer name.

3W transformers are PSS/E-only; MATPOWER files have no
`data["3w_transformer"]` section and this function returns an empty dict.

**ICT attachment**: when called with non-empty `ict_instances` (from
[`read_impedance_correction!`]) and a
`supplemental_attribute_associations` accumulator, each 3W transformer
gets one ICT association row per winding (primary/secondary/tertiary)
that references a correction table.
"""
function read_3w_transformer!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}},
    arcs::Dict{Int, Dict{String, Any}},
    transformer_circuits::Dict{Int, Dict{String, Any}};
    ict_instances::Dict{Tuple{Int, String}, Dict{String, Any}} =
        Dict{Tuple{Int, String}, Dict{String, Any}}(),
    supplemental_attribute_associations::Vector{Dict{String, Any}} =
        Dict{String, Any}[],
    kwargs...,
)
    @info "Reading 3W transformer data"
    data = pm_data.data
    three_winding_transformer = Dict{String, Dict{String, Any}}()
    if !haskey(data, "3w_transformer")
        @info "There is no 3W transformer data in this file"
        return (; three_winding_transformer)
    end

    _get_name = get(kwargs, :xfrm_3w_name_formatter, _get_pm_3w_name)

    for (_, d) in data["3w_transformer"]
        bus_primary = bus_dicts[d["bus_primary"]]
        bus_secondary = bus_dicts[d["bus_secondary"]]
        bus_tertiary = bus_dicts[d["bus_tertiary"]]
        star_bus = bus_dicts[d["star_bus"]]

        name = String(_get_name(d, bus_primary, bus_secondary, bus_tertiary))
        xfrm_type = get_three_winding_transformer_type(d)

        xfrm = if xfrm_type === :PhaseShiftingTransformer3W
            make_3w_phase_shifting_transformer(
                name,
                d,
                bus_primary,
                bus_secondary,
                bus_tertiary,
                star_bus,
                ids,
                arcs,
                transformer_circuits,
            )
        elseif xfrm_type === :ThreeWindingTransformer
            make_3w_transformer(
                name,
                d,
                bus_primary,
                bus_secondary,
                bus_tertiary,
                star_bus,
                ids,
                arcs,
                transformer_circuits,
            )
        else
            error("Unsupported three winding transformer type $xfrm_type")
        end

        haskey(three_winding_transformer, name) && throw(
            DataFormatError(
                "Found duplicate 3W transformer name $name; consider passing an `xfrm_3w_name_formatter` kwarg",
            ),
        )
        three_winding_transformer[name] = xfrm

        # Per PSY 1781: every 3W transformer (both plain and phase-shifting)
        # gets ICT attachment per winding.
        _attach_impedance_correction_tables!(
            xfrm,
            d,
            ict_instances,
            supplemental_attribute_associations;
            is_3w = true,
        )
    end
    return (; three_winding_transformer)
end

# =============================================================================
# Switches/Breakers, DC Lines, VSC Lines, FACTS
# =============================================================================

"""
Build an `InputOutputCurve`-shaped dict carrying `LinearFunctionData`.
"""
function _linear_io_curve_dict(proportional, constant)
    return Dict{String, Any}(
        "curve_type" => "INPUT_OUTPUT",
        "function_data" => Dict{String, Any}(
            "function_type" => "LINEAR",
            "proportional_term" => float(proportional),
            "constant_term" => float(constant),
        ),
    )
end

"""
For each switch or breaker return a `Dict{String, Dict{String, Any}}` 
mapping each branch name to a DiscreteControlledACBranch-shaped dict.

The argument `section` is either "switch" or "breaker".
"""
function read_switch_breaker!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}},
    arcs::Dict{Int, Dict{String, Any}},
    section::AbstractString;
    kwargs...,
)
    @info "Reading $section data"
    data = pm_data.data
    branches = Dict{String, Dict{String, Any}}()
    if !haskey(data, String(section))
        @info "There is no $section data in this file"
        return branches
    end

    _get_name = get(kwargs, :branch_name_formatter, _get_pm_branch_name)

    for (_, d) in data[String(section)]
        bus_f_dict = bus_dicts[d["f_bus"]]
        bus_t_dict = bus_dicts[d["t_bus"]]
        name = String(_get_name(d, bus_f_dict, bus_t_dict))
        branch = make_switch_breaker(name, d, bus_f_dict, bus_t_dict, section, ids, arcs)
        haskey(branches, name) && throw(
            DataFormatError(
                "Found duplicate $section name $name; consider passing a `branch_name_formatter` kwarg",
            ),
        )
        branches[name] = branch
    end
    return branches
end

"""
Translate one PowerModels dcline row into a HVDC-line-shaped dict.

Forks by `source_type`:
- `"pti"` → TwoTerminalLCCLine
- `"matpower"` → TwoTerminalGenericHVDCLine

The `loss` field is a `TwoTerminalLoss` discriminated union over
`{IncrementalCurve, InputOutputCurve}`. PSY-side `ext` is dropped.
"""
function make_dcline(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    source_type::AbstractString,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    arc_id =
        _get_or_mint_arc_id!(ids, arcs, Int(bus_f_dict["id"]), Int(bus_t_dict["id"]))
    pf = get(d, "pf", 0.0)
    loss_dict = _linear_io_curve_dict(d["loss1"], d["loss0"])

    if source_type == "pti"
        return Dict{String, Any}(
            "id" => getid!(ids, :TwoTerminalLCCLine, d["index"]),
            "name" => String(name),
            "available" => d["available"],
            "arc" => arc_id,
            "active_power_flow" => pf,
            "r" => d["r"],
            "transfer_setpoint" => d["transfer_setpoint"],
            "scheduled_dc_voltage" => d["scheduled_dc_voltage"],
            "rectifier_bridges" => d["rectifier_bridges"],
            "rectifier_delay_angle_limits" => d["rectifier_delay_angle_limits"],
            "rectifier_rc" => d["rectifier_rc"],
            "rectifier_xc" => d["rectifier_xc"],
            "rectifier_base_voltage" => d["rectifier_base_voltage"],
            "inverter_bridges" => d["inverter_bridges"],
            "inverter_extinction_angle_limits" => d["inverter_extinction_angle_limits"],
            "inverter_rc" => d["inverter_rc"],
            "inverter_xc" => d["inverter_xc"],
            "inverter_base_voltage" => d["inverter_base_voltage"],
            "power_mode" => d["power_mode"],
            "switch_mode_voltage" => d["switch_mode_voltage"],
            "compounding_resistance" => d["compounding_resistance"],
            "min_compounding_voltage" => d["min_compounding_voltage"],
            "rectifier_transformer_ratio" => d["rectifier_transformer_ratio"],
            "rectifier_tap_setting" => d["rectifier_tap_setting"],
            "rectifier_tap_limits" => d["rectifier_tap_limits"],
            "rectifier_tap_step" => d["rectifier_tap_step"],
            "rectifier_delay_angle" => d["rectifier_delay_angle"],
            "rectifier_capacitor_reactance" => d["rectifier_capacitor_reactance"],
            "inverter_transformer_ratio" => d["inverter_transformer_ratio"],
            "inverter_tap_setting" => d["inverter_tap_setting"],
            "inverter_tap_limits" => d["inverter_tap_limits"],
            "inverter_tap_step" => d["inverter_tap_step"],
            "inverter_extinction_angle" => d["inverter_extinction_angle"],
            "inverter_capacitor_reactance" => d["inverter_capacitor_reactance"],
            # Upstream psse.jl stashes these as NamedTuples; from_json expects
            # a nested Dict for the MinMax sub-object, so re-wrap.
            "active_power_limits_from" => _min_max_dict(d["pminf"], d["pmaxf"]),
            "active_power_limits_to" => _min_max_dict(d["pmint"], d["pmaxt"]),
            "reactive_power_limits_from" => _min_max_dict(d["qminf"], d["qmaxf"]),
            "reactive_power_limits_to" => _min_max_dict(d["qmint"], d["qmaxt"]),
            "loss" => loss_dict,
        )
    elseif source_type == "matpower"
        return Dict{String, Any}(
            "id" => getid!(ids, :TwoTerminalGenericHVDCLine, d["index"]),
            "name" => String(name),
            "available" => d["br_status"] == 1,
            "active_power_flow" => pf,
            "arc" => arc_id,
            "active_power_limits_from" => _min_max_dict(d["pminf"], d["pmaxf"]),
            "active_power_limits_to" => _min_max_dict(d["pmint"], d["pmaxt"]),
            "reactive_power_limits_from" => _min_max_dict(d["qminf"], d["qmaxf"]),
            "reactive_power_limits_to" => _min_max_dict(d["qmint"], d["qmaxt"]),
            "loss" => loss_dict,
        )
    else
        error("Not supported source type for DC lines: $source_type")
    end
end

"""
For every dcline return a NamedTuple of per-OpenAPI-type sub-collections.
"""
function read_dcline!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}},
    arcs::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    @info "Reading DC Line data"
    data = pm_data.data
    two_terminal_lcc_line = Dict{String, Dict{String, Any}}()
    two_terminal_generic_hvdc_line = Dict{String, Dict{String, Any}}()
    if !haskey(data, "dcline")
        @info "There is no DClines data in this file"
        return (; two_terminal_lcc_line, two_terminal_generic_hvdc_line)
    end

    _get_name = get(kwargs, :dcline_name_formatter, _get_pm_branch_name)
    source_type = data["source_type"]
    bucket = if source_type == "pti"
        two_terminal_lcc_line
    elseif source_type == "matpower"
        two_terminal_generic_hvdc_line
    else
        error("Not supported source type for DC lines: $source_type")
    end

    for (d_key, d) in data["dcline"]
        d["name"] = get(d, "name", d_key)
        bus_f_dict = bus_dicts[d["f_bus"]]
        bus_t_dict = bus_dicts[d["t_bus"]]
        name = String(_get_name(d, bus_f_dict, bus_t_dict))
        dcline = make_dcline(name, d, bus_f_dict, bus_t_dict, source_type, ids, arcs)
        haskey(bucket, name) && throw(
            DataFormatError(
                "Found duplicate dcline name $name; consider passing a `dcline_name_formatter` kwarg",
            ),
        )
        bucket[name] = dcline
    end
    return (; two_terminal_lcc_line, two_terminal_generic_hvdc_line)
end

"""
Translate one PowerModels vscline row into a TwoTerminalVSCLine-shaped
dict.

PSY-side `ext` is dropped.
"""
function make_vscline(
    name::AbstractString,
    d::Dict,
    bus_f_dict::Dict,
    bus_t_dict::Dict,
    ids::IDGenerator,
    arcs::Dict{Int, Dict{String, Any}},
)
    arc_id =
        _get_or_mint_arc_id!(ids, arcs, Int(bus_f_dict["id"]), Int(bus_t_dict["id"]))
    g_value = d["r"] == 0.0 ? 0.0 : 1.0 / d["r"]
    return Dict{String, Any}(
        "id" => getid!(ids, :TwoTerminalVSCLine, d["index"]),
        "name" => String(name),
        "available" => d["available"],
        "arc" => arc_id,
        "active_power_flow" => get(d, "pf", 0.0),
        "rating" => d["rating"],
        "active_power_limits_from" => _min_max_dict(d["pminf"], d["pmaxf"]),
        "active_power_limits_to" => _min_max_dict(d["pmint"], d["pmaxt"]),
        "g" => g_value,
        "dc_current" => get(d, "if", 0.0),
        "reactive_power_from" => get(d, "qf", 0.0),
        "dc_voltage_control_from" => d["dc_voltage_control_from"],
        "ac_voltage_control_from" => d["ac_voltage_control_from"],
        "dc_setpoint_from" => d["dc_setpoint_from"],
        "ac_setpoint_from" => d["ac_setpoint_from"],
        "converter_loss_from" => _linear_curve_to_io_dict(d["converter_loss_from"]),
        "max_dc_current_from" => d["max_dc_current_from"],
        "rating_from" => d["rating_from"],
        "reactive_power_limits_from" => _min_max_dict(d["qminf"], d["qmaxf"]),
        "power_factor_weighting_fraction_from" =>
            d["power_factor_weighting_fraction_from"],
        "reactive_power_to" => get(d, "qt", 0.0),
        "dc_voltage_control_to" => d["dc_voltage_control_to"],
        "ac_voltage_control_to" => d["ac_voltage_control_to"],
        "dc_setpoint_to" => d["dc_setpoint_to"],
        "ac_setpoint_to" => d["ac_setpoint_to"],
        "converter_loss_to" => _linear_curve_to_io_dict(d["converter_loss_to"]),
        "max_dc_current_to" => d["max_dc_current_to"],
        "rating_to" => d["rating_to"],
        "reactive_power_limits_to" => _min_max_dict(d["qmint"], d["qmaxt"]),
        "power_factor_weighting_fraction_to" => d["power_factor_weighting_fraction_to"],
    )
end

"""
For every vscline return a `Dict{String, Dict{String, Any}}` mapping each 
line name to a TwoTerminalVSCLine-shaped dict.
"""
function read_vscline!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}},
    arcs::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    @info "Reading VSC Line data"
    data = pm_data.data
    vsclines = Dict{String, Dict{String, Any}}()
    if !haskey(data, "vscline")
        @info "There is no VSC lines data in this file"
        return vsclines
    end

    _get_name = get(kwargs, :vsc_line_name_formatter, _get_pm_branch_name)

    for (d_key, d) in data["vscline"]
        d["name"] = get(d, "name", d_key)
        bus_f_dict = bus_dicts[d["f_bus"]]
        bus_t_dict = bus_dicts[d["t_bus"]]
        name = String(_get_name(d, bus_f_dict, bus_t_dict))
        vscline = make_vscline(name, d, bus_f_dict, bus_t_dict, ids, arcs)
        haskey(vsclines, name) && throw(
            DataFormatError(
                "Found duplicate vscline name $name; consider passing a `vsc_line_name_formatter` kwarg",
            ),
        )
        vsclines[name] = vscline
    end
    return vsclines
end

"""
Translate one PowerModels FACTS row into a FACTSControlDevice-shaped dict.
Single-bus device — no Arc minted.
"""
function make_facts(name::AbstractString, d::Dict, bus_dict::Dict, ids::IDGenerator)
    if d["tbus"] != 0
        @warn "Series FACTs not supported."
    end
    if d["control_mode"] > 3
        throw(DataFormatError("Operation mode not supported."))
    end
    if d["reactive_power_required"] < 0
        throw(DataFormatError("% MVAr required must me positive."))
    end

    return Dict{String, Any}(
        "id" => getid!(ids, :FACTSControlDevice, d["index"]),
        "name" => String(name),
        "available" => Bool(d["available"]),
        "bus" => Int(bus_dict["id"]),
        "control_mode" => _normalize_facts_control_mode(d["control_mode"]),
        "voltage_setpoint" => d["voltage_setpoint"],
        "max_shunt_current" => d["max_shunt_current"],
        "reactive_power_required" => d["reactive_power_required"],
    )
end

"""
For every FACTS device return a `Dict{String, Dict{String, Any}}` mapping each 
device name to a FACTSControlDevice-shaped dict.
"""
function read_facts!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    @info "Reading FACTS data"
    data = pm_data.data
    facts = Dict{String, Dict{String, Any}}()
    if !haskey(data, "facts")
        @info "There is no facts data in this file"
        return facts
    end

    _get_name = get(kwargs, :bus_name_formatter, _get_pm_dict_name)

    for (d_key, d) in data["facts"]
        d["name"] = get(d, "name", d_key)
        name = String(_get_name(d))
        bus_dict = bus_dicts[d["bus"]]
        full_name = "$(d["bus"])_$(name)"
        facts_entry = make_facts(full_name, d, bus_dict, ids)
        haskey(facts, full_name) && throw(
            DataFormatError(
                "Found duplicate FACTS name $full_name; consider passing a `bus_name_formatter` kwarg",
            ),
        )
        facts[full_name] = facts_entry
    end
    return facts
end

# =============================================================================
# Storage
# =============================================================================

"""
Build the dict equivalent of PSY's auto-defaulted `StorageCost(nothing)`.
"""
function _zero_storage_cost_dict()
    zero_io_curve = Dict{String, Any}(
        "curve_type" => "INPUT_OUTPUT",
        "function_data" => Dict{String, Any}(
            "function_type" => "LINEAR",
            "proportional_term" => 0.0,
            "constant_term" => 0.0,
        ),
    )
    zero_cost_curve = Dict{String, Any}(
        "variable_cost_type" => "COST",
        "power_units" => "NATURAL_UNITS",
        "value_curve" => zero_io_curve,
        "vom_cost" => deepcopy(zero_io_curve),
    )
    return Dict{String, Any}(
        "cost_type" => "STORAGE",
        "charge_variable_cost" => zero_cost_curve,
        "discharge_variable_cost" => deepcopy(zero_cost_curve),
        "fixed" => 0.0,
        "shut_down" => 0.0,
        # StorageCostStartUp is a OneOf{Float64, StorageCostStartUpOneOf};
        # the plain-Float64 branch matches PSY's default scalar start_up.
        "start_up" => 0.0,
        "energy_shortage_cost" => 0.0,
        "energy_surplus_cost" => 0.0,
    )
end

"""
Translate one PowerModels storage row into an EnergyReservoirStorage-shaped
dict.
"""
function make_generic_battery(
    storage_name::AbstractString,
    d::Dict,
    bus_dict::Dict,
    ids::IDGenerator,
)
    energy_rating = iszero(d["energy_rating"]) ? d["energy"] : d["energy_rating"]
    return Dict{String, Any}(
        "id" => getid!(ids, :EnergyReservoirStorage, d["index"]),
        "name" => String(storage_name),
        "available" => Bool(d["status"]),
        "bus" => Int(bus_dict["id"]),
        "prime_mover_type" => "BA",
        "storage_technology_type" => "OTHER_CHEM",
        "storage_capacity" => energy_rating,
        "storage_level_limits" => _min_max_dict(0.0, energy_rating),
        "initial_storage_capacity_level" => d["energy"] / energy_rating,
        "rating" => d["thermal_rating"],
        "active_power" => d["ps"],
        "input_active_power_limits" => _min_max_dict(0.0, d["charge_rating"]),
        "output_active_power_limits" => _min_max_dict(0.0, d["discharge_rating"]),
        "efficiency" => _in_out_dict(d["charge_efficiency"], d["discharge_efficiency"]),
        "reactive_power" => d["qs"],
        "reactive_power_limits" => _min_max_dict(d["qmin"], d["qmax"]),
        "base_power" => d["thermal_rating"],
        "operation_cost" => _zero_storage_cost_dict(),
    )
end

"""
For each storage device return a `Dict{String, Dict{String, Any}}` mapping each 
device name to an EnergyReservoirStorage-shaped dict.

Storage entries are skipped by `read_gen!`, they come in through this
separate `data["storage"]` pathway instead. MATPOWER files generally have
no `data["storage"]` section; PSS/E exposes it via its own data section.
"""
function read_storage!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    bus_dicts::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    @info "Reading storage data"
    data = pm_data.data
    storage = Dict{String, Dict{String, Any}}()
    if !haskey(data, "storage")
        @info "There is no storage data in this file"
        return storage
    end

    _get_name = get(kwargs, :gen_name_formatter, _get_pm_dict_name)

    for (d_key, d) in data["storage"]
        d["name"] = get(d, "name", d_key)
        name = String(_get_name(d))
        bus_dict = bus_dicts[d["storage_bus"]]
        battery = make_generic_battery(name, d, bus_dict, ids)
        haskey(storage, name) && throw(
            DataFormatError(
                "Found duplicate storage name $name; consider passing a `gen_name_formatter` kwarg",
            ),
        )
        storage[name] = battery
    end
    return storage
end

# =============================================================================
# Areas + Inter-Area Interchange
# =============================================================================

"""
Build an Area-shaped `Dict{String, Any}`. PSY relies on the struct constructor's
field defaults; we emit them explicitly:
- `peak_active_power = 0.0`
- `peak_reactive_power = 0.0`
- `load_response = 0.0`
"""
function make_area(area_number::Int, name::AbstractString, ids::IDGenerator)
    return Dict{String, Any}(
        "id" => getid!(ids, :Area, area_number),
        "name" => String(name),
        "peak_active_power" => 0.0,
        "peak_reactive_power" => 0.0,
        "load_response" => 0.0,
    )
end

"""
For each bus return a `Dict{Int, Dict{String, Any}}` mapping each unique area 
number to an Area-shaped dict (areas are not duplicated).

Areas are collected solely from bus rows (PSY-strict). PSS/E
`data["area_interchange"]` metadata (`ARNAME`/`I`/`ISW`/`PDES`/`PTOL`)
would land in PSY's `Area.ext` but the OpenAPI Area schema has no `ext`,
so that data is lost.
"""
function read_area!(pm_data::PowerModelsData, ids::IDGenerator; kwargs...)
    @info "Reading Area data"
    data = pm_data.data
    areas = Dict{Int, Dict{String, Any}}()
    if !haskey(data, "bus")
        @info "There is no bus data — no areas to materialize"
        return areas
    end

    _get_name_area = get(kwargs, :area_name_formatter, string)

    seen = Set{Int}()
    for (_, b) in data["bus"]
        push!(seen, Int(b["area"]))
    end

    for area_number in seen
        name = String(_get_name_area(area_number))
        areas[area_number] = make_area(area_number, name, ids)
    end
    return areas
end

"""
Build an AreaInterchange-shaped dict from a PSS/E `interarea_transfer` row.

PSY hardcodes: `flow_limits = (from_to = -INFINITE_BOUND, to_from =
INFINITE_BOUND)`; `available` flag as `true`.
"""
function make_area_interchange(
    name::AbstractString,
    d::Dict,
    from_area_id::Int,
    to_area_id::Int,
    ids::IDGenerator,
)
    return Dict{String, Any}(
        "id" => getid!(ids, :AreaInterchange, d["index"]),
        "name" => String(name),
        "available" => true,
        "active_power_flow" => d["power_transfer"],
        "from_area" => from_area_id,
        "to_area" => to_area_id,
        "flow_limits" => Dict{String, Any}(
            "from_to" => -INFINITE_BOUND,
            "to_from" => INFINITE_BOUND,
        ),
    )
end

"""
For each PSS/E `interarea_transfer` return a `Dict{String, Dict{String, Any}}` 
mapping each transfer name to an AreaInterchange-shaped dict.

PSS/E-only; MATPOWER files don't carry `interarea_transfer` and this
function returns an empty dict.
"""
function read_area_interchange!(
    pm_data::PowerModelsData,
    ids::IDGenerator,
    area_dicts::Dict{Int, Dict{String, Any}};
    kwargs...,
)
    @info "Reading area interchange data"
    data = pm_data.data
    interchanges = Dict{String, Dict{String, Any}}()
    if data["source_type"] != "pti" || !haskey(data, "interarea_transfer")
        @info "There is no interarea_transfer data in this file"
        return interchanges
    end

    _get_name_area = get(kwargs, :area_name_formatter, string)

    for (_, d) in data["interarea_transfer"]
        area_from = Int(d["area_from"])
        area_to = Int(d["area_to"])

        if !haskey(area_dicts, area_from) || !haskey(area_dicts, area_to)
            @warn "Skipping interarea_transfer: from_area=$area_from to_area=$area_to references an area not present on any bus"
            continue
        end

        from_area_id = getid!(ids, :Area, area_from)
        to_area_id = getid!(ids, :Area, area_to)
        area_from_name = String(_get_name_area(area_from))
        area_to_name = String(_get_name_area(area_to))
        transfer_id = get(d, "transfer_id", "1")
        name = "$(area_from_name)_$(area_to_name)_$transfer_id"

        haskey(interchanges, name) && throw(
            DataFormatError(
                "Found duplicate interarea_transfer name $name; consider passing an `area_name_formatter` kwarg",
            ),
        )
        interchanges[name] =
            make_area_interchange(name, d, from_area_id, to_area_id, ids)
    end
    return interchanges
end

# =============================================================================
# Impedance Correction Tables (ICT) — supplemental attributes
# =============================================================================

"""
Read PSS/E impedance-correction-table data and return a
`Dict{Tuple{Int, String}, Dict{String, Any}}` mapping each
`(table_number, transformer_winding)` pair to an ImpedanceCorrectionData-
shaped dict ready for `OpenAPI.from_json`.

PSS/E-only; MATPOWER files have no `data["impedance_correction"]` and this
function returns an empty dict.
"""
function read_impedance_correction!(pm_data::PowerModelsData, ids::IDGenerator)
    @info "Reading Impedance Correction Table data"
    ict_instances = Dict{Tuple{Int, String}, Dict{String, Any}}()
    data = pm_data.data
    if !haskey(data, "impedance_correction")
        @info "There is no Impedance Correction Table data in this file"
        return ict_instances
    end

    for (_, table_data) in data["impedance_correction"]
        table_number = Int(table_data["table_number"])
        x = table_data["tap_or_angle"]
        y = table_data["scaling_factor"]

        if length(x) != length(y)
            throw(
                DataFormatError(
                    "Impedance correction mismatch at table $table_number: tap/angle and scaling count differs.",
                ),
            )
        end
        if length(x) < 2
            @warn "Skipping impedance correction entry due to insufficient data points ($(length(x)) < 2): $x"
            continue
        end

        pwl_dict = Dict{String, Any}(
            "function_type" => "PIECEWISE_LINEAR",
            "points" => [
                Dict{String, Any}("x" => float(x[i]), "y" => float(y[i])) for
                i in eachindex(x)
            ],
        )

        table_type =
            if PSSE_PARSER_TAP_RATIO_LBOUND <= x[1] <= PSSE_PARSER_TAP_RATIO_UBOUND
                "TAP_RATIO"
            else
                "PHASE_SHIFT_ANGLE"
            end

        for winding in _ICT_WINDING_CATEGORIES
            ict_instances[(table_number, winding)] = Dict{String, Any}(
                "id" => getid!(
                    ids,
                    :ImpedanceCorrectionData,
                    (table_number, winding),
                ),
                "table_number" => table_number,
                "impedance_correction_curve" => deepcopy(pwl_dict),
                "transformer_winding" => winding,
                "transformer_control_mode" => table_type,
            )
        end
    end
    return ict_instances
end

"""
Look up the ICT for one `(table_number, transformer_winding)` pair and
append a `{"attribute_id", "entity_id"}` association entry linking the
transformer to the ICT.
"""
function _attach_single_ict!(
    transformer_dict::Dict,
    table_number::Int,
    winding::AbstractString,
    ict_instances::Dict{Tuple{Int, String}, Dict{String, Any}},
    supp_assoc::Vector{Dict{String, Any}},
)
    key = (table_number, String(winding))
    if !haskey(ict_instances, key)
        @debug "No ICT associated with transformer $(transformer_dict["name"]) for winding $winding."
        return
    end
    push!(
        supp_assoc,
        Dict{String, Any}(
            "attribute_id" => ict_instances[key]["id"],
            "entity_id" => transformer_dict["id"],
        ),
    )
    return
end

"""
Attach the ICT(s) referenced by a transformer row to `supp_assoc`.
No-ops if `ict_instances` is empty.
"""
function _attach_impedance_correction_tables!(
    transformer_dict::Dict,
    d::Dict,
    ict_instances::Dict{Tuple{Int, String}, Dict{String, Any}},
    supp_assoc::Vector{Dict{String, Any}};
    is_3w::Bool,
)
    isempty(ict_instances) && return

    if is_3w
        for (key_prefix, winding) in _ICT_3W_WINDING_KEYS
            key = "$(key_prefix)_correction_table"
            haskey(d, key) || continue
            _attach_single_ict!(
                transformer_dict,
                Int(d[key]),
                winding,
                ict_instances,
                supp_assoc,
            )
        end
    else
        haskey(d, "correction_table") || return
        _attach_single_ict!(
            transformer_dict,
            Int(d["correction_table"]),
            "TR2W_WINDING",
            ict_instances,
            supp_assoc,
        )
    end
    return
end

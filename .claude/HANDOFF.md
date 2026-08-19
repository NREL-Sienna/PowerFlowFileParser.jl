# PowerFlowFileParser.jl — Handoff (branch: `hc/fix_removePSY_breaks`)

## Status

End-to-end file → SQLite database works on the `modified_14bus_system.raw`
fixture. All 15 OpenAPI types the parser emits are written to the DB;
concrete-type distinctions are preserved in `entities.entity_type` even
when subtypes ride along on a parent table. `using PowerFlowFileParser`
precompiles cleanly. Test suite is broken (see gaps).

## Pipeline overview

Three stages:

1. **Readers** (`src/power_models_data.jl`, ~3400 lines) produce
   OpenAPI-shaped `Dict{String, Any}`s. Entry point:
   `parse_to_openapi_dicts(pm_data::PowerModelsData; kwargs...)`. Defined
   in the module but **not exported** — reach via qualified access for
   debugging.
2. **Typed layer** — `parse_to_openapi_objects(pm_data; kwargs...) →
   ParsedOpenAPIObjects` runs `OpenAPI.from_json` per output collection,
   validating required fields and enum membership. Returns a struct of
   typed `Vector{T}` of POM structs.
3. **DB write** — `make_database(pm_data; path=":memory:", kwargs...) →
   SQLite.DB` calls `parse_to_openapi_objects` first (so schema
   validation fails before any disk write), initializes the schema via
   `make_sqlite!(db)`, and walks the type order. `save_database(db, path)`
   persists an in-memory DB to a file.

**No PSY dependency in the parsing code.** Downstream PSY6 System
construction is a separate consumer (not in this repo).

## OpenAPI target

`PowerOperationsOpenAPIModels` (POM) — resolved from
`~/SiennaRepos/InactiveRepos/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl`.
POM ships the OpenAPI structs; it does **not** ship a DB schema. The
schema lives locally under `src/dbinterface/`.

Types emitted by our readers, all POM:
`ACBus`, `Area`, `AreaInterchange`, `LoadZone`, `PowerLoad`,
`StandardLoad`, `InterruptibleStandardLoad`, `FixedAdmittance`,
`SwitchedAdmittance`, `ThermalStandard`, `HydroDispatch`,
`RenewableDispatch`, `RenewableNonDispatch`, `SynchronousCondenser`,
`EnergyReservoirStorage`, `Line`, `TwoWindingTransformer`,
`ThreeWindingTransformer`, `TransformerCircuit`,
`DiscreteControlledACBranch`, `TwoTerminalLCCLine`,
`TwoTerminalGenericHVDCLine`, `TwoTerminalVSCLine`, `FACTSControlDevice`,
`Arc`, `ImpedanceCorrectionData`.

## Reader outputs (`ParsedOpenAPIDicts` / `ParsedOpenAPIObjects`)

| Reader | Output | POM type(s) |
|---|---|---|
| `read_bus!` | `Dict{Int, Dict}` by bus_number | `ACBus` |
| `read_area!` | `Dict{Int, Dict}` by area_number | `Area` |
| `read_area_interchange!` | `Dict{String, Dict}` | `AreaInterchange` |
| `read_loadzones!` | `Dict{Int, Dict}` by zone_number | `LoadZone` |
| `read_loads!` | NamedTuple | `power_load` / `standard_load` / `interruptible_standard_load` |
| `read_switched_shunt!` | `Dict{String, Dict}` | `SwitchedAdmittance` |
| `read_shunt!` | `Dict{String, Dict}` | `FixedAdmittance` |
| `read_gen!` | NamedTuple | `thermal_standard` / `hydro_dispatch` / `renewable_dispatch` / `renewable_non_dispatch` / `synchronous_condenser` |
| `read_storage!` | `Dict{String, Dict}` | `EnergyReservoirStorage` |
| `read_branch!` | NamedTuple | `line` / `two_winding_transformer` / `discrete_controlled_ac_branch` (also mutates `transformer_circuits`) |
| `read_3w_transformer!` | NamedTuple | `three_winding_transformer` (also mutates `transformer_circuits`) |
| `read_switch_breaker!` | `Dict{String, Dict}` | `DiscreteControlledACBranch` |
| `read_dcline!` | NamedTuple | `two_terminal_lcc_line` / `two_terminal_generic_hvdc_line` |
| `read_vscline!` | `Dict{String, Dict}` | `TwoTerminalVSCLine` |
| `read_facts!` | `Dict{String, Dict}` | `FACTSControlDevice` |
| `read_impedance_correction!` | `Dict{Tuple{Int,String}, Dict}` | `ImpedanceCorrectionData` |

## Transformer decomposition (POM design)

POM decomposes transformers into **holder + per-winding circuit**:

- `TwoWindingTransformer` holder: `id, name, circuit(FK), admittance_units, magnetizing_shunt, shunt_location`.
- `ThreeWindingTransformer` holder: `id, name, primary_circuit(FK), secondary_circuit(FK), tertiary_circuit(FK), star_bus, r_12, x_12, r_23, x_23, r_31, x_31, base_power_12, base_power_23, base_power_31, admittance_units, magnetizing_shunt, shunt_location`.
- `TransformerCircuit` per winding: `id, available, arc, tap, alpha, r, x, control_objective, rating(_b,_c), active/reactive_power_flow, base_power, base_voltage_primary/secondary`.

Three PSS/E-side variants (`:TwoWindingTransformer`, `:TapTransformer`,
`:PhaseShiftingTransformer` from the branch-type dispatcher) all emit a
`TwoWindingTransformer` holder — the variant only determines which
circuit fields (tap, alpha, control_objective) get populated. Same for 3W
plain vs. phase-shifting.

Circuits are threaded via a shared `transformer_circuits::Dict{Int, Dict}`
accumulator (mirrors the `arcs` pattern). Populated by both `read_branch!`
and `read_3w_transformer!`; consumed by `_extract_type_dicts/_objects` at
the `:TransformerCircuit` case.

## ID generation

`IDGenerator()` — per-parse int counter (`nextid=1`) + cache keyed by
`(type_tag::Symbol, natural_key)`.

- `getid!(ids, type_tag, natural_key)` returns cached id or mints a new one.
- Passing `nothing` as the natural key returns `nothing` (for optional FKs).
- Cross-references between readers collapse via the cache (whichever
  reader hits a given key second gets the same id).
- Composite keys where a single index would collide:
  - `:DiscreteControlledACBranch` — `("branch"|"switch"|"breaker", index)`
  - `:ImpedanceCorrectionData` — `(table_number, winding_string)`
  - `:TransformerCircuit` — `(:TwoWinding, index)` or `(:ThreeWinding, index, :primary|:secondary|:tertiary)`

## Accumulators threaded through readers

| Accumulator | Type | Mutated by |
|---|---|---|
| `arcs` | `Dict{Int, Dict}` keyed by Arc id | branch/3W/switch-breaker/dcline/vscline readers |
| `transformer_circuits` | `Dict{Int, Dict}` keyed by circuit id | branch (2W) + 3W readers |
| `supplemental_attribute_associations` | `Vector{Dict}` of `{attribute_id, entity_id}` | branch (2W ICT) + 3W (per-winding ICT) |

## DB layer

`src/dbinterface/`:

- `schema.sql` — CREATE TABLE statements. `two_winding_transformers`,
  `three_winding_transformers`, `transformer_circuits` are our
  decomposition. Rest matches SOM's schema layout byte-for-byte.
- `triggers.sql`, `db_schema.jl` — table registration
  (`TABLE_SCHEMAS`, `OPENAPI_FIELDS_TO_DB`, `JSON_COLUMNS`, entity_types
  lists), `make_sqlite!(db)`.
- `db_helpers.jl` — `get_row_field`, `insert_attributes!`,
  `insert_uuid!`, statement prep helpers. Direct import of SOM's helper
  shape — operates purely on OpenAPI structs.

`src/db_write.jl`:

- `_POAM_TYPE_TO_TABLE` — concrete OpenAPI type → target table. Subtypes
  ride along on parent tables (see "Subtype inheritance" below).
- `send_openapi_table_to_db!(T, db, components)` — generic per-type
  writer; uses `nameof(T)` as `entities.entity_type` so concrete types
  are recorded even when sharing a parent's table.
- `send_openapi_table_to_db!(::Type{AreaInterchange}, …)` — inline arc
  minting specialization.
- `write_arcs_to_db!`, `write_supplemental_attributes_to_db!`,
  `write_supplemental_attribute_associations_to_db!` — helpers for topology
  arcs and ICT SAs.

`src/common.jl`:

- `_MAKE_DATABASE_TYPE_ORDER` — insertion order. Topology first, then
  Line/TransformerCircuit before the 2W/3W holders (FK ordering).

## `make_database` flow

```
parse_to_openapi_objects(pm_data)   # from_json validation happens here
    ↓
SQLite.DB open + make_sqlite!(db)   # schema + entity_types + prime_mover_types + fuels seed
    ↓
Write topology (Area, LoadZone, ACBus) so `entities` has bus ids
    ↓
write_arcs_to_db!                   # arcs.from_id/to_id FK to entities
    ↓
write_supplemental_attributes_to_db!(ImpedanceCorrectionData, ...)  # ICT SAs
    ↓
Loop through _MAKE_DATABASE_TYPE_ORDER (skipping topology, already done):
    for each POM type T:
        components = _extract_type_objects(parsed, T)
        isempty(components) && continue
        send_openapi_table_to_db!(T, db, components)
    ↓
write_supplemental_attribute_associations_to_db!  # transformer↔ICT edges
```

Synthesized UUIDs (via `UUIDs.uuid4()`) are written into `attributes`
at the `uuid` name slot. One-way parser → DB workflow — no round-trip
back to PSY components.

## Subtype inheritance in the DB write

Seven POM types share tables with their parents. `entities.entity_type`
records the concrete OpenAPI type; subtype-specific fields land in the
generic `attributes` table via `insert_attributes!` (which walks
`OpenAPI.to_json(c)` and pushes any key not in the parent's
`TABLE_SCHEMAS[table_name].names`).

| POM type | Shared table | Reason |
|---|---|---|
| `DiscreteControlledACBranch` | `transmission_lines` | Arc-based AC branch |
| `TwoTerminalLCCLine` | `transmission_lines` | DC line, arc-based |
| `TwoTerminalVSCLine` | `transmission_lines` | DC line, arc-based |
| `FACTSControlDevice` | `loads` | Single-bus injection |
| `SwitchedAdmittance` | `loads` | Single-bus shunt, same category as FixedAdmittance |
| `SynchronousCondenser` | `loads` | Single-bus, avoids required thermal_generators columns (fuel/prime_mover/active_power_limits) that SC lacks |
| `InterruptibleStandardLoad` | `loads` | Follows PowerLoad / StandardLoad grouping |

## Public API

```julia
using PowerFlowFileParser

pm_data = PowerModelsData("path/to/case.raw")   # or .m

# Path 1: raw → SQLite DB
db = make_database(pm_data; path = ":memory:")  # or a file path

# Path 2: raw → typed POM structs (for JSON export or downstream System build)
parsed = parse_to_openapi_objects(pm_data)
parsed.buses                                     # Vector{POM.ACBus}
parsed.transformer_circuits                      # Vector{POM.TransformerCircuit}
parsed.branches.two_winding_transformer          # Vector{POM.TwoWindingTransformer}
parsed.xfrm_3w.three_winding_transformer         # Vector{POM.ThreeWindingTransformer}
# … etc.
```

Reader kwargs (all silently ignored by readers that don't need them):
`bus_name_formatter`, `gen_name_formatter`, `generator_mapping`,
`branch_name_formatter`, `xfrm_3w_name_formatter`,
`transformer_control_objective_formatter`.

## Session history (what this branch consolidated)

- **PSY dependency removed** from `pm_io/`, `im_io/`, and the top-level module.
- **Swap SOM → POM.** Direct dep on `SiennaOpenAPIModels` dropped in favor
  of `PowerCoreOpenAPIModels` + `PowerOperationsOpenAPIModels`.
- **Transformer decomposition** to POM's holder + TransformerCircuit
  model. Five OpenAPI type Symbols (`:Transformer2W`, `:TapTransformer`,
  `:PhaseShiftingTransformer`, `:Transformer3W`, `:PhaseShiftingTransformer3W`)
  collapsed to two OUTPUT types (`:TwoWindingTransformer`,
  `:ThreeWindingTransformer`) plus a shared circuit collection.
- **ICT shim removed** in favor of POM's `ImpedanceCorrectionData` — the
  field/enum layout is identical. `dbinterface/local_types.jl` deleted.
- **Subtype table sharing** wired up. 7 previously-skipped types now
  write to shared parent tables with concrete type preserved in
  `entities.entity_type`.
- **`make_database` reordered** — topology → arcs → ICTs → everything
  else, so `entities` FK from arcs resolves.
- **DC-line NamedTuple → Dict** in `src/pm_io/psse.jl` so
  `OpenAPI.from_json` can build MinMax sub-objects.
- **Arc field rename**: `arc.from`/`arc.to` → `arc.from_id`/`arc.to_id`
  matching POM's Arc.

## Known gaps

1. **Tests broken.** `test/runtests.jl` needs `Logging` in
   `test/Project.toml`; `test/test_parse_psse.jl` and
   `test/test_parse_matpower.jl` reference `PSY.System(pm_data)` which
   no longer exists in this branch. Needs rewrite against
   `parse_to_openapi_objects` / `make_database`.
2. **`PowerFlowDataNetwork` workflow not ported** — no
   `parse_to_openapi_objects` / `make_database` methods for the
   `PowerFlowData.Network` path. Rebasing onto
   `origin/psse-parser-consolidation` drops this concern entirely
   (that branch removes the PowerFlowData path upstream).
3. **Stale mappings in `OPENAPI_FIELDS_TO_DB`:** `("arcs", "from") =>
   "from_id"` and `("arcs", "to") => "to_id"` are no-ops now that POM's
   Arc has `from_id`/`to_id` directly. Harmless but cleanup-worthy.

## Deferred design decisions (HANDOFF originals still open)

- **`bustype` type 3** — currently `"REF"`. Confirm downstream doesn't
  need `"SLACK"` instead.
- **`ext` field data loss** — settled as accepted loss (Sienna doesn't
  use these fields per user directive).
- **FACTS `control_mode` code 3** — PSY accepts 0-3, POM enum has only
  `{"OOS", "NML", "BYP"}`. We throw on code 3 (`_normalize_facts_control_mode`).
  Either widen the enum or document a coercion rule.
- **Synthetic UUIDs** — `UUIDs.uuid4()` in the DB `attributes` table.
  Fine for one-way parser → DB; no round-trip to PSY components.
- **Single-point piecewise cost curves** — `_thermal_variable_cost_and_fixed`
  will `BoundsError` on 1-point piecewise (matches PSY's behavior).

## File layout

```
src/
├── PowerFlowFileParser.jl     # module: exports, imports, includes
├── common.jl                  # shared constants, _MAKE_DATABASE_TYPE_ORDER
├── db_write.jl                # per-type writer + _POAM_TYPE_TO_TABLE
├── power_models_data.jl       # readers + parse_to_openapi_dicts/objects + make_database
├── powerflowdata_data.jl      # PowerFlowDataNetwork wrapper (no OpenAPI methods yet)
├── generator_mapping_pm.yaml  # fuel/prime-mover mapping
├── dbinterface/
│   ├── db_schema.jl           # TABLE_SCHEMAS, OPENAPI_FIELDS_TO_DB, entity_types seed, make_sqlite!
│   ├── db_helpers.jl          # get_row_field, insert_attributes!, statement prep
│   ├── schema.sql             # CREATE TABLE statements
│   └── triggers.sql           # trigger definitions
├── pm_io/                     # upstream PowerModels-style parsers (PSY-free)
│   ├── common.jl, data.jl, matpower.jl, psse.jl, pti.jl, LICENSE.md
├── pm_io.jl                   # pm_io/ includes
├── im_io/                     # InfrastructureModels-style parsers (PSY-free)
│   ├── common.jl, data.jl, matlab.jl, LICENSE.md
└── im_io.jl                   # im_io/ includes
```

## Reference paths

- **Upstream PSY parser** (historical reference for reader field names):
  `~/SiennaRepos/Extra-unused-PowerSystems.jl/src/parsers/power_models_data.jl`
- **POM checkout** (target OpenAPI schema):
  `~/SiennaRepos/InactiveRepos/PowerOpenAPIModels/PowerOperationsOpenAPIModels.jl/`
- **SOM checkout** (companion — DB helper shape lives here, transformer
  decomposition NOT yet reflected in SOM's main branch):
  `~/SiennaRepos/PowerSystemSchemas/SiennaOpenAPIModels.jl/`
- **Sibling branch to consider rebasing onto**:
  `origin/psse-parser-consolidation` — free-format PTI, v30 native path,
  drops PowerFlowData entirely.

## Related branches in this repo

| Branch | Direction | Relation |
|---|---|---|
| `main` | Baseline (still uses PSY) | Ancestor of everything below |
| `origin/psse-parser-consolidation` | Parser-only fixes (v30 native, free-format PTI, drop PowerFlowData) | Contains fixes we don't have |
| `origin/jd/openapi-json-export` | Builds `src/openapi/` SOM emit layer on top of psse-parser-consolidation | Opposite direction from this branch |
| `origin/psy6` | jd/openapi-json-export + HVDC + oneOf wrap | Descendant of jd/openapi-json-export |
| `hc/fix_removePSY_breaks` (this one) | Removes PSY, inlines DB schema, targets POM | Diverged directly from main |

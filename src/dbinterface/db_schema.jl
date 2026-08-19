# =============================================================================
# DB schema definition and initialization.
#
# Duplicated from `SiennaOpenAPIModels.jl/src/dbinterface/db_definition.jl`
# so the parser can build and populate the Sienna SQLite schema without
# taking a (transitive) PowerSystems.jl dependency. The SQL text and the
# `TABLE_SCHEMAS` table map are kept byte-identical to SOM; only
# `make_sqlite!` is trimmed — it iterates a local list of the OpenAPI type
# names PFFP actually writes, in place of SOM's PSY-keyed type registries.
# =============================================================================

import SQLite
import DBInterface
using Tables

function _read_sql_statements(filepath::AbstractString)
    sql_content = read(filepath, String)
    statements = split(sql_content, ';')
    cleaned_statements = [strip(s) for s in statements if !isempty(strip(s))]
    return cleaned_statements
end

# Track the SQL files as precompilation dependencies so editing them
# (without touching any .jl) correctly invalidates the precompile cache.
include_dependency(joinpath(@__DIR__, "schema.sql"))
include_dependency(joinpath(@__DIR__, "triggers.sql"))

const SQLITE_CREATE_STR = _read_sql_statements(joinpath(@__DIR__, "schema.sql"))
const SQLITE_TRIGGERS_STR = [read(joinpath(@__DIR__, "triggers.sql"), String)]

# OpenAPI field name → DB column name overrides, keyed by (table, openapi_field).
# Used by `insert_attributes!` and `get_row_field` to detect which OpenAPI
# fields land in typed columns vs. the generic `attributes` table.
const OPENAPI_FIELDS_TO_DB = Dict(
    ("transmission_lines", "arc") => "arc_id",
    ("transformer_circuits", "arc") => "arc_id",
    ("two_winding_transformers", "circuit") => "circuit_id",
    ("three_winding_transformers", "primary_circuit") => "primary_circuit_id",
    ("three_winding_transformers", "secondary_circuit") => "secondary_circuit_id",
    ("three_winding_transformers", "tertiary_circuit") => "tertiary_circuit_id",
    ("thermal_generators", "bus") => "balancing_topology",
    ("renewable_generators", "bus") => "balancing_topology",
    ("hydro_generators", "bus") => "balancing_topology",
    ("storage_units", "bus") => "balancing_topology",
    ("loads", "bus") => "balancing_topology",
    ("arcs", "from") => "from_id",
    ("arcs", "to") => "to_id",
    ("transmission_lines", "rating") => "continuous_rating",
)

const DB_TO_OPENAPI_FIELDS = Dict((s[1], t) => s[2] for (s, t) in OPENAPI_FIELDS_TO_DB)

# Columns whose values are stored as JSON strings in SQLite. Consulted by
# `get_row_field` when serializing rows out of OpenAPI structs and by the
# db-read path when reconstituting dicts from rows.
const JSON_COLUMNS = Set([
    "operation_cost",
    "active_power_limits",
    "reactive_power_limits",
    "ramp_limits",
    "time_limits",
    "outflow_limits",
    "storage_level_limits",
    "input_active_power_limits",
    "output_active_power_limits",
    "efficiency",
    "spillage_limits",
    "head_to_volume_factor",
    "region",
    "fuel",
    "capacity_limits",
    "capacity_limits_charge",
    "capacity_limits_discharge",
    "capacity_limits_energy",
    "co2",
    "capital_costs",
    "capital_costs_charge",
    "capital_costs_discharge",
    "capital_costs_energy",
    "operation_costs",
    "cofire_start_limits",
    "cofire_level_limits",
    "financial_data",
    "unserved_demand_curve",
    "duration_limits",
    "features",
])

const TABLE_SCHEMAS = Dict(
    "entities" =>
        Tables.Schema(["id", "entity_table", "entity_type"], [Int64, String, String]),
    "entity_types" => Tables.Schema(["name", "is_topology"], [String, Bool]),
    "prime_mover_types" => Tables.Schema(
        ["id", "name", "description"],
        [Int64, String, Union{String, Nothing}],
    ),
    "fuels" => Tables.Schema(
        ["id", "name", "description"],
        [Int64, String, Union{String, Nothing}],
    ),
    "planning_regions" => Tables.Schema(
        ["id", "name", "description"],
        [Int64, String, Union{String, Nothing}],
    ),
    "balancing_topologies" => Tables.Schema(
        ["id", "name", "area", "description"],
        [Int64, String, Union{Int64, Nothing}, Union{String, Nothing}],
    ),
    "arcs" => Tables.Schema(["id", "from_id", "to_id"], [Int64, Int64, Int64]),
    "transmission_lines" => Tables.Schema(
        [
            "id",
            "name",
            "arc_id",
            "continuous_rating",
            "ste_rating",
            "lte_rating",
            "line_length",
        ],
        [
            Int64,
            String,
            Int64,
            Float64,
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
        ],
    ),
    "transmission_interchanges" => Tables.Schema(
        ["id", "name", "arc_id", "max_flow_from", "max_flow_to"],
        [Int64, String, Int64, Float64, Float64],
    ),
    # Per-winding electricals for both 2W and 3W transformers. Mirrors POM's
    # TransformerCircuit. Column order MUST match the CREATE TABLE in schema.sql.
    "transformer_circuits" => Tables.Schema(
        [
            "id",
            "available",
            "arc_id",
            "tap",
            "alpha",
            "parameter_units",
            "r",
            "x",
            "control_objective",
            "regulated_bus_number",
            "number_of_tap_positions",
            "rating",
            "rating_b",
            "rating_c",
            "active_power_flow",
            "reactive_power_flow",
            "base_power",
            "base_voltage_primary",
            "base_voltage_secondary",
        ],
        [
            Int64,
            Bool,
            Int64,
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{String, Nothing},
            Float64,
            Float64,
            Union{String, Nothing},
            Union{Int64, Nothing},
            Union{Int64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
        ],
    ),
    # TwoWindingTransformer holder — electricals live on the referenced
    # TransformerCircuit row.
    "two_winding_transformers" => Tables.Schema(
        ["id", "name", "circuit_id", "admittance_units", "shunt_location"],
        [
            Int64,
            String,
            Int64,
            Union{String, Nothing},
            Union{String, Nothing},
        ],
    ),
    # ThreeWindingTransformer holder — per-winding electricals live on the
    # three referenced TransformerCircuit rows; pairwise mutual impedances /
    # base powers stay here to match POM's ThreeWindingTransformer struct.
    "three_winding_transformers" => Tables.Schema(
        [
            "id",
            "name",
            "primary_circuit_id",
            "secondary_circuit_id",
            "tertiary_circuit_id",
            "star_bus",
            "parameter_units",
            "r_12",
            "x_12",
            "r_23",
            "x_23",
            "r_31",
            "x_31",
            "base_power_12",
            "base_power_23",
            "base_power_31",
            "admittance_units",
            "shunt_location",
        ],
        [
            Int64,
            String,
            Int64,
            Int64,
            Int64,
            Int64,
            Union{String, Nothing},
            Float64,
            Float64,
            Float64,
            Float64,
            Float64,
            Float64,
            Float64,
            Float64,
            Float64,
            Union{String, Nothing},
            Union{String, Nothing},
        ],
    ),
    "thermal_generators" => Tables.Schema(
        [
            "id",
            "name",
            "prime_mover_type",
            "fuel",
            "balancing_topology",
            "rating",
            "base_power",
            "active_power_limits",
            "reactive_power_limits",
            "ramp_limits",
            "time_limits",
            "must_run",
            "available",
            "status",
            "active_power",
            "reactive_power",
            "operation_cost",
        ],
        [
            Int64,
            String,
            String,
            String,
            Int64,
            Float64,
            Float64,
            String,  # JSON: {"min": ..., "max": ...}
            Union{String, Nothing},  # JSON: {"min": ..., "max": ...}
            Union{String, Nothing},  # JSON: {"up": ..., "down": ...}
            Union{String, Nothing},  # JSON: {"up": ..., "down": ...}
            Bool,
            Bool,
            Bool,
            Float64,
            Float64,
            String,  # JSON stored as String
        ],
    ),
    "renewable_generators" => Tables.Schema(
        [
            "id",
            "name",
            "prime_mover_type",
            "balancing_topology",
            "rating",
            "base_power",
            "power_factor",
            "reactive_power_limits",
            "available",
            "active_power",
            "reactive_power",
            "operation_cost",
        ],
        [
            Int64,
            String,
            String,
            Int64,
            Float64,
            Float64,
            Float64,
            Union{String, Nothing},  # JSON: {"min": ..., "max": ...}
            Bool,
            Float64,
            Float64,
            Union{String, Nothing},  # JSON stored as String, NULL for RenewableNonDispatch
        ],
    ),
    "hydro_generators" => Tables.Schema(
        [
            "id",
            "name",
            "prime_mover_type",
            "balancing_topology",
            "rating",
            "base_power",
            "active_power_limits",
            "reactive_power_limits",
            "ramp_limits",
            "time_limits",
            "available",
            "active_power",
            "reactive_power",
            "powerhouse_elevation",
            "outflow_limits",
            "conversion_factor",
            "travel_time",
            "operation_cost",
        ],
        [
            Int64,
            String,
            String,
            Int64,
            Float64,
            Float64,
            String,  # JSON: {"min": ..., "max": ...}
            Union{String, Nothing},  # JSON: {"min": ..., "max": ...}
            Union{String, Nothing},  # JSON: {"up": ..., "down": ...}
            Union{String, Nothing},  # JSON: {"up": ..., "down": ...}
            Bool,
            Float64,
            Float64,
            Union{Float64, Nothing},
            Union{String, Nothing},  # JSON: {"min": ..., "max": ...}
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            String,  # JSON stored as String
        ],
    ),
    "storage_units" => Tables.Schema(
        [
            "id",
            "name",
            "prime_mover_type",
            "storage_technology_type",
            "balancing_topology",
            "rating",
            "base_power",
            "storage_capacity",
            "storage_level_limits",
            "initial_storage_capacity_level",
            "input_active_power_limits",
            "output_active_power_limits",
            "efficiency",
            "reactive_power_limits",
            "active_power",
            "reactive_power",
            "available",
            "conversion_factor",
            "storage_target",
            "cycle_limits",
            "operation_cost",
        ],
        [
            Int64,
            String,
            String,
            String,
            Int64,
            Float64,
            Float64,
            Float64,
            String,  # JSON: {"min": ..., "max": ...}
            Float64,
            String,  # JSON: {"min": ..., "max": ...}
            String,  # JSON: {"min": ..., "max": ...}
            String,  # JSON: {"in": ..., "out": ...}
            Union{String, Nothing},  # JSON: {"min": ..., "max": ...}
            Float64,
            Float64,
            Bool,
            Float64,
            Float64,
            Int64,
            Union{String, Nothing},  # JSON stored as String, nullable
        ],
    ),
    "hydro_reservoirs" => Tables.Schema(
        [
            "id",
            "name",
            "available",
            "storage_level_limits",
            "initial_level",
            "spillage_limits",
            "inflow",
            "outflow",
            "level_targets",
            "intake_elevation",
            "head_to_volume_factor",
            "operation_cost",
            "level_data_type",
        ],
        [
            Int64,
            String,
            Bool,
            String,  # JSON
            Float64,
            Union{String, Nothing},  # JSON, nullable
            Float64,
            Float64,
            Union{Float64, Nothing},
            Float64,
            String,  # JSON
            String,  # JSON
            String,
        ],
    ),
    "hydro_reservoir_connections" =>
        Tables.Schema(["source_id", "sink_id"], [Int64, Int64]),
    "supply_technologies" => Tables.Schema(
        [
            "id",
            "name",
            "prime_mover_type",
            "region",
            "power_systems_type",
            "lifetime",
            "unit_size",
            "capacity_limits",
            "fuel",
            "start_fuel_mmbtu_per_mwh",
            "cofire_level_limits",
            "cofire_start_limits",
            "co2",
            "available",
            "ramp_limits",
            "time_limits",
            "outage_factor",
            "min_generation_fraction",
            "capital_costs",
            "operation_costs",
            "financial_data",
        ],
        [
            Int64,
            String,
            String,
            String,
            String,
            Union{Int64, Nothing},
            Union{Float64, Nothing},
            Union{String, Nothing},
            String,
            Union{Float64, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
            Bool,
            Union{String, Nothing},
            Union{String, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            String,
            String,
            String,
        ],
    ),
    "storage_technologies" => Tables.Schema(
        [
            "id",
            "name",
            "prime_mover_type",
            "storage_tech",
            "region",
            "power_systems_type",
            "lifetime",
            "unit_size_charge",
            "unit_size_discharge",
            "unit_size_energy",
            "capacity_limits_charge",
            "capacity_limits_discharge",
            "capacity_limits_energy",
            "available",
            "duration_limits",
            "efficiency",
            "min_discharge_fraction",
            "losses",
            "capital_costs_charge",
            "capital_costs_discharge",
            "capital_costs_energy",
            "operation_costs",
            "financial_data",
        ],
        [
            Int64,
            String,
            String,
            String,
            String,
            String,
            Union{Int64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
            Bool,
            Union{String, Nothing},
            Union{String, Nothing},
            Union{Float64, Nothing},
            Union{Float64, Nothing},
            Union{String, Nothing},
            String,
            String,
            String,
            String,
        ],
    ),
    "transport_technologies" => Tables.Schema(
        [
            "id",
            "name",
            "power_systems_type",
            "available",
            "capital_costs",
            "financial_data",
            "unit_size",
        ],
        [Int64, String, String, Bool, String, String, Union{Float64, Nothing}],
    ),
    "demand_technologies" => Tables.Schema(
        ["id", "name", "available", "region", "power_systems_type"],
        [Int64, String, Bool, String, String],
    ),
    "attributes" => Tables.Schema(
        ["id", "entity_id", "TYPE", "name", "value"],
        # Note: json_type is a generated column, not included here
        [Int64, Int64, String, String, String],
    ),
    "supplemental_attributes" => Tables.Schema(
        ["id", "TYPE", "value"],
        # Note: json_type is a generated column, not included here
        [Int64, String, String],
    ),
    "supplemental_attributes_association" =>
        Tables.Schema(["attribute_id", "entity_id"], [Int64, Int64]),
    "plants" => Tables.Schema(
        ["id", "name", "TYPE", "value"],
        # Note: json_type is a generated column, not included here
        [Int64, String, String, Union{String, Nothing}],
    ),
    "plant_associations" =>
        Tables.Schema(["plant_id", "entity_id", "group_index"], [Int64, Int64, Int64]),
    "combined_cycle_associations" => Tables.Schema(
        ["plant_id", "entity_id", "role", "hrsg_index"],
        [Int64, Int64, String, Int64],
    ),
    "time_series_associations" => Tables.Schema(
        [
            "id",
            "time_series_uuid",
            "time_series_type",
            "initial_timestamp",
            "resolution",
            "horizon",
            "interval",
            "window_count",
            "length",
            "name",
            "owner_id",
            "owner_type",
            "owner_category",
            "features",
            "scaling_factor_multiplier",
            "metadata_uuid",
            "units",
        ],
        [
            Int64,
            String,
            String,
            String,
            Int64,
            Union{Int64, Nothing},
            Union{Int64, Nothing},
            Union{Int64, Nothing},
            Union{Int64, Nothing},
            Union{String, Nothing},
            String,
            Int64,
            Union{String, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
            Union{String, Nothing},
        ],
    ),
    "loads" => Tables.Schema(
        ["id", "name", "balancing_topology", "base_power"],
        [Int64, String, Int64, Union{Float64, Nothing}],
    ),
    "static_time_series" =>
        Tables.Schema(["id", "uuid", "idx", "value"], [Int64, String, Int64, Float64]),
)

# OpenAPI type names PFFP writes into the DB. Populated into `entity_types`
# by `make_sqlite!`. Mirrors the union of SOM's TYPE_NAMES / SA_TYPE_NAMES
# for the subset PFFP actually emits — the PSIP and plant registries are
# omitted because PFFP never produces those. Two arrays because SOM keys the
# topology flag on whether the type maps to `planning_regions` /
# `balancing_topologies`; here we hard-code that distinction.
const _TOPOLOGY_TYPE_NAMES = [
    "Area",
    "LoadZone",
    "ACBus",
]

const _NON_TOPOLOGY_TYPE_NAMES = [
    "Arc",
    "AreaInterchange",
    "Line",
    "TransformerCircuit",
    "TwoWindingTransformer",
    "TwoTerminalGenericHVDCLine",
    "ThreeWindingTransformer",
    "PowerLoad",
    "StandardLoad",
    "FixedAdmittance",
    "ThermalStandard",
    "RenewableDispatch",
    "RenewableNonDispatch",
    "HydroDispatch",
    "EnergyReservoirStorage",
    "ImpedanceCorrectionData",
    # Subtypes that share tables with their parents. Registered so
    # `entities.entity_type` can record the concrete OpenAPI type.
    "DiscreteControlledACBranch",
    "TwoTerminalLCCLine",
    "TwoTerminalVSCLine",
    "FACTSControlDevice",
    "SwitchedAdmittance",
    "SynchronousCondenser",
    "InterruptibleStandardLoad",
]

"""
Initialize a fresh SQLite database with the Sienna schema: creates all
tables, indexes, and triggers, then seeds the metadata tables
(`entity_types`, `prime_mover_types`, `fuels`, `storage_technology_types`)
with the default enum populations.

Duplicated from `SiennaOpenAPIModels.jl/src/dbinterface/db_definition.jl:543`.
The only substantive change: `entity_types` is populated from the local
`_TOPOLOGY_TYPE_NAMES` + `_NON_TOPOLOGY_TYPE_NAMES` lists rather than SOM's
PSY-keyed `TYPE_NAMES` / `SA_TYPE_NAMES` / `SA_TYPE_NAMES_PSIP` /
`PLANT_TYPE_NAMES` registries.
"""
function make_sqlite!(db)
    for table in SQLITE_CREATE_STR
        DBInterface.execute(db, table)
    end
    for table in SQLITE_TRIGGERS_STR
        DBInterface.execute(db, table)
    end

    entity_type_stmt = DBInterface.prepare(
        db,
        "INSERT INTO entity_types (name, is_topology) VALUES (?, ?)",
    )
    for type_name in _TOPOLOGY_TYPE_NAMES
        DBInterface.execute(entity_type_stmt, (type_name, true))
    end
    for type_name in _NON_TOPOLOGY_TYPE_NAMES
        DBInterface.execute(entity_type_stmt, (type_name, false))
    end

    # Default prime mover types (derived from PowerSystems.PrimeMovers enums).
    pm_stmt = DBInterface.prepare(
        db,
        "INSERT INTO prime_mover_types (id, name, description) VALUES (?, ?, ?)",
    )
    default_prime_movers = [
        (1, "BA", "Battery Energy Storage"),
        (2, "BT", "Binary Cycle Turbine"),
        (3, "CA", "Compressed Air Energy Storage"),
        (4, "CC", "Combined Cycle"),
        (5, "CE", "Reciprocating Engine"),
        (6, "CP", "Concentrated Solar Power"),
        (7, "CS", "Combined Cycle Steam"),
        (8, "CT", "Combustion (Gas) Turbine"),
        (9, "ES", "Energy Storage"),
        (10, "FC", "Fuel Cell"),
        (11, "FW", "Flywheel Energy Storage"),
        (12, "GT", "Gas Turbine"),
        (13, "HA", "Hydro Francis"),
        (14, "HB", "Hydro Bulb"),
        (15, "HK", "Hydro Kaplan"),
        (16, "HY", "Hydro"),
        (17, "IC", "Internal Combustion Engine"),
        (18, "OT", "Other"),
        (19, "PS", "Pumped Storage"),
        (20, "PVe", "Photovoltaic"),
        (21, "ST", "Steam Turbine"),
        (22, "WS", "Wind Offshore"),
        (23, "WT", "Wind Onshore"),
    ]
    for (id, name, desc) in default_prime_movers
        DBInterface.execute(pm_stmt, (id, name, desc))
    end

    # Default fuels (derived from PowerSystems.ThermalFuels enums).
    fuel_stmt = DBInterface.prepare(
        db,
        "INSERT INTO fuels (id, name, description) VALUES (?, ?, ?)",
    )
    default_fuels = [
        (1, "COAL", "Coal"),
        (2, "ANTHRACITE_COAL", "Anthracite Coal"),
        (3, "BITUMINOUS_COAL", "Bituminous Coal"),
        (4, "LIGNITE_COAL", "Lignite Coal"),
        (5, "SUBBITUMINOUS_COAL", "Subbituminous Coal"),
        (6, "WASTE_COAL", "Waste Coal"),
        (7, "REFINED_COAL", "Refined Coal"),
        (8, "SYNTHESIS_GAS_COAL", "Synthesis Gas Coal"),
        (9, "DISTILLATE_FUEL_OIL", "Distillate Fuel Oil"),
        (10, "JET_FUEL", "Jet Fuel"),
        (11, "KEROSENE", "Kerosene"),
        (12, "PETROLEUM_COKE", "Petroleum Coke"),
        (13, "RESIDUAL_FUEL_OIL", "Residual Fuel Oil"),
        (14, "PROPANE", "Propane"),
        (15, "SYNTHESIS_GAS_PETROLEUM_COKE", "Synthesis Gas Petroleum Coke"),
        (16, "WASTE_OIL", "Waste Oil"),
        (17, "BLASTE_FURNACE_GAS", "Blaste Furnace Gas"),
        (18, "NATURAL_GAS", "Natural Gas"),
        (19, "OTHER_GAS", "Other Gas"),
        (20, "NUCLEAR", "Nuclear"),
        (21, "AG_BYPRODUCT", "Ag Byproduct"),
        (22, "MUNICIPAL_WASTE", "Municipal Waste"),
        (23, "OTHER_BIOMASS_SOLIDS", "Other Biomass Solids"),
        (24, "WOOD_WASTE_SOLIDS", "Wood Waste Solids"),
        (26, "OTHER_BIOMASS_LIQUIDS", "Other Biomass Liquids"),
        (27, "SLUDGE_WASTE", "Sludge Waste"),
        (28, "BLACK_LIQUOR", "Black Liquor"),
        (29, "WOOD_WASTE_LIQUIDS", "Wood Waste Liquids"),
        (30, "LANDFILL_GAS", "Landfill Gas"),
        (31, "OTHEHR_BIOMASS_GAS", "Other Biomass Gas"),
        (32, "GEOTHERMAL", "Geothermal"),
        (33, "WASTE_HEAT", "Waste Heat"),
        (34, "TIREDERIVED_FUEL", "Tirederived Fuel"),
        (35, "OTHER", "Other"),
        (36, "WIND", "Wind"),
        (37, "SOLAR", "Solar"),
    ]
    for (id, name, desc) in default_fuels
        DBInterface.execute(fuel_stmt, (id, name, desc))
    end

    # Default storage technology types (derived from PowerSystems.StorageTech enums).
    st_stmt = DBInterface.prepare(
        db,
        "INSERT INTO storage_technology_types (id, name, description) VALUES (?, ?, ?)",
    )
    default_storage_techs = [
        (1, "PTES", "Pumped Thermal Energy Storage"),
        (2, "LIB", "Lithium-Ion Battery"),
        (3, "LAB", "Lead Acid Battery"),
        (4, "FLWB", "Redox Flow Battery"),
        (5, "SIB", "Sodium Ion Battery"),
        (6, "ZIB", "Zinc Ion Battery"),
        (7, "HGS", "Hydrogen Gas Storage"),
        (8, "LAES", "Liquid Air Energy Storage"),
        (9, "OTHER_CHEM", "Chemical Storage"),
        (10, "OTHER_MECH", "Mechanical Storage"),
        (11, "OTHER_THERM", "Thermal Storage"),
    ]
    for (id, name, desc) in default_storage_techs
        DBInterface.execute(st_stmt, (id, name, desc))
    end
end

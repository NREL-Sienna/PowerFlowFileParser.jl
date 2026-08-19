const SKIP_PM_VALIDATION = false
const PS_MAX_LOG = parse(Int, get(ENV, "PS_MAX_LOG", "50"))

const DEFAULT_BASE_MVA = 100.0

const DEFAULT_SYSTEM_FREQUENCY = 60.0

const INFINITE_TIME = 1e4
const START_COST = 1e8
const INFINITE_COST = 1e8
const INFINITE_BOUND = 1e6
const BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL = 0.01

const PSSE_PARSER_TAP_RATIO_UBOUND = 1.5
const PSSE_PARSER_TAP_RATIO_LBOUND = 0.5
const PARSER_TAP_RATIO_CORRECTION_TOL = 1e-5

const ZERO_IMPEDANCE_REACTANCE_THRESHOLD = 1e-4

# Winding names for three-winding transformers
const WINDING_NAMES = Dict(
    1 => "primary",
    2 => "secondary",
    3 => "tertiary",
)

const WINDING_NAMES_PARSING = [
    "PRIMARY_WINDING",
    "SECONDARY_WINDING",
    "TERTIARY_WINDING",
]

const TRANSFORMER3W_PARAMETER_NAMES = [
    "COD", "CONT", "NOMV", "WINDV", "RMA", "RMI",
    "NTP", "VMA", "VMI", "RATA", "RATB", "RATC",
]

#################################################

const _PM_BUS_TYPE_ENUM = Dict(
    1 => "PQ",
    2 => "PV",
    3 => "REF",
    4 => "ISOLATED",
)

const _LOAD_CONFORMITY_ENUM = Dict(
    0 => "NON_CONFORMING",
    1 => "CONFORMING",
    2 => "UNDEFINED",
)
_loadconformity_string(val::Integer) = get(_LOAD_CONFORMITY_ENUM, Int(val), "UNDEFINED")

# Render a `ComplexF64` as the OpenAPI `ComplexNumber` dict shape
# (`{"real": ..., "imag": ...}`). Mirrors
# `sienna_to_json/common.jl:get_complex_number`.
_complex_to_dict(z::Complex) =
    Dict{String, Any}("real" => real(z), "imag" => imag(z))

const _GENERATOR_MAPPING_FILE = joinpath(@__DIR__, "generator_mapping_pm.yaml")

const _PRIME_MOVER_CANONICAL = (
    "BA", "BT", "CA", "CC", "CE", "CP", "CS", "CT", "ES", "FC", "FW", "GT",
    "HA", "HB", "HK", "HY", "IC", "PS", "OT", "ST", "PVe", "WT", "WS",
)

const _PRIME_MOVER_ALIASES = Dict(
    "w2" => "WT",
    "wind" => "WT",
    "pv" => "PVe",
    "solar" => "PVe",
    "rtpv" => "PVe",
    "nb" => "ST",
    "steam" => "ST",
    "hydro" => "HY",
    "ror" => "HY",
    "pump" => "PS",
    "pumped_hydro" => "PS",
    "nuclear" => "ST",
    "sync_cond" => "OT",
    "csp" => "CP",
    "un" => "OT",
    "storage" => "BA",
    "ice" => "IC",
)

const _STRING2PRIMEMOVER = let d = Dict{String, String}()
    for canonical in _PRIME_MOVER_CANONICAL
        d[lowercase(canonical)] = canonical
    end
    merge!(d, _PRIME_MOVER_ALIASES)
    d
end

const _FUEL_CANONICAL = (
    "ANTHRACITE_COAL", "BITUMINOUS_COAL", "LIGNITE_COAL", "SUBBITUMINOUS_COAL",
    "WASTE_COAL", "REFINED_COAL", "SYNTHESIS_GAS_COAL", "DISTILLATE_FUEL_OIL",
    "JET_FUEL", "KEROSENE", "PETROLEUM_COKE", "RESIDUAL_FUEL_OIL", "PROPANE",
    "SYNTHESIS_GAS_PETROLEUM_COKE", "WASTE_OIL", "BLASTE_FURNACE_GAS",
    "NATURAL_GAS", "OTHER_GAS", "AG_BYPRODUCT", "MUNICIPAL_WASTE",
    "OTHER_BIOMASS_SOLIDS", "WOOD_WASTE_SOLIDS", "OTHER_BIOMASS_LIQUIDS",
    "SLUDGE_WASTE", "BLACK_LIQUOR", "WOOD_WASTE_LIQUIDS", "LANDFILL_GAS",
    "OTHEHR_BIOMASS_GAS", "NUCLEAR", "WASTE_HEAT", "TIREDERIVED_FUEL",
    "COAL", "GEOTHERMAL", "OTHER",
)

const _FUEL_ALIASES = Dict(
    "ng" => "NATURAL_GAS",
    "nuc" => "NUCLEAR",
    "gas" => "NATURAL_GAS",
    "oil" => "DISTILLATE_FUEL_OIL",
    "dfo" => "DISTILLATE_FUEL_OIL",
    "sync_cond" => "OTHER",
)

const _STRING2FUEL = let d = Dict{String, String}()
    for canonical in _FUEL_CANONICAL
        d[lowercase(canonical)] = canonical
    end
    merge!(d, _FUEL_ALIASES)
    d
end

const _SHIFT_TO_GROUP_MAP = Dict{Float64, String}(
    0.0 => "GROUP_0",
    -30.0 => "GROUP_1",
    -150.0 => "GROUP_5",
    180.0 => "GROUP_6",
    150.0 => "GROUP_7",
    30.0 => "GROUP_11",
)

const _CONTROL_OBJECTIVE_MAP = Dict{Int, String}(
    0 => "FIXED",
    1 => "REACTIVE_POWER_FLOW",
    -1 => "REACTIVE_POWER_FLOW_DISABLED",
    2 => "VOLTAGE",
    -2 => "VOLTAGE_DISABLED",
    3 => "ACTIVE_POWER_FLOW",
    -3 => "ACTIVE_POWER_FLOW_DISABLED",
    4 => "CONTROL_OF_DC_LINE",
    -4 => "CONTROL_OF_DC_LINE_DISABLED",
    5 => "ASYMETRIC_ACTIVE_POWER_FLOW",
    -5 => "ASYMETRIC_ACTIVE_POWER_FLOW_DISABLED",
    -99 => "UNDEFINED",
)

_normalize_control_objective(val::Integer) =
    get(_CONTROL_OBJECTIVE_MAP, Int(val), "UNDEFINED")

const _DISCRETE_BRANCH_TYPE_MAP = Dict{Int, String}(
    0 => "SWITCH",
    1 => "BREAKER",
    2 => "OTHER",
)

const _BRANCH_STATUS_MAP = Dict{Int, String}(
    0 => "OPEN",
    1 => "CLOSED",
)

# FACTS control_mode: the PSS/E POM v33 manual and PSY's `FACTSOperationModes`
# enum both define exactly three modes — OOS=0, NML=1, BYP=2. The OpenAPI
# `FACTSControlDevice.control_mode` enum covers the same set.
const _FACTS_CONTROL_MODE_MAP = Dict{Int, String}(
    0 => "OOS",
    1 => "NML",
    2 => "BYP",
)

const _ICT_WINDING_CATEGORIES =
    ("TR2W_WINDING", "PRIMARY_WINDING", "SECONDARY_WINDING", "TERTIARY_WINDING")

const _ICT_3W_WINDING_KEYS = (
    ("primary", "PRIMARY_WINDING"),
    ("secondary", "SECONDARY_WINDING"),
    ("tertiary", "TERTIARY_WINDING"),
)

# Insertion order for the OpenAPI types: matches `ALL_DESERIALIZABLE_TYPES`
# / `ALL_PSY_TYPES` in `SiennaOpenAPIModels.jl/src/dbinterface/translation_constants.jl:59-86`,
# so FK references (e.g. ThermalStandard.bus → ACBus.id) resolve in order.
# Topology and arcs first, then branches, then injections.
const _MAKE_DATABASE_TYPE_ORDER = (
    :Area,
    :LoadZone,
    :ACBus,
    # Arcs are inserted by `write_arcs_to_db!` before the branch-like types
    # below, not via send_openapi_table_to_db!.
    :AreaInterchange,
    :Line,
    # TransformerCircuit rows must exist before the 2W/3W holders that FK
    # into them.
    :TransformerCircuit,
    :TwoWindingTransformer,
    :ThreeWindingTransformer,
    :TwoTerminalLCCLine,
    :TwoTerminalGenericHVDCLine,
    :TwoTerminalVSCLine,
    :DiscreteControlledACBranch,
    :FACTSControlDevice,
    :PowerLoad,
    :StandardLoad,
    :InterruptibleStandardLoad,
    :FixedAdmittance,
    :SwitchedAdmittance,
    :ThermalStandard,
    :RenewableDispatch,
    :RenewableNonDispatch,
    :HydroDispatch,
    :SynchronousCondenser,
    :EnergyReservoirStorage,
)

"""
Translate a PSS/E FACTS control_mode integer to the OpenAPI enum string
(0/1/2 → "OOS"/"NML"/"BYP"). Throws on any other integer.
"""
function _normalize_facts_control_mode(val::Integer)
    haskey(_FACTS_CONTROL_MODE_MAP, Int(val)) || throw(
        DataFormatError(
            "FACTS control_mode $val has no corresponding OpenAPI enum string",
        ),
    )
    return _FACTS_CONTROL_MODE_MAP[Int(val)]
end

_min_max_dict(min_val, max_val) =
    Dict{String, Any}("min" => min_val, "max" => max_val)

_up_down_dict(up_val, down_val) =
    Dict{String, Any}("up" => up_val, "down" => down_val)

_in_out_dict(in_val, out_val) =
    Dict{String, Any}("in" => in_val, "out" => out_val)

"""
Look up the canonical OpenAPI `prime_mover_type` enum string for a raw input
string (e.g. `"WIND"` → `"WT"`).
"""
function _normalize_prime_mover(raw::AbstractString)
    key = lowercase(strip(String(raw)))
    if haskey(_STRING2PRIMEMOVER, key)
        return _STRING2PRIMEMOVER[key]
    end
    @warn "Unrecognized prime mover string $(repr(raw)); falling back to \"OT\""
    return "OT"
end

"""
Look up the canonical OpenAPI `fuel_type` enum string for a raw input string
(e.g. `"NG"` → `"NATURAL_GAS"`).
"""
function _normalize_fuel(raw::AbstractString)
    key = lowercase(strip(String(raw)))
    if haskey(_STRING2FUEL, key)
        return _STRING2FUEL[key]
    end
    @warn "Unrecognized fuel string $(repr(raw)); falling back to \"OTHER\""
    return "OTHER"
end

"""
Resolve a generator's per-unit base power.
"""
function _resolve_mbase(d::Dict, sys_mbase::Float64, gen_name::AbstractString)
    if d["mbase"] != 0.0
        return float(d["mbase"])
    end
    @warn "Generator $gen_name has base power equal to zero: $(d["mbase"]).
        Changing it to system base: $sys_mbase"
    return sys_mbase
end

# Functions for calculating generator values.

function _calculate_gen_rating(pmax::Float64, qmax::Float64, base_conversion::Float64)
    rating = sqrt(pmax^2 + qmax^2)
    if rating == 0.0
        @warn "Rating calculation returned 0.0. Changing to 1.0 in the p.u. of the device."
        return 1.0
    end
    return rating * base_conversion
end

function _calculate_ramp_limit_dict(d::Dict, gen_name::AbstractString)
    if haskey(d, "ramp_agc")
        return _up_down_dict(d["ramp_agc"], d["ramp_agc"])
    end
    if haskey(d, "ramp_10")
        return _up_down_dict(d["ramp_10"], d["ramp_10"])
    end
    if haskey(d, "ramp_30")
        return _up_down_dict(d["ramp_30"], d["ramp_30"])
    end
    if abs(d["pmax"]) > 0.0
        @debug "No ramp limits found for generator $gen_name. Using pmax as ramp limit."
        return _up_down_dict(abs(d["pmax"]), abs(d["pmax"]))
    end
    @warn "Not enough information to determine ramp limit for generator $gen_name. Returning nothing"
    return nothing
end

"""
Load the YAML mapping from `(fuel, unit_type)` tuples to OpenAPI generator
type tags.
"""
function _get_generator_mapping(filename::AbstractString)
    genmap = open(YAML.load, filename)
    mappings = Dict{NamedTuple{(:fuel, :unit_type), Tuple{Any, Any}}, Symbol}()
    for (gen_type, vals) in genmap
        tag = Symbol(gen_type)
        for val in vals
            key = (fuel = val["fuel"], unit_type = val["type"])
            if haskey(mappings, key)
                error("duplicate generator mappings: $tag $(key.fuel) $(key.unit_type)")
            end
            mappings[key] = tag
        end
    end
    return mappings
end

"""
Look up the OpenAPI generator type tag for a given `(fuel, unit_type)` pair.
"""
function _get_generator_type(fuel, unit_type, mappings)
    fuel_str = isnothing(fuel) ? "" : uppercase(String(fuel))
    unit_type_str = uppercase(String(unit_type))
    for ut in (unit_type_str, nothing), fu in (fuel_str, nothing)
        key = (fuel = fu, unit_type = ut)
        if haskey(mappings, key)
            return mappings[key]
        end
    end
    @error "No mapping for generator fuel=$fuel_str unit_type=$unit_type_str"
    return nothing
end

"""
Extract proportional/constant terms from an `IS.LinearCurve` and wrap as
an OpenAPI `InputOutputCurve` dict.
"""
_linear_curve_to_io_dict(curve) =
    _linear_io_curve_dict(IS.get_proportional_term(curve), IS.get_constant_term(curve))

"""
Monotonic id minter for OpenAPI-shaped component dicts. Guarantees
cross-component-type uniqueness.
"""
mutable struct IDGenerator
    nextid::Int64
    key2int::Dict{Tuple{Symbol, Any}, Int64}
end

IDGenerator(nextid::Int64 = 1) = IDGenerator(nextid, Dict{Tuple{Symbol, Any}, Int64}())

"""
Return the int id for `(type_tag, natural_key)`, minting one from the
generator's counter if this is the first time the key has been seen.
"""
function getid!(ids::IDGenerator, type_tag::Symbol, natural_key)
    key = (type_tag, natural_key)
    if haskey(ids.key2int, key)
        return ids.key2int[key]
    end
    ids.key2int[key] = ids.nextid
    ids.nextid += 1
    return ids.key2int[key]
end

getid!(::IDGenerator, ::Symbol, ::Nothing) = nothing

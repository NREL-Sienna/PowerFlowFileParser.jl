# this function would be exactly the same for both System(PowerModelsData) and
# System(PowerFlowNetworkData) so it feels redundant to put in both power*.jl
# files. Instead I'm putting it here, but this also doesnt feel like the right
# place for it

"""
Function that creates a database from System.

"""
function make_database(sys::System, database_name::Union{String, Nothing})

    # making sure that database_name isn't an existing file
    if isfile(database_name) || isfile(string(database_name, ".sqlite"))
        error("database with this name already exists")
    # creating database file name with .sqlite extension
    elseif !isfile(database_name)
        if !endswith(database_name, ".sqlite")
            database_name = string(database_name, ".sqlite")
        elseif endswith(database_name, ".sqlite")
            database_name = database_name
        end
    end

    # making database, with time series, if given
    db = SQLite.DB(database_name)
    SiennaOpenAPIModels.make_sqlite!(db)
    ids = SiennaOpenAPIModels.IDGenerator()
    SiennaOpenAPIModels.sys2db!(db, sys, ids)
    #TODO (this repo and PowerTableDataParser) this check should already be
    #built in to serialize_timeseries!()
    if IS.get_num_time_series(sys.data) !== 0
        SiennaOpenAPIModels.serialize_timeseries!(db, sys, ids)
    end
end

const GENERATOR_MAPPING_FILE_PM =
    joinpath(dirname(pathof(PowerSystems)), "parsers", "generator_mapping_pm.yaml")

const SKIP_PM_VALIDATION = false

const PSSE_PARSER_TAP_RATIO_UBOUND = 1.5
const PSSE_PARSER_TAP_RATIO_LBOUND = 0.5
const INFINITE_BOUND = 1e6

const STRING2FUEL =
    Dict((normalize(string(x); casefold = true) => x) for x in instances(ThermalFuels))
merge!(
    STRING2FUEL,
    Dict(
        "ng" => ThermalFuels.NATURAL_GAS,
        "nuc" => ThermalFuels.NUCLEAR,
        "gas" => ThermalFuels.NATURAL_GAS,
        "oil" => ThermalFuels.DISTILLATE_FUEL_OIL,
        "dfo" => ThermalFuels.DISTILLATE_FUEL_OIL,
        "sync_cond" => ThermalFuels.OTHER,
        "geothermal" => ThermalFuels.GEOTHERMAL,
        "ag_byproduct" => ThermalFuels.AG_BYPRODUCT,
    ),  
)

const STRING2PRIMEMOVER =
    Dict((normalize(string(x); casefold = true) => x) for x in instances(PrimeMovers))
merge!(
    STRING2PRIMEMOVER,
    Dict(
        "w2" => PrimeMovers.WT,
        "wind" => PrimeMovers.WT,
        "pv" => PrimeMovers.PVe,
        "solar" => PrimeMovers.PVe,
        "rtpv" => PrimeMovers.PVe,
        "nb" => PrimeMovers.ST,
        "steam" => PrimeMovers.ST,
        "hydro" => PrimeMovers.HY,
        "ror" => PrimeMovers.HY,
        "pump" => PrimeMovers.PS,
        "pumped_hydro" => PrimeMovers.PS,
        "nuclear" => PrimeMovers.ST,
        "sync_cond" => PrimeMovers.OT,
        "csp" => PrimeMovers.CP,
        "un" => PrimeMovers.OT,
        "storage" => PrimeMovers.BA,
        "ice" => PrimeMovers.IC,
    ),
)

"""Return a dict where keys are a tuple of input parameters (fuel, unit_type) and values are
generator types."""
function get_generator_mapping(filename::String)
    genmap = open(filename) do file
        YAML.load(file)
    end 

    mappings = Dict{NamedTuple, DataType}()
    for (gen_type, vals) in genmap
        if gen_type == "GenericBattery"
            @warn "GenericBattery type is no longer supported. The new type is EnergyReservoirStorage"
            gen = EnergyReservoirStorage
        else
            gen = getfield(PowerSystems, Symbol(gen_type))
        end 
        for val in vals
            key = (fuel = val["fuel"], unit_type = val["type"])
            if haskey(mappings, key)
                error("duplicate generator mappings: $gen $(key.fuel) $(key.unit_type)")
            end 
            mappings[key] = gen 
        end 
    end 

    return mappings
end

"""Return the PowerSystems generator type for this fuel and unit_type."""
function get_generator_type(fuel, unit_type, mappings::Dict{NamedTuple, DataType})
    fuel = isnothing(fuel) ? "" : uppercase(fuel)
    unit_type = uppercase(unit_type)
    generator = nothing

    # Try to match the unit_type if it's defined. If it's nothing then just match on fuel.
    for ut in (unit_type, nothing), fu in (fuel, nothing)
        key = (fuel = fu, unit_type = ut)
        if haskey(mappings, key)
            generator = mappings[key]
            break
        end
    end

    if isnothing(generator)
        @error "No mapping for generator fuel=$fuel unit_type=$unit_type"
    end

    return generator
end

function calculate_gen_rating(
    active_power_limits::Union{MinMax, Nothing},
    reactive_power_limits::Union{MinMax, Nothing},
    base_conversion::Float64,
)
    reactive_power_max = isnothing(reactive_power_limits) ? 0.0 : reactive_power_limits.max
    return calculate_gen_rating(
        active_power_limits.max,
        reactive_power_max,
        base_conversion,
    )
end

function calculate_gen_rating(
    active_power_max::Float64,
    reactive_power_max::Float64,
    base_conversion::Float64,
)
    rating = sqrt(active_power_max^2 + reactive_power_max^2)
    if rating == 0.0
        @warn "Rating calculation returned 0.0. Changing to 1.0 in the p.u. of the device."
        return 1.0
    end
    return rating * base_conversion
end

function calculate_ramp_limit(
    d::Dict{String, Any},
    gen_name::Union{SubString{String}, String},
)
    if haskey(d, "ramp_agc")
        return (up = d["ramp_agc"], down = d["ramp_agc"])
    end
    if haskey(d, "ramp_10")
        return (up = d["ramp_10"], down = d["ramp_10"])
    end
    if haskey(d, "ramp_30")
        return (up = d["ramp_30"], down = d["ramp_30"])
    end
    if abs(d["pmax"]) > 0.0
        @debug "No ramp limits found for generator $(gen_name). Using pmax as ramp limit."
        return (up = abs(d["pmax"]), down = abs(d["pmax"]))
    end
    @warn "Not enough information to determine ramp limit for generator $(gen_name). Returning nothing"
    return nothing
end

function parse_enum_mapping(::Type{ThermalFuels}, fuel::AbstractString)
    return STRING2FUEL[normalize(fuel; casefold = true)]
end

function parse_enum_mapping(::Type{ThermalFuels}, fuel::Symbol)
    return parse_enum_mapping(ThermalFuels, string(fuel))
end

function parse_enum_mapping(::Type{PrimeMovers}, prime_mover::AbstractString)
    return STRING2PRIMEMOVER[normalize(prime_mover; casefold = true)]
end

function parse_enum_mapping(::Type{PrimeMovers}, prime_mover::Symbol)
    return parse_enum_mapping(PrimeMovers, string(prime_mover))
end

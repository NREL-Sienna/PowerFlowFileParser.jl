isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export PowerFlowDataNetwork
#export System # this function is tested via PowerFlowFileParser.System
export parse_file

#################################################################################
# Imports

import PowerFlowData
import LinearAlgebra # in PSY only used in src/pm_io/data.jl 
import DataStructures: SortedDict
# import CSV
# import DataFrames
# import JSON3
# import SiennaOpenAPIModels
# import SQLite
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems

import PowerSystems
const PSY = PowerSystems

# should I import entire model library? end user might build a system with any
# object in model library, but at the same time we only want to support the
# current objects we build in this repo

# importing PSY.System. Previously, when just exporting System as defined in
# this repo I got an error saying there was no method for
# System(PowerFlowDataNetwork). Whenever System is tested, its the method from
# this repo. But that System is defined using methods of System from PSY as
# well.

import PowerSystems:
    ACBus,
    ACBusTypes,
    TwoWindingTransformer,
    ThreeWindingTransformer,
    ImpedanceCorrectionData,
    Area,
    WindingCategory,
    WindingGroupNumber,
    System,
    get_component,
    add_component!,
    set_ext!,
    has_component,
    StandardLoad,
    get_name,
    LoadZone,
    set_load_zone!,
    PowerLoad,
    ThermalStandard,
    GeneratorCostModels,
    QuadraticFunctionData,
    CostCurve,
    InputOutputCurve,
    UnitSystem,
    ThermalGenerationCost,
    MinMax,
    ThermalFuels,
    PrimeMovers,
    Line,
    DiscreteControlledACBranch,
    Transformer2W,
    TapTransformer,
    PhaseShiftingTransformer,
    get_bustype,
    Arc,
    FixedAdmittance,
    check,
    HydroDispatch,
    HydroTurbine,
    RenewableDispatch,
    RenewableGenerationCost,
    get_slopes,
    PiecewiseLinearData,
    RenewableNonDispatch,
    SynchronousCondenser,
    HydroGenerationCost,
    EnergyReservoirStorage,
    LinearCurve,
    TwoTerminalGenericHVDCLine,
    StorageTech

import InfrastructureSystems:
    DataFormatError

#################################################################################
# Includes

include("powerflowdata_data.jl")
include("power_models_data.jl")
include("common.jl")
include("definitions.jl")
include("im_io.jl")
include("pm_io.jl")
#include("utils/print.jl")
   
#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

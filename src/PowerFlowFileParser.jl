isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export PowerFlowDataNetwork
export parse_file

#################################################################################
# Imports

import PowerFlowData
import LinearAlgebra # in PSY only used in src/pm_io/data.jl
import DataStructures: SortedDict
# import CSV
# import DataFrames
# import JSON3
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems

import InfrastructureSystems:
    DataFormatError

#################################################################################
# Includes

include("definitions.jl")
include("powerflowdata_data.jl")
include("power_models_data.jl")
include("im_io.jl")
include("pm_io.jl")

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

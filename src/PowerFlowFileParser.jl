isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export parse_file
export merge_multi_case
export presence_summary

#################################################################################
# Imports

import LinearAlgebra
import DataStructures: SortedDict
import Unicode: normalize
import YAML

import InfrastructureSystems
const IS = InfrastructureSystems

import InfrastructureSystems:
    DataFormatError,
    LinearCurve

#################################################################################
# Includes

include("definitions.jl")
include("power_models_data.jl")
include("im_io.jl")
include("pm_io.jl")
include("multi_case.jl")
include("multi_case_display.jl")
#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

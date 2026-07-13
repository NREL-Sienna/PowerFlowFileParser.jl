isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export parse_file

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

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

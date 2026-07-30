isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export parse_file
export OpenAPISystem

#################################################################################
# Imports

import LinearAlgebra
import DataStructures: SortedDict
import Unicode: normalize
import YAML
import JSON
import OpenAPI
import PowerCoreOpenAPIModels
import PowerOperationsOpenAPIModels
const PC = PowerCoreOpenAPIModels
const PO = PowerOperationsOpenAPIModels

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
include("openapi/identity.jl")
include("openapi/units.jl")
include("openapi/container.jl")

#################################################################################

using DocStringExtensions

@template (FUNCTIONS, METHODS) = """
                                 $(TYPEDSIGNATURES)
                                 $(DOCSTRING)
                                 """

#################################################################################

end

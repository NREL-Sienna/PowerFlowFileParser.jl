isdefined(Base, :__precompile__) && __precompile__()

module PowerFlowFileParser

#################################################################################
# Exports

export PowerModelsData
export parse_file
export IDGenerator
export ParsedOpenAPIObjects
export parse_to_openapi_objects
export make_database
export save_database
export send_openapi_table_to_db!

#################################################################################
# Imports

import LinearAlgebra
import DataStructures: SortedDict
import PowerCoreOpenAPIModels
import PowerOperationsOpenAPIModels
import PowerOperationsOpenAPIModels: ImpedanceCorrectionData
import SQLite
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
include("dbinterface/db_schema.jl")
include("dbinterface/db_helpers.jl")
include("db_write.jl")
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

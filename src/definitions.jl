# copied from PowerSystems/src/definitions.jl

const PS_MAX_LOG = parse(Int, get(ENV, "PS_MAX_LOG", "50"))

const BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL = 0.01

const WINDING_NAMES_PARSING = [
   "PRIMARY_WINDING",
   "SECONDARY_WINDING",
   "TERTIARY_WINDING",
]

const TRANSFORMER3W_PARAMETER_NAMES = [
    "COD", "CONT", "NOMV", "WINDV", "RMA", "RMI",
    "NTP", "VMA", "VMI", "RATA", "RATB", "RATC",
]

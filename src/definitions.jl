# copied from PowerSystems/src/definitions.jl

const PS_MAX_LOG = parse(Int, get(ENV, "PS_MAX_LOG", "50"))

const BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL = 0.01

const WINDING_NAMES = Dict(
    WindingCategory.PRIMARY_WINDING => "primary",
    WindingCategory.SECONDARY_WINDING => "secondary",
    WindingCategory.TERTIARY_WINDING => "tertiary",
)

const TRANSFORMER3W_PARAMETER_NAMES = [
    "COD", "CONT", "NOMV", "WINDV", "RMA", "RMI",
    "NTP", "VMA", "VMI", "RATA", "RATB", "RATC",
]

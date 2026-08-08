# Ported from PowerSystemCaseBuilder/src/parsers/power_models_data.jl:1349-1388
# (make_switch_breaker, read_switch_breaker!, called once per device type there and
# folded into one reader here since all three pm sections share an identical row shape).
#
# None of "switch"/"breaker"/"generic_connector" are native PowerModels sections —
# `_psse2pm_switch_breaker!` (`pm_io/psse.jl`) writes `r`/`rating`/`active_power_flow`/
# `reactive_power_flow` directly from PSS/E fields with no `_make_per_unit!` pass over
# them, so every value here is used exactly as parsed: no `sys_mbase` scaling anywhere in
# this file, matching the oracle. `active_power_flow`/`reactive_power_flow` are always
# `0.0` at the source (`_build_switch_breaker_sub_data` never computes a flow for a
# switching device), so this is a fixed-zero passthrough, not a simplification.
#
# `state`'s isolated-bus zeroing already happened while parsing
# (`branch_isolated_bus_modifications!`, `pm_io/psse.jl`, called from
# `_psse2pm_switch_breaker!` itself), so unlike `make_line!`/`make_transformer_2w!` this
# needs no separate `_branch_available`-style guard — matching the oracle, which applies
# none either.
#
# MATPOWER's own native `mpc.switch` table (parsed by `pm_io/matpower.jl`: a distinct
# shape — `f_bus`/`t_bus`/`psw`/`qsw`/`state`/`thermal_rating`/`status`, none of `r`/`x`/
# `rating`/`discrete_branch_type`) is NOT this reader's target and is not exercised by any
# fixture in this repo. PSCB's own `read_switch_breaker!` would `KeyError` on it exactly
# the same way this reader does — an existing oracle gap, not one this task introduces or
# fixes.

"""PowerModels/PSS/E discrete-branch-type codes (`0`/`1`/`2`), in the schema's
`DiscreteControlledACBranch.discrete_branch_type` spelling. Ported from PSY's own
`DiscreteControlledBranchType` enum (`SWITCH = 0`, `BREAKER = 1`, `OTHER = 2`,
`definitions.jl`)."""
const DISCRETE_BRANCH_TYPE_NAMES = Dict(0 => "SWITCH", 1 => "BREAKER", 2 => "OTHER")

function _discrete_branch_type(code::Integer)
    if !haskey(DISCRETE_BRANCH_TYPE_NAMES, code)
        throw(IS.DataFormatError("unsupported discrete branch type=$code"))
    end
    return DISCRETE_BRANCH_TYPE_NAMES[code]
end

"""PSS/E STAT/ST-style 0/1 status, in the schema's `DiscreteControlledACBranch.branch_status`
spelling. Ported from PSY's own `DiscreteControlledBranchStatus` enum (`OPEN = 0`,
`CLOSED = 1`, `definitions.jl`)."""
function _discrete_branch_status(code::Integer)
    if code == 0
        return "OPEN"
    elseif code == 1
        return "CLOSED"
    end
    throw(IS.DataFormatError("unsupported discrete branch status=$code"))
end

"""
A switch, breaker, or generic connector as a `DiscreteControlledACBranch`. Ported from
PSCB's `make_switch_breaker` (:1349-1363). `base_power` is not set by the oracle's
constructor call — PSY's own `add_component!` back-fills it from the system base for
every `BasePowerKind::SystemBasePower` type, `DiscreteControlledACBranch` among them
(matching `Line`'s D-C convention) — so this reader sets it explicitly, same as
`make_line!`/`make_switch_from_zero_impedance_branch!` do for the same reason.
"""
function make_switch_breaker!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    from_id::Int,
    to_id::Int,
    sys_mbase::Float64,
)
    arc_id = add_arc!(sys, from_id, to_id)
    state = Int(d["state"])

    component = PO.DiscreteControlledACBranch()
    set_value!(component, :id, register!(reg, "DiscreteControlledACBranch", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(state))
    set_value!(component, :active_power_flow, d["active_power_flow"], "MW")
    set_value!(component, :reactive_power_flow, d["reactive_power_flow"], "MVAr")
    set_value!(component, :arc, arc_id)
    set_value!(component, :base_power, sys_mbase, "MVA")
    set_value!(component, :r, d["r"], "pu")
    set_value!(component, :x, d["x"], "pu")
    # Verbatim-oracle passthrough: unlike `_get_rating` (Line/TransformerCircuit), PSCB's
    # own `make_switch_breaker` never treats a zero rating as INFINITE_BOUND here.
    set_value!(component, :rating, d["rating"], "MVA")
    set_value!(
        component,
        :discrete_branch_type,
        _discrete_branch_type(Int(d["discrete_branch_type"])),
    )
    set_value!(component, :branch_status, _discrete_branch_status(state))
    add_component!(sys, component)
    extras = get(d, "ext", Dict{String, Any}())
    if !isempty(extras)
        set_ext!(sys, get_value(component, :id), extras)
    end
    return
end

"""
Create one `DiscreteControlledACBranch` per `data["switch"]`/`data["breaker"]`/
`data["generic_connector"]` entry. Ported from PSCB's `read_switch_breaker!`
(:1365-1388).
"""
function read_switch_breaker!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    sys_mbase = get_base_power(sys)
    bus_lookup = _pm_bus_lookup(sys)
    _get_name = get(kwargs, :branch_name_formatter, _get_pm_branch_name)

    for device_type in ("switch", "breaker", "generic_connector")
        for (_, d) in _sorted_pm_entries(get(data, device_type, Dict{String, Any}()))
            from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
            from_name, = bus_lookup[from_number]
            to_name, = bus_lookup[to_number]
            from_id = get_bus_id(reg, from_number)
            to_id = get_bus_id(reg, to_number)
            name = String(_get_name(d, from_name, to_name))
            make_switch_breaker!(sys, reg, name, d, from_id, to_id, sys_mbase)
        end
    end
    return
end

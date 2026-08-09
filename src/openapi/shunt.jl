# Ported from PowerSystemCaseBuilder/src/parsers/power_models_data.jl:1904-2036
# (make_switched_shunt, read_switched_shunt!, make_shunt, make_facts, read_facts!,
# read_shunt!). None of `"shunt"`/`"switched_shunt"`/`"facts"` are native PowerModels
# sections, so `_make_per_unit!` never touches them; every field PFFP's own psse.jl
# parser writes is used exactly as written (either PSS/E-native per-unit-at-unity-voltage,
# `ShuntAdmittanceUnitBasis.DEVICE_MVAR`, for shunt admittances, or a plain natural value
# for everything else) — no `sys_mbase` scaling anywhere in this file.

"""Fixed admittance (PSS/E `FIXED SHUNT`). Ported from PSCB's `make_shunt`
(:1959-1966)."""
function make_fixed_admittance!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    bus_id::Int,
)
    component = PO.FixedAdmittance()
    set_value!(component, :id, register!(reg, "FixedAdmittance", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :admittance_units, "DEVICE_MVAR")
    set_value!(component, :Y, (real = d["gs"], imag = d["bs"]), "MVAr")
    add_component!(sys, component)
    return
end

"""PSS/E MODSW switched-shunt control-mode codes, in the schema's
`SwitchedAdmittance.control_mode` spelling. Ported from PSY's
`SwitchedAdmittanceControlMode` enum (`definitions.jl:155-163`)."""
const SWITCHED_ADMITTANCE_CONTROL_MODE_NAMES = Dict(
    -99 => "UNDEFINED",
    0 => "FIXED",
    1 => "DISCRETE_VOLTAGE",
    2 => "CONTINUOUS_VOLTAGE",
    3 => "DISCRETE_REACTIVE_PLANT",
    4 => "DISCRETE_REACTIVE_VSC",
    5 => "DISCRETE_ADMITTANCE_REMOTE",
)

function _switched_admittance_control_mode(code::Integer)
    if !haskey(SWITCHED_ADMITTANCE_CONTROL_MODE_NAMES, code)
        throw(IS.DataFormatError("unsupported switched shunt MODSW control mode=$code"))
    end
    return SWITCHED_ADMITTANCE_CONTROL_MODE_NAMES[code]
end

"""
Assign `Y_increase`: an array of complex admittances sharing `admittance_units`'s
discriminated unit. `units.jl`'s generic compound-value path builds ONE compound object
per call and cannot construct a `Vector` of them; this is the only array-of-compound
shape any reader needs, so it reuses `units.jl`'s private `_declared`/`_convert` here
rather than extending `set_value!` for a single call site.
"""
function _set_y_increase!(
    component,
    values::Vector{ComplexF64},
    source_unit::AbstractString,
)
    target, quantity = _declared(component, :Y_increase)
    converted = [
        PC.ComplexNumber(;
            real = _convert(component, :Y_increase, real(v), source_unit, target, quantity),
            imag = _convert(component, :Y_increase, imag(v), source_unit, target, quantity),
        ) for v in values
    ]
    setproperty!(component, :Y_increase, converted)
    return
end

"""
Switched admittance (PSS/E `SWITCHED SHUNT`). Ported from PSCB's `make_switched_shunt`
(:1904-1933).

`admittance_limits` mirrors PSCB's own field verbatim: PSS/E's `VSWLO`/`VSWHI` are a
controlled-voltage band, not an admittance band, despite the oracle's field name — a
pre-existing PSCB naming quirk reproduced faithfully, not fixed here.
"""
function make_switched_admittance!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    bus_id::Int,
)
    control_mode = _switched_admittance_control_mode(Int(d["control_mode"]))

    component = PO.SwitchedAdmittance()
    set_value!(component, :id, register!(reg, "SwitchedAdmittance", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["status"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :admittance_units, "DEVICE_MVAR")
    set_value!(component, :Y, (real = d["gs"], imag = d["bs"]), "MVAr")
    set_value!(component, :number_of_steps, d["step_number"])
    _set_y_increase!(component, d["y_increment"], "MVAr")
    admittance_limits = d["admittance_limits"]
    set_value!(component, :admittance_limits,
        (min = admittance_limits[1], max = admittance_limits[2]), "MVAr")
    set_value!(component, :control_mode, control_mode)
    set_value!(
        component,
        :regulated_bus_number,
        Int(get(d, "regulated_bus_number", 0)),
        "1",
    )
    if haskey(d, "initial_status")
        set_value!(component, :initial_status, d["initial_status"])
    end
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    return
end

"""PSS/E FACTS MODE codes (0/1/2 — "Unavailable"/"Normal"/"Link bypassed", per
`pm_io/psse.jl:430`), in the schema's `FACTSControlDevice.control_mode` spelling. Ported
from PSY's `FACTSOperationModes` enum (`definitions.jl:98-102`). PSCB's own
`make_facts` guards only `d["control_mode"] > 3`, a stale bound from a since-shrunk enum;
this reader's bound is 0-2, the current enum's actual domain."""
const FACTS_CONTROL_MODE_NAMES = Dict(0 => "OOS", 1 => "NML", 2 => "BYP")

function _facts_control_mode(code::Integer)
    if !haskey(FACTS_CONTROL_MODE_NAMES, code)
        throw(IS.DataFormatError("unsupported FACTS control mode=$code"))
    end
    return FACTS_CONTROL_MODE_NAMES[code]
end

"""FACTS control device. Ported from PSCB's `make_facts` (:1968-1987). Series FACTS
(`tbus != 0`) are unsupported and only warned about, matching the oracle; this reader
still emits the STATCOM-simplified device."""
function make_facts!(
    sys::OpenAPISystem,
    reg::IdRegistry,
    name::AbstractString,
    d::Dict,
    bus_id::Int,
)
    if d["tbus"] != 0
        @warn "Series FACTs not supported for $name."
    end
    control_mode = _facts_control_mode(Int(d["control_mode"]))

    component = PO.FACTSControlDevice()
    set_value!(component, :id, register!(reg, "FACTSControlDevice", name))
    set_value!(component, :name, name)
    set_value!(component, :available, Bool(d["available"]))
    set_value!(component, :bus, bus_id)
    set_value!(component, :control_mode, control_mode)
    set_value!(component, :voltage_setpoint_units, "DEVICE_BASE")
    set_value!(component, :voltage_setpoint, d["voltage_setpoint"], "pu")
    set_value!(component, :max_shunt_current, d["max_shunt_current"], "MVA")
    set_value!(component, :reactive_power_required, get(d, "reactive_power_required", 0.0),
        "1")
    set_value!(
        component,
        :regulated_bus_number,
        Int(get(d, "regulated_bus_number", 0)),
        "1",
    )
    add_component!(sys, component)
    set_component_ext!(sys, component, get(d, "ext", Dict{String, Any}()))
    return
end

"""
Create one `FixedAdmittance` per `data["shunt"]` entry, one `SwitchedAdmittance` per
`data["switched_shunt"]` entry, and one `FACTSControlDevice` per `data["facts"]` entry.
Ported from PSCB's `read_shunt!`/`read_switched_shunt!`/`read_facts!` (:1935-2036), run
together as one stage.

Deviates from the oracle in one place: PSCB's `read_facts!` reads its name formatter under
`:bus_name_formatter`, the same kwarg `read_bus!` uses — a copy-paste artifact, since a
real bus formatter would `KeyError` on a FACTS entry. This reader uses
`:facts_name_formatter` instead, with the same default and identical behavior for any
caller that overrides neither.
"""
function read_shunts!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    _get_shunt_name = get(kwargs, :shunt_name_formatter, _get_pm_dict_name)
    _get_switched_shunt_name =
        get(kwargs, :switched_shunt_name_formatter, _get_pm_dict_name)
    _get_facts_name = get(kwargs, :facts_name_formatter, _get_pm_dict_name)

    for (d_key, d) in _sorted_pm_entries(get(data, "shunt", Dict{String, Any}()))
        d["name"] = get(d, "name", string(d_key))
        name = String(_get_shunt_name(d))
        bus_id = get_bus_id(reg, Int(d["shunt_bus"]))
        make_fixed_admittance!(sys, reg, name, d, bus_id)
    end

    for (d_key, d) in _sorted_pm_entries(get(data, "switched_shunt", Dict{String, Any}()))
        d["name"] = get(d, "name", string(d_key))
        name = String(_get_switched_shunt_name(d))
        bus_id = get_bus_id(reg, Int(d["shunt_bus"]))
        make_switched_admittance!(sys, reg, name, d, bus_id)
    end

    for (d_key, d) in _sorted_pm_entries(get(data, "facts", Dict{String, Any}()))
        d["name"] = get(d, "name", string(d_key))
        name = String(_get_facts_name(d))
        bus_number = Int(d["bus"])
        full_name = "$(bus_number)_$(name)"
        bus_id = get_bus_id(reg, bus_number)
        make_facts!(sys, reg, full_name, d, bus_id)
    end
    return
end

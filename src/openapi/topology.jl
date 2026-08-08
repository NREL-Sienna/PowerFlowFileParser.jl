# Ported from PowerSystemCaseBuilder/src/parsers/power_models_data.jl (read_bus!,
# read_loadzones!, and the Arc id path shared by the branch/dc_branch/transformer_3w
# readers a later sub-task adds).
#
# `PowerModelsData(file)` defaults `pm_data_corrections = true`, which runs PowerModels'
# `_make_per_unit!`: every power quantity in `data` (including load pd/qd) arrives as
# system per-unit on `baseMVA`, not natural units. The schemas' ActivePower/
# ReactivePower quantities have no "pu" row (D2 in
# `.claude/plans/2026-08-05-pffp-openapi-emit-layer.md`), so every power value this file
# writes is multiplied back by `baseMVA` before `set_value!` — the conversion the
# document requires, not a workaround.
#
# Two quantities need no such rescaling: `vm`/`vmin`/`vmax` are already pu on `base_kv`,
# which is exactly what `ACBus.magnitude`/`voltage_limits` (`x-unit-base`) want, and `va`
# is already radians — PowerFlowFileParser converts PSS/E degrees to radians while
# parsing (`src/pm_io/data.jl`), so no conversion runs here either. `base_kv` itself is
# a natural quantity PowerModels never rebases.

"""PowerModels `bus_type` codes 1-4, in the schema's `ACBus.bustype` spelling.

PowerModels never emits code 5; the schema's fifth option, `"SLACK"`, is reached only
through the `area_slack` override below, matching the oracle's `set_bustype!` call.
"""
const PM_BUS_TYPE_NAMES = ("PQ", "PV", "REF", "ISOLATED")

function _bustype_name(code::Integer)
    if !(1 <= code <= length(PM_BUS_TYPE_NAMES))
        throw(
            IS.DataFormatError(
                "unsupported PowerModels bus_type=$code; expected 1-$(length(PM_BUS_TYPE_NAMES))",
            ),
        )
    end
    return PM_BUS_TYPE_NAMES[code]
end

"""
Default bus name: the pm dict's own `"name"`, `bus_i`-suffixed only when names collide
across the file. Falls back to `source_id` for a bus with no `"name"` at all (the
Matpower path never carries one).
"""
function _default_bus_name(d::Dict, unique_names::Bool)
    if haskey(d, "name")
        if unique_names
            return strip(d["name"])
        end
        return string(strip(d["name"]), "_", d["bus_i"])
    end
    return strip(join(string.(d["source_id"]), "-"))
end

"""Whether every bus carrying a `"name"` in `bus_data` has a distinct one."""
function _unique_bus_names(bus_data)
    seen = Set{String}()
    for (_, d) in bus_data
        if !haskey(d, "name")
            continue
        end
        if d["name"] in seen
            return false
        end
        push!(seen, d["name"])
    end
    return true
end

"""
Return the id of the named `Area`, creating it with a zero peak on first sight.

PSCB's oracle never back-fills an `Area`'s peak from load data — only `LoadZone` does,
via `read_loadzones!` below — so this ports that asymmetry rather than "fixing" it; the
zero comes from `PO.Area`'s own default, not an explicit `set_value!` here.
"""
function _ensure_area!(sys::OpenAPISystem, name::AbstractString)
    reg = get_registry(sys)
    if has_id(reg, "Area", name)
        return get_id(reg, "Area", name)
    end
    area = PO.Area()
    id = register!(reg, "Area", name)
    set_value!(area, :id, id)
    set_value!(area, :name, name)
    # Area has no device base of its own; base_power records the system base here,
    # the documented convention for the types this applies to (D-C).
    set_value!(area, :base_power, get_base_power(sys), "MVA")
    add_component!(sys, area)
    return id
end

"""
Sum `data["load"]`'s pd/qd/pi/qi/py/qy per bus zone, converting pm's system per-unit
values to MW/MVAr (D2). Mirrors `read_loadzones!`'s `load_zone_map`.
"""
function _zone_peak_loads(data::Dict, base_power::Float64)
    per_unit_peaks = Dict{Int, Tuple{Float64, Float64}}()
    for load in values(get(data, "load", Dict{String, Any}()))
        zone = data["bus"][load["load_bus"]]["zone"]
        active, reactive = get(per_unit_peaks, zone, (0.0, 0.0))
        active +=
            load["pd"] + get(load, "pi", 0.0) + get(load, "py", 0.0)
        reactive +=
            load["qd"] + get(load, "qi", 0.0) + get(load, "qy", 0.0)
        per_unit_peaks[zone] = (active, reactive)
    end
    return Dict(
        zone => (active * base_power, reactive * base_power) for
        (zone, (active, reactive)) in per_unit_peaks
    )
end

"""
Create one `LoadZone` per distinct bus zone, with the summed bus load as its peak.

Runs before [`read_bus!`](@ref), which resolves each bus's zone to this id.
"""
function read_loadzones!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    zones = sort!(collect(Set(b["zone"] for b in values(data["bus"]))))
    peaks = _zone_peak_loads(data, get_base_power(sys))
    _get_name = get(kwargs, :loadzone_name_formatter, string)
    for zone in zones
        name = _get_name(zone)
        active, reactive = get(peaks, zone, (0.0, 0.0))
        load_zone = PO.LoadZone()
        set_value!(load_zone, :id, register!(reg, "LoadZone", name))
        set_value!(load_zone, :name, name)
        set_value!(load_zone, :peak_active_power, active, "MW")
        set_value!(load_zone, :peak_reactive_power, reactive, "MVAr")
        # LoadZone has no device base of its own; base_power records the system base
        # here, the documented convention for the types this applies to (D-C).
        set_value!(load_zone, :base_power, get_base_power(sys), "MVA")
        add_component!(sys, load_zone)
    end
    return
end

"""
Create an `ACBus` per pm dict bus row.

Every bus resolves its `Area` (created lazily here, per the oracle) and its `LoadZone`
(created by [`read_loadzones!`](@ref), which must run first) to an id. Iterates the pm
dict in bus-number order so id assignment — and therefore the emitted document — is
deterministic regardless of `Dict` iteration order.
"""
function read_bus!(sys::OpenAPISystem, data::Dict; kwargs...)
    reg = get_registry(sys)
    bus_data = sort(collect(data["bus"]); by = first)
    unique_names = _unique_bus_names(bus_data)
    default_naming = d -> _default_bus_name(d, unique_names)
    _get_bus_name = get(kwargs, :bus_name_formatter, default_naming)
    _get_area_name = get(kwargs, :area_name_formatter, string)
    _get_zone_name = get(kwargs, :loadzone_name_formatter, string)

    for (_, d) in bus_data
        name = strip(_get_bus_name(d))
        number = Int(d["bus_i"])
        area_id = _ensure_area!(sys, _get_area_name(d["area"]))
        zone_id = get_id(reg, "LoadZone", _get_zone_name(d["zone"]))

        bus = PO.ACBus()
        set_value!(bus, :id, register_bus!(reg, number, name))
        set_value!(bus, :number, number)
        set_value!(bus, :name, name)
        set_value!(bus, :available, Bool(get(d, "bus_status", true)))
        set_value!(bus, :bustype, _bustype_name(Int(d["bus_type"])))
        set_value!(bus, :area, area_id)
        set_value!(bus, :load_zone, zone_id)
        set_value!(bus, :base_voltage, d["base_kv"], "kV")
        set_value!(bus, :angle, d["va"], "rad")
        set_value!(bus, :magnitude, d["vm"], "pu")
        set_value!(bus, :voltage_limits, (min = d["vmin"], max = d["vmax"]), "pu")
        add_component!(sys, bus)

        # PSS/E's extended-bus-number slack convention (ISW), mapped onto "area_slack"
        # while parsing; overrides whatever bus_type said, matching the oracle.
        if get(d, "area_slack", false)
            set_value!(bus, :bustype, "SLACK")
        end
    end
    return
end

"""
Return the id of the `Arc` between two bus ids, creating it on first sight.

Parallel circuits (PSS/E allows several `CKT`s on one bus pair) share one arc. This is
scaffolding for the branch, dc_branch and transformer_3w readers a later sub-task adds;
nothing in this sub-task calls it outside its own tests.
"""
function add_arc!(sys::OpenAPISystem, from_id::Int, to_id::Int)
    id, created = arc_id!(get_registry(sys), from_id, to_id)
    if created
        arc = PO.Arc()
        set_value!(arc, :id, id)
        set_value!(arc, :from_id, from_id)
        set_value!(arc, :to_id, to_id)
        add_component!(sys, arc)
    end
    return id
end

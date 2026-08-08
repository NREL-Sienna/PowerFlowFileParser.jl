# Hand-written: the DEVICE_BASE post-build conversion pass.
#
# Every reader in this directory (load.jl, generation.jl, branch.jl, ...) computes and
# assigns natural-unit values (MW/MVAr/MVA) onto the OpenAPI components it builds,
# regardless of `unit_system` — `set_value!` (units.jl) only converts between compatible
# physical units (kW -> MW), never into a per-unit convention. Before this pass existed,
# a `unit_system = "DEVICE_BASE"` document stamped the flag but carried the same natural
# values as `"NATURAL_UNITS"`. This pass closes that gap: when the document is DEVICE_BASE,
# it walks every built component afterward and divides each power-family field by the
# component's own device base (or, for a type with no device base of its own, the
# document's system base) — the exact inverse of what PowerSystems' own `NaturalUnit`
# importer does (`src/openapi/import_handwritten.jl`/`src/models/generated/*.jl` there),
# so that PowerSystems' `DeviceBaseUnit` importer reading this document's numbers directly
# reproduces the same System a `NATURAL_UNITS` document produces through `NaturalUnit`.
#
# ── Field classification ─────────────────────────────────────────────────────────
#
# A field is converted when, mechanically:
#   - it declares a unit (`PC.has_declared_unit`);
#   - that unit is not relative to a sibling field (`!PC.has_unit_base` — e.g.
#     `ACBus.magnitude` is already pu on `base_voltage` regardless of document unit
#     system, so it is untouched here);
#   - its Type-level (not instance-level) `PC.declared_unit`/`PC.declared_quantity`
#     resolve without error. A field whose unit depends on a runtime discriminator field
#     (`TransformerCircuit.r`'s `parameter_units`, `FACTSControlDevice.voltage_setpoint`'s
#     `voltage_setpoint_units`, `TwoTerminalLCCLine`'s several `parameter_units`/
#     `dc_voltage_units` fields, `SwitchedAdmittance.Y`'s `admittance_units`, ...) only
#     defines the instance-level method, so the Type-level call falls through to
#     `PowerCoreOpenAPIModels`'s generic error stub — that governs its own convention
#     independent of the document's, and PowerSystems' own converters confirm it: identical
#     between `DeviceBaseUnit` and `NaturalUnit` in every case checked (`export_handwritten.jl`);
#   - that unit's quantity is power-family (`ActivePower`/`ReactivePower`/`ApparentPower`/
#     `ActivePowerChangeRate` — a generator/storage `ramp_limits` in MW/min is scaled by
#     device base exactly like its MW siblings in every PowerSystems converter checked).
#
# Two cases this mechanical rule cannot see, found by diffing PowerSystems'
# `to_openapi(..., ::DeviceBaseUnit)` against `::NaturalUnit)` field-by-field in
# `export_handwritten.jl`:
#   - `Area`/`LoadZone.peak_active_power`/`peak_reactive_power` (and
#     `TransmissionInterface.active_power_flow_limits`, not reachable from this package's
#     readers today) are schema-fixed-natural: always MW/MVAr, multiplied by the SYSTEM
#     base in BOTH of PowerSystems' export methods — not document-unit-system-governed at
#     all. `_DEVICEBASE_FIXED_NATURAL` lists them explicitly.
#   - `FACTSControlDevice` has no `base_power` field of its own; its one plain
#     power-family field (`max_shunt_current`) falls back to the document's system base,
#     the same fallback PowerSystems' own reserve/`TwoTerminalGenericHVDCLine` converters
#     use for a type with no per-device base. `_DEVICEBASE_SYSTEM_BASE_TYPES` lists the
#     document keys that need this fallback (only `FACTSControlDevice` is reachable from
#     this package's readers today; the reserve types are listed defensively in case a
#     future reader adds them).
#
# Anything else that reaches `_devicebase_own_base`'s error is a real gap — a component
# field this pass has not been taught to classify — not a value to skip.

const _DEVICEBASE_POWER_QUANTITIES =
    ("ActivePower", "ReactivePower", "ApparentPower", "ActivePowerChangeRate")

const _DEVICEBASE_FIXED_NATURAL = Set{Tuple{String, Symbol}}([
    ("Area", :peak_active_power),
    ("Area", :peak_reactive_power),
    ("LoadZone", :peak_active_power),
    ("LoadZone", :peak_reactive_power),
    ("TransmissionInterface", :active_power_flow_limits),
])

const _DEVICEBASE_SYSTEM_BASE_TYPES =
    Set(["FACTSControlDevice", "OnlineReserve", "OfflineReserve", "GroupReserve"])

"""Whether `T.prop`'s declared unit is fixed — resolvable from the Type alone, rather than
depending on a runtime discriminator field only the instance-level method reads."""
function _has_fixed_declared_unit(::Type{T}, prop::Symbol) where {T}
    try
        PC.declared_unit(T, Val(prop))
        return true
    catch e
        e isa ErrorException || rethrow()
        return false
    end
end

"""
Classify `key.prop` (PO type `T`) for the DEVICE_BASE pass: `:convert_own` (divide by the
component's own `base_power`), `:convert_system` (divide by the document's system base), or
`:skip`. See this file's header for the full rule.
"""
function _devicebase_classification(::Type{T}, key::AbstractString, prop::Symbol) where {T}
    # `base_power`/`base_power_12`/`base_power_23`/`base_power_31`: anchors themselves
    # (`ThreeWindingTransformer`'s three pairwise bases), never scaled by their own value.
    if startswith(string(prop), "base_power")
        return :skip
    end
    if !PC.has_declared_unit(T, Val(prop)) || PC.has_unit_base(T, Val(prop))
        return :skip
    end
    if !_has_fixed_declared_unit(T, prop)
        return :skip
    end
    if !(PC.declared_quantity(T, Val(prop)) in _DEVICEBASE_POWER_QUANTITIES)
        return :skip
    end
    if (String(key), prop) in _DEVICEBASE_FIXED_NATURAL
        return :skip
    end
    if key in _DEVICEBASE_SYSTEM_BASE_TYPES
        return :convert_system
    end
    return :convert_own
end

_devicebase_scale(::Nothing, ::Float64) = nothing
_devicebase_scale(x::Real, base::Float64) = Float64(x) / base

"""A compound field (`MinMax`/`UpDown`/`FromTo`/`FromToToFrom`, ...): every one of these PO
types holds only `Real`/`Nothing` leaves, so scaling every field generically is exact —
mirrors PowerSystems' own per-shape `_minmax_po_scaled`/`_updown_po_scaled_optional`/...
without needing one method per compound type here."""
function _devicebase_scale(x::T, base::Float64) where {T <: OpenAPI.APIModel}
    return T(; (f => _devicebase_scale(getfield(x, f), base) for f in fieldnames(T))...)
end

"""Own device base for `po`, naming `key`/`prop` in the error when the type has neither a
`base_power` field of its own nor a system-base fallback registered in
`_DEVICEBASE_SYSTEM_BASE_TYPES` — the loud path for a field this pass has not been taught
to classify, rather than a silent skip."""
function _devicebase_own_base(po, key::AbstractString, prop::Symbol)
    if !hasfield(typeof(po), :base_power)
        error(
            "DEVICE_BASE conversion: $key.$prop is a power-family field with no own " *
            "base_power field and $key is not in _DEVICEBASE_SYSTEM_BASE_TYPES",
        )
    end
    return Float64(po.base_power)
end

"""
    apply_device_base_conversion!(sys::OpenAPISystem)

Convert every power-family field [`build_openapi_system`](@ref)'s readers wrote in natural
units into per-unit-on-device-base, in place, when `sys`'s document is
`unit_system = "DEVICE_BASE"`. A no-op for `"NATURAL_UNITS"`. See this file's header for the
field-classification rule and its two hand-diffed exceptions.
"""
function apply_device_base_conversion!(sys::OpenAPISystem)
    doc = get_document(sys)
    if !PC.uses_per_unit(doc)
        return sys
    end
    system_base = PC.get_base_power(doc)
    for key in PC.component_type_names(doc)
        components = PC.get_components(doc, key)
        isempty(components) && continue
        T = eltype(components)
        for prop in fieldnames(T)
            classification = _devicebase_classification(T, key, prop)
            classification === :skip && continue
            for po in components
                base = if classification === :convert_system
                    system_base
                else
                    _devicebase_own_base(po, key, prop)
                end
                setproperty!(po, prop, _devicebase_scale(getproperty(po, prop), base))
            end
        end
    end
    return sys
end

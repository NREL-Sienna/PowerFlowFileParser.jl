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
# ── Field classification, mechanical path ───────────────────────────────────────
#
# A field converts when, mechanically:
#   - it declares a unit (`PC.has_declared_unit`);
#   - that unit is not relative to a sibling field (`!PC.has_unit_base` — e.g.
#     `ACBus.magnitude` is already pu on `base_voltage` regardless of document unit
#     system, so it is untouched here);
#   - its Type-level (not instance-level) `PC.declared_unit`/`PC.declared_quantity`
#     resolve without error (`_has_fixed_declared_unit`) — see the next section for what
#     happens when they do not;
#   - that unit's quantity is power-family (`ActivePower`/`ReactivePower`/`ApparentPower`/
#     `ActivePowerChangeRate` — a generator/storage `ramp_limits` in MW/min is scaled by
#     device base exactly like its MW siblings in every PowerSystems converter checked).
#
# Two cases the mechanical rule cannot see, found by diffing PowerSystems'
# `to_openapi(..., ::DeviceBaseUnit)` against `::NaturalUnit)` field-by-field in
# `export_handwritten.jl`:
#   - `Area`/`LoadZone.peak_active_power`/`peak_reactive_power` (and
#     `TransmissionInterface.active_power_flow_limits`, not reachable from this package's
#     readers today) are schema-fixed-natural: always MW/MVAr, multiplied by the SYSTEM
#     base in BOTH of PowerSystems' export methods — not document-unit-system-governed at
#     all. `_DEVICEBASE_FIXED_NATURAL` lists them explicitly.
#   - `FACTSControlDevice`'s `base_power` records the SYSTEM base, not a device base — the
#     schema's deliberate exception ("in lieu of a system-level table"), same as `Line`. So
#     its one plain power-family field (`max_shunt_current`) scales by the document's system
#     base, the same fallback PowerSystems' own reserve/`TwoTerminalGenericHVDCLine`
#     converters use for a type with no per-device base; both paths yield the same number
#     here. `_DEVICEBASE_SYSTEM_BASE_TYPES` lists the document keys that take this route
#     (only `FACTSControlDevice` is reachable from this package's readers today; the reserve
#     types are listed defensively in case a future reader adds them).
#
# ── Field classification, instance-dispatched path ──────────────────────────────
#
# A field whose Type-level `declared_unit`/`declared_quantity` throws depends on a runtime
# discriminator sibling (`parameter_units`, `admittance_units`, `energy_units`,
# `voltage_setpoint_units`, `dc_voltage_units`, `power_mode`, ...). That discriminator is
# used for two semantically different things in this schema, and conflating them is a bug:
# a single-bucket "instance-dispatched => skip" rule leaves
# `EnergyReservoirStorage.storage_capacity` unconverted and unflagged.
#
#   1. A **representation switch** between per-unit and natural for the SAME field
#      (`parameter_units`/`admittance_units`/`voltage_setpoint_units`/`dc_voltage_units`
#      choosing between e.g. "pu" and "ohm"/"kV"). Every reader in this package writes a
#      FIXED value for these discriminators, independent of the document's `unit_system` —
#      confirmed by grepping every `set_value!(_, :*_units, ...)` call in this directory —
#      so the field's own representation never depends on the document convention either,
#      and PowerSystems' own converters confirm it is identical between `DeviceBaseUnit`/
#      `NaturalUnit` in every case checked. These are `:skip`.
#   2. A **natural-unit choice** among sibling units of the SAME quantity
#      (`EnergyReservoirStorage.energy_units`: "MWH" vs "MWMIN", both genuine energy units)
#      or, in one case, a **quantity switch** between two physically different quantities
#      (`TwoTerminalLCCLine.power_mode` selects `transfer_setpoint`'s unit between MW
#      (`ActivePower`) and A (`CurrentFlow`)). Neither is a pu-vs-natural switch, so neither
#      is exempt from document-level conversion on that basis. PowerSystems' own converter
#      divides `storage_capacity` by device `base_power` exactly like every other
#      `:mva`-tagged field regardless of which (implemented) `energy_units` branch is active
#      (`export_handwritten.jl`'s `EnergyReservoirStorage` section) — these are
#      `:convert_own` (or, for the quantity-switch case, resolved dynamically per component).
#
# `_DEVICEBASE_INSTANCE_DISPATCHED` is the explicit registry every instance-dispatched
# `(key, prop)` this package's readers can produce must appear in, classified as one of the
# above. A pair that reaches the registry lookup and is NOT listed is a real gap — a field
# this pass has not been taught to classify — and errors by construction
# (`_devicebase_instance_dispatched`): falling through silently is not possible.

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

const _DEVICEBASE_INSTANCE_DISPATCHED = Dict{Tuple{String, Symbol}, Symbol}(
    # parameter_units/admittance_units/voltage_setpoint_units always "DEVICE_BASE"
    # (branch.jl, shunt.jl) -- pu on the component's own base_power (or, for the shunt
    # admittance fields, DEVICE_MVAR, see below) already, identical in both document
    # conventions.
    ("TransformerCircuit", :r) => :skip,
    ("TransformerCircuit", :x) => :skip,
    ("ThreeWindingTransformer", :r_12) => :skip,
    ("ThreeWindingTransformer", :x_12) => :skip,
    ("ThreeWindingTransformer", :r_23) => :skip,
    ("ThreeWindingTransformer", :x_23) => :skip,
    ("ThreeWindingTransformer", :r_31) => :skip,
    ("ThreeWindingTransformer", :x_31) => :skip,
    ("TwoWindingTransformer", :magnetizing_shunt) => :skip,
    ("ThreeWindingTransformer", :magnetizing_shunt) => :skip,
    ("FACTSControlDevice", :voltage_setpoint) => :skip,
    # control_objective governs both of TransformerCircuit's own control fields.
    # `control_limits` resolves to Dimensionless ("1") or Angle ("rad") on EVERY
    # control_objective branch (checked against every enum value in the schema, not just
    # this fixture's "FIXED") -- never power-family, so a static verdict is correct
    # regardless of which branch a future producer hits.
    ("TransformerCircuit", :control_limits) => :skip,
    # `controlled_quantity_limits` DOES switch schema quantity with control_objective
    # (Voltage/pu for VOLTAGE-family objectives, MW/MVAr for ACTIVE_POWER_FLOW/
    # REACTIVE_POWER_FLOW/CONTROL_OF_DC_LINE-family objectives) -- but PowerSystems' own
    # to_openapi calls the SAME unscaled `_minmax_po(get_controlled_quantity_limits(circuit))`
    # in BOTH the DeviceBaseUnit and NaturalUnit methods (export_handwritten.jl:166-167 and
    # :195-196) -- i.e. PSY never scales this field by base_power regardless of document
    # convention OR control_objective. A first cut of this registry made it `:dynamic`
    # (converting the power-flow-family branches) purely from the schema's declared
    # quantity, without checking PSY's actual DU/NU pair -- wrong, and invisible on the
    # 14-bus fixture because every circuit there is control_objective = "FIXED" (a
    # VOLTAGE-family, already-`:skip` branch either way). Static `:skip`, matching
    # `control_limits`.
    ("TransformerCircuit", :controlled_quantity_limits) => :skip,
    # admittance_units always "DEVICE_MVAR" (shunt.jl) -- PowerSystems' own to_openapi
    # confirms this is fixed-natural, multiplied by the SYSTEM base in both document
    # conventions (export_handwritten.jl's FixedAdmittance section), not document-unit-
    # system-governed at all (same shape as Area/LoadZone's peak fields).
    ("FixedAdmittance", :Y) => :skip,
    ("SwitchedAdmittance", :Y) => :skip,
    ("SwitchedAdmittance", :Y_increase) => :skip,
    ("SwitchedAdmittance", :admittance_limits) => :skip,
    # parameter_units/dc_voltage_units/admittance_units always "NATURAL_UNITS" for the
    # PSS/E-native LCC/VSC fields (dc_branch.jl) -- fixed ohm/kV/S regardless of the
    # document's unit_system, the mirror image of the DEVICE_BASE cases above.
    ("TwoTerminalLCCLine", :r) => :skip,
    ("TwoTerminalLCCLine", :rectifier_rc) => :skip,
    ("TwoTerminalLCCLine", :rectifier_xc) => :skip,
    ("TwoTerminalLCCLine", :inverter_rc) => :skip,
    ("TwoTerminalLCCLine", :inverter_xc) => :skip,
    ("TwoTerminalLCCLine", :compounding_resistance) => :skip,
    ("TwoTerminalLCCLine", :rectifier_capacitor_reactance) => :skip,
    ("TwoTerminalLCCLine", :inverter_capacitor_reactance) => :skip,
    ("TwoTerminalLCCLine", :scheduled_dc_voltage) => :skip,
    ("TwoTerminalLCCLine", :switch_mode_voltage) => :skip,
    ("TwoTerminalLCCLine", :min_compounding_voltage) => :skip,
    ("TwoTerminalVSCLine", :g) => :skip,
    # energy_units is a NATURAL-UNIT CHOICE (MWh vs MWmin), not a pu-vs-natural
    # representation switch: both branches are genuine energy quantities, and PSY's own
    # converter divides storage_capacity by device base_power regardless of which
    # (implemented) branch is active.
    ("EnergyReservoirStorage", :storage_capacity) => :convert_own,
    # power_mode selects between two DIFFERENT PHYSICAL QUANTITIES (ActivePower vs
    # CurrentFlow), not two representations of the same one -- resolved per component from
    # the instance-level quantity, not statically here.
    #
    # SETTLED (design decision, 2026-08-08): Sienna models LCC only as this two-terminal
    # HVDC line type -- there is no standalone LCC converter model -- so the field follows
    # the two-terminal HVDC family convention, like its own sibling power fields
    # (`active_power_flow`, `active_power_limits_from/to`) and the generic type's PSY
    # converter. PSY has no `TwoTerminalLCCLine` converter yet (`openapi_type: null`);
    # when one is written it must match this convention.
    ("TwoTerminalLCCLine", :transfer_setpoint) => :dynamic,
)

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
Classification for a `key.prop` whose Type-level declared unit is NOT fixed (an
instance-level discriminator governs it) — `_DEVICEBASE_INSTANCE_DISPATCHED` lookup, erroring
by name when the pair is not registered rather than silently skipping it. See this file's
header for the two kinds of discriminator and why they classify differently.
"""
function _devicebase_instance_dispatched(key::AbstractString, prop::Symbol)
    verdict = get(_DEVICEBASE_INSTANCE_DISPATCHED, (String(key), prop), nothing)
    if verdict === nothing
        error(
            "DEVICE_BASE conversion: $key.$prop has an instance-level unit discriminator " *
            "not accounted for in _DEVICEBASE_INSTANCE_DISPATCHED — classify it as " *
            ":convert_own, :skip, or :dynamic (see device_base.jl's header) before " *
            "building a DEVICE_BASE document containing this type",
        )
    end
    return verdict
end

"""
Per-`(key, prop)` map from a `:dynamic` field's resolved instance-level *quantity* to its
verdict — every quantity the field's discriminator can ever produce must be listed
(checked against every enum value in the schema, not just what a given fixture exercises),
or [`_devicebase_dynamic`](@ref) errors naming the unexpected quantity rather than guessing.

  - `TwoTerminalLCCLine.transfer_setpoint` (`power_mode`): `ActivePower` (MW, converts like
    every sibling power field) or `CurrentFlow` (A — no power-base conversion is defined for
    a current quantity anywhere in this schema). Settled per the registry entry above.

`TransformerCircuit.controlled_quantity_limits` was the one other candidate for this table
(its schema quantity does switch with `control_objective`) but is `:skip` in
`_DEVICEBASE_INSTANCE_DISPATCHED` instead, not `:dynamic` here — PowerSystems' own
`to_openapi` never scales it regardless of `control_objective` (see that registry entry's
comment), so there is no quantity-dependent verdict to look up.
"""
const _DEVICEBASE_DYNAMIC_QUANTITIES = Dict{Tuple{String, Symbol}, Dict{String, Symbol}}(
    ("TwoTerminalLCCLine", :transfer_setpoint) => Dict(
        "ActivePower" => :convert_own,
        "CurrentFlow" => :skip,
    ),
)

"""Resolve a `:dynamic` verdict for one component `po`, from its own instance-level
quantity, via `_DEVICEBASE_DYNAMIC_QUANTITIES`."""
function _devicebase_dynamic(key::AbstractString, prop::Symbol, po)
    quantities = get(_DEVICEBASE_DYNAMIC_QUANTITIES, (key, prop), nothing)
    if quantities === nothing
        error(
            "DEVICE_BASE conversion: $key.$prop is registered :dynamic with no entry in " *
            "_DEVICEBASE_DYNAMIC_QUANTITIES",
        )
    end
    quantity = PC.declared_quantity(po, Val(prop))
    verdict = get(quantities, quantity, nothing)
    if verdict === nothing
        error(
            "DEVICE_BASE conversion: $key.$prop resolved quantity \"$quantity\", not " *
            "accounted for in _DEVICEBASE_DYNAMIC_QUANTITIES[($key, :$prop)]",
        )
    end
    return verdict
end

"""
Classify `key.prop` (PO type `T`) for the DEVICE_BASE pass: `:convert_own` (divide by the
component's own `base_power`), `:convert_system` (divide by the document's system base),
`:dynamic` (resolved per component by [`_devicebase_dynamic`](@ref)), or `:skip`. See this
file's header for the full rule.
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
        return _devicebase_instance_dispatched(key, prop)
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
field-classification rule and its exceptions.
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
                resolved = if classification === :dynamic
                    _devicebase_dynamic(key, prop, po)
                else
                    classification
                end
                resolved === :skip && continue
                base = if resolved === :convert_system
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

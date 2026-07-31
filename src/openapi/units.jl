"""
Unit-checked assignment onto generated OpenAPI components.

Components are built empty and populated one property at a time, mirroring how
OpenAPI.jl itself deserializes them (`from_json(T(), json)` then per-property).
Every numeric assignment names the unit of the incoming value; the declared unit
comes from the schema annotations generated into PowerOpenAPIModels.

The two arities are the enforcement. A property that declares a unit can only be
written by the 4-argument form, and one that does not can only be written by the
3-argument form, so the check cannot be skipped by choosing the shorter call.

Assignment goes through `setproperty!` rather than `setfield!`, which runs the
generated `validate_property` and so keeps enum and range checks in force.

A property annotated `x-unit-base` is per-unit on a sibling property rather than on
a scalar factor. Assigning one converts through that sibling's own declared unit,
so the sibling must be assigned first.
"""

"""
Constructor for a compound property, e.g. `MinMax` for `ACBus.voltage_limits`.

Generated property types are `Union{Nothing, T}`; drop the `Nothing` arm.
"""
function _compound_type(o::OpenAPI.APIModel, prop::Symbol)
    ftype = OpenAPI.property_type(typeof(o), prop)
    concrete = filter(t -> t !== Nothing, Base.uniontypes(ftype))
    if length(concrete) != 1
        throw(
            IS.DataFormatError(
                "$(nameof(typeof(o))).$prop is not a single compound type: $ftype",
            ),
        )
    end
    return only(concrete)
end

function _declared(o::OpenAPI.APIModel, prop::Symbol)
    T = typeof(o)
    if !PC.has_declared_unit(T, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares no unit; use the 3-argument set_value!",
            ),
        )
    end
    # Instance dispatch: for discriminated properties both the unit and the
    # quantity depend on a sibling field.
    return PC.declared_unit(o, Val(prop)), PC.declared_quantity(o, Val(prop))
end

function _reject_declared(o::OpenAPI.APIModel, prop::Symbol)
    T = typeof(o)
    if PC.has_declared_unit(T, Val(prop))
        unit = PC.declared_unit(o, Val(prop))
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop declares unit \"$unit\"; use the 4-argument set_value!",
            ),
        )
    end
    return
end

function _convert_by_factor(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
)
    if source_unit == target
        return value
    end
    T = typeof(o)
    if !PC.has_conversion_factor(quantity, source_unit)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\"; " *
                "\"$source_unit\" is not a convertible $quantity unit",
            ),
        )
    end
    if !PC.has_conversion_factor(quantity, target)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop: the unit vocabulary records no conversion factor " *
                "for $quantity in \"$target\"",
            ),
        )
    end
    return value * PC.conversion_factor(quantity, source_unit) /
           PC.conversion_factor(quantity, target)
end

"""Whether the sibling property holding a per-unit value's base has been assigned."""
function _base_is_set(o::OpenAPI.APIModel, base_prop::Symbol)
    return !isnothing(getproperty(o, base_prop))
end

"""
The assigned base, rejected unless it is positive.

A zero or negative voltage or power base is physically meaningless, and PSS/E writes
`BASKV = 0.0` for buses with no specified base. Dividing by it would store an `Inf` or
`NaN` that survives every later check and first fails inside `JSON.print`, after the
output file has been truncated.
"""
function _checked_base(o::OpenAPI.APIModel, prop::Symbol, base_prop::Symbol)
    base = getproperty(o, base_prop)
    if base <= 0
        throw(
            IS.DataFormatError(
                "$(nameof(typeof(o))).$prop is per-unit on $base_prop, which is $base; " *
                "the base must be positive",
            ),
        )
    end
    return base
end

"""
Convert into a per-unit property whose base lives in a sibling property.

`x-unit-base` names that sibling. The base carries its own declared unit, so the
incoming value is first brought into that unit by the factor path and then divided.
The base must already be assigned, which makes assignment order significant here
and nowhere else.
"""
function _convert_onto_base(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
)
    T = typeof(o)
    base_prop = PC.unit_base(T, Val(prop))
    if !_base_is_set(o, base_prop)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$target\" on $base_prop, which is " *
                "unset; assign $base_prop first",
            ),
        )
    end
    base_unit, base_quantity = _declared(o, base_prop)
    natural = _convert_by_factor(o, prop, value, source_unit, base_unit, base_quantity)
    return natural / _checked_base(o, prop, base_prop)
end

function _convert(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Float64,
    source_unit::AbstractString,
    target::AbstractString,
    quantity::AbstractString,
)
    if source_unit == target
        return value
    end
    if PC.has_unit_base(typeof(o), Val(prop))
        return _convert_onto_base(o, prop, value, source_unit, target, quantity)
    end
    return _convert_by_factor(o, prop, value, source_unit, target, quantity)
end

"""Convert `value` from `source_unit` into the unit `prop` declares."""
function convert_to_declared(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
)
    target, quantity = _declared(o, prop)
    return _convert(o, prop, Float64(value), source_unit, target, quantity)
end

"""Assign a numeric property, converting from `source_unit` to the declared unit."""
function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::Real,
    source_unit::AbstractString,
)
    setproperty!(o, prop, convert_to_declared(o, prop, value, source_unit))
    return
end

"""
Assign a compound property such as `MinMax`, `UpDown`, `FromTo` or `InOut`.

The schemas annotate these at the object level rather than per member, so one
unit applies to every field of the tuple.
"""
function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value::NamedTuple,
    source_unit::AbstractString,
)
    target, quantity = _declared(o, prop)
    converted = map(
        v -> _convert(o, prop, Float64(v), source_unit, target, quantity),
        values(value),
    )
    ctor = _compound_type(o, prop)
    setproperty!(o, prop, ctor(; NamedTuple{keys(value)}(converted)...))
    return
end

"""
Reject a unit supplied for something that cannot carry one.

Either the property declares no unit, or the value is neither a number nor a
compound tuple. Both are caller mistakes worth naming precisely rather than
surfacing as a MethodError.
"""
function set_value!(
    o::OpenAPI.APIModel,
    prop::Symbol,
    value,
    source_unit::AbstractString,
)
    _reject_declared(o, prop)
    throw(
        IS.DataFormatError(
            "$(nameof(typeof(o))).$prop: a unit applies only to a number or a compound " *
            "tuple, got $(typeof(value))",
        ),
    )
end

"""Assign a property that declares no unit: names, ids, flags, enum strings."""
function set_value!(o::OpenAPI.APIModel, prop::Symbol, value)
    _reject_declared(o, prop)
    setproperty!(o, prop, value)
    return
end

"""Return the stored value of `prop`."""
get_value(o::OpenAPI.APIModel, prop::Symbol) = getproperty(o, prop)

"""Return the value of `prop` expressed in `unit`."""
function get_value(o::OpenAPI.APIModel, prop::Symbol, unit::AbstractString)
    source, quantity = _declared(o, prop)
    value = getproperty(o, prop)
    if source == unit
        return value
    end
    T = typeof(o)
    if PC.has_unit_base(T, Val(prop))
        base_prop = PC.unit_base(T, Val(prop))
        if !_base_is_set(o, base_prop)
            throw(
                IS.DataFormatError(
                    "$(nameof(T)).$prop is $quantity in \"$source\" on $base_prop, " *
                    "which is unset; assign $base_prop first",
                ),
            )
        end
        base_unit, base_quantity = _declared(o, base_prop)
        return _convert_by_factor(
            o,
            prop,
            value * _checked_base(o, prop, base_prop),
            base_unit,
            unit,
            base_quantity,
        )
    end
    if !PC.has_conversion_factor(quantity, unit) ||
       !PC.has_conversion_factor(quantity, source)
        throw(
            IS.DataFormatError(
                "$(nameof(T)).$prop is $quantity in \"$source\"; cannot express in \"$unit\"",
            ),
        )
    end
    return value * PC.conversion_factor(quantity, source) /
           PC.conversion_factor(quantity, unit)
end

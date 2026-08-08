# Ported from PowerSystemCaseBuilder/src/parsers/power_models_data.jl:209-330
# (_impedance_correction_table_lookup, _attach_single_ict!, _attach_impedance_correction_tables!).
#
# ImpedanceCorrectionData is a supplemental attribute, not a component: it describes one
# (table, winding) pair and links to whichever TwoWindingTransformer/ThreeWindingTransformer
# references that table via its own `correction_table`/`primary_correction_table`/
# `secondary_correction_table`/`tertiary_correction_table` field.
#
# PSCB's `_impedance_correction_table_lookup` pre-builds exactly one `ImpedanceCorrectionData`
# instance per (table_number, winding) pair and reuses that SAME instance for every
# transformer that references it — verified empirically against the real oracle on
# `modified_14bus_system.raw`: table 8 is referenced as the secondary-winding correction
# table by BOTH 3W transformers in that fixture, and the built `System` carries exactly
# ONE `ImpedanceCorrectionData` for `(8, SECONDARY_WINDING)`, shared across both, not two
# separate objects (8 distinct attributes for 9 attachments — one table shared twice, the
# other seven each used once). This reader reproduces that sharing: one attribute id per
# (table_number, winding), created lazily on first reference and re-associated (a new
# `SupplementalAttributeAssociation` row against the same `attribute_id`) on every
# subsequent one — never a second `ImpedanceCorrectionData` object for the same pair.
#
# `add_supplemental_attribute!`'s `group_index`/`role` (`container.jl`) do NOT apply to
# this association: those two exist for plant/service memberships this parser never
# produces (a service membership row or a plant-family grouping), and an
# impedance-correction link is a plain attribute-to-transformer association — so the one
# `add_supplemental_attribute!` call below (the first sighting of a given (table, winding)
# pair) leaves both at their `nothing` default, same as every other
# `add_supplemental_attribute!` call site in this codebase. Every subsequent sighting of
# the same pair reuses `add_service_association!`'s low-level pattern instead — pushing a
# `SupplementalAttributeAssociation` row directly, since the attribute component already
# exists.
#
# GeographicInfo (`data["substation"]`) is NOT read here — see
# `KNOWN_UNCONSUMED_PM_SECTIONS` in build.jl for why "substation" is allow-listed rather
# than implemented in this pass.

"""
One piecewise-linear curve and control-mode per impedance-correction table number.
Ported from PSCB's `_impedance_correction_table_lookup` (:213-261), minus the per-winding
pre-expansion (see file header) — that expansion is done lazily by
[`_impedance_correction_attribute_id!`](@ref) instead, only for (table, winding) pairs a
transformer actually references.
"""
function _impedance_correction_curves(data::Dict)
    curves = Dict{Int, Tuple{PC.PiecewiseLinearData, String}}()
    for (_, d) in
        _sorted_pm_entries(get(data, "impedance_correction", Dict{String, Any}()))
        table_number = Int(d["table_number"])
        x = d["tap_or_angle"]
        y = d["scaling_factor"]
        if length(x) != length(y)
            throw(
                IS.DataFormatError(
                    "impedance correction mismatch at table $table_number: " *
                    "tap/angle ($(length(x))) and scaling factor ($(length(y))) count differs.",
                ),
            )
        end
        if length(x) < 2
            @warn "Skipping impedance correction table $table_number: insufficient data points ($(length(x)) < 2)."
            continue
        end
        curve = PC.PiecewiseLinearData(;
            points = [PC.XYCoords(; x = x[i], y = y[i]) for i in eachindex(x)],
        )
        control_mode =
            if PSSE_PARSER_TAP_RATIO_LBOUND <= x[1] <= PSSE_PARSER_TAP_RATIO_UBOUND
                "TAP_RATIO"
            else
                "PHASE_SHIFT_ANGLE"
            end
        curves[table_number] = (curve, control_mode)
    end
    return curves
end

"""Push a `SupplementalAttributeAssociation` row against an already-registered
`ImpedanceCorrectionData` id, without creating a second attribute — the reuse path for a
(table, winding) pair this reader has already attached once. Mirrors
`add_service_association!`'s (`container.jl`) low-level push, for the same reason: the
"attribute" here already exists, so only the association is new."""
function _add_impedance_correction_association!(
    sys::OpenAPISystem,
    attribute_id::Int,
    entity_id::Int,
)
    push!(
        get_document(sys).supplemental_attribute_associations,
        PC.SupplementalAttributeAssociation(;
            attribute_id = attribute_id,
            entity_id = entity_id,
            attribute_type = "ImpedanceCorrectionData",
        ),
    )
    return
end

"""
Build and register a new `ImpedanceCorrectionData` for `(table_number, winding)` and
attach it to `transformer_id` — the first-sighting path for a (table, winding) pair.
Returns the new attribute's id, so later sightings of the same pair can associate against
it directly (see [`_attach_impedance_correction!`](@ref)).
"""
function _new_impedance_correction_attribute!(
    sys::OpenAPISystem,
    curves::Dict{Int, Tuple{PC.PiecewiseLinearData, String}},
    table_number::Int,
    winding::AbstractString,
    transformer_id::Int,
)
    curve, control_mode = curves[table_number]
    attribute = PO.ImpedanceCorrectionData()
    set_value!(attribute, :id, next_id!(get_registry(sys)))
    set_value!(attribute, :table_number, table_number)
    set_value!(attribute, :impedance_correction_curve, curve)
    set_value!(attribute, :transformer_winding, winding)
    set_value!(attribute, :transformer_control_mode, control_mode)
    add_supplemental_attribute!(sys, attribute, transformer_id)
    return get_value(attribute, :id)
end

"""
Attach the `ImpedanceCorrectionData` for `(d[table_key], winding)` to `transformer_id`,
if `d[table_key]` names a table `curves` has an entry for. `table_key` absent, or naming
table `0` (PSS/E's "no correction table" default, per `pti.jl`'s TAB1/TAB2/TAB3
defaults), is a no-op — matching PSCB's `_attach_single_ict!`, which only ever finds a
cache hit for a real table number. `cache` remembers the attribute id already created for
each `(table_number, winding)` pair, so a pair referenced by more than one transformer
gets one shared attribute and multiple associations — see the file header.
"""
function _attach_impedance_correction!(
    sys::OpenAPISystem,
    cache::Dict{Tuple{Int, String}, Int},
    curves::Dict{Int, Tuple{PC.PiecewiseLinearData, String}},
    d::Dict,
    table_key::AbstractString,
    winding::AbstractString,
    transformer_id::Int,
)
    if isempty(curves) || !haskey(d, table_key)
        return
    end
    table_number = Int(d[table_key])
    if !haskey(curves, table_number)
        return
    end
    key = (table_number, winding)
    if haskey(cache, key)
        _add_impedance_correction_association!(sys, cache[key], transformer_id)
    else
        cache[key] =
            _new_impedance_correction_attribute!(sys, curves, table_number, winding,
                transformer_id)
    end
    return
end

"""
Attach `ImpedanceCorrectionData` supplemental attributes to every `TwoWindingTransformer`/
`ThreeWindingTransformer` that references an impedance-correction table. Ported from
PSCB's `_attach_impedance_correction_tables!` (:294-330), driven here by re-walking
`data["branch"]`/`data["3w_transformer"]` (rather than PSCB's inline call from within its
own transformer readers) since [`read_branches!`](@ref)/[`read_3w_transformers!`](@ref)
have already registered every transformer by name by the time this stage runs — the name
derivation below must therefore match theirs exactly, including the same
`branch_name_formatter`/`xfrm_3w_name_formatter` override.

Runs after every other reader in [`build_openapi_system`](@ref).
"""
function read_attributes!(sys::OpenAPISystem, data::Dict; kwargs...)
    curves = _impedance_correction_curves(data)
    if isempty(curves)
        return
    end
    reg = get_registry(sys)
    bus_lookup = _pm_bus_lookup(sys)
    _get_branch_name = get(kwargs, :branch_name_formatter, _get_pm_branch_name)
    _get_3w_name = get(kwargs, :xfrm_3w_name_formatter, _get_pm_3w_name)
    cache = Dict{Tuple{Int, String}, Int}()

    for (_, d) in _sorted_pm_entries(get(data, "branch", Dict{String, Any}()))
        if !haskey(d, "correction_table")
            continue
        end
        from_number, to_number = Int(d["f_bus"]), Int(d["t_bus"])
        from_name, = bus_lookup[from_number]
        to_name, = bus_lookup[to_number]
        name = String(_get_branch_name(d, from_name, to_name))
        transformer_id = get_id(reg, "TwoWindingTransformer", name)
        _attach_impedance_correction!(
            sys, cache, curves, d, "correction_table", "TR2W_WINDING", transformer_id,
        )
    end

    for (_, d) in _sorted_pm_entries(get(data, "3w_transformer", Dict{String, Any}()))
        primary_number = Int(d["bus_primary"])
        secondary_number = Int(d["bus_secondary"])
        tertiary_number = Int(d["bus_tertiary"])
        name = String(
            _get_3w_name(
                d,
                bus_lookup[primary_number][1],
                bus_lookup[secondary_number][1],
                bus_lookup[tertiary_number][1],
            ),
        )
        transformer_id = get_id(reg, "ThreeWindingTransformer", name)
        _attach_impedance_correction!(
            sys, cache, curves, d, "primary_correction_table", "PRIMARY_WINDING",
            transformer_id,
        )
        _attach_impedance_correction!(
            sys, cache, curves, d, "secondary_correction_table", "SECONDARY_WINDING",
            transformer_id,
        )
        _attach_impedance_correction!(
            sys, cache, curves, d, "tertiary_correction_table", "TERTIARY_WINDING",
            transformer_id,
        )
    end
    return
end

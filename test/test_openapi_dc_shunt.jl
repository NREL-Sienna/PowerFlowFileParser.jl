@testset "TwoTerminalLCCLine: custom PSS/E-native fields passthrough, native pf ×baseMVA" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["dcline"]))
    line = only(PFP.get_components(sys, "TwoTerminalLCCLine"))

    @test PFP.get_value(line, :available) == d["available"]
    @test PFP.get_value(line, :active_power_flow) ≈ d["pf"] * 100.0
    @test PFP.get_value(line, :parameter_units) == "NATURAL_UNITS"
    @test PFP.get_value(line, :r) == d["r"]
    @test PFP.get_value(line, :power_mode) == d["power_mode"]
    @test PFP.get_value(line, :transfer_setpoint) == d["transfer_setpoint"]
    @test PFP.get_value(line, :scheduled_dc_voltage) == d["scheduled_dc_voltage"]
    @test PFP.get_value(line, :rectifier_bridges) == Int(d["rectifier_bridges"])
    @test _matches_nt(
        PFP.get_value(line, :rectifier_delay_angle_limits),
        d["rectifier_delay_angle_limits"],
    )
    @test PFP.get_value(line, :rectifier_rc) == d["rectifier_rc"]
    @test PFP.get_value(line, :rectifier_base_voltage) == d["rectifier_base_voltage"]
    @test _matches_nt(
        PFP.get_value(line, :inverter_extinction_angle_limits),
        d["inverter_extinction_angle_limits"],
    )
    @test _matches_nt(PFP.get_value(line, :rectifier_tap_limits), d["rectifier_tap_limits"])
    @test _matches_nt(PFP.get_value(line, :inverter_tap_limits), d["inverter_tap_limits"])
    @test PFP.get_value(line, :base_power) == 100.0
end

@testset "TwoTerminalGenericHVDCLine (matpower): native pminf/pmaxf/... ×baseMVA" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5_dc.m"))
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["dcline"]))
    line = only(PFP.get_components(sys, "TwoTerminalGenericHVDCLine"))
    base = pm.data["baseMVA"]

    @test PFP.get_value(line, :available) == (d["br_status"] == 1)
    @test PFP.get_value(line, :active_power_flow) ≈ d["pf"] * base
    @test _matches_nt(
        PFP.get_value(line, :active_power_limits_from),
        (min = d["pminf"] * base, max = d["pmaxf"] * base),
    )
    @test _matches_nt(
        PFP.get_value(line, :active_power_limits_to),
        (min = d["pmint"] * base, max = d["pmaxt"] * base),
    )
    @test _matches_nt(
        PFP.get_value(line, :reactive_power_limits_from),
        (min = d["qminf"] * base, max = d["qmaxf"] * base),
    )
    @test _matches_nt(
        PFP.get_value(line, :reactive_power_limits_to),
        (min = d["qmint"] * base, max = d["qmaxt"] * base),
    )
    @test PFP.get_value(line, :base_power) == base
end

@testset "FixedAdmittance: PSS/E-native DEVICE_MVAR Y, no scaling" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(v for v in values(pm.data["shunt"]) if v["shunt_bus"] == 111)
    shunt = only(
        s for s in PFP.get_components(sys, "FixedAdmittance") if
        PFP.get_value(s, :bus) == PFP.get_bus_id(PFP.get_registry(sys), 111)
    )
    @test PFP.get_value(shunt, :available) == d["status"]
    @test PFP.get_value(shunt, :admittance_units) == "DEVICE_MVAR"
    @test _matches_nt(PFP.get_value(shunt, :Y), (real = d["gs"], imag = d["bs"]))
end

@testset "SwitchedAdmittance: control mode mapping, Y_increase array conversion, admittance_limits passthrough" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(v for v in values(pm.data["switched_shunt"]) if v["shunt_bus"] == 101)
    @test d["control_mode"] == 1

    shunt = only(
        s for s in PFP.get_components(sys, "SwitchedAdmittance") if
        PFP.get_value(s, :bus) == PFP.get_bus_id(PFP.get_registry(sys), 101)
    )
    @test PFP.get_value(shunt, :control_mode) == "DISCRETE_VOLTAGE"
    @test _matches_nt(PFP.get_value(shunt, :Y), (real = d["gs"], imag = d["bs"]))
    @test PFP.get_value(shunt, :number_of_steps) == d["step_number"]
    y_increase = PFP.get_value(shunt, :Y_increase)
    @test length(y_increase) == length(d["y_increment"])
    @test all(
        PFP.get_value(shunt, :Y_increase)[i].real == real(d["y_increment"][i]) &&
        PFP.get_value(shunt, :Y_increase)[i].imag == imag(d["y_increment"][i]) for
        i in eachindex(d["y_increment"])
    )
    @test _matches_nt(
        PFP.get_value(shunt, :admittance_limits),
        (min = d["admittance_limits"][1], max = d["admittance_limits"][2]),
    )
    @test PFP.get_value(shunt, :initial_status) == d["initial_status"]
end

@testset "_switched_admittance_control_mode rejects an unrecognized MODSW code" begin
    @test_throws IS.DataFormatError PFP._switched_admittance_control_mode(42)
end

@testset "FACTSControlDevice: PSS/E MODE 0/1/2 maps to OOS/NML/BYP" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(values(pm.data["facts"]))
    @test d["control_mode"] == 1

    facts = only(PFP.get_components(sys, "FACTSControlDevice"))
    @test PFP.get_value(facts, :control_mode) == "NML"
    @test PFP.get_value(facts, :available) == d["available"]
    @test PFP.get_value(facts, :voltage_setpoint_units) == "DEVICE_BASE"
    @test PFP.get_value(facts, :voltage_setpoint) == d["voltage_setpoint"]
    @test PFP.get_value(facts, :max_shunt_current) == d["max_shunt_current"]
    @test PFP.get_value(facts, :reactive_power_required) == 0.0
    @test PFP.get_value(facts, :regulated_bus_number) == d["regulated_bus_number"]
end

@testset "_facts_control_mode rejects a code outside the current 0-2 enum domain" begin
    @test_throws IS.DataFormatError PFP._facts_control_mode(3)
end

"""Minimal two-bus, two-area pm dict for the AreaInterchange bug-compatible site and its
undefined-area skip path — no fixture on hand carries `interarea_transfer` data."""
function _two_area_pm_data(; power_transfer::Float64 = 50.0, area_to::Int = 2)
    bus = Dict{String, Any}(
        "1" => Dict{String, Any}(
            "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
            "base_kv" => 138.0,
            "va" => 0.0, "vm" => 1.0, "vmin" => 0.9, "vmax" => 1.1, "name" => "b1",
        ),
        "2" => Dict{String, Any}(
            "bus_i" => 2, "bus_type" => 1, "area" => 2, "zone" => 1,
            "base_kv" => 138.0,
            "va" => 0.0, "vm" => 1.0, "vmin" => 0.9, "vmax" => 1.1, "name" => "b2",
        ),
    )
    return Dict{String, Any}(
        "baseMVA" => 100.0,
        "source_type" => "pti",
        "bus" => bus,
        "load" => Dict{String, Any}(),
        "interarea_transfer" => Dict{String, Any}(
            "1" => Dict{String, Any}(
                "area_from" => 1, "area_to" => area_to, "transfer_id" => "1",
                "power_transfer" => power_transfer, "index" => 1,
            ),
        ),
    )
end

@testset "Bug-compatible: AreaInterchange.active_power_flow is power_transfer ×baseMVA a second time (D5 #4)" begin
    data = _two_area_pm_data()
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_area_interchanges!(sys, data)

    ai = only(PFP.get_components(sys, "AreaInterchange"))
    # power_transfer (50.0) is PFFP's raw, already-natural PTRAN value (psse.jl copies it
    # verbatim; "interarea_transfer" is not a native PowerModels section, so
    # `_make_per_unit!` never touches it either). PSCB's oracle assigns it directly into
    # a field PSY declares SU (system-base pu), with no division by sys_mbase first — a
    # real `get_active_power_flow(interchange, PSY.NU)` call therefore multiplies this
    # already-natural number by sys_mbase a SECOND time. This reader reproduces exactly
    # that inflated value.
    @test PFP.get_value(ai, :active_power_flow) == 50.0 * 100.0
    @test _matches_nt(
        PFP.get_value(ai, :flow_limits),
        (from_to = -1.0e6, to_from = 1.0e6),
    )
    @test PFP.get_value(ai, :base_power) == 100.0
    @test PFP.get_value(ai, :available)
end

@testset "read_area_interchanges! warns and skips a transfer referencing an undefined area" begin
    data = _two_area_pm_data(; area_to = 3)
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    Test.@test_logs (:warn, r"undefined area") PFP.read_area_interchanges!(sys, data)
    @test isempty(PFP.get_components(sys, "AreaInterchange"))
end

@testset "read_area_interchanges! is a no-op for matpower source data" begin
    data = _two_area_pm_data()
    data["source_type"] = "matpower"
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    PFP.read_area_interchanges!(sys, data)
    @test isempty(PFP.get_components(sys, "AreaInterchange"))
end

"""Minimal synthetic `vscline` entry for the DC_POWER/AC_REACTIVE_POWER case. No fixture
on hand carries a `vscline` section."""
function _synthetic_vscline_dict()
    return Dict{String, Any}(
        "available" => true,
        "f_bus" => 1, "t_bus" => 2,
        "pf" => 0.05, "qf" => 0.01, "qt" => -0.01,
        "rating" => 1.0,
        "pminf" => -1.0, "pmaxf" => 1.0, "pmint" => -1.0, "pmaxt" => 1.0,
        "qminf" => -0.5, "qmaxf" => 0.5, "qmint" => -0.5, "qmaxt" => 0.5,
        "r" => 0.5, "if" => 10.0,
        "dc_voltage_control_from" => false, "ac_voltage_control_from" => false,
        "dc_voltage_control_to" => false, "ac_voltage_control_to" => false,
        "dc_setpoint_from" => 0.02, "ac_setpoint_from" => 1.0,
        "dc_setpoint_to" => -0.02, "ac_setpoint_to" => 1.0,
        "converter_loss_from" => IS.LinearCurve(0.001, 0.002),
        "converter_loss_to" => IS.LinearCurve(0.001, 0.002),
        "max_dc_current_from" => 100.0, "max_dc_current_to" => 100.0,
        "rating_from" => 1.0, "rating_to" => 1.0,
        "power_factor_weighting_fraction_from" => 1.0,
        "power_factor_weighting_fraction_to" => 1.0,
        "rated_dc_voltage" => 100.0,
    )
end

@testset "TwoTerminalVSCLine: DC_POWER/AC_REACTIVE_POWER case ×sys_mbase where PFFP pre-scales" begin
    data = merge(
        Dict{String, Any}(
            "baseMVA" => 100.0, "source_type" => "pti",
            "bus" => Dict{String, Any}(
                "1" => Dict{String, Any}(
                    "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
                    "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                    "vmax" => 1.1, "name" => "b1",
                ),
                "2" => Dict{String, Any}(
                    "bus_i" => 2, "bus_type" => 1, "area" => 1, "zone" => 1,
                    "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                    "vmax" => 1.1, "name" => "b2",
                ),
            ),
            "load" => Dict{String, Any}(),
        ),
    )
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, 1)
    to_id = PFP.get_bus_id(reg, 2)

    d = _synthetic_vscline_dict()
    PFP.make_vscline!(sys, reg, "vsc1", d, from_id, to_id, PFP.get_base_power(sys))
    vsc = only(PFP.get_components(sys, "TwoTerminalVSCLine"))
    @test PFP.get_value(vsc, :dc_control_from) == "DC_POWER"
    @test PFP.get_value(vsc, :ac_control_from) == "AC_REACTIVE_POWER"
    @test PFP.get_value(vsc, :active_power_flow) ≈ 0.05 * 100.0
    @test PFP.get_value(vsc, :rating) ≈ 1.0 * 100.0
    @test PFP.get_value(vsc, :dc_setpoint_from) ≈ 0.02 * 100.0
    @test PFP.get_value(vsc, :ac_setpoint_from) == 1.0
    @test PFP.get_value(vsc, :dc_current) == 10.0
    @test PFP.get_value(vsc, :g) ≈ 1.0 / 0.5
    @test PFP.get_value(vsc, :max_dc_current_from) == 100.0
    @test PFP.get_value(vsc, :rated_dc_voltage) == 100.0
end

@testset "TwoTerminalVSCLine: make_vscline! still refuses DC_VOLTAGE/AC_VOLTAGE, now loudly by design" begin
    # PowerOperationsOpenAPIModels.jl's units.jl now completes the DC_VOLTAGE/
    # AC_VOLTAGE branches (voltage_units defaults to NATURAL_UNITS, so
    # dc_setpoint_from/ac_setpoint_from would resolve to declared unit "kV"
    # without complaint), so set_value!(..., "kV") would no longer error on
    # its own -- it would silently store a value that is actually p.u. (of
    # rated_dc_voltage for DC_VOLTAGE, of the AC bus base for AC_VOLTAGE)
    # under a "kV" tag. That is exactly the silent-wrong-value pattern the
    # psy6 non-negotiables forbid, so make_vscline! now raises its own loud
    # `error()` for both modes instead of leaning on the (now closed) codegen
    # gap -- see dc_branch.jl's RECORDED GAP docstring note and
    # `_vsc_voltage_control_unsupported`.
    data = Dict{String, Any}(
        "baseMVA" => 100.0, "source_type" => "pti",
        "bus" => Dict{String, Any}(
            "1" => Dict{String, Any}(
                "bus_i" => 1, "bus_type" => 3, "area" => 1, "zone" => 1,
                "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                "vmax" => 1.1, "name" => "b1",
            ),
            "2" => Dict{String, Any}(
                "bus_i" => 2, "bus_type" => 1, "area" => 1, "zone" => 1,
                "base_kv" => 138.0, "va" => 0.0, "vm" => 1.0, "vmin" => 0.9,
                "vmax" => 1.1, "name" => "b2",
            ),
        ),
        "load" => Dict{String, Any}(),
    )
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, 1)
    to_id = PFP.get_bus_id(reg, 2)

    d_dc = _synthetic_vscline_dict()
    d_dc["dc_voltage_control_from"] = true
    @test_throws ErrorException PFP.make_vscline!(
        sys,
        reg,
        "vsc2",
        d_dc,
        from_id,
        to_id,
        100.0,
    )

    d_ac = _synthetic_vscline_dict()
    d_ac["ac_voltage_control_from"] = true
    @test_throws ErrorException PFP.make_vscline!(
        sys,
        reg,
        "vsc3",
        d_ac,
        from_id,
        to_id,
        100.0,
    )
end

@testset "TwoTerminalVSCLine: dc_setpoint_from/to convert correctly under DC_VOLTAGE and DC_VOLTAGE_DROOP" begin
    # psse.jl's own VSC parsing (src/pm_io/psse.jl:2083-2097) documents this
    # exactly: "PSY documents dc_setpoint_from/to as p.u. of rated_dc_voltage
    # for the DC-voltage-controlling side (TYPE = 1)", computed there as
    # `from_bus["DCSET"] / base_voltage`. Hand math: DCSET = 515.0 kV,
    # base_voltage (rated_dc_voltage) = 500.0 kV => 515.0 / 500.0 = 1.03 p.u.
    # That division already produces the number PSY expects, so passing it
    # through set_value! with unit "pu" is an identity conversion: source
    # unit "pu" equals the DEVICE_BASE-branch declared unit "pu", and "pu"
    # carries no fixed conversion factor (to_default: null in
    # Core/units.json) -- there is nothing left to scale.
    vsc = PFP.PO.TwoTerminalVSCLine()
    PFP.set_value!(vsc, :dc_control_from, "DC_VOLTAGE")
    PFP.set_value!(vsc, :voltage_units, "DEVICE_BASE")
    PFP.set_value!(vsc, :dc_setpoint_from, 515.0 / 500.0, "pu")
    @test PFP.get_value(vsc, :dc_setpoint_from) == 1.03

    # NATURAL_UNITS is the schema's other DC-voltage basis: dc_setpoint_from
    # is then a literal kV magnitude. "kV" is both the source and the
    # DC_VOLTAGE/NATURAL_UNITS-branch declared unit (to_default 1.0 on both
    # sides), so this is also an identity conversion.
    PFP.set_value!(vsc, :voltage_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :dc_setpoint_from, 515.0, "kV")
    @test PFP.get_value(vsc, :dc_setpoint_from) == 515.0

    # DC_VOLTAGE_DROOP shares the exact same nested voltage_units branch as
    # DC_VOLTAGE in TwoTerminalVSCLine.json's dc_setpoint_from annotation;
    # confirm the emitter's recursive walk produced the same result for it.
    PFP.set_value!(vsc, :dc_control_from, "DC_VOLTAGE_DROOP")
    PFP.set_value!(vsc, :voltage_units, "DEVICE_BASE")
    PFP.set_value!(vsc, :dc_setpoint_from, 1.03, "pu")
    @test PFP.get_value(vsc, :dc_setpoint_from) == 1.03

    # dc_setpoint_to shares TwoTerminalVSCLine's one voltage_units field with
    # dc_setpoint_from but has its own dc_control_to discriminator.
    PFP.set_value!(vsc, :dc_control_to, "DC_VOLTAGE")
    PFP.set_value!(vsc, :dc_setpoint_to, 1.03, "pu")
    @test PFP.get_value(vsc, :dc_setpoint_to) == 1.03
end

@testset "TwoTerminalVSCLine: ac_setpoint_from/to convert correctly under AC_VOLTAGE" begin
    # psse.jl: `sub_data["ac_setpoint_from"] = from_bus["ACSET"]` -- PSS/E's
    # ACSET for a VSC converter bus is already per-unit of the AC bus's own
    # base voltage (the same PSS/E convention as bus VM), so no scaling
    # happens before this value reaches PSY. Passing "pu" here is again an
    # identity: source unit "pu" equals the AC_VOLTAGE/DEVICE_BASE-branch
    # declared unit "pu".
    vsc = PFP.PO.TwoTerminalVSCLine()
    PFP.set_value!(vsc, :ac_control_from, "AC_VOLTAGE")
    PFP.set_value!(vsc, :voltage_units, "DEVICE_BASE")
    PFP.set_value!(vsc, :ac_setpoint_from, 1.02, "pu")
    @test PFP.get_value(vsc, :ac_setpoint_from) == 1.02

    # NATURAL_UNITS basis: ac_setpoint_from would be a literal kV magnitude
    # (e.g. 1.02 p.u. x 138.0 kV bus base = 140.76 kV); identity again since
    # source and declared units both resolve to "kV".
    PFP.set_value!(vsc, :voltage_units, "NATURAL_UNITS")
    PFP.set_value!(vsc, :ac_setpoint_from, 1.02 * 138.0, "kV")
    @test PFP.get_value(vsc, :ac_setpoint_from) == 140.76

    # ac_setpoint_to mirrors ac_setpoint_from; voltage_units is shared across
    # both sides of the component, ac_control_to is independent.
    PFP.set_value!(vsc, :ac_control_to, "AC_VOLTAGE")
    PFP.set_value!(vsc, :ac_setpoint_to, 1.02 * 138.0, "kV")
    @test PFP.get_value(vsc, :ac_setpoint_to) == 140.76
end

"""Find the `TransformerCircuit`/`Line`/dc-line-shaped component of `type_name` whose
`:arc` connects pm bus numbers `from_number`/`to_number`. `add_arc!` is idempotent — it
only registers a new arc when the pair is not already known — so calling it here is a
side-effect-free lookup for an arc a reader already created."""
function _component_between(
    sys,
    type_name::AbstractString,
    from_number::Int,
    to_number::Int,
)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, from_number)
    to_id = PFP.get_bus_id(reg, to_number)
    arc_id = PFP.add_arc!(sys, from_id, to_id)
    for c in PFP.get_components(sys, type_name)
        if PFP.get_value(c, :arc) == arc_id
            return c
        end
    end
    error("no $type_name between pm bus $from_number and $to_number")
end

function _transformer_circuit_between(sys, from_number::Int, to_number::Int)
    return _component_between(sys, "TransformerCircuit", from_number, to_number)
end

"""The `TwoWindingTransformer` whose `:circuit` matches `circuit`'s id."""
function _two_winding_transformer_for(sys, circuit)
    circuit_id = PFP.get_value(circuit, :id)
    for t in PFP.get_components(sys, "TwoWindingTransformer")
        if PFP.get_value(t, :circuit) == circuit_id
            return t
        end
    end
    error("no TwoWindingTransformer references circuit id=$circuit_id")
end

@testset "Line: r/x/b are pu-by-convention passthrough, ratings/flows are ×baseMVA" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(
        v for v in values(pm.data["branch"]) if
        v["f_bus"] == 102 && v["t_bus"] == 104,
    )
    @test !d["transformer"]

    line = _component_between(sys, "Line", 102, 104)
    @test PFP.get_value(line, :available)
    @test PFP.get_value(line, :r) == d["br_r"]
    @test PFP.get_value(line, :x) == d["br_x"]
    @test _matches_nt(PFP.get_value(line, :b), (from = d["b_fr"], to = d["b_to"]))
    @test PFP.get_value(line, :base_power) == 100.0
    @test PFP.get_value(line, :rating) ≈ d["rate_a"] * 100.0
    @test _matches_nt(
        PFP.get_value(line, :angle_limits),
        (min = d["angmin"], max = d["angmax"]),
    )
    @test PFP.get_value(line, :active_power_flow) == 0.0
    @test PFP.get_value(line, :reactive_power_flow) == 0.0
end

@testset "TwoWindingTransformer + TransformerCircuit: r/x device-base passthrough, rating/flow ×circuit base_power" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(
        v for v in values(pm.data["branch"]) if
        v["f_bus"] == 109 && v["t_bus"] == 104,
    )
    @test d["transformer"]
    @test d["base_power"] == 100.0  # coincides with sys_mbase in this fixture

    circuit = _transformer_circuit_between(sys, 109, 104)
    @test PFP.get_value(circuit, :available)
    @test PFP.get_value(circuit, :parameter_units) == "DEVICE_BASE"
    @test PFP.get_value(circuit, :r) == d["br_r"]
    @test PFP.get_value(circuit, :x) == d["br_x"]
    @test PFP.get_value(circuit, :tap) == d["tap"]
    @test PFP.get_value(circuit, :alpha) == d["shift"]
    @test PFP.get_value(circuit, :base_power) == d["base_power"]
    @test PFP.get_value(circuit, :base_voltage_primary) == d["base_voltage_from"]
    @test PFP.get_value(circuit, :base_voltage_secondary) == d["base_voltage_to"]
    # rating is per-unit-on-system-base in the raw pm dict (PowerModels' generic branch
    # correction) but the circuit's rating field is device-base pu (PSY.DU); this fixture
    # cannot distinguish the two bases (base_power == sys_mbase), see the task report for
    # the synthetic cross-check that does.
    @test PFP.get_value(circuit, :rating) ≈ d["rate_a"] * d["base_power"]
    @test PFP.get_value(circuit, :active_power_flow) == 0.0
    @test PFP.get_value(circuit, :reactive_power_flow) == 0.0
    # COD1 = 0 => FIXED; RMI1/RMA1/VMI1/VMA1 are the schema defaults, present verbatim.
    @test PFP.get_value(circuit, :control_objective) == "FIXED"
    @test _matches_nt(
        PFP.get_value(circuit, :control_limits),
        (min = d["RMI1"], max = d["RMA1"]),
    )
    @test _matches_nt(
        PFP.get_value(circuit, :controlled_quantity_limits),
        (min = d["VMI1"], max = d["VMA1"]),
    )
    @test PFP.get_value(circuit, :number_of_tap_positions) == Int(d["NTP1"])

    transformer = _two_winding_transformer_for(sys, circuit)
    @test PFP.get_value(transformer, :admittance_units) == "DEVICE_BASE"
    @test _matches_nt(
        PFP.get_value(transformer, :magnetizing_shunt),
        (real = d["g_fr"], imag = d["b_fr"]),
    )
end

@testset "ThreeWindingTransformer: three circuits, unbounded (zero) ratings become INFINITE_BOUND, no rating scaling" begin
    pm = fourteen_bus_pm_data()
    sys = PFP.build_openapi_system(pm)
    d = only(v for v in values(pm.data["3w_transformer"]) if v["bus_primary"] == 109)
    @test d["rating_primary"] == 0.0  # unbounded in the raw record

    transformer = only(
        t for t in PFP.get_components(sys, "ThreeWindingTransformer") if
        PFP.get_value(
            _component_between(sys, "TransformerCircuit", d["bus_primary"], d["star_bus"]),
            :id,
        ) == PFP.get_value(t, :primary_circuit)
    )
    primary = _component_between(sys, "TransformerCircuit", d["bus_primary"], d["star_bus"])
    secondary =
        _component_between(sys, "TransformerCircuit", d["bus_secondary"], d["star_bus"])
    tertiary =
        _component_between(sys, "TransformerCircuit", d["bus_tertiary"], d["star_bus"])

    # rating_primary/secondary/tertiary are ALREADY natural MVA in the pm dict (a custom,
    # non-PM-native section psse.jl populates directly from RATA1/RATB1/RATC1) — the
    # unbounded (zero) sentinel is used AS-IS, not multiplied by any base.
    @test PFP.get_value(primary, :rating) == PFP.INFINITE_BOUND
    @test PFP.get_value(secondary, :rating) == PFP.INFINITE_BOUND
    @test PFP.get_value(tertiary, :rating) == PFP.INFINITE_BOUND
    @test PFP.get_value(primary, :active_power_flow) == 0.0
    @test PFP.get_value(primary, :reactive_power_flow) == 0.0

    @test PFP.get_value(primary, :r) == d["r_primary"]
    @test PFP.get_value(primary, :base_power) == d["base_power_12"]
    @test PFP.get_value(primary, :base_voltage_primary) == d["base_voltage_primary"]
    @test PFP.get_value(primary, :base_voltage_secondary) == d["base_voltage_primary"]
    @test PFP.get_value(secondary, :base_voltage_primary) == d["base_voltage_secondary"]
    @test PFP.get_value(tertiary, :base_voltage_primary) == d["base_voltage_tertiary"]

    @test PFP.get_value(transformer, :star_bus) ==
          PFP.get_bus_id(PFP.get_registry(sys), d["star_bus"])
    @test PFP.get_value(transformer, :parameter_units) == "DEVICE_BASE"
    @test PFP.get_value(transformer, :r_12) == d["r_12"]
    @test PFP.get_value(transformer, :base_power_12) == d["base_power_12"]
    @test PFP.get_value(transformer, :admittance_units) == "DEVICE_BASE"
    @test _matches_nt(
        PFP.get_value(transformer, :magnetizing_shunt),
        (real = d["g"], imag = d["b"]),
    )
end

@testset "matpower: tap!=1/shift!=0 detects a TwoWindingTransformer; base_power always equals sys_mbase" begin
    pm = PFP.PowerModelsData(joinpath(MATPOWER_DIR, "case5.m"))
    sys = PFP.build_openapi_system(pm)
    d5 = pm.data["branch"][5]
    @test d5["transformer"] && d5["tap"] == 1.05

    circuit = _transformer_circuit_between(sys, d5["f_bus"], d5["t_bus"])
    @test PFP.get_value(circuit, :tap) == 1.05
    @test PFP.get_value(circuit, :base_power) == pm.data["baseMVA"]
    # A matpower Line: branch 4 has tap=1.0, shift=0.0, transformer=false.
    d4 = pm.data["branch"][4]
    @test !d4["transformer"] && d4["tap"] == 1.0 && d4["shift"] == 0.0
    line = _component_between(sys, "Line", d4["f_bus"], d4["t_bus"])
    @test PFP.get_value(line, :r) == d4["br_r"]
    @test length(PFP.get_components(sys, "TwoWindingTransformer")) == 2
    @test length(PFP.get_components(sys, "Line")) == 5
end

@testset "zero-impedance branch becomes a DiscreteControlledACBranch of type SWITCH" begin
    data = fourteen_bus_pm_data().data
    d = first(values(data["branch"]))
    zero_z = merge(
        Dict{String, Any}(k => v for (k, v) in d),
        Dict{String, Any}(
            "br_r" => 0.0, "br_x" => 0.0, "transformer" => false, "f_bus" => d["f_bus"],
            "t_bus" => d["t_bus"], "index" => 999, "name" => "zero_z_test",
        ),
    )
    synthetic = deepcopy(data)
    synthetic["branch"] = Dict{String, Any}("999" => zero_z)
    delete!(synthetic, "3w_transformer")
    delete!(synthetic, "dcline")
    delete!(synthetic, "vscline")
    delete!(synthetic, "interarea_transfer")
    delete!(synthetic, "shunt")
    delete!(synthetic, "switched_shunt")
    delete!(synthetic, "facts")

    sys = PFP.OpenAPISystem(Float64(synthetic["baseMVA"]))
    PFP.read_loadzones!(sys, synthetic)
    PFP.read_bus!(sys, synthetic)
    Test.@test_logs (:warn, r"zero impedance") PFP.read_branches!(sys, synthetic)

    @test isempty(PFP.get_components(sys, "Line"))
    switch = only(PFP.get_components(sys, "DiscreteControlledACBranch"))
    @test PFP.get_value(switch, :discrete_branch_type) == "SWITCH"
    @test PFP.get_value(switch, :branch_status) ==
          (PFP.get_value(switch, :available) ? "CLOSED" : "OPEN")
end

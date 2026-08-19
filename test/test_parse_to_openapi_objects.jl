@testset "parse_to_openapi_objects: basic invariants" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case14.raw"))
    objs = parse_to_openapi_objects(pm)

    @test isa(objs, ParsedOpenAPIObjects)
    @test length(objs.buses) == length(pm.data["bus"])

    # each 2W transformer contributes exactly one TransformerCircuit
    @test length(objs.transformer_circuits) ==
          length(objs.branches.two_winding_transformer) +
          3 * length(objs.xfrm_3w.three_winding_transformer)

    # gens/loads NamedTuples cover all POM subtypes
    total_gens =
        length(objs.gens.thermal_standard) +
        length(objs.gens.hydro_dispatch) +
        length(objs.gens.renewable_dispatch) +
        length(objs.gens.renewable_non_dispatch) +
        length(objs.gens.synchronous_condenser)
    @test total_gens == length(pm.data["gen"])
end

@testset "parse_to_openapi_objects: case14.raw expected counts" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case14.raw"))
    objs = parse_to_openapi_objects(pm)
    @test length(objs.buses) == 14
    @test length(objs.branches.line) == 17
    @test length(objs.branches.two_winding_transformer) == 3
    @test length(objs.xfrm_3w.three_winding_transformer) == 0
    @test length(objs.transformer_circuits) == 3
    @test length(objs.gens.thermal_standard) == 5
    @test length(objs.loads.standard_load) == 11
    @test length(objs.arcs) == 20
end

@testset "parse_to_openapi_objects: case16_all_components.raw exercises all POM subtypes" begin
    # This is the one PSB file that populates every subtype we care about
    # (TwoTerminalLCCLine, TwoTerminalVSCLine, DiscreteControlledACBranch,
    # FACTSControlDevice, SwitchedAdmittance, InterruptibleStandardLoad,
    # plus TransformerCircuit / TwoWindingTransformer / ThreeWindingTransformer).
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    objs = parse_to_openapi_objects(pm)

    @test length(objs.buses) == 18
    @test length(objs.branches.line) == 7
    @test length(objs.branches.two_winding_transformer) == 3
    @test length(objs.xfrm_3w.three_winding_transformer) == 2
    # 3 circuits per 3W (2 * 3 = 6) plus one per 2W (3) = 9
    @test length(objs.transformer_circuits) == 9

    @test length(objs.dclines.two_terminal_lcc_line) == 2
    @test length(objs.vsclines) == 1
    @test length(objs.facts) == 1
    @test length(objs.switched_shunts) == 1
    @test length(objs.shunts) == 3
    @test length(objs.switches) == 1
    @test length(objs.breakers) == 1
    @test length(objs.loads.interruptible_standard_load) == 2
    @test length(objs.loads.standard_load) == 4
end

@testset "parse_to_openapi_objects: transformer decomposition circuits FK back to holders" begin
    # Each ThreeWindingTransformer.primary_circuit_id / secondary / tertiary
    # must refer to a TransformerCircuit id present in the accumulator.
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    objs = parse_to_openapi_objects(pm)

    circuit_ids = Set(c.id for c in objs.transformer_circuits)
    @test !isempty(circuit_ids)

    # Holders reference circuits by id (Int), not by nested object.
    for tw in objs.branches.two_winding_transformer
        @test tw.circuit in circuit_ids
    end
    for tri in objs.xfrm_3w.three_winding_transformer
        @test tri.primary_circuit in circuit_ids
        @test tri.secondary_circuit in circuit_ids
        @test tri.tertiary_circuit in circuit_ids
    end
end

@testset "parse_to_openapi_objects: IDs are unique across all typed collections" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    objs = parse_to_openapi_objects(pm)

    seen = Int[]
    append!(seen, [x.id for x in objs.buses])
    append!(seen, [x.id for x in objs.areas])
    append!(seen, [x.id for x in objs.loadzones])
    append!(seen, [x.id for x in objs.branches.line])
    append!(seen, [x.id for x in objs.branches.two_winding_transformer])
    append!(seen, [x.id for x in objs.xfrm_3w.three_winding_transformer])
    append!(seen, [x.id for x in objs.transformer_circuits])
    append!(seen, [x.id for x in objs.gens.thermal_standard])
    append!(seen, [x.id for x in objs.loads.standard_load])
    append!(seen, [x.id for x in objs.loads.interruptible_standard_load])
    append!(seen, [x.id for x in objs.dclines.two_terminal_lcc_line])
    append!(seen, [x.id for x in objs.vsclines])
    append!(seen, [x.id for x in objs.facts])
    append!(seen, [x.id for x in objs.switched_shunts])
    append!(seen, [x.id for x in objs.shunts])
    append!(seen, [x.id for x in objs.switches])
    append!(seen, [x.id for x in objs.breakers])

    @test length(seen) == length(unique(seen))
end

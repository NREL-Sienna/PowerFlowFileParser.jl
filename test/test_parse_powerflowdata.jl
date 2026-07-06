# Incumbent baseline for the PowerFlowData path on low-version PSS/E files.
# TEMPORARY: removed together with the PowerFlowData path in Phase 3.
# The native-path counts added in Phase 2 must equal these (note: PowerFlowData
# reports transformers separately from branches; the native `Dict` counts them
# inside "branch", so Phase 2 compares native branch == branches + transformers).
@testset "PowerFlowData path (v29/v30 baseline)" begin
    expected = Dict(
        "synthetic_data_v29.raw" =>
            (buses = 2, loads = 2, gens = 1, branches = 3, transformers = 3),
        "synthetic_data_v30.raw" =>
            (buses = 3, loads = 2, gens = 3, branches = 3, transformers = 2),
        "11BUS_KUNDUR_30.raw" =>
            (buses = 11, loads = 2, gens = 4, branches = 8, transformers = 4),
        "RTS_30.raw" =>
            (buses = 73, loads = 51, gens = 160, branches = 105, transformers = 15),
    )
    for (f, e) in expected
        net = PowerFlowDataNetwork(joinpath(PSSE_RAW_DIR, f)).data
        @test length(net.buses.i) == e.buses
        @test length(net.loads.i) == e.loads
        @test length(net.generators.i) == e.gens
        @test length(net.branches.i) == e.branches
        @test length(net.transformers.i) == e.transformers
    end
end

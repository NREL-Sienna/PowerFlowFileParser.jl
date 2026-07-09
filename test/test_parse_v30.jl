@testset "PSSE v30 parsing" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "synthetic_data_v30.raw"))

    @test pm.data["source_version"] == "30"
    @test pm.data["baseMVA"] == 100.0

    @test haskey(pm.data["bus"], 111)
    @test haskey(pm.data["bus"], 112)
    @test haskey(pm.data["bus"], 113)
    @test pm.data["bus"][111]["base_kv"] == 69.0
    @test isapprox(pm.data["bus"][111]["vm"], 1.09814; atol = 1e-5)

    @test length(pm.data["gen"]) == 3
    @test length(pm.data["load"]) == 2
    # 3 lines + 1 two-winding transformer are all stored under "branch"
    @test length(pm.data["branch"]) == 4
    @test length(pm.data["3w_transformer"]) == 1

    # branch 111-112 series impedance from the raw file
    b = first(v for v in values(pm.data["branch"])
              if Set((v["f_bus"], v["t_bus"])) == Set((111, 112)) && !v["transformer"])
    @test isapprox(b["br_r"], 0.001870; atol = 1e-6)
    @test isapprox(b["br_x"], 0.004420; atol = 1e-6)

    for (_, g) in pm.data["gen"]
        @test haskey(g, "ext")
    end
end

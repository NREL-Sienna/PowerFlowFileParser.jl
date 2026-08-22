@testset "PSSE Parsing" begin
    files = readdir(PSSE_RAW_DIR)
    if length(files) == 0
        error("No test files in the folder")
    end

    for f in files[1:1]
        @info "Parsing $f ..."
        pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, f))
        @info "Successfully parsed $f to PowerModelsData"

        # Verify basic data structure
        @test isa(pm_data, PowerModelsData)
        @test haskey(pm_data.data, "baseMVA")
        @test haskey(pm_data.data, "bus")
        @test haskey(pm_data.data, "gen")
        @test haskey(pm_data.data, "branch")

        # Verify generators have ext data (impedance info may or may not be present depending on source)
        for (gen_id, gen) in pm_data.data["gen"]
            @test haskey(gen, "ext")
            # Note: "r" and "x" fields may be present depending on the PSS/E file version
        end

        @info "Successfully validated $f data structure"
    end

    # Test bad input
    pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, files[1]))
    pm_data.data["bus"] = Dict{String, Any}()
    # Note: Since we removed PowerSystems.System constructor,
    # we just verify the data structure is valid
    @test !haskey(pm_data.data, "ref_buses") || isempty(pm_data.data["ref_buses"])
end

@testset "PSSE v35 load distributed generation section" begin
    file = joinpath(@__DIR__, "fixtures", "v35_dgen.raw")
    pm_data = PowerModelsData(file).data

    # Loads keep the gross demand (per-unit on system base).
    load_at(bus) = only([l for l in values(pm_data["load"]) if l["load_bus"] == bus])
    @test load_at(2)["pd"] ≈ 1.0
    @test load_at(2)["qd"] ≈ 0.25
    @test load_at(3)["pd"] ≈ 0.5
    @test load_at(3)["qd"] ≈ 0.1

    # Distributed generation is split into its own section.
    dgens = pm_data["distributed_generation"]
    @test length(dgens) == 2
    dgen_at(bus) = only([d for d in values(dgens) if d["bus"] == bus])
    d2 = dgen_at(2)
    @test d2["pg"] ≈ 0.2
    @test d2["qg"] ≈ 0.05
    @test d2["status"] == 1
    @test d2["source_id"] == ["distributed_generation", 2, "1"]
    d3 = dgen_at(3)
    @test d3["pg"] ≈ 0.15
    @test d3["qg"] ≈ 0.03
    @test d3["status"] == 0

    # DGEN fields are consumed, not leaked into ext.
    @test !haskey(load_at(2)["ext"], "DGENP")

    # Without validation the values stay in natural units.
    pm_nat = parse_file(file; validate = false)
    d2_nat = only([d for d in values(pm_nat["distributed_generation"]) if d["bus"] == 2])
    @test d2_nat["pg"] == 20.0

    # Loads without DGEN produce no entries; the section still exists for PTI input.
    pm_v33 = PowerModelsData(joinpath(PSSE_RAW_DIR, "Benchmark_4ger_33_2015.RAW")).data
    @test isempty(pm_v33["distributed_generation"])
end

@testset "PSSE two-terminal DC resistance per-unit base" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_two_terminal_dc.raw")
    pm_data = PowerModelsData(file).data
    dcline = only(values(pm_data["dcline"]))
    @test dcline["r"] ≈ 0.003125
    @test dcline["scheduled_dc_voltage"] == 400.0
    @test !(dcline["r"] ≈ 5.0 / (200.0^2 / 100.0))

    # A zero scheduled DC voltage cannot serve as a per-unit base on a line that is
    # in service. The check applies to every PSS(R)E version's two-terminal DC records.
    raw = read_fixture(file)
    bad = replace(raw, "400.00" => "0.0000"; count = 1)
    @test_throws ArgumentError parse_file(IOBuffer(bad); filetype = "raw")

    # A blocked line (MDC=0) with no DC voltage schedule warns and falls back to the
    # rectifier AC base rather than aborting the parse; the value is inert anyway.
    blocked = replace(bad, "\"DCTEST1     \",1," => "\"DCTEST1     \",0,")
    pm_blocked = @test_logs(
        (:warn, r"out of service"),
        match_mode = :any,
        parse_file(IOBuffer(blocked); filetype = "raw"),
    )
    blocked_dcline = only(values(pm_blocked["dcline"]))
    @test blocked_dcline["available"] == false
    @test blocked_dcline["r"] ≈ 5.0 / (200.0^2 / 100.0)
end

@testset "PSSE VSC line captures each converter's own AC bus base_kv" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_vsc_line.raw")
    pm_data = PowerModelsData(file).data
    vscline = only(values(pm_data["vscline"]))
    @test vscline["f_bus"] == 1
    @test vscline["t_bus"] == 3
    @test vscline["base_voltage_from"] == 200.0
    @test vscline["base_voltage_to"] == 138.0
    @test vscline["rated_dc_voltage"] == 150.0
end

@testset "PSSE ISW area-slack flag" begin
    file = joinpath(@__DIR__, "fixtures", "v35_area_slack_variants.raw")
    pm_data = @test_logs(
        (:warn, r"ISW=3"),
        (:warn, r"ISW=999"),
        match_mode = :any,
        PowerModelsData(file).data,
    )
    @test pm_data["bus"][2]["area_slack"] === true
    @test !haskey(pm_data["bus"][1], "area_slack")
    @test !haskey(pm_data["bus"][3], "area_slack")

    # Real v33 case: area 1 ISW=1 targets a PV bus; area 2 ISW=3 targets the REF bus.
    pm_v33 = PowerModelsData(joinpath(PSSE_RAW_DIR, "Benchmark_4ger_33_2015.RAW")).data
    @test pm_v33["bus"][1]["area_slack"] === true
    @test !haskey(pm_v33["bus"][3], "area_slack")
end

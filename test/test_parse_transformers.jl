# Contract tests for transformer emission (transformer-refactor train step 2).
# Characterization values below were captured from the pre-refactor parser and
# must not drift: the star-leg deletion is not allowed to perturb surviving keys.

const STAR_LEG_KEYS =
    ("r_primary", "x_primary", "r_secondary", "x_secondary", "r_tertiary", "x_tertiary")

const SURVIVING_3W_KEYS = (
    "r_12", "x_12", "r_23", "x_23", "r_13", "x_13",
    "base_power_12", "base_power_23", "base_power_13",
    "base_voltage_primary", "base_voltage_secondary", "base_voltage_tertiary",
    "primary_turns_ratio", "secondary_turns_ratio", "tertiary_turns_ratio",
    "rating_primary", "rating_secondary", "rating_tertiary",
    "available", "available_primary", "available_secondary", "available_tertiary",
    "g", "b", "star_bus", "COD1", "COD2", "COD3", "ext",
)

@testset "3W transformer emission: pairwise-only contract (mixed case)" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case14_with_pst3w.raw"))
    @test haskey(d, "3w_transformer")
    @test length(d["3w_transformer"]) == 2
    for (_, t) in d["3w_transformer"]
        for k in STAR_LEG_KEYS
            @test !haskey(t, k)   # RED until the deletion lands
        end
        # surviving keys present
        for k in SURVIVING_3W_KEYS
            @test haskey(t, k)
        end
    end
    # characterization: exact values captured pre-refactor from "TRAFO 3W 2" (record "1")
    t = d["3w_transformer"]["1"]
    @test t["r_12"] ≈ 0.0 atol = 1e-12
    @test t["x_12"] ≈ 0.0002 atol = 1e-12
    @test t["x_23"] ≈ 0.0002 atol = 1e-12
    @test t["x_13"] ≈ 0.0002 atol = 1e-12
    @test t["base_power_12"] == 100.0
    @test t["g"] ≈ 0.0 atol = 1e-12
    # star bus exists as a real hidden bus
    star = d["bus"][t["star_bus"]]
    @test star["hidden"] == true
end

@testset "2W transformer emission unchanged" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case14_with_pst3w.raw"))
    two_w = [b for (_, b) in d["branch"] if get(b, "transformer", false)]
    @test length(two_w) == 3
    # "TRAFO 2W 3", the 50-degree phase shifter. A second transformer,
    # "TRAFO 2W 2", carries an independent -60-degree shift, so selecting by
    # shift != 0.0 would be ambiguous; select by the record's own PSSE name
    # (stored in ext with trailing padding) instead of a fragile dict key.
    pst = only(
        b for (_, b) in d["branch"] if
        get(b, "transformer", false) &&
        strip(get(get(b, "ext", Dict()), "psse_name", "")) == "TRAFO 2W 3"
    )
    @test pst["shift"] ≈ 0.8726646259971648 atol = 1e-12    # 50 degrees, in radians
    @test pst["br_x"] ≈ 0.0001 atol = 1e-12
end

@testset "3W transformer emission: pairwise-only contract (pure 3W case)" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case6_3w.raw"))
    @test haskey(d, "3w_transformer")
    @test length(d["3w_transformer"]) == 1
    for (_, t) in d["3w_transformer"]
        for k in STAR_LEG_KEYS
            @test !haskey(t, k)   # RED until the deletion lands
        end
        for k in SURVIVING_3W_KEYS
            @test haskey(t, k)
        end
    end
    t = d["3w_transformer"]["1"]
    @test t["r_12"] ≈ 0.0 atol = 1e-12
    @test t["x_12"] ≈ 0.0002 atol = 1e-12
    @test t["x_23"] ≈ 0.0002 atol = 1e-12
    @test t["x_13"] ≈ 0.0002 atol = 1e-12
    @test t["base_power_12"] == 100.0
    @test t["g"] ≈ 0.0 atol = 1e-12
    star = d["bus"][t["star_bus"]]
    @test star["hidden"] == true
end

const CONTROL_KEYS_2W = ("COD1", "CONT1", "RMA1", "RMI1", "VMA1", "VMI1", "NTP1")
const CONTROL_KEYS_3W = Tuple(
    "$(f)$(w)" for w in 1:3 for f in ("COD", "CONT", "RMA", "RMI", "VMA", "VMI", "NTP")
)

@testset "transformer control block is first-class" begin
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case14_with_pst3w.raw"))
    for (_, b) in d["branch"]
        get(b, "transformer", false) || continue
        for k in CONTROL_KEYS_2W
            @test haskey(b, k)
        end
    end
    for (_, t) in d["3w_transformer"]
        for k in CONTROL_KEYS_3W
            @test haskey(t, k)
        end
    end
    # value spot-checks read directly from the "TRAFO 2W 3" raw record (v33
    # template: WINDV1,NOMV1,ANG1,RATA1,RATB1,RATC1,COD1,CONT1,RMA1,RMI1,VMA1,
    # VMI1,NTP1,TAB1,CR1,CX1,CNXA1):
    #   0.95000, 0.000, 50.000, 0.00, 0.00, 0.00, 0, 0, 1.10000, 0.90000, 1.10000, 0.90000, 33, 1, ...
    pst = only(
        b for (_, b) in d["branch"] if
        get(b, "transformer", false) &&
        strip(get(get(b, "ext", Dict()), "psse_name", "")) == "TRAFO 2W 3"
    )
    @test pst["NTP1"] == 33.0
    @test pst["RMA1"] == 1.1
    @test pst["CONT1"] == 0

    # "TRAFO 3W 2" (record "1") winding lines, same field order per winding:
    #   W1: 1.00000, 0.000, -30.000, 0.00, 0.00, 0.00, 0, 0, 1.10000, 0.90000, 1.10000, 0.90000, 33, 4, ...
    #   W2: 1.00000, 0.000, 150.000, 0.00, 0.00, 0.00, 0, 0, 1.10000, 0.90000, 1.10000, 0.90000, 33, 5, ...
    t = d["3w_transformer"]["1"]
    @test t["NTP1"] == 33.0
    @test t["RMA1"] == 1.1
    @test t["CONT1"] == 0
    @test t["NTP2"] == 33.0
end

@testset "transformer control block is first-class (v35)" begin
    # v35 regression: the ext-only TRANSFORMER3W_PARAMETER_NAMES loop in psse.jl
    # skips source_version 35 entirely; first-class emission must not.
    d = PowerFlowFileParser.parse_file(joinpath(PSSE_RAW_DIR, "case25_v35_savnwb.raw"))
    @test d["source_version"] == "35"
    two_w = [b for (_, b) in d["branch"] if get(b, "transformer", false)]
    @test !isempty(two_w)
    for b in two_w
        for k in CONTROL_KEYS_2W
            @test haskey(b, k)
        end
    end
    @test haskey(d, "3w_transformer")
    @test !isempty(d["3w_transformer"])
    for (_, t) in d["3w_transformer"]
        for k in CONTROL_KEYS_3W
            @test haskey(t, k)
        end
    end
    # spot-check against the raw "TR3W FOR TESTING V35 EXPORTER." record
    # (I=110, J=211, K=222), winding-1 line:
    #   0.99884,138.000,0.000,...,1,110,0,1.10020,0.92000,1.16000,0.93000,33,3,...
    t3w = only(
        t for (_, t) in d["3w_transformer"] if
        strip(get(get(t, "ext", Dict()), "psse_name", "")) ==
        "TR3W FOR TESTING V35 EXPORTER.         Z"
    )
    @test t3w["NTP1"] == 33.0
    @test t3w["RMA1"] == 1.1002
    @test t3w["CONT1"] == 110
end

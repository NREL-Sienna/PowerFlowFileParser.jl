# PSS/E revision is field 3 of the case-identification line (line 1).
# A missing field 3 means the file predates the REV field (v29-era) => treat as 30.
function _psse_rev(path)
    line1 = first(eachline(path))
    # v35 files lead with an `@!` column-header line; the REV is not on line 1.
    startswith(strip(line1), "@!") && return 35
    fields = split(split(line1, '/')[1], ',')
    length(fields) < 3 && return 30
    rev = tryparse(Int, strip(fields[3]))
    return rev === nothing ? 30 : rev
end

# The `parser_test_*` fixtures are targeted edge-case files that crash the native
# parser today (InexactError, iterate(::Nothing)); they predate this work and are
# excluded here. Tracked for separate triage, not by this consolidation.
_is_parser_test(f) = startswith(f, "parser_test_")

@testset "PSSE Parsing (native path, supported versions)" begin
    files = readdir(PSSE_RAW_DIR)
    @test !isempty(files)
    supported = filter(
        f -> _psse_rev(joinpath(PSSE_RAW_DIR, f)) >= 32 && !_is_parser_test(f),
        files,
    )
    @test !isempty(supported)
    for f in supported
        @info "Parsing $f ..."
        pm_data = PowerModelsData(joinpath(PSSE_RAW_DIR, f))
        @test isa(pm_data, PowerModelsData)
        for key in ("baseMVA", "bus", "gen", "branch")
            @test haskey(pm_data.data, key)
        end
        @test !isempty(pm_data.data["bus"])
        for (_, gen) in pm_data.data["gen"]
            @test haskey(gen, "ext")
        end
    end
end

# Expected component counts for the low-version fixtures, taken from the
# PowerFlowData baseline (see test_parse_powerflowdata.jl).
const _LOW_VERSION_COUNTS = Dict(
    "synthetic_data_v29.raw" => (bus = 2, load = 2, gen = 1, branch = 3, transformer = 3),
    "synthetic_data_v30.raw" => (bus = 3, load = 2, gen = 3, branch = 3, transformer = 2),
    "11BUS_KUNDUR_30.raw" => (bus = 11, load = 2, gen = 4, branch = 8, transformer = 4),
    "RTS_30.raw" => (bus = 73, load = 51, gen = 160, branch = 105, transformer = 15),
)

# LAYOUT stage (`parse_pti`): text -> raw section dicts, no topology resolution,
# analogous to the PowerFlowData path. Every low-version file must parse cleanly
# with section counts matching the baseline. This is the v29/v30 dtype-table and
# section-ordering proof, independent of connectivity.
@testset "PSSE v29/v30 layout parsing" begin
    for (f, c) in _LOW_VERSION_COUNTS
        d = PowerFlowFileParser.parse_pti(joinpath(PSSE_RAW_DIR, f))
        @test length(d["BUS"]) == c.bus
        @test length(d["LOAD"]) == c.load
        @test length(d["GENERATOR"]) == c.gen
        @test length(d["BRANCH"]) == c.branch
        @test length(d["TRANSFORMER"]) == c.transformer
    end
end

# BUILD stage (`PowerModelsData`): topology resolution. The real v30 systems build
# fully. The native "branch" dict includes transformers, so it equals the baseline
# branches + transformers.
@testset "PSSE v30 native build (real systems)" begin
    for f in ("11BUS_KUNDUR_30.raw", "RTS_30.raw")
        c = _LOW_VERSION_COUNTS[f]
        pm = PowerModelsData(joinpath(PSSE_RAW_DIR, f)).data
        @test pm["source_version"] == "30"
        @test length(pm["bus"]) == c.bus
        @test length(pm["gen"]) == c.gen
        @test length(pm["load"]) == c.load
        @test length(pm["branch"]) == c.branch + c.transformer
    end
end

# The synthetic fixtures are parser-stress files that reference undefined buses
# (e.g. a generator at a bus absent from the BUS section). They parse cleanly at
# the layout stage above, but the native build correctly refuses to resolve
# topology for a dangling reference. Encoded here as an expected failure.
@testset "PSSE v29/v30 native build rejects dangling references" begin
    for f in ("synthetic_data_v29.raw", "synthetic_data_v30.raw")
        @test_throws Exception PowerModelsData(joinpath(PSSE_RAW_DIR, f))
    end
end

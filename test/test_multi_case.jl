# Usage + tests for the multi-case merge API (`merge_multi_case`, `merge_views`,
# `MultiCase`, `CaseView`).
#
# `merge_multi_case(paths)` parses every file and folds them into one
# PowerModels-style dictionary where each component is unioned across cases by
# `source_id` and each leaf field becomes a length-N vector aligned to `paths`.
#
# This file is self-contained (a local fixture + hand-built cases) and does not
# depend on PowerSystemCaseBuilder.

const MULTI_CASE_RAW = "/Users/mbossart/sienna/tmp-parser-consolidation/PowerFlowFileParser.jl/test/modified_14bus_system.raw"#joinpath(@__DIR__, "modified_14bus_system.raw")

@testset "merge_multi_case: basic usage on real files" begin
    # Merge two cases (here the same file twice) into one MultiCase.
    mc = merge_multi_case([MULTI_CASE_RAW, MULTI_CASE_RAW]; validate = false)

    # `cases` is the per-slot label; index k in every vector corresponds to cases[k].
    @test length(mc) == 2
    @test mc.cases == ["modified_14bus_system.raw", "modified_14bus_system.raw"]

    # `sections` mirrors the PowerModels layout: section -> component-key -> entry.
    @test haskey(mc.sections, "gen")
    @test haskey(mc.sections, "branch")

    # Each entry has a `present` BitVector plus one length-N vector per field.
    gen_entry = first(values(mc.sections["gen"]))

    #   presence: which cases contain this component
    @test gen_entry["present"] isa BitVector
    @test gen_entry["present"] == BitVector([1, 1])      # in both cases

    #   values: length-N, concretely typed, aligned to `mc.cases`
    @test gen_entry["pg"] isa Vector{Union{Missing, Float64}}
    @test length(gen_entry["pg"]) == 2
    @test gen_entry["pg"][1] == gen_entry["pg"][2]       # identical file -> identical values

    #   the source_id/index bookkeeping fields are dropped (source_id is the key)
    @test !haskey(gen_entry, "source_id")
    @test !haskey(gen_entry, "index")

    #   nested `ext` dicts are flattened into `ext.<key>` scalar leaves
    @test any(k -> startswith(k, "ext."), keys(gen_entry))

    # Case-level scalars (baseMVA, per_unit, ...) also become length-N vectors.
    @test mc.scalars["baseMVA"] == Any[100.0, 100.0]
end

@testset "merge: component- and field-level discrepancies" begin
    # Build cases by hand to show how presence/absence is represented. A CaseView
    # is: name, components[section][key][field] (flat fields), and scalars.
    mkcase(name, gens) = CaseView(
        name,
        Dict("gen" => Dict{String, Dict{String, Any}}(gens)),
        Dict{String, Any}("baseMVA" => 100.0),
    )

    # gen "A" in all three cases; gen "B" only in cases 1 and 3;
    # gen "A" has an optional field only in case 2.
    c1 = mkcase("c1", ["A" => Dict("pg" => 1.0), "B" => Dict("pg" => 5.0)])
    c2 = mkcase("c2", ["A" => Dict("pg" => 2.0, "opt" => 9.0)])
    c3 = mkcase("c3", ["A" => Dict("pg" => 3.0), "B" => Dict("pg" => 7.0)])

    mc = merge_views([c1, c2, c3])

    A = mc.sections["gen"]["A"]
    B = mc.sections["gen"]["B"]

    # component present everywhere vs. missing in a case
    @test A["present"] == BitVector([1, 1, 1])
    @test B["present"] == BitVector([1, 0, 1])           # absent in case 2

    # values align to case index; `missing` marks the absent case
    @test A["pg"] == [1.0, 2.0, 3.0]
    @test isequal(B["pg"], [5.0, missing, 7.0])

    # field-level discrepancy: `opt` exists only in case 2 (present component,
    # absent field elsewhere) -> missing in the other slots
    @test isequal(A["opt"], [missing, 9.0, missing])

    # Interpreting a `missing`:
    #   present[k] == false            -> the whole component is absent in case k
    #   present[k] == true && missing  -> component present, but that field absent
end

@testset "presence_summary: at-a-glance display" begin
    # `presence_summary(io, mc)` (also the REPL display for a MultiCase) prints one
    # table per section. Status is binary: present & available (●) vs. everything
    # else (·) — present-but-unavailable counts the same as absent. Components with
    # identical status across all cases are omitted; the title reports how many
    # varied vs. were omitted.
    mkcase(name, gens) = CaseView(
        name,
        Dict("gen" => Dict{String, Dict{String, Any}}(gens)),
        Dict{String, Any}("baseMVA" => 100.0),
    )
    # gen A available in all cases -> omitted; gen B available/unavailable -> shown;
    # gen C present only in cases 1,2 -> shown.
    c1 = mkcase("caseA", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 1), "C" => Dict("gen_status" => 1)])
    c2 = mkcase("caseB", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 0), "C" => Dict("gen_status" => 1)])
    c3 = mkcase("caseC", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 1)])
    mc = merge_views([c1, c2, c3])

    buf = IOBuffer()
    presence_summary(buf, mc)                 # or simply `mc` at the REPL
    out = String(take!(buf))

    @test occursin("GEN — 2 of 3 vary (66.7%); 1 identical, omitted", out)
    @test occursin("caseB", out)              # case legend printed
    @test occursin("●", out) && occursin("·", out)
    @test occursin(r"\bB\b", out)             # varying components appear as rows
    @test occursin(r"\bC\b", out)
end

@testset "presence_summary: zero in on a subset of cases" begin
    # Build a superset of cases, then compare only a subset via `cases=` (indices
    # or names) — vary/omit is recomputed relative to just the selected cases,
    # without rebuilding the MultiCase.
    mkcase(name, gens) = CaseView(
        name,
        Dict("gen" => Dict{String, Dict{String, Any}}(gens)),
        Dict{String, Any}("baseMVA" => 100.0),
    )
    # gen A always on (omitted); gen B off only in case 2; gen C off only in case 4.
    c1 = mkcase("h1", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 1), "C" => Dict("gen_status" => 1)])
    c2 = mkcase("h2", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 0), "C" => Dict("gen_status" => 1)])
    c3 = mkcase("h3", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 1), "C" => Dict("gen_status" => 1)])
    c4 = mkcase("h4", ["A" => Dict("gen_status" => 1), "B" => Dict("gen_status" => 1), "C" => Dict("gen_status" => 0)])
    mc = merge_views([c1, c2, c3, c4])

    grab(; kwargs...) = (b = IOBuffer(); presence_summary(b, mc; kwargs...); String(take!(b)))

    # all 4: both B and C vary
    @test occursin("GEN — 2 of 3 vary", grab())

    # subset [1,3] are identical -> nothing varies
    out13 = grab(cases = [1, 3])
    @test occursin("showing 2 of 4 cases", out13)
    @test occursin("GEN — 0 of 3 vary", out13)

    # subset by name ["h1","h4"] -> only C differs
    out14 = grab(cases = ["h1", "h4"])
    @test occursin("GEN — 1 of 3 vary", out14)
    @test occursin(r"\bC\b", out14)

    # bad selectors error clearly
    @test_throws ArgumentError grab(cases = [1, 99])
    @test_throws ArgumentError grab(cases = ["nope.raw"])
end

@testset "presence_summary: three-valued status" begin
    # Status is three-valued: ● present & available, · present but unavailable,
    # x not present. A component that is present-but-unavailable in one case and
    # absent in another now counts as *varying* (it did not under the old binary).
    mkcase(name, gens) = CaseView(
        name,
        Dict("gen" => Dict{String, Dict{String, Any}}(gens)),
        Dict{String, Any}("baseMVA" => 100.0),
    )
    # D: present-unavailable in k1, absent in k2  -> · vs x  -> varies (three-state only)
    # E: available in both                        -> omitted
    c1 = mkcase("k1", ["D" => Dict("gen_status" => 0), "E" => Dict("gen_status" => 1)])
    c2 = mkcase("k2", ["E" => Dict("gen_status" => 1)])
    mc = merge_views([c1, c2])

    buf = IOBuffer()
    presence_summary(buf, mc)
    out = String(take!(buf))

    @test occursin("GEN — 1 of 2 vary (50.0%); 1 identical, omitted", out)
    @test occursin("·", out)          # present but unavailable
    @test occursin("x", out)          # not present
    @test occursin(r"\bD\b", out)     # the ·-vs-x component is shown
    @test occursin("not present", out)  # legend documents the third state
end

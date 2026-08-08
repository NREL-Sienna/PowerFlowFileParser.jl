const FOURTEEN_BUS_FIXTURE = joinpath(@__DIR__, "modified_14bus_system.raw")

function _fourteen_bus_pm_data()
    return PFP.PowerModelsData(FOURTEEN_BUS_FIXTURE)
end

@testset "build_openapi_system reads topology, loads, generation, branches, transformers, dc lines, and shunts" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    @test PFP.component_type_names(sys) == [
        "ACBus", "Arc", "Area", "FACTSControlDevice", "FixedAdmittance", "Line",
        "LoadZone", "StandardLoad", "SwitchedAdmittance", "ThermalStandard",
        "ThreeWindingTransformer", "TransformerCircuit", "TwoTerminalLCCLine",
        "TwoWindingTransformer",
    ]
    @test length(PFP.get_components(sys, "ACBus")) == 22
    @test length(PFP.get_components(sys, "Area")) == 1
    @test length(PFP.get_components(sys, "LoadZone")) == 1
    # Coefficient-level load/generator/cost assertions live in test_openapi_load.jl and
    # test_openapi_generation.jl (task 13b); branch/transformer/dc-line/shunt assertions
    # live in test_openapi_branch.jl and test_openapi_dc_shunt.jl (task 13c); this just
    # locks in the component census.
    @test length(PFP.get_components(sys, "StandardLoad")) == 13
    @test length(PFP.get_components(sys, "ThermalStandard")) == 7
    @test length(PFP.get_components(sys, "Line")) == 20
    @test length(PFP.get_components(sys, "TwoWindingTransformer")) == 3
    @test length(PFP.get_components(sys, "ThreeWindingTransformer")) == 2
    @test length(PFP.get_components(sys, "TransformerCircuit")) == 9
    @test length(PFP.get_components(sys, "TwoTerminalLCCLine")) == 1
    @test length(PFP.get_components(sys, "FixedAdmittance")) == 4
    @test length(PFP.get_components(sys, "SwitchedAdmittance")) == 2
    @test length(PFP.get_components(sys, "FACTSControlDevice")) == 1
end

@testset "build_openapi_system warns about unconsumed pm dict sections" begin
    sys = @test_logs(
        (:warn, r"switch"),
        match_mode = :any,
        PFP.build_openapi_system(_fourteen_bus_pm_data()),
    )
    # The warning names sections, not just "switch"; "breaker"/"impedance_correction"/
    # "switch" are the only categories the 14-bus fixture carries that remain unread
    # (a future attributes-stage sub-task) — the warning is the only signal of that, so
    # it must fire. "branch"/"3w_transformer"/"dcline"/"shunt"/"switched_shunt"/"facts"
    # are now consumed (task 13c) and must NOT appear; see the dedicated exclusion test
    # below.
    @test "Line" in PFP.component_type_names(sys)
end

@testset "the unconsumed-section warning excludes branch/transformer/dc-line/shunt sections now consumed" begin
    data = _fourteen_bus_pm_data().data
    only_consumed = Dict{String, Any}(
        (key => data[key] for key in PFP._CONSUMED_PM_SECTIONS if haskey(data, key))...,
    )
    only_consumed["baseMVA"] = data["baseMVA"]
    only_consumed["source_type"] = data["source_type"]
    only_consumed["per_unit"] = data["per_unit"]
    logs, _ = Test.collect_test_logs() do
        PFP._warn_unconsumed_sections(only_consumed)
    end
    @test isempty(logs)
end

@testset "the unconsumed-section warning excludes scalar pm dict keys and fully-consumed sections" begin
    data = _fourteen_bus_pm_data().data
    only_consumed = Dict{String, Any}(
        "bus" => data["bus"],
        "baseMVA" => data["baseMVA"],
        "source_type" => data["source_type"],
        "per_unit" => data["per_unit"],
    )
    logs, _ = Test.collect_test_logs() do
        PFP._warn_unconsumed_sections(only_consumed)
    end
    @test isempty(logs)
end

@testset "LoadZone peak sums bus loads and converts system pu to MW/MVAr" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    zone = only(PFP.get_components(sys, "LoadZone"))
    # Cross-checked against PowerSystemCaseBuilder's oracle: 34.8 / -8.62 pu on a
    # 100 MVA base.
    @test PFP.get_value(zone, :peak_active_power) ≈ 3480.0
    @test PFP.get_value(zone, :peak_reactive_power) ≈ -862.0
    @test PFP.get_value(zone, :base_power) == 100.0
end

@testset "Area gets a zero peak, matching the oracle's asymmetry with LoadZone" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    area = only(PFP.get_components(sys, "Area"))
    @test PFP.get_value(area, :peak_active_power) == 0.0
    @test PFP.get_value(area, :peak_reactive_power) == 0.0
    @test PFP.get_value(area, :base_power) == 100.0
end

@testset "ACBus fields come off the pm dict with the declared units" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    data = _fourteen_bus_pm_data().data
    reg = PFP.get_registry(sys)
    for bus in PFP.get_components(sys, "ACBus")
        number = PFP.get_value(bus, :number)
        d = data["bus"][number]
        @test PFP.get_value(bus, :base_voltage) == d["base_kv"]
        @test PFP.get_value(bus, :angle) == d["va"]
        @test PFP.get_value(bus, :magnitude) == d["vm"]
        @test PFP.get_value(bus, :voltage_limits).min == d["vmin"]
        @test PFP.get_value(bus, :voltage_limits).max == d["vmax"]
        @test PFP.get_bus_id(reg, number) == PFP.get_value(bus, :id)
    end
end

@testset "ACBus resolves area and load zone to registered ids" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    reg = PFP.get_registry(sys)
    area_id = PFP.get_id(reg, "Area", "1")
    zone_id = PFP.get_id(reg, "LoadZone", "1")
    for bus in PFP.get_components(sys, "ACBus")
        @test PFP.get_value(bus, :area) == area_id
        @test PFP.get_value(bus, :load_zone) == zone_id
    end
end

@testset "bus_type 3 (REF) maps to the schema's REF string" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    data = _fourteen_bus_pm_data().data
    for bus in PFP.get_components(sys, "ACBus")
        number = PFP.get_value(bus, :number)
        expected = PFP._bustype_name(Int(data["bus"][number]["bus_type"]))
        @test PFP.get_value(bus, :bustype) == expected
    end
end

@testset "an unavailable bus (bus_status = false) sets available = false" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    data = _fourteen_bus_pm_data().data
    for bus in PFP.get_components(sys, "ACBus")
        number = PFP.get_value(bus, :number)
        @test PFP.get_value(bus, :available) ==
              Bool(get(data["bus"][number], "bus_status", true))
    end
end

@testset "area_slack overrides bus_type to SLACK" begin
    pm_data =
        PFP.PowerModelsData(joinpath(@__DIR__, "fixtures", "v35_area_slack_variants.raw"))
    sys = PFP.build_openapi_system(pm_data)
    reg = PFP.get_registry(sys)
    buses = PFP.get_components(sys, "ACBus")
    slack_bus = only(b for b in buses if PFP.get_value(b, :number) == 2)
    @test PFP.get_value(slack_bus, :bustype) == "SLACK"
    other = [b for b in buses if PFP.get_value(b, :number) != 2]
    @test all(b -> PFP.get_value(b, :bustype) != "SLACK", other)
end

@testset "_bustype_name rejects a code outside PowerModels' 1-4 range" begin
    @test PFP._bustype_name(1) == "PQ"
    @test PFP._bustype_name(4) == "ISOLATED"
    @test_throws IS.DataFormatError PFP._bustype_name(5)
    @test_throws IS.DataFormatError PFP._bustype_name(0)
end

@testset "bus_name_formatter, area_name_formatter and loadzone_name_formatter thread through" begin
    sys = PFP.build_openapi_system(
        _fourteen_bus_pm_data();
        bus_name_formatter = d -> "BUS_$(d["bus_i"])",
        area_name_formatter = a -> "AREA_$a",
        loadzone_name_formatter = z -> "ZONE_$z",
    )
    reg = PFP.get_registry(sys)
    @test PFP.has_id(reg, "ACBus", "BUS_101")
    @test PFP.has_id(reg, "Area", "AREA_1")
    @test PFP.has_id(reg, "LoadZone", "ZONE_1")
end

@testset "add_arc! deduplicates a bus pair regardless of direction" begin
    # Topology only (no branches/transformers/dc lines) so the Arc census this test
    # asserts is self-contained; `build_openapi_system` now creates real arcs of its own
    # (task 13c), which would make a fixed expected count fragile.
    data = _fourteen_bus_pm_data().data
    sys = PFP.OpenAPISystem(Float64(data["baseMVA"]))
    PFP.read_loadzones!(sys, data)
    PFP.read_bus!(sys, data)
    reg = PFP.get_registry(sys)
    from_id = PFP.get_bus_id(reg, 101)
    to_id = PFP.get_bus_id(reg, 102)
    id1 = PFP.add_arc!(sys, from_id, to_id)
    id2 = PFP.add_arc!(sys, from_id, to_id)
    id3 = PFP.add_arc!(sys, to_id, from_id)
    @test id1 == id2
    @test id1 != id3
    @test length(PFP.get_components(sys, "Arc")) == 2
    arc = first(a for a in PFP.get_components(sys, "Arc") if PFP.get_value(a, :id) == id1)
    @test PFP.get_value(arc, :from_id) == from_id
    @test PFP.get_value(arc, :to_id) == to_id
end

@testset "the emitted document round-trips through PC and validates" begin
    sys = PFP.build_openapi_system(_fourteen_bus_pm_data())
    path = joinpath(mktempdir(), "fourteen_bus.json")
    PFP.to_json(sys, path)
    doc = PFP.PC.read_document(path)
    @test length(PFP.PC.get_components(doc, "ACBus")) == 22
    @test length(PFP.PC.get_components(doc, "Area")) == 1
    @test length(PFP.PC.get_components(doc, "LoadZone")) == 1
    # Loads/generation (13b) and branches/transformers/dc-lines/shunts (13c) are real;
    # only the attributes stage (GeographicInfo/ImpedanceCorrectionData) leaves an
    # honestly empty bucket rather than erroring.
    @test length(PFP.PC.get_components(doc, "StandardLoad")) == 13
    @test length(PFP.PC.get_components(doc, "ThermalStandard")) == 7
    @test length(PFP.PC.get_components(doc, "Line")) == 20
    @test length(PFP.PC.get_components(doc, "TwoWindingTransformer")) == 3
    @test length(PFP.PC.get_components(doc, "ThreeWindingTransformer")) == 2
    @test length(PFP.PC.get_components(doc, "TwoTerminalLCCLine")) == 1
    @test length(PFP.PC.get_components(doc, "FixedAdmittance")) == 4
    @test length(PFP.PC.get_components(doc, "SwitchedAdmittance")) == 2
    @test length(PFP.PC.get_components(doc, "FACTSControlDevice")) == 1
    @test isempty(PFP.PC.get_components(doc, "GeographicInfo"))
end

@testset "the attributes stage is a named, clearly-failing stub" begin
    sys = PFP.OpenAPISystem(100.0)
    data = _fourteen_bus_pm_data().data
    @test_throws ErrorException PFP.read_attributes!(sys, data)
end

@testset "build_openapi_system rejects a pm dict with no buses" begin
    pm_data = PFP.PowerModelsData(
        Dict{String, Any}("bus" => Dict{String, Any}(), "baseMVA" => 100.0),
    )
    @test_throws IS.DataFormatError PFP.build_openapi_system(pm_data)
end

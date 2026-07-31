function _serialize_test_system()
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)

    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :id, PFP.register_bus!(reg, 101, "Abel"))
    PFP.set_value!(bus, :number, 101)
    PFP.set_value!(bus, :name, "Abel")
    PFP.set_value!(bus, :available, true)
    PFP.set_value!(bus, :bustype, "REF")
    PFP.set_value!(bus, :base_voltage, 138.0, "kV")
    PFP.add_component!(sys, bus)

    area = PFP.PO.Area()
    PFP.set_value!(area, :id, PFP.register!(reg, "Area", "1"))
    PFP.set_value!(area, :name, "1")
    PFP.add_component!(sys, area)

    geo = PFP.PC.GeographicInfo()
    PFP.set_value!(geo, :id, PFP.next_id!(reg))
    PFP.set_value!(geo, :geo_json, Dict{String, Any}("type" => "Point"))
    push!(sys.supplemental_attributes, geo)
    PFP.add_supplemental_attribute_association!(
        sys,
        PFP.get_value(geo, :id),
        PFP.get_value(bus, :id),
    )
    return sys
end

@testset "openapi_document has the agreed envelope" begin
    doc = PFP.openapi_document(_serialize_test_system())
    @test collect(keys(doc)) == [
        "base_power",
        "components",
        "supplemental_attribute_associations",
        "supplemental_attributes",
        "time_series",
        "time_series_associations",
        "unit_system",
    ]
    @test doc["base_power"] == 100.0
    @test isempty(doc["time_series"])
    @test isempty(doc["time_series_associations"])
end

@testset "unit_system defaults to NATURAL_UNITS" begin
    sys = PFP.OpenAPISystem(100.0)
    @test PFP.get_unit_system(sys) == "NATURAL_UNITS"
    @test !PFP.uses_per_unit(sys)
end

@testset "unit_system accepts DEVICE_BASE" begin
    sys = PFP.OpenAPISystem(100.0; unit_system = "DEVICE_BASE")
    @test PFP.get_unit_system(sys) == "DEVICE_BASE"
    @test PFP.uses_per_unit(sys)
end

@testset "unit_system rejects invalid values" begin
    @test_throws IS.DataFormatError PFP.OpenAPISystem(100.0; unit_system = "PER_UNIT")
end

@testset "unit_system is carried into the document" begin
    natural = PFP.openapi_document(_serialize_test_system())
    @test natural["unit_system"] == "NATURAL_UNITS"

    sys = PFP.OpenAPISystem(100.0; unit_system = "DEVICE_BASE")
    device_base = PFP.openapi_document(sys)
    @test device_base["unit_system"] == "DEVICE_BASE"
end

@testset "components are grouped by type name in sorted order" begin
    doc = PFP.openapi_document(_serialize_test_system())
    @test collect(keys(doc["components"])) == ["ACBus", "Area"]
    @test length(doc["components"]["ACBus"]) == 1
    @test length(doc["components"]["Area"]) == 1
end

@testset "unset properties are absent, not null" begin
    doc = PFP.openapi_document(_serialize_test_system())
    bus = only(doc["components"]["ACBus"])
    @test haskey(bus, :name)
    @test bus[:number] == 101
    @test !haskey(bus, :angle)
    @test !haskey(bus, :voltage_limits)
end

@testset "supplemental attribute associations serialize as id pairs" begin
    doc = PFP.openapi_document(_serialize_test_system())
    assoc = only(doc["supplemental_attribute_associations"])
    @test assoc[:attribute_id] == 3
    @test assoc[:entity_id] == 1
end

@testset "to_json writes a file that round-trips through JSON" begin
    sys = _serialize_test_system()
    path = joinpath(mktempdir(), "case.json")
    @test PFP.to_json(sys, path) == path
    parsed = JSON.parsefile(path)
    @test parsed["base_power"] == 100.0
    @test parsed["components"]["ACBus"][1]["name"] == "Abel"
    @test parsed["components"]["ACBus"][1]["base_voltage"] == 138.0
    @test !haskey(parsed["components"]["ACBus"][1], "angle")
    @test parsed["supplemental_attribute_associations"][1]["entity_id"] == 1
end

@testset "to_json refuses to overwrite without force" begin
    path = joinpath(mktempdir(), "case.json")
    PFP.to_json(_serialize_test_system(), path)
    @test_throws ErrorException PFP.to_json(_serialize_test_system(), path)
    @test PFP.to_json(_serialize_test_system(), path; force = true) == path
end

@testset "pretty = true changes bytes but not parsed content" begin
    dir = mktempdir()
    compact = joinpath(dir, "compact.json")
    pretty = joinpath(dir, "pretty.json")
    PFP.to_json(_serialize_test_system(), compact)
    PFP.to_json(_serialize_test_system(), pretty; pretty = true)
    @test read(compact, String) != read(pretty, String)
    @test JSON.parsefile(compact) == JSON.parsefile(pretty)
end

@testset "output is byte-deterministic" begin
    dir = mktempdir()
    a = joinpath(dir, "a.json")
    b = joinpath(dir, "b.json")
    PFP.to_json(_serialize_test_system(), a)
    PFP.to_json(_serialize_test_system(), b)
    @test read(a, String) == read(b, String)
end

@testset "every emitted component satisfies check_required" begin
    sys = _serialize_test_system()
    for type_name in PFP.component_type_names(sys)
        for component in PFP.get_components(sys, type_name)
            @test OpenAPI.check_required(component)
        end
    end
    for association in sys.supplemental_attribute_associations
        @test OpenAPI.check_required(association)
    end
end

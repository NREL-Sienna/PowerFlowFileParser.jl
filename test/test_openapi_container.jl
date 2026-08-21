function _bus(id::Int, name::AbstractString)
    bus = PFP.PO.ACBus()
    PFP.set_value!(bus, :id, id)
    PFP.set_value!(bus, :name, name)
    return bus
end

@testset "OpenAPISystem starts empty" begin
    sys = PFP.OpenAPISystem(100.0)
    @test PFP.get_base_power(sys) == 100.0
    @test isempty(PFP.component_type_names(sys))
    @test isempty(PFP.get_document(sys).time_series_associations)
    @test isempty(PFP.get_document(sys).supplemental_attributes)
    @test isempty(PFP.get_document(sys).supplemental_attribute_associations)
end

@testset "add_component! groups by type name" begin
    sys = PFP.OpenAPISystem(100.0)
    PFP.add_component!(sys, _bus(1, "Abel"))
    PFP.add_component!(sys, _bus(2, "Adams"))

    area = PFP.PO.Area()
    PFP.set_value!(area, :id, 3)
    PFP.set_value!(area, :name, "1")
    PFP.add_component!(sys, area)

    @test PFP.component_type_names(sys) == ["ACBus", "Area"]
    @test length(PFP.get_components(sys, "ACBus")) == 2
    @test length(PFP.get_components(sys, "Area")) == 1
end

@testset "component_type_names is sorted for deterministic output" begin
    sys = PFP.OpenAPISystem(100.0)
    line = PFP.PO.Line()
    PFP.set_value!(line, :id, 1)
    PFP.set_value!(line, :name, "L1")
    PFP.add_component!(sys, line)
    PFP.add_component!(sys, _bus(2, "Abel"))
    @test PFP.component_type_names(sys) == ["ACBus", "Line"]
end

@testset "per-type buckets stay concretely typed" begin
    sys = PFP.OpenAPISystem(100.0)
    PFP.add_component!(sys, _bus(1, "Abel"))
    PFP.add_component!(sys, _bus(2, "Adams"))
    @test eltype(PFP.get_components(sys, "ACBus")) == PFP.PO.ACBus
end

@testset "get_components on an absent type is empty, not an error" begin
    sys = PFP.OpenAPISystem(100.0)
    @test isempty(PFP.get_components(sys, "ACBus"))
end

@testset "the registry travels with the system" begin
    sys = PFP.OpenAPISystem(100.0)
    reg = PFP.get_registry(sys)
    id = PFP.register_bus!(reg, 101, "Abel")
    PFP.add_component!(sys, _bus(id, "Abel"))
    @test PFP.get_bus_id(PFP.get_registry(sys), 101) == id
end

@testset "add_supplemental_attribute! records the attribute and its link" begin
    sys = PFP.OpenAPISystem(100.0)
    PFP.add_component!(sys, _bus(1, "Abel"))
    geo = PFP.PC.GeographicInfo()
    PFP.set_value!(geo, :id, 2)
    PFP.set_value!(geo, :geo_json, Dict{String, Any}("type" => "Point"))
    PFP.add_supplemental_attribute!(sys, geo, 1)

    assoc = only(PFP.get_document(sys).supplemental_attribute_associations)
    @test PFP.get_value(assoc, :attribute_id) == 2
    @test PFP.get_value(assoc, :component_id) == 1
    @test PFP.get_value(assoc, :component_type) == "ACBus"
    @test only(PFP.get_supplemental_attributes(sys, "GeographicInfo")) === geo
end

@testset "add_service_association! records a membership row" begin
    sys = PFP.OpenAPISystem(100.0)
    PFP.add_component!(sys, _bus(1, "Abel"))
    PFP.add_service_association!(sys, 99, 1)
    assoc = only(PFP.get_document(sys).service_associations)
    @test PFP.get_value(assoc, :service_id) == 99
    @test PFP.get_value(assoc, :entity_id) == 1
    @test isempty(PFP.get_document(sys).supplemental_attribute_associations)
    @test_throws IS.DataFormatError PFP.add_service_association!(sys, 99, 1)
end

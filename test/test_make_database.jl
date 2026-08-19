import SQLite
import DBInterface

# Return a Dict{String, Int} of entity_type => row count from the entities table.
function _entity_type_counts(db::SQLite.DB)
    counts = Dict{String, Int}()
    for row in DBInterface.execute(db,
        "SELECT entity_type, COUNT(*) FROM entities GROUP BY entity_type",
    )
        counts[row[1]] = row[2]
    end
    return counts
end

_table_count(db::SQLite.DB, table::String) =
    first(DBInterface.execute(db, "SELECT COUNT(*) FROM $table"))[1]

@testset "make_database: returns a SQLite.DB" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case14.raw"))
    db = make_database(pm)
    @test isa(db, SQLite.DB)
    @test !isempty(SQLite.tables(db))
end

@testset "make_database: case14.raw entity_type counts match parse_to_openapi_objects" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case14.raw"))
    objs = parse_to_openapi_objects(pm)
    db = make_database(pm)
    counts = _entity_type_counts(db)

    @test counts["ACBus"] == length(objs.buses)
    @test counts["Line"] == length(objs.branches.line)
    @test counts["TwoWindingTransformer"] ==
          length(objs.branches.two_winding_transformer)
    @test counts["TransformerCircuit"] == length(objs.transformer_circuits)
    @test counts["ThermalStandard"] == length(objs.gens.thermal_standard)
    @test counts["StandardLoad"] == length(objs.loads.standard_load)
    @test counts["SwitchedAdmittance"] == length(objs.switched_shunts)
    @test counts["Arc"] == length(objs.arcs)
end

@testset "make_database: case16_all_components.raw covers every POM subtype" begin
    # Each of the 7 subtypes we wired to inherit from a shared parent table
    # must appear as an entity_type row on this file.
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    db = make_database(pm)
    counts = _entity_type_counts(db)

    for subtype in (
        "TransformerCircuit",
        "TwoWindingTransformer",
        "ThreeWindingTransformer",
        "DiscreteControlledACBranch",
        "TwoTerminalLCCLine",
        "TwoTerminalVSCLine",
        "FACTSControlDevice",
        "SwitchedAdmittance",
        "InterruptibleStandardLoad",
    )
        @test get(counts, subtype, 0) > 0
    end
end

@testset "make_database: dedicated transformer tables get the right row counts" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    objs = parse_to_openapi_objects(pm)
    db = make_database(pm)

    @test _table_count(db, "transformer_circuits") ==
          length(objs.transformer_circuits)
    @test _table_count(db, "two_winding_transformers") ==
          length(objs.branches.two_winding_transformer)
    @test _table_count(db, "three_winding_transformers") ==
          length(objs.xfrm_3w.three_winding_transformer)
end

@testset "make_database: arcs FK all point at existing entities" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    db = make_database(pm)

    orphan_from = first(DBInterface.execute(db, """
        SELECT COUNT(*) FROM arcs
        WHERE from_id NOT IN (SELECT id FROM entities)
    """))[1]
    orphan_to = first(DBInterface.execute(db, """
        SELECT COUNT(*) FROM arcs
        WHERE to_id NOT IN (SELECT id FROM entities)
    """))[1]

    @test orphan_from == 0
    @test orphan_to == 0
end

@testset "make_database: 3W holders reference existing transformer_circuit rows" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case16_all_components.raw"))
    db = make_database(pm)

    orphan = first(DBInterface.execute(db, """
        SELECT COUNT(*) FROM three_winding_transformers t
        WHERE t.primary_circuit_id NOT IN (SELECT id FROM transformer_circuits)
           OR t.secondary_circuit_id NOT IN (SELECT id FROM transformer_circuits)
           OR t.tertiary_circuit_id NOT IN (SELECT id FROM transformer_circuits)
    """))[1]
    @test orphan == 0
end

@testset "make_database: local modified_14bus_system.raw round-trips" begin
    # Sanity check on the local fixture we've been using end-to-end.
    pm = PowerModelsData(joinpath(@__DIR__, "modified_14bus_system.raw"))
    db = make_database(pm)
    counts = _entity_type_counts(db)

    @test counts["ACBus"] == 22
    @test counts["Line"] == 20
    @test counts["TwoWindingTransformer"] == 3
    @test counts["ThreeWindingTransformer"] == 2
    @test counts["TransformerCircuit"] == 9
    @test counts["FACTSControlDevice"] == 1
    @test counts["TwoTerminalLCCLine"] == 1
    @test counts["DiscreteControlledACBranch"] == 2
end

@testset "make_database: path kwarg writes to disk" begin
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, "case14.raw"))
    path = tempname() * ".sqlite"
    db = make_database(pm; path = path)
    @test isfile(path)
    @test filesize(path) > 0
    # The returned DB should still be usable.
    @test _table_count(db, "entities") > 0
    rm(path; force = true)
end

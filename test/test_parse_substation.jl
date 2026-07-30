using Test
using PowerFlowFileParser

const V35_SUBSTATION_FIXTURE = joinpath(@__DIR__, "fixtures", "v35_substation.raw")

@testset "PTI v35 substation section parsing" begin
    pti_data = PowerFlowFileParser._parse_pti_data(
        IOBuffer(read(V35_SUBSTATION_FIXTURE, String)),
    )

    @test haskey(pti_data, "SUBSTATION DATA")
    substations = pti_data["SUBSTATION DATA"]
    @test length(substations) == 2

    alpha = substations[1]
    @test alpha["IS"] == 1
    @test alpha["NAME"] == "ALPHA"
    @test alpha["LATITUDE"] == 34.61
    @test alpha["LONGITUDE"] == -86.67
    @test alpha["SGR"] == 0.25

    @testset "nodes" begin
        nodes = alpha["NODES"]
        @test length(nodes) == 3
        @test nodes[1]["NI"] == 1
        @test nodes[1]["NAME"] == "ALPHA\$138\$0001"
        @test nodes[1]["I"] == 1
        @test nodes[1]["STATUS"] == 1
        @test nodes[1]["VM"] == 1.01
        @test nodes[1]["VA"] == -11.0
        @test nodes[3]["STATUS"] == 0
        # Omitted node voltages stay empty; a node with no stored voltage
        # inherits its bus voltage downstream instead of a fabricated 1.0/0.0.
        @test nodes[3]["VM"] == ""
        @test nodes[3]["VA"] == ""
    end

    @testset "switching devices" begin
        devices = alpha["SWITCHING DEVICES"]
        @test length(devices) == 3
        breaker = devices[1]
        @test breaker["NI"] == 1
        @test breaker["NJ"] == 2
        @test breaker["CKT"] == "1"
        @test breaker["NAME"] == "ALPHA\$138\$CB\$0001"
        @test breaker["TYPE"] == 2
        @test breaker["STATUS"] == 1
        @test breaker["NSTAT"] == 1
        @test breaker["X"] == 0.0001
        @test breaker["RATE1"] == 100.0
        @test breaker["RATE2"] == 110.0
        @test breaker["RATE3"] == 120.0
        disconnect = devices[2]
        @test disconnect["TYPE"] == 3
        @test disconnect["STATUS"] == 0
        @test disconnect["NSTAT"] == 1
        generic = devices[3]
        @test generic["TYPE"] == 1
        @test generic["CKT"] == "2"
    end

    @testset "terminals" begin
        terminals = alpha["TERMINALS"]
        @test length(terminals) == 6
        load_terminal = terminals[1]
        @test load_terminal["I"] == 1
        @test load_terminal["NI"] == 1
        @test load_terminal["TYP"] == "L"
        @test load_terminal["ID"] == "1"
        @test iszero(load_terminal["J"])
        @test iszero(load_terminal["K"])
        branch_terminal = terminals[4]
        @test branch_terminal["TYP"] == "B"
        @test branch_terminal["J"] == 2
        @test iszero(branch_terminal["K"])
        @test branch_terminal["ID"] == "1"
        xf2_terminal = terminals[5]
        @test xf2_terminal["TYP"] == "2"
        @test xf2_terminal["J"] == 3
        @test xf2_terminal["ID"] == "T1"
        xf3_terminal = terminals[6]
        @test xf3_terminal["TYP"] == "3"
        @test xf3_terminal["J"] == 2
        @test xf3_terminal["K"] == 3
    end

    @testset "comment-free empty-sub-block substation" begin
        bravo = substations[2]
        @test bravo["IS"] == 2
        @test bravo["NAME"] == "BRAVO"
        @test length(bravo["NODES"]) == 1
        @test bravo["NODES"][1]["I"] == 2
        @test isempty(bravo["SWITCHING DEVICES"])
        @test isempty(bravo["TERMINALS"])
    end
end

@testset "PowerModels substation conversion" begin
    pm = PowerModelsData(V35_SUBSTATION_FIXTURE)
    pm_data = pm.data

    @test haskey(pm_data, "substation")
    @test !haskey(pm_data, "substation_data")
    substations = pm_data["substation"]
    @test length(substations) == 2

    alpha = substations["1"]
    @test alpha["index"] == 1
    @test alpha["number"] == 1
    @test alpha["name"] == "ALPHA"
    @test alpha["latitude"] == 34.61
    @test alpha["longitude"] == -86.67
    @test alpha["grounding_resistance"] == 0.25
    @test alpha["source_id"] == ["substation", 1]

    @test length(alpha["nodes"]) == 3
    node1 = alpha["nodes"][1]
    @test node1["number"] == 1
    @test node1["name"] == "ALPHA\$138\$0001"
    @test node1["bus"] == 1
    @test node1["status"] == 1
    @test node1["vm"] == 1.01
    @test node1["va"] == -11.0

    node3 = alpha["nodes"][3]
    @test !haskey(node3, "vm")
    @test !haskey(node3, "va")

    @test length(alpha["switching_devices"]) == 3
    breaker = alpha["switching_devices"][1]
    @test breaker["from_node"] == 1
    @test breaker["to_node"] == 2
    @test breaker["ckt"] == "1"
    @test breaker["name"] == "ALPHA\$138\$CB\$0001"
    @test breaker["device_type"] == 2
    @test breaker["status"] == 1
    @test breaker["normal_status"] == 1
    @test breaker["x"] == 0.0001
    @test breaker["rates"] == [100.0, 110.0, 120.0]

    @test length(alpha["terminals"]) == 6
    xf3_terminal = alpha["terminals"][6]
    @test xf3_terminal["bus"] == 1
    @test xf3_terminal["node"] == 3
    @test xf3_terminal["type"] == "3"
    @test xf3_terminal["secondary_bus"] == 2
    @test xf3_terminal["tertiary_bus"] == 3
    @test xf3_terminal["id"] == "3"
    load_terminal = alpha["terminals"][1]
    @test iszero(load_terminal["secondary_bus"])
    @test iszero(load_terminal["tertiary_bus"])

    bravo = substations["2"]
    @test bravo["number"] == 2
    @test isempty(bravo["switching_devices"])
    @test isempty(bravo["terminals"])

    @testset "substation switching devices materialize into the breaker table" begin
        @test length(pm_data["bus"]) == 4   # buses 1-3 plus one injected node-bus
        # The one device on in-service nodes is a TYPE 2 circuit breaker; the other two
        # touch out-of-service node 3 and are dropped.
        breakers = collect(values(pm_data["breaker"]))
        @test length(breakers) == 1
        cb = only(breakers)
        @test cb["discrete_branch_type"] == 1
        @test cb["state"] == 1
        @test cb["ext"]["TYPE"] == 2
        @test cb["ext"]["NAME"] == "ALPHA\$138\$CB\$0001"
        @test cb["ext"]["nb_substation"] == 1
        @test cb["rating"] == 100.0
        @test isempty(get(pm_data, "switch", []))
        @test isempty(get(pm_data, "other", []))
    end

    @testset "import_all" begin
        pm_all = PowerModelsData(V35_SUBSTATION_FIXTURE; import_all = true)
        subs_all = pm_all.data["substation"]
        @test length(subs_all) == 2
        @test subs_all["1"]["name"] == "ALPHA"
        @test length(subs_all["1"]["switching_devices"]) == 3
    end
end

@testset "_psse2pm_substation_node carries voltage only when stored" begin
    absent = PowerFlowFileParser._psse2pm_substation_node(
        Dict{String, Any}(
            "NI" => 5, "NAME" => "N5", "I" => 10, "STATUS" => 1, "VM" => "", "VA" => "",
        ),
    )
    @test !haskey(absent, "vm") && !haskey(absent, "va")
    @test absent["number"] == 5 && absent["bus"] == 10 && absent["status"] == 1
    present = PowerFlowFileParser._psse2pm_substation_node(
        Dict{String, Any}(
            "NI" => 6, "NAME" => "N6", "I" => 10, "STATUS" => 1, "VM" => 1.03,
            "VA" => 7.5,
        ),
    )
    @test present["vm"] == 1.03 && present["va"] == 7.5
end

@testset "_prepare_node_breaker! injects node-buses with representative keeping I" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 1, "type" => "B",
                        "secondary_bus" => 20, "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "B",
                        "secondary_bus" => 30, "id" => "1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    @test 10 in nb.nb_bus_numbers
    @test length(data["bus"]) == 2
    @test nb.node_number[(1, 1)] == 10
    @test nb.node_number[(1, 2)] != 10
    new_no = nb.node_number[(1, 2)]
    # This pass runs before per-unit conversion, so angles stay in degrees.
    @test data["bus"][new_no]["va"] == 5.0
    @test data["bus"][new_no]["bus_type"] == 1
    @test nb.terminal_node[(10, "B", 30, "1")] == new_no
    @test length(nb.switches) == 1 && nb.switches[1].closed
    @test nb.switches[1].from == 10 && nb.switches[1].to == new_no
end

@testset "_prepare_node_breaker! node without stored voltage inherits bus voltage" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.04277, "va" => 23.04, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.015, "va" => 21.9),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 0,
                        "device_type" => 3, "x" => 1e-4, "ckt" => "1",
                        "name" => "DSC1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    @test nb.node_number[(1, 1)] == 10
    @test data["bus"][10]["vm"] == 1.04277
    @test data["bus"][10]["va"] == 23.04
    new_no = nb.node_number[(1, 2)]
    @test new_no != 10
    @test data["bus"][new_no]["vm"] == 1.015
    @test data["bus"][new_no]["va"] == 21.9
    @test length(nb.switches) == 1 && !nb.switches[1].closed
end

@testset "_prepare_node_breaker! derives a name for blank-named nodes" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "   ",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                    Dict{String, Any}("number" => 3, "bus" => 10,
                        "status" => 1, "vm" => 1.0, "va" => 6.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    blank = data["bus"][nb.node_number[(1, 2)]]
    missing_name = data["bus"][nb.node_number[(1, 3)]]
    @test blank["name"] == "SUB_2"
    @test missing_name["name"] == "SUB_3"
    @test blank["name"] isa String && missing_name["name"] isa String
end

@testset "_prepare_node_breaker! is a no-op without substation data" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(10 => Dict{String, Any}("bus_i" => 10)),
    )
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    @test isempty(nb.nb_bus_numbers) && length(data["bus"]) == 1
end

@testset "_reroute_devices_to_nodes! attaches devices to their node-buses" begin
    make_data() = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "B",
                        "secondary_bus" => 40, "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "2",
                        "secondary_bus" => 50, "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "L",
                        "id" => "1"),
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "3",
                        "secondary_bus" => 20, "tertiary_bus" => 30,
                        "id" => "3W1"),
                ],
            ),
        ],
    )

    data = make_data()
    data["breaker"] =
        [
            Dict{String, Any}("f_bus" => 10, "t_bus" => 40,
                "source_id" => ["breaker", 10, 40, "1"]),
        ]
    data["branch"] =
        [
            Dict{String, Any}("f_bus" => 10, "t_bus" => 50,
                "source_id" => ["transformer", 10, 50, 0, "1", 0]),
        ]
    data["load"] =
        [Dict{String, Any}("load_bus" => 10, "source_id" => ["load", 10, "1"])]
    data["distributed_generation"] =
        [Dict{String, Any}("bus" => 10,
            "source_id" => ["distributed_generation", 10, "1"])]
    data["3w_transformer"] =
        [
            Dict{String, Any}("bus_primary" => 10, "bus_secondary" => 20,
                "bus_tertiary" => 30, "circuit" => "3W1"),
        ]

    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    PowerFlowFileParser._reroute_devices_to_nodes!(data, nb)
    new_no = nb.node_number[(1, 2)]
    @test data["breaker"][1]["f_bus"] == new_no
    @test data["branch"][1]["f_bus"] == new_no
    @test data["load"][1]["load_bus"] == new_no
    @test data["distributed_generation"][1]["bus"] == new_no
    @test data["3w_transformer"][1]["bus_primary"] == new_no
    @test data["3w_transformer"][1]["bus_secondary"] == 20
    @test data["3w_transformer"][1]["bus_tertiary"] == 30
end

@testset "_reroute_devices_to_nodes! migrates PV/REF bus_type when a generator moves off the representative bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 2,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "M", "id" => "1"),
                ],
            ),
        ],
    )
    data["gen"] =
        [Dict{String, Any}("gen_bus" => 10, "source_id" => ["generator", "10", "1"])]

    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    PowerFlowFileParser._reroute_devices_to_nodes!(data, nb)
    new_no = nb.node_number[(1, 2)]
    @test data["gen"][1]["gen_bus"] == new_no
    @test data["bus"][new_no]["bus_type"] == 2
    @test data["bus"][10]["bus_type"] == 1
end

@testset "area slack follows the bus_type migrated onto a node-bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "source_version" => "35",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 2,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "area_interchange" => [
            Dict{String, Any}("area_number" => 1, "bus_number" => 10),
        ],
        "gen" => [
            Dict{String, Any}("gen_bus" => 10,
                "source_id" => ["generator", "10", "1"]),
        ],
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => Dict{String, Any}[],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "M", "id" => "1"),
                ],
            ),
        ],
    )
    nb = PowerFlowFileParser.materialize_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    @test data["bus"][new_no]["bus_type"] == 2
    @test data["bus"][10]["ext"]["nb_bus_type_moved_to"] == new_no
    # No warning: the ISW bus's voltage control moved with its generator.
    @test_logs PowerFlowFileParser._psse2pm_area_slack!(data)
    @test data["bus"][new_no]["area_slack"] === true
    @test !haskey(data["bus"][10], "area_slack")
end

@testset "materialize_node_breaker! de-energizes switches touching an isolated (IDE=4) node-bus" begin
    data = Dict{String, Any}(
        "source_type" => "pti",
        "source_version" => "35",
        "has_isolated_type_buses" => true,
        "connected_buses" => Set{Int}(),
        "candidate_isolated_to_pq_buses" => Set{Int}(),
        "candidate_isolated_to_pv_buses" => Set{Int}(),
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 4,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1, "bus_status" => false,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => Dict{String, Any}[],
            ),
        ],
    )
    nb = PowerFlowFileParser.materialize_node_breaker!(data)
    new_no = nb.node_number[(1, 2)]
    @test data["bus"][new_no]["bus_type"] == 4
    cb = only(data["breaker"])
    @test cb["state"] == 0
    @test cb["discrete_branch_type"] == 1
end

@testset "_reroute_devices_to_nodes! reroutes switched shunts by RAW ID, not source_id index" begin
    make_data() = Dict{String, Any}(
        "source_type" => "pti",
        "bus" => Dict{Int, Any}(
            10 => Dict{String, Any}(
                "bus_i" => 10, "name" => "SUB", "base_kv" => 138.0,
                "bus_type" => 1,
                "vm" => 1.02, "va" => 0.0, "area" => 1, "zone" => 1,
                "vmin" => 0.9, "vmax" => 1.1,
            ),
        ),
        "substation" => [
            Dict{String, Any}(
                "index" => 1,
                "nodes" => [
                    Dict{String, Any}("number" => 1, "name" => "SUB\$N1",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.02, "va" => 0.0),
                    Dict{String, Any}("number" => 2, "name" => "SUB\$N2",
                        "bus" => 10,
                        "status" => 1, "vm" => 1.01, "va" => 5.0),
                ],
                "switching_devices" => [
                    Dict{String, Any}("from_node" => 1, "to_node" => 2,
                        "status" => 1,
                        "device_type" => 2, "x" => 1e-4, "ckt" => "1",
                        "name" => "CB1",
                        "rates" => [0.0, 0.0, 0.0]),
                ],
                "terminals" => [
                    Dict{String, Any}("bus" => 10, "node" => 2, "type" => "S", "id" => "2"),
                ],
            ),
        ],
    )
    data = make_data()
    data["switched_shunt"] = [
        Dict{String, Any}("shunt_bus" => 10, "sw_id" => "2",
            "source_id" => ["switched shunt", 10, 1]),
        Dict{String, Any}("shunt_bus" => 10, "sw_id" => "9",
            "source_id" => ["switched shunt", 10, 2]),
    ]
    nb = PowerFlowFileParser._prepare_node_breaker!(data)
    PowerFlowFileParser._reroute_devices_to_nodes!(data, nb)
    new_no = nb.node_number[(1, 2)]
    @test data["switched_shunt"][1]["shunt_bus"] == new_no
    @test data["switched_shunt"][2]["shunt_bus"] == 10
end

@testset "v35 node-breaker case materializes node-buses and switches" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_node_breaker.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 6

    # Two TYPE 2 circuit breakers land in the breaker table; the TYPE 3 disconnect
    # lands in the switch table.
    breakers = collect(values(pm_data["breaker"]))
    @test length(breakers) == 2
    @test all(b["discrete_branch_type"] == 1 for b in breakers)
    @test all(b["state"] == 1 for b in breakers)
    @test all(b["ext"]["TYPE"] == 2 for b in breakers)
    switches = collect(values(pm_data["switch"]))
    @test length(switches) == 1
    o = only(switches)
    @test o["discrete_branch_type"] == 0
    @test o["state"] == 0
    @test o["f_bus"] != o["t_bus"]
    @test o["ext"]["NAME"] == "NBFCSUB\$DSC\$23"
    @test o["ext"]["TYPE"] == 3
    @test o["ext"]["nb_substation"] == 1

    node_bus(ni) = only([
        b for b in values(pm_data["bus"])
        if get(get(b, "ext", Dict{String, Any}()), "nb_node", nothing) == ni
    ])["bus_i"]
    @test node_bus(1) == 2

    branches = collect(values(pm_data["branch"]))
    br21 = only([b for b in branches if b["source_id"][2] == 2 && b["source_id"][3] == 1])
    br23 = only([b for b in branches if b["source_id"][2] == 2 && b["source_id"][3] == 3])
    @test br21["f_bus"] == 2
    @test br23["f_bus"] == node_bus(4)
    @test br23["f_bus"] != 2

    nb_buses = [
        b for b in values(pm_data["bus"])
        if haskey(get(b, "ext", Dict{String, Any}()), "nb_node")
    ]
    @test length(nb_buses) == 4
    @test all(b["ext"]["nb_bus"] == 2 for b in nb_buses)
    @test all(b["ext"]["nb_substation"] == 1 for b in nb_buses)
end

@testset "v35 populated SUBSTATION section materializes" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_substation.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 4
    # One TYPE 2 breaker and one TYPE 3 switch, so the device chain spans both sections.
    devices = vcat(
        collect(values(pm_data["breaker"])),
        collect(values(pm_data["switch"])),
    )
    @test length(pm_data["breaker"]) == 1
    @test length(pm_data["switch"]) == 1
    @test all(s["state"] == 1 for s in devices)
    ends = [Set((s["f_bus"], s["t_bus"])) for s in devices]
    touched = union(ends...)
    @test 1 in touched && 2 in touched
    @test !(Set((1, 2)) in ends)
end

@testset "node-buses inherit the bus voltage when the RAW stores none" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_node_voltage_inherit.raw")
    pm_data = PowerModelsData(file).data
    nb_buses = [
        b for b in values(pm_data["bus"])
        if haskey(get(b, "ext", Dict{String, Any}()), "nb_node")
    ]
    @test length(nb_buses) == 3
    for b in nb_buses
        @test isapprox(b["vm"], 1.05; atol = 1e-6)
        # Validation converts bus angles to radians after materialization.
        @test isapprox(b["va"], deg2rad(3.0); atol = 1e-6)
    end
end

@testset "materialization is a no-op without substation nodes" begin
    file = joinpath(@__DIR__, "fixtures", "synthetic_v35_two_terminal_dc.raw")
    pm_data = PowerModelsData(file).data
    @test length(pm_data["bus"]) == 3
    @test isempty(pm_data["switch"])
end

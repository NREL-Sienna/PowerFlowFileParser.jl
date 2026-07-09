import PowerFlowData

# Temporary equivalence coverage: the native PowerModels path must reproduce the
# PowerFlowData parse for v30-family files. Removed when the PowerFlowData
# dependency is dropped.

function _native_counts(file)
    pm = PowerModelsData(joinpath(PSSE_RAW_DIR, file)).data
    nstar = count(v -> startswith(get(v, "name", ""), "starbus"), values(pm["bus"]))
    (
        bus = length(pm["bus"]) - nstar,
        load = length(pm["load"]),
        gen = length(pm["gen"]),
        line = count(v -> !v["transformer"], values(pm["branch"])),
        xf2 = count(v -> v["transformer"], values(pm["branch"])),
        xf3 = length(get(pm, "3w_transformer", Dict())),
    )
end

function _powerflowdata_counts(file)
    net = PowerFlowData.parse_network(joinpath(PSSE_RAW_DIR, file))
    k = net.transformers.k
    (
        bus = length(net.buses.i),
        load = length(net.loads.i),
        gen = length(net.generators.i),
        line = length(net.branches.i),
        xf2 = count(==(0), k),
        xf3 = count(!=(0), k),
    )
end

@testset "Native vs PowerFlowData equivalence (v30 family)" begin
    # _native_counts excludes the star buses the native path synthesizes for
    # three-winding transformers, so real-component counts match exactly.
    for file in ("11BUS_KUNDUR_30.raw", "RTS_30.raw", "synthetic_data_v30.raw")
        native = _native_counts(file)
        reference = _powerflowdata_counts(file)
        @test native == reference
    end
end

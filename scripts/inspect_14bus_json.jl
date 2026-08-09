#!/usr/bin/env julia
#
# Parse a PSS/E case and write JSON for visual inspection.
#
#   julia --project scripts/inspect_14bus_json.jl
#   julia --project scripts/inspect_14bus_json.jl --case path/to/other.raw --out /tmp/look
#
# Produces three files in the output directory (default `inspection_output/`):
#
#   <case>.pm.json                  the parsed PowerModels dict
#   <case>.NATURAL_UNITS.json       OpenAPI document, unit_system = NATURAL_UNITS
#   <case>.DEVICE_BASE.json         OpenAPI document, unit_system = DEVICE_BASE
#
# Both OpenAPI documents are built via `build_openapi_system` and carry real components —
# buses, loads, generators, branches, transformers, dc lines, shunts, plus
# `ImpedanceCorrectionData` and `DiscreteControlledACBranch`.
# `../power-openapi-models/scripts/check_json_compat.py` reads this directory's `*.json`
# (excluding `.pm.json`/`.roundtrip.json`) to validate Julia's output against the
# generated Python models.

import JSON
using PowerFlowFileParser

const DEFAULT_CASE = joinpath(@__DIR__, "..", "test", "modified_14bus_system.raw")
const UNIT_SYSTEMS = ("NATURAL_UNITS", "DEVICE_BASE")

function parse_args(argv)
    case = DEFAULT_CASE
    out = joinpath(@__DIR__, "..", "inspection_output")
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--case"
            case = argv[i + 1]
            i += 2
        elseif arg == "--out"
            out = argv[i + 1]
            i += 2
        elseif arg in ("-h", "--help")
            println(read(@__FILE__, String)[1:findfirst("import JSON", read(@__FILE__, String)).start - 1])
            exit(0)
        else
            error("Unrecognized argument: $arg")
        end
    end
    return (case = abspath(case), out = abspath(out))
end

"""Write `data` as indented JSON, reporting the path and size."""
function write_json(path, data)
    open(path, "w") do io
        JSON.print(io, data, 2)
    end
    println("  wrote $(relpath(path)) ($(round(filesize(path) / 1024; digits = 1)) KiB)")
    return path
end

"""Count entries per top-level PM-dict section, so the parse can be eyeballed."""
function summarize_pm(data)
    println("\nParsed sections (component counts):")
    for key in sort(collect(keys(data)))
        value = data[key]
        if value isa Dict && !isempty(value) && all(v -> v isa Dict, values(value))
            println("  $(rpad(key, 26)) $(length(value))")
        elseif value isa Vector
            println("  $(rpad(key, 26)) $(length(value))")
        end
    end
    println("\nScalars: base_power=$(get(data, "baseMVA", "?")) per_unit=$(get(data, "per_unit", "?"))")
    return nothing
end

"""
Report the shunts, including any relocated off a switching device.

A BRANCH row with a '@'/'*' CKT is a breaker or switch and has no line shunt, so
GI/BI/GJ/BJ on such a row is malformed input and gets moved to the bus it was
declared on. Those carry a `branch shunt` source_id, so they are worth calling out
separately during a visual check.
"""
function summarize_shunts(data)
    shunts = get(data, "shunt", Dict())
    if isempty(shunts)
        println("\nNo shunts in this case.")
        return nothing
    end
    println("\nShunts ($(length(shunts))):")
    for key in sort(collect(keys(shunts)))
        s = shunts[key]
        source = get(s, "source_id", Any[])
        tag = isempty(source) ? "?" : string(first(source))
        marker = tag == "branch shunt" ? "  <-- relocated from a switching device" : ""
        println(
            "  bus=$(rpad(get(s, "shunt_bus", "?"), 6)) " *
            "gs=$(rpad(get(s, "gs", "?"), 12)) bs=$(rpad(get(s, "bs", "?"), 12)) " *
            "source=$tag$marker",
        )
    end
    return nothing
end

function main(argv)
    opts = parse_args(argv)
    isfile(opts.case) || error("Case not found: $(opts.case)")
    mkpath(opts.out)
    stem = first(splitext(basename(opts.case)))

    println("Case:   $(opts.case)")
    println("Output: $(opts.out)\n")

    println("Parsing...")
    pm = PowerModelsData(opts.case)
    data = pm.data

    println("\nWriting JSON:")
    write_json(joinpath(opts.out, "$stem.pm.json"), data)

    # The OpenAPI envelope in both unit systems, built from the same parsed case via the
    # full emit layer.
    for unit_system in UNIT_SYSTEMS
        sys = build_openapi_system(pm; unit_system = unit_system)
        path = joinpath(opts.out, "$stem.$unit_system.json")
        to_json(sys, path; force = true, pretty = true)
        println("  wrote $(relpath(path)) ($(round(filesize(path) / 1024; digits = 1)) KiB)")
        println(
            "    components: $(join(PowerFlowFileParser.component_type_names(sys), ", "))",
        )
    end

    summarize_pm(data)
    summarize_shunts(data)
    return nothing
end

main(ARGS)

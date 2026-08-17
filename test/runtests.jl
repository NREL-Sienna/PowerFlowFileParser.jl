using Test
using Logging
import LazyArtifacts
import InfrastructureSystems as IS
import InfrastructureSystems: DataFormatError

using PowerFlowFileParser
const PFP = PowerFlowFileParser
import JSON
import OpenAPI

import Aqua
Aqua.test_unbound_args(PowerFlowFileParser)
Aqua.test_undefined_exports(PowerFlowFileParser)
Aqua.test_ambiguities(PowerFlowFileParser)
Aqua.test_stale_deps(PowerFlowFileParser)
Aqua.test_deps_compat(PowerFlowFileParser)

const DATA_DIR =
    joinpath(LazyArtifacts.artifact"CaseData", "PowerSystemsTestData-5.0-dev4")
const MATPOWER_DIR = joinpath(DATA_DIR, "matpower")
const PSSE_RAW_DIR = joinpath(DATA_DIR, "psse_raw")
const BAD_DATA = joinpath(DATA_DIR, "bad_data_for_tests")

"""
Read a raw fixture as text with LF line endings, whatever the checkout produced.

The parser itself is line-ending agnostic — it consumes fixtures through `readlines`, which
strips `\\n` and `\\r\\n` alike. Tests that instead match a byte pattern against the file
text are not: a Windows checkout rewrites these LF fixtures to CRLF, and a pattern spanning
a line boundary then fails to match, silently leaving the text unmodified.
"""
read_fixture(path::AbstractString) = replace(read(path, String), "\r\n" => "\n")

const FOURTEEN_BUS_FIXTURE = joinpath(@__DIR__, "modified_14bus_system.raw")

fourteen_bus_pm_data() = PFP.PowerModelsData(FOURTEEN_BUS_FIXTURE)

"""Compound OpenAPI values (`MinMax`, `FromTo`, `ComplexNumber`, ...) are generated
structs, not `NamedTuple`s — compare them to a `NamedTuple` field-by-field rather than
via `==`, which would always be `false` across the two types."""
_matches_nt(value, nt::NamedTuple) =
    all(getproperty(value, k) == v for (k, v) in pairs(nt))

LOG_FILE = "power-flow-parser.log"
LOG_LEVELS = Dict(
    "Debug" => Logging.Debug,
    "Info" => Logging.Info,
    "Warn" => Logging.Warn,
    "Error" => Logging.Error,
)

"""
Copied @includetests from https://github.com/ssfrr/TestSetExtensions.jl.
Ideally, we could import and use TestSetExtensions.  Its functionality was broken by changes
in Julia v0.7.  Refer to https://github.com/ssfrr/TestSetExtensions.jl/pull/7.
"""

"""
Includes the given test files, given as a list without their ".jl" extensions.
If none are given it will scan the directory of the calling file and include all
the julia files.
"""
macro includetests(testarg...)
    if length(testarg) == 0
        tests = []
    elseif length(testarg) == 1
        tests = testarg[1]
    else
        error("@includetests takes zero or one argument")
    end

    quote
        tests = $tests
        rootfile = @__FILE__
        if length(tests) == 0
            tests = readdir(dirname(rootfile))
            tests = filter(
                f ->
                    startswith(f, "test_") && endswith(f, ".jl") && f != basename(rootfile),
                tests,
            )
        else
            tests = map(f -> string(f, ".jl"), tests)
        end
        println()
        for test in tests
            print(splitext(test)[1], ": ")
            include(test)
            println()
        end
    end
end

function get_logging_level_from_env(env_name::String, default)
    level = get(ENV, env_name, default)
    return IS.get_logging_level(level)
end

function run_tests()
    logging_config_filename = get(ENV, "SIENNA_LOGGING_CONFIG", nothing)
    if logging_config_filename !== nothing
        config = IS.LoggingConfiguration(logging_config_filename)
    else
        config = IS.LoggingConfiguration(;
            filename = LOG_FILE,
            file_level = Logging.Info,
            console_level = Logging.Error,
        )
    end
    console_logger = ConsoleLogger(config.console_stream, config.console_level)

    IS.open_file_logger(config.filename, config.file_level) do file_logger
        levels = (Logging.Info, Logging.Warn, Logging.Error)
        multi_logger =
            IS.MultiLogger([console_logger, file_logger], IS.LogEventTracker(levels))
        global_logger(multi_logger)

        if !isempty(config.group_levels)
            IS.set_group_levels!(multi_logger, config.group_levels)
        end

        # Testing parser functionality
        @time @testset "Begin PowerFlowFileParser tests" begin
            @includetests ARGS
        end

        # Note: Some test files have intentional data issues (voltage inconsistencies)
        # that generate error logs, so we don't check for zero errors here
        @info IS.report_log_summary(multi_logger)
    end
end

logger = global_logger()

try
    run_tests()
finally
    # Guarantee that the global logger is reset.
    global_logger(logger)
    nothing
end

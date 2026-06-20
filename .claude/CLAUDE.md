# PowerFlowFileParser.jl — Claude Guide

Platform-wide Sienna conventions (performance, type stability, formatter, environments, code style) live in `.claude/Sienna.md` — read it too. This file is repo-specific and does not restate them.

## Purpose & place in the stack

A focused parsing library that turns text-based power-flow case files into plain Julia
data structures (a PowerModels-style `Dict` or a `PowerFlowData.Network` struct). It is a
leaf/utility package: it does **not** depend on PowerSystems.jl. Downstream packages
(PowerSystems.jl, PowerFlows.jl) consume its output and build typed `System`s — that
conversion is their concern, not this package's. The intent is to keep the parser
independent of the heavy modeling stack so parsed data can be inspected and reused.

Verify against `Project.toml`: deps are DataStructures, DocStringExtensions,
InfrastructureSystems, LinearAlgebra, PowerFlowData, Unicode, YAML. There is **no**
PowerSystems, SQLite, or SiennaOpenAPIModels dependency, and **no** `make_database` /
`System` constructor in this package (older docs mentioning these are stale).

## Supported formats

- **MATPOWER `.m`** — via `parse_matpower` (PowerModels pathway).
- **PSS/E RAW `.raw`** — two independent pathways:
  - PowerModels pathway (`parse_psse` / `PowerModelsData`): handles `source_version`
    **32, 33, 35**. Other versions raise `error("Unsupported PSS(R)E source version ...")`.
  - PowerFlowData.jl pathway (`PowerFlowDataNetwork`): supports **v30, v32, v33**.
- **`.json`** — PowerModels JSON via `parse_json` (default `filetype` when extension is
  unrecognized).

## Public API

Exports (all in `src/PowerFlowFileParser.jl`): `parse_file`, `PowerModelsData`,
`PowerFlowDataNetwork`.

- `parse_file(file::Union{String,IO}; import_all=false, validate=true, correct_branch_rating=true)`
  — dispatches on file extension (`m` / `raw` / `json`) and returns a
  `Dict{String,Any}` in PowerModels format (keys `"baseMVA"`, `"bus"`, `"gen"`,
  `"branch"`, `"dcline"`, ...). For `String` it opens the file and infers `filetype` from
  the extension; the `IO` method takes `filetype` explicitly.
- `PowerModelsData(file; pm_data_corrections=true, import_all=false, correct_branch_rating=true)`
  — thin wrapper: `struct PowerModelsData; data::Dict{String,Any}; end`. Calls
  `parse_file` then `correct_pm_transformer_status!` (flips a branch to a transformer when
  the two end buses differ in base kV by more than `BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL`).
  Note: the constructor's `pm_data_corrections` kwarg maps to `parse_file`'s `validate`.
- `PowerFlowDataNetwork(file)` — `struct ...; data::PowerFlowData.Network; end`; delegates
  entirely to `PowerFlowData.parse_network(file)`. Access via `data.buses`, etc.

## Architecture / src layout

Include order is set in `src/PowerFlowFileParser.jl`: `definitions.jl` →
`powerflowdata_data.jl` → `power_models_data.jl` → `im_io.jl` → `pm_io.jl`. Respect this
when adding constants/types.

- `src/definitions.jl` — `const`s: base MVA/frequency defaults, validation tolerances
  (`BRANCH_BUS_VOLTAGE_DIFFERENCE_TOL`, tap-ratio bounds, zero-impedance threshold),
  `WINDING_NAMES`, `TRANSFORMER3W_PARAMETER_NAMES`.
- `src/power_models_data.jl`, `src/powerflowdata_data.jl` — the two container structs above.
- `src/pm_io.jl` includes (order matters): `pm_io/matpower.jl`, `pm_io/common.jl`,
  `pm_io/pti.jl`, `pm_io/psse.jl`, `pm_io/data.jl`.
  - `pm_io/common.jl` — `parse_file` entry points + `correct_network_data!` (the
    validation/correction pipeline: connectivity, reference-bus, per-unit conversion,
    transformer/VAD/thermal-limit/branch-direction/dcline corrections, cost-function
    cleanup).
  - `pm_io/matpower.jl` (~825 lines) — MATPOWER `.m` reader.
  - `pm_io/pti.jl` (~2680 lines) — PSS/E PTI section/field **dtype tables**
    (`_<section>_dtypes`, and `_<section>_dtypes_v35` variants for v35). Defines field
    name + Julia type + default per column for each RAW section.
  - `pm_io/psse.jl` (~2350 lines) — `parse_psse`; section-based, branches on
    `source_version`; three-winding transformers create a synthetic "starbus".
  - `pm_io/data.jl` (~2890 lines) — PowerModels data manipulation / corrections, plus
    `move_genfuel_and_gentype!` (run for all formats after parse).
- `src/im_io.jl` includes `im_io/matlab.jl` (generic Matlab assignment/matrix parser),
  `im_io/common.jl`, `im_io/data.jl` (multi-network merge/update utilities).

The `pm_io/` and `im_io/` trees are adapted from PowerModels.jl / InfrastructureModels.jl
(see the `LICENSE.md` in each); preserve their structure when patching.

## Conventions & gotchas

- **PTI parsing is comma-delimited, not fixed-width.** Lines are split with a quote-aware
  regex (`_split_string = r",(?=(?:[^']*'[^']*')*[^']*$)"`) and comments stripped with
  `_comment_split`. When touching field handling, edit the dtype table in `pti.jl`, not ad
  hoc splitting in `psse.jl`.
- **Version handling lives in `psse.jl`** as `source_version ∈ ("32","33")` vs `== "35"`
  branches with an `error` fallthrough. Add new versions by extending both the `pti.jl`
  dtype tables and these branches; do not silently default.
- **Two parser pathways diverge in version coverage** (PowerModels 32/33/35 vs
  PowerFlowData 30/32/33) — pick `PowerFlowDataNetwork` for v30 RAW files.
- Some `error("Multiconductor Not Supported in PowerSystems")` messages remain in the
  code — they refer to a limitation, not a dependency.
- Per global prefs: prefer multiple dispatch over `isa`/`<:`; `if/else` over ternaries;
  `function … end` with explicit `return` for non-trivial bodies. (The existing tests
  contain `@test isa(...)` assertions — match surrounding style, but do not add `isa`
  branching to source logic.)

## Commands (verified)

Test env deps are in `test/Project.toml`: Aqua, InfrastructureSystems, Logging,
PowerSystemCaseBuilder, Test. Test data comes from `PowerSystemCaseBuilder.DATA_DIR`
(`matpower/`, `psse_raw/`, `bad_data_for_tests/`), so PSB shared-state caveats apply.

```sh
# Full suite (runtests.jl auto-includes every test/test_*.jl via @includetests)
julia --project=test test/runtests.jl

# Single test file (pass name without .jl, forwarded as ARGS)
julia --project=test test/runtests.jl test_parse_psse

# Instantiate test env
julia --project=test -e 'using Pkg; Pkg.instantiate()'

# Docs
julia --project=docs docs/make.jl

# Formatter (note: activates scripts/formatter, not scripts/formatter/Project.toml flag)
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

runtests.jl also runs Aqua checks (`test_unbound_args`, `test_undefined_exports`,
`test_ambiguities`, `test_stale_deps`, `test_deps_compat`) before the parsing testsets,
and writes a `power-flow-parser.log`. Test files (`test_parse_matpower.jl`,
`test_parse_psse.jl`) only assert on the parsed `Dict` structure — there is no `System`
construction here.

## Cross-package coupling

Output is the contract. The PowerModels `Dict` produced here is what PowerSystems.jl's
`System(::PowerModelsData)` consumes; `PowerFlowData.Network` is consumed where the
PowerFlowData pathway is preferred. Changes to dict keys, component fields, or the
correction pipeline can silently break System construction downstream — treat the parsed
schema as a public interface and check PowerSystems/PowerFlows usage before altering it.

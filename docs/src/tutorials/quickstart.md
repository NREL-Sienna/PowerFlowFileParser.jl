# Quick Start

## Basic Parsing

Parse a MATPOWER or PSS/E file to a dictionary:

```julia
using PowerFlowFileParser

# Parse to PowerModels dictionary
pm_dict = parse_file("case30.m")
println(keys(pm_dict))  # "bus", "gen", "branch", "baseMVA", etc.

# Or use container wrapper
pm_data = PowerModelsData("case30.m")
buses = pm_data.data["bus"]
```

## Alternative Parser

Use PowerFlowData.jl parser for PSS/E files:

```julia
pfd_data = PowerFlowDataNetwork("network.raw")
buses = pfd_data.data.buses
generators = pfd_data.data.generators
```

## Advanced Options

Control validation and data corrections:

```julia
pm_dict = parse_file(
    "case.raw";
    import_all = false,              # Essential fields only
    validate = true,                 # Apply corrections
    correct_branch_rating = true,     # Fix thermal ratings
)
```

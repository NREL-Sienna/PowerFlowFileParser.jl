# Main Data Structures

## PowerModelsData

Container wrapping PowerModels dictionary format. Access parsed components via `data["bus"]`, `data["gen"]`, `data["branch"]`, etc.

```julia
pm_data = PowerModelsData("case30.m")
buses = pm_data.data["bus"]
```

## PowerFlowDataNetwork

Container wrapping PowerFlowData.Network typed structs. Access parsed components via `.data.buses`, `.data.generators`, etc.

```julia
pfd_data = PowerFlowDataNetwork("network.raw")
buses = pfd_data.data.buses
```

## Main Functions

### `parse_file(file; kwargs...)`

Primary parsing function that dispatches based on file extension (`.m`, `.raw`, `.json`).

**Arguments:**

- `file::String`: Path to power flow file
- `import_all::Bool`: Import all fields vs essential only (default: `false`)
- `validate::Bool`: Apply data corrections (default: `true`)
- `correct_branch_rating::Bool`: Fix branch thermal ratings (default: `true`)

**Returns:** `Dict{String, Any}` in PowerModels format

For detailed API documentation, see the Public API and Internal API pages in the Reference section.

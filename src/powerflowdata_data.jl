"""
Container for data parsed by PowerFlowData.

# Fields
- `data::PowerFlowData.Network`: Network structure containing the parsed power system data

# Example
```julia
pfd_data = PowerFlowDataNetwork("system.raw")
# Access the network data
buses = pfd_data.data.buses
generators = pfd_data.data.generators
```
"""
struct PowerFlowDataNetwork
    data::PowerFlowData.Network
end

"""
Constructs PowerFlowDataNetwork from a raw file.
Currently Supports PSSE data files v30, v32 and v33

# Arguments
- `file::Union{String, IO}`: Path to the PSSE raw file or IO stream to parse

# Example
```julia
pfd_data = PowerFlowDataNetwork("system.raw")
```
"""
function PowerFlowDataNetwork(file::Union{String, IO}; kwargs...)
    return PowerFlowDataNetwork(PowerFlowData.parse_network(file))
end

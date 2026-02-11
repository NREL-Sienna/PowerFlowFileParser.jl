# PowerFlowFileParser.jl

**Package role:** File Parsing library for power system data
**Julia compat:** ^1.10

## Overview

PowerFlowFileParser.jl is a specialized library for parsing and converting text-based power flow file formats into PowerSystems.jl data structures. This library serves as a critical bridge between legacy power system data formats (MATPOWER, PSS/E) and modern Julia-based power system analysis tools in the Sienna ecosystem.

For general Sienna coding practices, conventions, and performance guidelines, see [.claude/Sienna.md](.claude/Sienna.md).

This document covers PowerFlowFileParser-specific aspects.

## Core Capabilities

### Supported File Formats

PowerFlowFileParser can parse and convert the following text-based power flow file formats:

1. **MATPOWER (.m files)**: Matlab-based power flow case files widely used in academic research
2. **PSS/E RAW files (.raw)**: Industry-standard format from Siemens PTI PSS/E software
   - Supports versions 30, 32, 33, and 35
3. **Generic Matlab files**: General Matlab data structure files

### Conversion Pipeline

The library provides two main parsing pathways:

#### 1. PowerModels-based Pipeline
- **Entry Point**: `PowerModelsData(file)` constructor
- **Input**: MATPOWER (.m) or PSS/E (.raw) files
- **Process**:
  1. Parse text file using format-specific parser
  2. Convert to PowerModels intermediate dictionary representation
  3. Apply data corrections and validation
  4. Build PowerSystems.System object with typed components
- **Output**: PowerSystems.System or PowerModelsData container

#### 2. PowerFlowData-based Pipeline
- **Entry Point**: `PowerFlowDataNetwork(file)` constructor
- **Input**: PSS/E RAW files (versions 30, 32, 33)
- **Process**:
  1. Parse using PowerFlowData.jl native parser
  2. Convert directly to PowerSystems typed components
- **Output**: PowerSystems.System or PowerFlowDataNetwork container

### Power System Components

The parser handles comprehensive power system modeling including:

- **Buses**: AC buses with voltage control, PQ/PV/Slack types
- **Branches**: Transmission lines, transformers (2-winding and 3-winding)
- **Generators**: Thermal, hydro, renewable (wind/solar), synchronous condensers
- **Loads**: Static loads, power loads
- **Shunts**: Fixed and switched admittances
- **DC Systems**: Two-terminal HVDC lines, VSC converters, multi-terminal DC
- **FACTS Devices**: Flexible AC transmission system controllers
- **Storage**: Energy reservoir storage systems
- **Control Devices**: Tap-changing transformers, phase-shifting transformers
- **Areas and Zones**: Load zones and areas for regional modeling

### Data Validation and Correction

Automatic data quality checks and corrections include:
- Connectivity validation
- Reference bus verification
- Per-unit conversion
- Transformer parameter correction
- Voltage angle difference bounds
- Thermal limit validation
- Branch rating corrections

## File Structure

### Top-Level Organization

```
PowerFlowFileParser.jl/
├── src/                      # Source code
│   ├── PowerFlowFileParser.jl  # Main module file (exports and imports)
│   ├── definitions.jl         # Constants and type definitions
│   ├── common.jl              # Shared utility functions
│   ├── pm_io.jl              # PowerModels IO includes
│   ├── im_io.jl              # InfrastructureModels IO includes
│   ├── power_models_data.jl  # PowerModelsData struct and System constructor
│   ├── powerflowdata_data.jl # PowerFlowDataNetwork struct and System constructor
│   ├── pm_io/                # PowerModels format parsers
│   └── im_io/                # InfrastructureModels format parsers
├── test/                     # Test suite
├── docs/                     # Documentation
└── scripts/                  # Utility scripts
```

### Source Code Details

#### Main Module (`src/PowerFlowFileParser.jl`)
- Defines module exports: `PowerModelsData`, `PowerFlowDataNetwork`, `System`, `parse_file`, `make_database`
- Imports dependencies: PowerSystems, PowerFlowData, InfrastructureSystems, SQLite, etc.
- Imports PowerSystems component types for construction

#### Core Data Structures

**`src/power_models_data.jl`**
- `PowerModelsData`: Container wrapping PowerModels dictionary format
- `System(::PowerModelsData)`: Constructor converting PM data to PowerSystems.System
- Component readers for each power system element type
- Data correction functions for transformer status, voltage levels

**`src/powerflowdata_data.jl`**
- `PowerFlowDataNetwork`: Container wrapping PowerFlowData.Network format
- `System(::PowerFlowDataNetwork)`: Alternative constructor using PowerFlowData parser
- Direct conversion from PowerFlowData structures to PowerSystems components

#### Parser Implementations

**`src/pm_io/` - PowerModels IO Pathway**
- `matpower.jl`: MATPOWER .m file parser (~826 lines)
  - Matlab code parsing for matrices and data structures
  - Column definitions for bus, gen, branch, cost data
  - Conversion to PowerModels dictionary format

- `psse.jl`: PSS/E RAW file parser (~2348 lines)
  - PSS/E v33/v35 format support
  - Section-based parsing (BUS, LOAD, GENERATOR, BRANCH, etc.)
  - Three-winding transformer handling with star-bus creation

- `pti.jl`: PTI format definitions (~2678 lines)
  - Data type specifications for all PSS/E sections
  - Field mappings and default values
  - Multi-version support (v30, v32, v33, v35)

- `common.jl`: Shared parsing utilities
  - `parse_file()`: Main entry point dispatching by file extension
  - Data validation and correction pipeline
  - Format detection (.m, .raw, .json)

- `data.jl`: PowerModels data manipulation
  - Network data correction functions
  - Component-specific readers (buses, generators, loads, etc.)

**`src/im_io/` - InfrastructureModels IO Pathway**
- `matlab.jl`: Generic Matlab file parser (~339 lines)
  - Parses Matlab assignment syntax
  - Handles matrices, cells, and scalar values
  - Extensible for custom Matlab formats

- `common.jl`: Shared utilities for IM format
- `data.jl`: Data manipulation utilities (~179 lines)
  - Multi-network support
  - Data merging and updating functions

#### Utilities

**`src/common.jl`**
- `make_database()`: Export System to SQLite database using SiennaOpenAPIModels
- Generator mapping from YAML configuration
- Fuel type and prime mover string conversions
- Constants for data validation thresholds

**`src/definitions.jl`**
- Constants for logging, validation tolerances
- Winding category mappings
- Transformer parameter names

### Test Structure

```
test/
├── runtests.jl                 # Test runner
├── test_parse_matpower.jl      # MATPOWER parsing tests
└── test_parse_psse.jl          # PSS/E parsing tests
```

Tests validate:
- Parsing of various file formats
- Conversion to PowerModels dictionary
- System construction with all components
- Data integrity and validation

## Usage Patterns

### Basic Parsing and Conversion

```julia
using PowerFlowFileParser

# Parse MATPOWER file
pm_data = PowerModelsData("case30.m")
sys = System(pm_data)

# Parse PSS/E RAW file
pfd_data = PowerFlowDataNetwork("network.raw")
sys = System(pfd_data)

# Direct file parsing
pm_dict = parse_file("case30.m")
sys = System(PowerModelsData(pm_dict))
```

### Advanced Options

```julia
# Control data validation and corrections
pm_data = PowerModelsData(
    "case.raw",
    pm_data_corrections = true,     # Apply PowerModels corrections
    import_all = false,              # Import only essential fields
    correct_branch_rating = true     # Fix branch thermal ratings
)

# Build System with custom settings
sys = System(
    pm_data,
    runchecks = true,                # Run component validation
    time_series_in_memory = false,   # Store time series in HDF5
    config_path = "validation.json"  # Custom validation config
)

# Export to database
make_database(sys, "power_system.sqlite")
```

## Key Dependencies

- **PowerSystems.jl**: Target data structure and component types
- **PowerFlowData.jl**: Alternative PSS/E parser
- **InfrastructureSystems.jl**: Base infrastructure for System objects
- **SiennaOpenAPIModels.jl**: Database serialization
- **DataStructures.jl**: Sorted dictionaries for component ordering
- **SQLite.jl**: Database export functionality
- **YAML.jl**: Configuration file parsing

## Design Philosophy

The library follows a two-stage conversion process:
1. **Parse**: Text file → Intermediate representation (Dict or typed struct)
2. **Build**: Intermediate representation → PowerSystems.System with typed components

This approach allows:
- Format-specific optimization in parsing stage
- Consistent validation and correction in intermediate stage
- Reusable component construction logic for System building
- Easy debugging by inspecting intermediate representations

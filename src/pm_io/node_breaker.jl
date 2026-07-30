# Node-breaker substation materialization. Expands the parsed `substation` section
# into real bus records ("node-buses"), reroutes devices to their terminal
# node-buses, and appends each substation switching device to the `breaker`,
# `switch`, or `other` section per its PSS(R)E device type. Devices attached to an
# out-of-service NODE are dropped; an out-of-service DEVICE is kept with state 0.
# Runs inside the PTI conversion, before per-unit and validation, so voltages here
# are in raw-file units (angles in degrees).

# Representative node for a PSS(R)E bus I within a substation: prefer a node that
# inherits or matches the BUS-record voltage (lowest NI first); if every node
# stores a differing voltage, fall back to the lowest NI. The representative keeps
# bus number I so by-number references stay valid. When it inherits, the retained
# record keeps the BUS-record solved voltage; when every node stores a differing
# voltage, the fallback node's stored voltage overwrites the BUS-record voltage.
function _representative_node(nodes::Vector, src::Dict)
    inherits_bus_voltage(n) =
        !haskey(n, "vm") ||
        (n["vm"] == get(src, "vm", nothing) &&
         get(n, "va", nothing) == get(src, "va", 0.0))
    pool = filter(inherits_bus_voltage, nodes)
    isempty(pool) && (pool = nodes)
    return pool[argmin([n["number"] for n in pool])]
end

# Pass 1: materialize node-buses in pm_data["bus"], resolve numbering, and build
# the terminal and switching-device tables.
function _prepare_node_breaker!(pm_data::Dict)
    node_number = Dict{Tuple{Int, Int}, Int}()
    terminal_node = Dict{Tuple{Int, String, Int, String}, Int}()
    nb_bus_numbers = Set{Int}()
    switches = NamedTuple{
        (:from, :to, :closed, :x, :dtype, :ckt, :name, :rates, :substation),
        Tuple{Int, Int, Bool, Float64, Int, String, String, Vector{Float64}, Int},
    }[]
    subs = get(pm_data, "substation", [])
    if get(pm_data, "source_type", "") != "pti" || isempty(subs)
        return (; node_number, terminal_node, nb_bus_numbers, switches)
    end

    busrec = pm_data["bus"]
    track_connectivity = get(pm_data, "has_isolated_type_buses", false)
    next_no = maximum(b["bus_i"] for b in values(busrec)) + 1
    for sub in sort(collect(values(subs)); by = s -> get(s, "index", 0))
        idx = get(sub, "index", 0)
        # local NI -> assigned bus number for this substation
        ni_to_no = Dict{Int, Int}()
        # group in-service nodes by PSS(R)E bus I
        by_bus = Dict{Int, Vector{Dict}}()
        for n in get(sub, "nodes", [])
            get(n, "status", 1) == 1 || continue
            push!(get!(by_bus, n["bus"], Vector{Dict}()), n)
        end
        # Sorted so injected bus numbers are reproducible across runs.
        for I in sort(collect(keys(by_bus)))
            nodes = by_bus[I]
            haskey(busrec, I) || continue
            push!(nb_bus_numbers, I)
            src = busrec[I]
            rep = _representative_node(nodes, src)
            for n in nodes
                if n === rep
                    num = I
                else
                    num = next_no
                    next_no += 1
                    rec = deepcopy(src)
                    rec["bus_i"] = num
                    rec["index"] = num
                    rec["source_id"] = ["bus", "$num"]
                    # A blank NAME column would give every such node the same empty
                    # name, so derive one from the source bus and the node number.
                    node_name = strip(string(get(n, "name", "")))
                    rec["name"] = if isempty(node_name)
                        "$(src["name"])_$(n["number"])"
                    else
                        String(node_name)
                    end
                    # Out-of-service (IDE=4) buses stay out-of-service on every
                    # node-bus split off of them; everything else starts PQ and
                    # is promoted back to PV/REF only if a generator lands on it
                    # (see `_reroute_gens_and_migrate_bus_type!`).
                    rec["bus_type"] = src["bus_type"] == 4 ? 4 : 1
                    busrec[num] = rec
                    if track_connectivity && I in pm_data["connected_buses"]
                        push!(pm_data["connected_buses"], num)
                    end
                end
                haskey(n, "vm") && (busrec[num]["vm"] = n["vm"])
                haskey(n, "va") && (busrec[num]["va"] = n["va"])
                ni_to_no[n["number"]] = num
                node_number[(idx, n["number"])] = num
                rec_ext = get!(busrec[num], "ext", Dict{String, Any}())
                rec_ext["nb_substation"] = idx
                rec_ext["nb_bus"] = I
                rec_ext["nb_node"] = n["number"]
            end
        end
        for t in get(sub, "terminals", [])
            haskey(ni_to_no, t["node"]) || continue
            terminal_node[(
                t["bus"],
                String(t["type"]),
                something(get(t, "secondary_bus", 0), 0),
                String(t["id"]),
            )] = ni_to_no[t["node"]]
        end
        for d in get(sub, "switching_devices", [])
            (haskey(ni_to_no, d["from_node"]) && haskey(ni_to_no, d["to_node"])) ||
                continue
            push!(
                switches,
                (
                    from = ni_to_no[d["from_node"]],
                    to = ni_to_no[d["to_node"]],
                    closed = get(d, "status", 1) == 1,
                    x = Float64(get(d, "x", 1e-4)),
                    dtype = Int(get(d, "device_type", 0)),
                    ckt = String(strip(string(get(d, "ckt", "1")))),
                    name = String(get(d, "name", "")),
                    rates = Float64.(get(d, "rates", [0.0, 0.0, 0.0])),
                    substation = idx,
                ),
            )
        end
    end
    return (; node_number, terminal_node, nb_bus_numbers, switches)
end

_nb_ckt(d) = (
    sid = get(d, "source_id", nothing);
    if sid === nothing
        ""
    else
        strip(string(sid[1] == "transformer" ? sid[end - 1] : sid[end]))
    end
)

_nb_branch_type(d) = (sid = get(d, "source_id", nothing);
(sid !== nothing && sid[1] == "transformer") ? "2" : "B")

function _nb_target(nb, busno, typ, other, id)
    ni = get(nb.terminal_node, (busno, typ, something(other, 0), string(id)), nothing)
    return ni === nothing ? busno : ni
end

# A type-"3" terminal's key carries only one of the winding's two sibling buses
# (whichever the RAW stored in its secondary-bus column); try both siblings and
# take whichever hits.
function _nb_target_3w(nb, busno, ckt, others)
    for other in others
        ni = get(nb.terminal_node, (busno, "3", other, ckt), nothing)
        ni !== nothing && return ni
    end
    return busno
end

# Pass 2: reroute every device's endpoint bus to its node-bus, per nb.terminal_node.
function _reroute_devices_to_nodes!(pm_data::Dict, nb)
    isempty(nb.nb_bus_numbers) && return nothing
    if haskey(pm_data, "branch")
        for d in values(pm_data["branch"])
            typ = _nb_branch_type(d)
            f0, t0 = d["f_bus"], d["t_bus"]
            f0 in nb.nb_bus_numbers &&
                (d["f_bus"] = _nb_target(nb, f0, typ, t0, _nb_ckt(d)))
            t0 in nb.nb_bus_numbers &&
                (d["t_bus"] = _nb_target(nb, t0, typ, f0, _nb_ckt(d)))
        end
    end
    for section in ("switch", "breaker", "other")
        haskey(pm_data, section) || continue
        for d in values(pm_data[section])
            f0, t0 = d["f_bus"], d["t_bus"]
            f0 in nb.nb_bus_numbers &&
                (d["f_bus"] = _nb_target(nb, f0, "B", t0, _nb_ckt(d)))
            t0 in nb.nb_bus_numbers &&
                (d["t_bus"] = _nb_target(nb, t0, "B", f0, _nb_ckt(d)))
        end
    end
    for (section, field, typ, id_fn) in (
        ("load", "load_bus", "L", _nb_ckt),
        ("shunt", "shunt_bus", "S", _nb_ckt),
        # Switched shunts key their terminal on the RAW's own "ID" column
        # (`sw_id`), not on `source_id[end]`, which for this section is a
        # running index rather than the PSS(R)E-assigned identifier.
        ("switched_shunt", "shunt_bus", "S", d -> strip(string(get(d, "sw_id", "1")))),
        ("distributed_generation", "bus", "L", _nb_ckt),
    )
        haskey(pm_data, section) || continue
        for d in values(pm_data[section])
            b = d[field]
            b in nb.nb_bus_numbers &&
                (d[field] = _nb_target(nb, b, typ, nothing, id_fn(d)))
        end
    end
    haskey(pm_data, "3w_transformer") && for d in values(pm_data["3w_transformer"])
        ckt = string(get(d, "circuit", ""))
        b1, b2, b3 = d["bus_primary"], d["bus_secondary"], d["bus_tertiary"]
        b1 in nb.nb_bus_numbers &&
            (d["bus_primary"] = _nb_target_3w(nb, b1, ckt, (b2, b3)))
        b2 in nb.nb_bus_numbers &&
            (d["bus_secondary"] = _nb_target_3w(nb, b2, ckt, (b1, b3)))
        b3 in nb.nb_bus_numbers &&
            (d["bus_tertiary"] = _nb_target_3w(nb, b3, ckt, (b1, b2)))
    end
    _reroute_gens_and_migrate_bus_type!(pm_data, nb)
    return nothing
end

# Reroutes generators to their terminal node-buses, then migrates PV/REF
# `bus_type` along with the first generator that moves off each source bus: if
# no generator remains attached to that bus afterward, its voltage-control
# status would otherwise be stranded on a now-generator-less bus while the
# node-bus that actually hosts the generator stays PQ. The move is recorded in
# the source bus's `ext` so later passes keying off bus numbers (such as the
# per-area ISW slack assignment) can follow the voltage-control status.
function _reroute_gens_and_migrate_bus_type!(pm_data::Dict, nb)
    haskey(pm_data, "gen") || return nothing
    gen_moves = Dict{Int, Int}()
    for d in values(pm_data["gen"])
        b = d["gen_bus"]
        b in nb.nb_bus_numbers || continue
        target = _nb_target(nb, b, "M", nothing, _nb_ckt(d))
        target == b && continue
        d["gen_bus"] = target
        haskey(gen_moves, b) || (gen_moves[b] = target)
    end
    isempty(gen_moves) && return nothing
    gen_buses = Set{Int}(d["gen_bus"] for d in values(pm_data["gen"]))
    for (src, target) in gen_moves
        src_bus = pm_data["bus"][src]
        bus_type = src_bus["bus_type"]
        bus_type in (2, 3) || continue
        src in gen_buses && continue
        pm_data["bus"][target]["bus_type"] = bus_type
        src_bus["bus_type"] = 1
        get!(src_bus, "ext", Dict{String, Any}())["nb_bus_type_moved_to"] = target
    end
    return nothing
end

# Appends each substation switching device to the `breaker`, `switch`, or `other`
# section, in the same shape as system-level switching devices and using the same
# device-type mapping (TYPE 2 breaker, TYPE 3 switch, anything else other). The
# PSS(R)E device type code, device name, and owning substation are preserved in ext.
function _create_node_breaker_switch_entries!(pm_data::Dict, nb)
    isempty(nb.switches) && return nothing
    for s in nb.switches
        section, discrete_branch_type = if s.dtype == 2
            ("breaker", 1)
        elseif s.dtype == 3
            ("switch", 0)
        else
            ("other", 2)
        end
        haskey(pm_data, section) || (pm_data[section] = [])
        device = Dict{String, Any}(
            "I" => s.from,
            "J" => s.to,
            "CKT" => s.ckt,
            "X" => s.x,
            "ST" => s.closed ? 1 : 0,
            "RATE1" => s.rates[1],
            "RATE2" => s.rates[2],
            "RATE3" => s.rates[3],
        )
        sub_data = _build_switch_breaker_sub_data(
            pm_data,
            device,
            section,
            discrete_branch_type,
            length(pm_data[section]) + 1,
        )
        sub_data["ext"]["TYPE"] = s.dtype
        sub_data["ext"]["NAME"] = s.name
        sub_data["ext"]["nb_substation"] = s.substation
        branch_isolated_bus_modifications!(pm_data, sub_data)
        push!(pm_data[section], sub_data)
    end
    return nothing
end

"""
Materializes node-breaker substation data into `pm_data`: splits each PSS(R)E bus
with substation nodes into node-buses (Pass 1), reroutes devices to their terminal
node-buses (Pass 2), and appends the substation switching devices to the `breaker`,
`switch`, or `other` section per their PSS(R)E device type. A no-op unless the dict
is a PTI case with a populated `substation`
section. Returns the intermediate node-breaker tables (useful for testing).
"""
function materialize_node_breaker!(pm_data::Dict)
    nb = _prepare_node_breaker!(pm_data)
    _reroute_devices_to_nodes!(pm_data, nb)
    _create_node_breaker_switch_entries!(pm_data, nb)
    return nb
end

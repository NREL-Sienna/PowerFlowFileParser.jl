# At-a-glance display for `MultiCase`: one table per section showing, for each
# component whose status DIFFERS across cases, its status in each case.
#
# Status is three-valued per (component, case):
#   ● present and available
#   · present but unavailable
#   x not present
# Components with the same status in every case are omitted; the section title
# reports how many were omitted vs. shown.

import PrettyTables

# Status codes (also the sort/compare basis for "does it vary across cases").
const _ABSENT = 0x0
const _UNAVAILABLE = 0x1
const _AVAILABLE = 0x2

const _MARK_AVAILABLE = "●"     # present and available
const _MARK_UNAVAILABLE = "·"   # present but unavailable
const _MARK_ABSENT = "x"        # not present

_mark(code::UInt8)::String =
    code == _AVAILABLE ? _MARK_AVAILABLE :
    code == _UNAVAILABLE ? _MARK_UNAVAILABLE : _MARK_ABSENT

# Preferred section ordering for display; anything else follows, sorted.
const _SECTION_ORDER =
    ["bus", "branch", "3w_transformer", "gen", "load", "shunt", "switched_shunt",
        "switch", "breaker", "dcline", "facts"]

"""
Three-valued status per case for one component: `_ABSENT`, `_UNAVAILABLE`, or
`_AVAILABLE`. A present component with a missing/inactive status field counts as
`_UNAVAILABLE`; sections without a status field are `_AVAILABLE` wherever present.
"""
function _status_codes(section::AbstractString, entry::Dict{String, Any}, N::Int)::Vector{UInt8}
    present = entry["present"]::BitVector
    codes = Vector{UInt8}(undef, N)
    status_field = get(pm_component_status, section, nothing)
    if status_field === nothing || !haskey(entry, status_field)
        @inbounds for k in 1:N
            codes[k] = present[k] ? _AVAILABLE : _ABSENT
        end
        return codes
    end
    inactive = get(pm_component_status_inactive, section, 0)
    vals = entry[status_field]
    @inbounds for k in 1:N
        if !present[k]
            codes[k] = _ABSENT
        else
            v = vals[k]
            codes[k] = (!ismissing(v) && v != inactive) ? _AVAILABLE : _UNAVAILABLE
        end
    end
    return codes
end

function _ordered_sections(mc::MultiCase)
    present = collect(keys(mc.sections))
    ordered = filter(in(present), _SECTION_ORDER)
    append!(ordered, sort(setdiff(present, ordered)))
    return ordered
end

"Resolve a `cases` selector (indices, names, or nothing=all) to column indices into `mc.cases`."
function _resolve_case_indices(mc::MultiCase, cases)::Vector{Int}
    N = length(mc)
    cases === nothing && return collect(1:N)
    if eltype(cases) <: Integer
        for c in cases
            (1 <= c <= N) || throw(ArgumentError("case index $c is out of range 1:$N"))
        end
        return collect(Int, cases)
    end
    idx = Int[]
    for name in cases
        matches = findall(==(String(name)), mc.cases)
        isempty(matches) && throw(ArgumentError("no case named \"$name\" in this MultiCase"))
        append!(idx, matches)
    end
    return idx
end

"""
    presence_summary([io], mc::MultiCase; cases = nothing, limit = 50)

Print one table per section giving an at-a-glance comparison of component
presence/availability across the merged cases. Only components whose active
status (present **and** available) differs across the displayed cases are shown;
each section title reports how many varied vs. how many were identical (and
omitted). At most `limit` rows are printed per section.

Pass `cases` to zero in on a subset of the same `MultiCase` without re-merging —
either case indices (`cases = [2, 5]`) or case names (`cases = ["a.raw", "b.raw"]`).
"Vary vs. identical" is recomputed relative to only the selected cases, so two
cases that differ from the rest but agree with each other show nothing.

`limit` caps the rows printed per section; pass `limit = nothing` to print every
varying row in every table. PrettyTables' own terminal cropping is disabled, so
`limit` is the only thing that omits rows (and the output is reproducible when
redirected to a file).
"""
function presence_summary(
    io::IO,
    mc::MultiCase;
    cases = nothing,
    limit::Union{Nothing, Int} = 50,
)
    idx = _resolve_case_indices(mc, cases)
    n = length(idx)
    header = n == length(mc) ? string(n, " cases") :
             string("showing ", n, " of ", length(mc), " cases")
    println(io, "MultiCase: ", header, ", ", length(mc.sections), " sections")
    println(io, "Cases (column index → source):")
    for (j, c) in enumerate(idx)
        println(io, "  ", lpad(j, 3), ": ", mc.cases[c])
    end
    println(io, "\nLegend: ", _MARK_AVAILABLE, " = present & available   ",
        _MARK_UNAVAILABLE, " = present but unavailable   ",
        _MARK_ABSENT, " = not present")

    N = length(mc)
    col_labels = vcat("component", string.(1:n))
    for section in _ordered_sections(mc)
        entries = mc.sections[section]
        total = length(entries)
        # keep only components whose status varies across the selected cases
        varying = Tuple{String, Vector{UInt8}}[]
        for (k, entry) in entries
            a = _status_codes(section, entry, N)[idx]
            all(==(a[1]), a) || push!(varying, (k, a))
        end
        nvary = length(varying)
        pct = total == 0 ? 0.0 : round(100 * nvary / total; digits = 1)
        title = string(uppercase(section), " — ", nvary, " of ", total,
            " vary (", pct, "%); ", total - nvary, " identical, omitted")
        if nvary == 0
            println(io, "\n", title)
            continue
        end
        sort!(varying; by = first)
        shown = limit === nothing ? nvary : min(nvary, limit)
        data = Matrix{String}(undef, shown, n + 1)
        for i in 1:shown
            key, a = varying[i]
            data[i, 1] = key
            @inbounds for j in 1:n
                data[i, j + 1] = _mark(a[j])
            end
        end
        PrettyTables.pretty_table(
            io,
            data;
            column_labels = col_labels,
            title = title,
            alignment = :l,
            fit_table_in_display_vertically = false,    # `limit` is the only row cap
            fit_table_in_display_horizontally = false,  # never drop case columns
        )
        nvary > shown && println(io, "  … and ", nvary - shown, " more varying (omitted)")
    end
    return
end

presence_summary(mc::MultiCase; kwargs...) = presence_summary(stdout, mc; kwargs...)

# Compact one-liner for interpolation / nested contexts.
Base.show(io::IO, mc::MultiCase) =
    print(io, "MultiCase(", length(mc), " cases, ", length(mc.sections), " sections)")

# Rich REPL display: the at-a-glance presence tables.
Base.show(io::IO, ::MIME"text/plain", mc::MultiCase) = presence_summary(io, mc)

# `PC.write_document` owns the JSON envelope now: it builds the tree, validates the
# document and encodes it in one pass. PowerFlowFileParser emits no time series, so
# unlike PowerTableDataParser there is no HDF5 sidecar to name or write here — `to_json`
# is a thin call-through that also returns `filename`, matching this package's prior API.

"""
Write `sys` to `filename` as the OpenAPI JSON document. Returns `filename`.

Validates first, so a malformed document is reported before anything reaches disk;
`PC.write_document` validates again as its own contract, which is cheap and keeps that
guarantee even for callers that reach it directly.

`force = false` refuses to overwrite an existing `filename`. `pretty = true` indents
the output; the default is compact.
"""
function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force::Bool = false,
    pretty::Bool = false,
)
    document = get_document(sys)
    PC.validate_document(document)
    PC.write_document(document, filename; pretty = pretty, force = force)
    return filename
end

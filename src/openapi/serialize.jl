"""
Write `sys` to `filename` as the OpenAPI JSON document. Returns `filename`.

`PD.write_document` validates before writing, so a malformed document is reported
before anything reaches disk. `force = false` refuses to overwrite an existing
`filename`; `pretty = true` indents the output, the default is compact.
"""
function to_json(
    sys::OpenAPISystem,
    filename::AbstractString;
    force::Bool = false,
    pretty::Bool = false,
)
    PD.write_document(get_document(sys), filename; pretty = pretty, force = force)
    return filename
end

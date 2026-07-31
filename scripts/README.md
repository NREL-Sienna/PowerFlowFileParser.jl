# scripts

## `validate_with_python.py`

Validates a JSON document written by `to_json` against the pydantic models generated from
the same SiennaSchemas, catching disagreements between the two generators.

```bash
python3 -m pip install -e ../power-openapi-models   # once, from a sibling checkout
python3 scripts/validate_with_python.py case.json
```

If your system Python refuses the install with `error: externally-managed-environment`
(PEP 668), install into a virtual environment instead and run the script with that
venv's interpreter:

```bash
python3 -m venv /path/to/venv
/path/to/venv/bin/python3 -m pip install -e ../power-openapi-models
/path/to/venv/bin/python3 scripts/validate_with_python.py case.json
```

Run by hand. It is not part of `julia --project=test test/runtests.jl`, which stays free of
a Python dependency.

## `formatter/`

```bash
julia --project=scripts/formatter -e 'include("scripts/formatter/formatter_code.jl")'
```

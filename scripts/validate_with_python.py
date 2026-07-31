#!/usr/bin/env python3
"""Validate a Sienna OpenAPI JSON document against the generated pydantic models.

The Julia and Python model packages are generated from the same SiennaSchemas, so a
component that loads in one and not the other is a schema-level defect. Validates
components, supplemental attributes, and both association sections (supplemental attribute
and time series). Run this by hand against emitted documents; it is deliberately not wired
into the Julia test suite, which stays free of a Python dependency.

Usage:
    python3 scripts/validate_with_python.py DOCUMENT.json
"""

import argparse
import importlib
import json
import sys

MODULES = (
    "power_openapi_models.core.models",
    "power_openapi_models.operations.models",
    "power_openapi_models.investments.models",
    "power_openapi_models.dynamics.models",
)

ASSOCIATION_SECTIONS = (
    ("supplemental_attribute_associations", "SupplementalAttributeAssociation"),
    ("time_series_associations", "TimeSeriesAssociation"),
)


def load_models():
    """Map every pydantic class name to its class, first module winning."""
    models = {}
    for name in MODULES:
        module = importlib.import_module(name)
        for attr in dir(module):
            if attr.startswith("_") or attr in models:
                continue
            models[attr] = getattr(module, attr)
    return models


def validate_group(models, type_name, payloads, failures):
    model = models.get(type_name)
    if model is None:
        failures.append(f"{type_name}: no pydantic class of that name in {MODULES}")
        return 0
    validated = 0
    for index, payload in enumerate(payloads):
        try:
            model.model_validate(payload)
            validated += 1
        except Exception as error:
            failures.append(f"{type_name}[{index}]: {error}")
    return validated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("document", help="path to a JSON document written by to_json")
    args = parser.parse_args()

    with open(args.document) as handle:
        document = json.load(handle)

    models = load_models()
    failures = []
    validated = 0

    for type_name in sorted(document.get("components", {})):
        validated += validate_group(
            models, type_name, document["components"][type_name], failures
        )

    for index, payload in enumerate(document.get("supplemental_attributes", [])):
        # The document does not record which class each attribute is; GeographicInfo is
        # the only one this parser emits.
        validated += validate_group(
            models, "GeographicInfo", [payload], failures
        )

    for section, type_name in ASSOCIATION_SECTIONS:
        validated += validate_group(
            models, type_name, document.get(section, []), failures
        )

    print(f"validated {validated} components")
    if failures:
        print(f"{len(failures)} failure(s):", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Convert YAML schema source files to Markdown class definition files.

Generates Markdown suitable for MkDocs (Material theme) from the same
ga4gh.gks.metaschema YAML sources that y2t uses for RST. Each public class
gets a .md file in the md/ output directory with:

  - Maturity admonition
  - Computational definition
  - Information model table (Field | Type | Limits | Description)
  - Link to generated JSON schema
"""

import os
import pathlib
import sys
from pathlib import Path

from ga4gh.gks.metaschema.tools.source_proc import YamlSchemaProcessor


def resolve_type(prop_def: dict) -> str:
    """Resolve a property definition to a type string."""
    if "type" in prop_def:
        if prop_def["type"] == "array":
            inner = resolve_type(prop_def.get("items", {}))
            return f"{inner}[]"
        return f"`{prop_def['type']}`"
    elif "$ref" in prop_def:
        identifier = prop_def["$ref"].split("/")[-1]
        return f"[{identifier}]({identifier}.md)"
    elif "$refCurie" in prop_def:
        identifier = prop_def["$refCurie"].split("/")[-1]
        return f"[{identifier}]({identifier}.md)"
    elif "oneOf" in prop_def or "anyOf" in prop_def:
        kw = "oneOf" if "oneOf" in prop_def else "anyOf"
        parts = []
        for item in prop_def[kw]:
            parts.append(resolve_type(item))
        return " | ".join(parts)
    return "_unspecified_"


def resolve_cardinality(prop_name: str, prop_attrs: dict, class_def: dict) -> str:
    """Resolve property cardinality."""
    required = class_def.get("required", []) + class_def.get("heritableRequired", [])
    min_count = "1" if prop_name in required else "0"
    if prop_attrs.get("type") == "array":
        max_count = prop_attrs.get("maxItems", "m")
        min_count = str(prop_attrs.get("minItems", 0))
    else:
        max_count = "1"
    return f"{min_count}..{max_count}"


def resolve_flags(prop_attrs: dict) -> str:
    """Resolve property flags (ordered, maturity)."""
    flags = []
    if prop_attrs.get("type") == "array":
        ordered = prop_attrs.get("ordered", False)
        flags.append("ordered" if ordered else "unordered")
    maturity = prop_attrs.get("maturity", "")
    if maturity == "draft":
        flags.append("draft")
    elif maturity == "deprecated":
        flags.append("deprecated")
    return ", ".join(flags)


def get_ancestor_with_attributes(ancestor, proc_schema):
    """Walk up the inheritance chain to find an ancestor with attributes."""
    while ancestor:
        ancestor_def = proc_schema.raw_defs.get(ancestor, {})
        if "heritableProperties" in ancestor_def or "properties" in ancestor_def:
            return ancestor
        ancestor = ancestor_def.get("inherits")
    return ancestor


def write_class_md(class_name: str, class_def: dict, proc_schema, out_dir: Path,
                   json_schema_base: str):
    """Write a single class Markdown file."""
    out_file = out_dir / f"{class_name}.md"

    with open(out_file, "w") as f:
        # Title
        f.write(f"# {class_name}\n\n")

        # Maturity admonition
        maturity = class_def.get("maturity", "")
        if maturity == "draft":
            f.write('!!! warning "Draft"\n\n')
            f.write("    This data class is at a **draft** maturity level and may "
                    "change significantly in future releases.\n\n")
        elif maturity == "trial use":
            f.write('!!! note "Trial Use"\n\n')
            f.write("    This data class is at a **trial use** maturity level and may "
                    "change in future releases.\n\n")

        # Computational definition
        description = class_def.get("description", "")
        f.write(f"{description}\n\n")

        # JSON schema link
        f.write(f"**JSON Schema:** "
                f"[{class_name}]({json_schema_base}/{class_name})"
                f"{{ target=_blank }}\n\n")

        # Show oneOf/anyOf members if present
        has_union = False
        for kw in ("oneOf", "anyOf"):
            if kw in class_def:
                has_union = True
                f.write("**One of:**\n\n")
                for item in class_def[kw]:
                    item_type = resolve_type(item)
                    f.write(f"- {item_type}\n")
                f.write("\n")

        # Show allOf composition if present
        if "allOf" in class_def:
            f.write("**Composed of:**\n\n")
            for item in class_def["allOf"]:
                item_type = resolve_type(item)
                f.write(f"- {item_type}\n")
            f.write("\n")

        # Determine properties key and check if there are any fields
        props = {}
        if "heritableProperties" in class_def:
            props = class_def["heritableProperties"]
        elif "properties" in class_def:
            props = class_def["properties"]

        if not props:
            # No local fields — passthrough, union, or allOf-only type
            if proc_schema.class_is_primitive(class_name):
                return
            if has_union or "allOf" in class_def:
                return
            return

        # Inheritance note
        ancestor = proc_schema.raw_defs[class_name].get("inherits")
        if ancestor:
            ancestor = get_ancestor_with_attributes(ancestor, proc_schema)
            if ancestor:
                f.write(f"Some {class_name} attributes are inherited from "
                        f"[{ancestor}]({ancestor}.md).\n\n")

        # Information model table
        f.write("## Information Model\n\n")
        f.write("| Field | Type | Limits | Description |\n")
        f.write("| --- | --- | --- | --- |\n")

        for prop_name, prop_attrs in props.items():
            prop_type = resolve_type(prop_attrs)
            cardinality = resolve_cardinality(prop_name, prop_attrs, class_def)
            desc = prop_attrs.get("description", "").replace("\n", " ").replace("|", "\\|")
            flags = resolve_flags(prop_attrs)
            if flags:
                prop_type = f"{prop_type} ({flags})"
            f.write(f"| `{prop_name}` | {prop_type} | {cardinality} | {desc} |\n")

        f.write("\n")


def main(proc_schema):
    """Generate Markdown files for all public classes."""
    md_dir = proc_schema.def_fp.parent / "md"
    os.makedirs(md_dir, exist_ok=True)

    # Base URL for JSON schema links (relative from docs site)
    json_schema_base = (
        "https://github.com/clingen-data-model/clinvar-gks/blob/main"
        "/schema/clinvar-gks/json"
    )

    for class_name, class_def in proc_schema.defs.items():
        write_class_md(class_name, class_def, proc_schema, md_dir,
                       json_schema_base)


def cli():
    source_file = pathlib.Path(sys.argv[1])
    p = YamlSchemaProcessor(source_file)
    if p.defs is None:
        exit(0)
    main(p)


if __name__ == "__main__":
    cli()

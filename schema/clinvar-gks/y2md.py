#!/usr/bin/env python3
"""Convert YAML schema source files to Markdown class definition files.

Generates Markdown suitable for MkDocs (Material theme) from the same
ga4gh.gks.metaschema YAML sources that y2t uses for RST. Each public class
gets a .md file in the md/ output directory with:

  - Maturity admonition
  - Computational definition
  - Information model table (Field | Type | Limits | Description)
  - Link to generated JSON schema

For classes composed via allOf, inherited fields from parent classes are
resolved and included in the information model table.
"""

import os
import pathlib
import sys
from pathlib import Path

from ga4gh.gks.metaschema.tools.source_proc import YamlSchemaProcessor

# Cache of loaded processors keyed by resolved source file path
_processor_cache: dict[str, YamlSchemaProcessor] = {}

# Set of class names that have local pages (populated at build time)
_local_classes: set[str] = set()


def _get_processor(source_path: Path) -> YamlSchemaProcessor:
    """Get or create a cached YamlSchemaProcessor for a source file."""
    key = str(source_path.resolve())
    if key not in _processor_cache:
        _processor_cache[key] = YamlSchemaProcessor(source_path)
    return _processor_cache[key]


def _format_type_ref(identifier: str) -> str:
    """Format a type reference — linked if local, plain code if external."""
    if identifier in _local_classes:
        return f"[{identifier}]({identifier}.md)"
    return f"`{identifier}`"


def resolve_type(prop_def: dict) -> str:
    """Resolve a property definition to a type string."""
    if "type" in prop_def:
        if prop_def["type"] == "array":
            inner = resolve_type(prop_def.get("items", {}))
            return f"{inner}[]"
        return f"`{prop_def['type']}`"
    elif "$ref" in prop_def:
        identifier = prop_def["$ref"].split("/")[-1]
        return _format_type_ref(identifier)
    elif "$refCurie" in prop_def:
        identifier = prop_def["$refCurie"].split(":")[-1]
        return _format_type_ref(identifier)
    elif "oneOf" in prop_def or "anyOf" in prop_def:
        kw = "oneOf" if "oneOf" in prop_def else "anyOf"
        parts = []
        for item in prop_def[kw]:
            parts.append(resolve_type(item))
        return " \\| ".join(parts)
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


def _resolve_ref_class_name(ref_item: dict) -> str | None:
    """Extract class name from a $ref or $refCurie."""
    if "$ref" in ref_item:
        return ref_item["$ref"].split("/")[-1]
    if "$refCurie" in ref_item:
        # $refCurie uses namespace:ClassName format
        return ref_item["$refCurie"].split(":")[-1]
    return None


def _find_class_in_processors(class_name: str, proc_schema) -> dict | None:
    """Find a class definition across the processor and its imports."""
    # Check the main processor
    if class_name in proc_schema.defs:
        return proc_schema.defs[class_name]
    # Check imported processors
    for imp_proc in proc_schema.imports.values():
        result = _find_class_in_processors(class_name, imp_proc)
        if result is not None:
            return result
    return None


def _get_class_properties(class_name: str, proc_schema) -> dict:
    """Get all properties for a class, including inherited ones via allOf."""
    class_def = _find_class_in_processors(class_name, proc_schema)
    if class_def is None:
        return {}

    props = {}

    # First, collect properties from allOf parents (inherited fields first)
    for ref_item in class_def.get("allOf", []):
        parent_name = _resolve_ref_class_name(ref_item)
        if parent_name:
            parent_props = _get_class_properties(parent_name, proc_schema)
            props.update(parent_props)

    # Then collect properties inherited via the inherits keyword
    # (already resolved by YamlSchemaProcessor into heritableProperties)

    # Finally, add local properties (override inherited ones)
    for key in ("heritableProperties", "properties"):
        if key in class_def and class_def[key]:
            props.update(class_def[key])
            break

    return props


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

        # Collect all properties including inherited via allOf
        all_props = _get_class_properties(class_name, proc_schema)

        # Identify allOf parents for the inheritance note
        allof_parents = []
        for ref_item in class_def.get("allOf", []):
            parent_name = _resolve_ref_class_name(ref_item)
            if parent_name:
                allof_parents.append(parent_name)

        if not all_props:
            if has_union or allof_parents:
                return
            if proc_schema.class_is_primitive(class_name):
                return
            return

        # Inheritance note
        ancestor = proc_schema.raw_defs[class_name].get("inherits")
        if ancestor:
            ancestor = get_ancestor_with_attributes(ancestor, proc_schema)
            if ancestor:
                f.write(f"Some {class_name} attributes are inherited from "
                        f"[{ancestor}]({ancestor}.md).\n\n")
        elif allof_parents:
            parent_links = ", ".join(
                f"[{p}]({p}.md)" for p in allof_parents
            )
            f.write(f"Some {class_name} attributes are inherited from "
                    f"{parent_links}.\n\n")

        # Information model table
        f.write("## Information Model\n\n")
        f.write("| Field | Type | Limits | Description |\n")
        f.write("| --- | --- | --- | --- |\n")

        for prop_name, prop_attrs in all_props.items():
            prop_type = resolve_type(prop_attrs)
            cardinality = resolve_cardinality(prop_name, prop_attrs, class_def)
            desc = prop_attrs.get("description", "").replace("\n", " ").replace("|", "\\|")
            flags = resolve_flags(prop_attrs)
            if flags:
                prop_type = f"{prop_type} ({flags})"
            f.write(f"| `{prop_name}` | {prop_type} | {cardinality} | {desc} |\n")

        f.write("\n")


def _load_local_classes(build_dir: Path):
    """Load all local class names from .classes files in the build directory."""
    if not build_dir.exists():
        return
    for classes_file in build_dir.glob("*.classes"):
        for line in classes_file.read_text().splitlines():
            name = line.strip()
            if name:
                _local_classes.add(name)


def main(proc_schema):
    """Generate Markdown files for all public classes."""
    md_dir = proc_schema.def_fp.parent / "md"
    os.makedirs(md_dir, exist_ok=True)

    # Load all local class names for link resolution
    build_dir = proc_schema.def_fp.parent / "build"
    _load_local_classes(build_dir)

    # Cache the main processor
    _processor_cache[str(proc_schema.schema_fp.resolve())] = proc_schema

    # Base URL for JSON schema links (relative from docs site)
    json_schema_base = (
        "https://github.com/clingen-data-model/clinvar-gks/blob/main"
        "/schema/clinvar-gks/json"
    )

    for class_name, class_def in proc_schema.defs.items():
        write_class_md(class_name, class_def, proc_schema, out_dir=md_dir,
                       json_schema_base=json_schema_base)


def cli():
    source_file = pathlib.Path(sys.argv[1])
    p = YamlSchemaProcessor(source_file)
    if p.defs is None:
        exit(0)
    main(p)


if __name__ == "__main__":
    cli()

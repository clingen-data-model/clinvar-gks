"""Recursively drop null / empty-array / empty-object values from a decoded JSON
value, matching JSON_STRIP_NULLS(remove_empty => TRUE) for our data shapes.

Used by assemble-gks-dicts.py so the published bundle (full + delta) has the same
cleanup gks_json_proc used to apply. Publish-layer only — never touches BigQuery
tables, so it cannot affect delta/change-log/oracle correctness.

Rules:
  * dict: drop keys whose stripped value is None, {} or [].
  * list: strip each element's internals but KEEP elements (SQL arrays hold no NULL
    elements; dropping non-empty elements would change array length).
  * scalars: returned unchanged (0 / False / "" are preserved).
"""


def _is_empty(v):
    return v is None or (isinstance(v, (dict, list)) and len(v) == 0)


def strip_empty(value):
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            sv = strip_empty(v)
            if not _is_empty(sv):
                out[k] = sv
        return out
    if isinstance(value, list):
        return [strip_empty(v) for v in value]
    return value

-- ============================================================================
-- Dataset Diff — initialization (order-independent JSON UDFs)
-- ============================================================================
-- Creates the two reusable JavaScript UDFs used for order-independent
-- comparison. They live in the existing clinvar_ingest dataset alongside the
-- dataset_diff / dataset_diff_all procedures (see 01-, 02- files).
--
-- The diff_<table> OUTPUT tables are written into the compare (2nd/newer)
-- snapshot's own dataset, not here.
--
-- Run once (per project) before deploying the procedures.
-- Project is inferred from the running job (e.g. clingen-dev).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- canonicalize_json(json_str)
--   Returns a canonical serialization of a JSON document such that neither
--   object-key order NOR array-element order affects the result:
--     * object keys are sorted
--     * array elements are sorted by their own canonical string
--     * a STRING value that itself parses as JSON (object/array) is recursed
--       into and canonicalized too — this transparently normalizes ClinVar's
--       `content` blob and the JSON-in-string elements of REPEATED columns
--       (e.g. interpretation_comments) without any per-table logic.
--   Non-JSON input is returned unchanged.
--
--   Two rows are semantically identical iff their canonicalize_json() values
--   are equal. This is the "expensive" tier — callers should only invoke it on
--   rows whose raw serialization already differs (see the two-tier logic in the
--   dataset_diff procedure).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `clinvar_ingest.canonicalize_json`(json_str STRING)
RETURNS STRING
LANGUAGE js AS r"""
  function canon(v) {
    if (v === null) return null;
    if (Array.isArray(v)) {
      var arr = v.map(canon);
      arr.sort(function (a, b) {
        var sa = JSON.stringify(a), sb = JSON.stringify(b);
        return sa < sb ? -1 : (sa > sb ? 1 : 0);
      });
      return arr;
    }
    if (typeof v === 'object') {
      var out = {};
      Object.keys(v).sort().forEach(function (k) { out[k] = canon(v[k]); });
      return out;
    }
    if (typeof v === 'string') {
      var t = v.trim();
      if (t.length > 1 && (t.charAt(0) === '{' || t.charAt(0) === '[')) {
        try {
          var parsed = JSON.parse(t);
          if (parsed !== null && typeof parsed === 'object') return canon(parsed);
        } catch (e) { /* not embedded JSON — treat as a plain string */ }
      }
      return v;
    }
    return v;
  }
  if (json_str === null) return null;
  try {
    return JSON.stringify(canon(JSON.parse(json_str)));
  } catch (e) {
    return json_str;
  }
""";

-- ----------------------------------------------------------------------------
-- json_changed_keys(a, b)
--   Given two row serializations (TO_JSON_STRING of the compared struct), return
--   a comma-separated, sorted list of the top-level column names whose canonical
--   values differ. Order-independent (uses the same canonicalization as above).
--   Intended to be called ONLY on rows already classified 'modified', so its
--   cost is negligible.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION `clinvar_ingest.json_changed_keys`(a STRING, b STRING)
RETURNS STRING
LANGUAGE js AS r"""
  function canon(v) {
    if (v === null) return null;
    if (Array.isArray(v)) {
      var arr = v.map(canon);
      arr.sort(function (x, y) {
        var sx = JSON.stringify(x), sy = JSON.stringify(y);
        return sx < sy ? -1 : (sx > sy ? 1 : 0);
      });
      return arr;
    }
    if (typeof v === 'object') {
      var out = {};
      Object.keys(v).sort().forEach(function (k) { out[k] = canon(v[k]); });
      return out;
    }
    if (typeof v === 'string') {
      var t = v.trim();
      if (t.length > 1 && (t.charAt(0) === '{' || t.charAt(0) === '[')) {
        try {
          var parsed = JSON.parse(t);
          if (parsed !== null && typeof parsed === 'object') return canon(parsed);
        } catch (e) { /* plain string */ }
      }
      return v;
    }
    return v;
  }
  function obj(s) {
    if (s === null) return {};
    try { var p = canon(JSON.parse(s)); return (p && typeof p === 'object' && !Array.isArray(p)) ? p : { _value: p }; }
    catch (e) { return { _value: s }; }
  }
  var oa = obj(a), ob = obj(b);
  var keys = {};
  Object.keys(oa).forEach(function (k) { keys[k] = 1; });
  Object.keys(ob).forEach(function (k) { keys[k] = 1; });
  var changed = [];
  Object.keys(keys).sort().forEach(function (k) {
    if (JSON.stringify(oa[k]) !== JSON.stringify(ob[k])) changed.push(k);
  });
  return changed.join(', ');
""";

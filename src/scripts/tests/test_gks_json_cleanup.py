import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gks_json_cleanup import strip_empty


def test_drops_empty_array_field():
    assert strip_empty({"name": "Benign", "extensions": []}) == {"name": "Benign"}


def test_drops_null_and_empty_object_fields():
    assert strip_empty({"a": None, "b": {}, "c": 1}) == {"c": 1}


def test_recurses_into_nested_objects():
    assert strip_empty({"x": {"y": [], "z": "k"}}) == {"x": {"z": "k"}}


def test_object_that_becomes_empty_is_dropped():
    assert strip_empty({"outer": {"inner": []}}) == {}


def test_preserves_falsy_scalars():
    assert strip_empty({"n": 0, "b": False, "s": ""}) == {"n": 0, "b": False, "s": ""}


def test_keeps_array_elements_but_strips_their_internals():
    assert strip_empty({"items": [{"k": "v", "e": []}, {"k": "w"}]}) == {
        "items": [{"k": "v"}, {"k": "w"}]
    }


def test_top_level_list_is_cleaned_elementwise():
    assert strip_empty([{"a": []}, {"b": 2}]) == [{}, {"b": 2}]


def test_idempotent_on_clean_input():
    clean = {"name": "x", "items": [{"k": "v"}]}
    assert strip_empty(clean) == clean
    assert strip_empty(strip_empty(clean)) == clean

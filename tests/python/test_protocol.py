from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = json.loads(
    (ROOT / "spec" / "rpc-message.schema.json").read_text(encoding="utf-8")
)
VALIDATOR = Draft202012Validator(SCHEMA)


def load_jsonl(path: Path) -> list[dict[str, object]]:
    return [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line
    ]


def test_rpc_schema_is_well_formed() -> None:
    Draft202012Validator.check_schema(SCHEMA)


def test_every_transcript_message_matches_protocol_schema() -> None:
    paths = sorted((ROOT / "tests" / "fixtures" / "messages").glob("*.jsonl"))
    assert paths

    for path in paths:
        for line_number, message in enumerate(load_jsonl(path), start=1):
            errors = sorted(
                VALIDATOR.iter_errors(message), key=lambda error: list(error.path)
            )
            assert not errors, f"{path}:{line_number}: {errors}"


def test_transcript_sequence_numbers_are_strictly_increasing() -> None:
    for path in sorted((ROOT / "tests" / "fixtures" / "messages").glob("*.jsonl")):
        sequences = [message["seq"] for message in load_jsonl(path)]
        assert sequences == sorted(set(sequences)), path


def test_every_fixture_request_has_a_correlated_response() -> None:
    for path in sorted((ROOT / "tests" / "fixtures" / "messages").glob("*.jsonl")):
        messages = load_jsonl(path)
        requests = {
            message["id"] for message in messages if message["kind"] == "request"
        }
        responses = {
            message["id"] for message in messages if message["kind"] == "response"
        }
        assert requests == responses, path


def test_revisions_and_cell_ids_are_present_on_execution_messages() -> None:
    for path in sorted((ROOT / "tests" / "fixtures" / "messages").glob("*.jsonl")):
        for message in load_jsonl(path):
            if str(message["type"]).startswith("execution."):
                assert "cell_id" in message, (path, message)
                assert "revision" in message, (path, message)

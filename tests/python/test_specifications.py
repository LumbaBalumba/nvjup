from __future__ import annotations

import json
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_nbformat_support_contract_has_required_sections() -> None:
    contract = json.loads(
        (ROOT / "spec" / "nbformat-support.json").read_text(encoding="utf-8")
    )
    assert contract["contract_version"] == 1
    assert contract["nbformat_major"] == 4
    assert {"code", "markdown", "raw"} <= set(contract["cell_types"])
    assert {"stream", "execute_result", "display_data", "error"} <= set(
        contract["output_types"]
    )
    assert contract["round_trip"]["unknown_metadata"] == "preserve"
    assert contract["round_trip"]["unknown_mime"] == "preserve"


def test_state_machines_are_internally_consistent_and_reachable() -> None:
    paths = sorted((ROOT / "spec" / "state-machines").glob("*.json"))
    assert paths

    for path in paths:
        machine = json.loads(path.read_text(encoding="utf-8"))
        states = set(machine["states"])
        assert machine["initial"] in states, path
        assert set(machine["terminal"]) <= states, path
        assert len(states) == len(machine["states"]), path

        adjacency: dict[str, set[str]] = {state: set() for state in states}
        transition_keys: set[tuple[str, str, str]] = set()
        for transition in machine["transitions"]:
            source = transition["from"]
            target = transition["to"]
            assert source in states, (path, transition)
            assert target in states, (path, transition)
            key = (source, transition["event"], target)
            assert key not in transition_keys, (path, transition)
            transition_keys.add(key)
            adjacency[source].add(target)

        reached = {machine["initial"]}
        queue = deque([machine["initial"]])
        while queue:
            source = queue.popleft()
            for target in adjacency[source] - reached:
                reached.add(target)
                queue.append(target)

        assert reached == states, f"{path}: unreachable={sorted(states - reached)}"


def test_normative_documents_exist() -> None:
    required = {
        "README.md",
        "acceptance.md",
        "lsp-navigation.md",
        "nbformat.md",
        "protocol.md",
        "state-machines.md",
        "trust.md",
    }
    actual = {path.name for path in (ROOT / "docs" / "spec").glob("*.md")}
    assert required <= actual

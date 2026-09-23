from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

import nbformat

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures"
MANIFEST = json.loads((FIXTURES / "manifest.json").read_text(encoding="utf-8"))


def test_manifest_references_existing_files_and_covers_required_features() -> None:
    covered: set[str] = set()
    for relative_path, features in MANIFEST["files"].items():
        assert (FIXTURES / relative_path).is_file(), relative_path
        covered.update(features)

    assert set(MANIFEST["required_features"]) <= covered


def test_every_notebook_is_valid_nbformat_v4() -> None:
    notebooks = sorted((FIXTURES / "notebooks").glob("*.ipynb"))
    assert notebooks

    for path in notebooks:
        node = nbformat.read(path, as_version=nbformat.NO_CONVERT)
        assert node.nbformat == 4, path
        nbformat.validate(node)


def test_every_notebook_survives_semantic_round_trip() -> None:
    for path in sorted((FIXTURES / "notebooks").glob("*.ipynb")):
        original = nbformat.read(path, as_version=nbformat.NO_CONVERT)
        serialized = nbformat.writes(original, version=nbformat.NO_CONVERT)
        restored = nbformat.reads(serialized, as_version=nbformat.NO_CONVERT)
        assert restored == original, path


def test_fixture_generation_is_deterministic() -> None:
    tracked = sorted(
        [
            *(FIXTURES / "notebooks").glob("*.ipynb"),
            *(FIXTURES / "messages").glob("*.jsonl"),
            FIXTURES / "manifest.json",
        ]
    )
    before = {path: path.read_bytes() for path in tracked}

    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "generate-fixtures.py")],
        cwd=ROOT,
        check=True,
    )

    after = {path: path.read_bytes() for path in tracked}
    assert after == before


def test_png_payloads_are_real_png_files() -> None:
    rich = json.loads(
        (FIXTURES / "notebooks" / "03_rich_outputs.ipynb").read_text(encoding="utf-8")
    )
    png_data = rich["cells"][0]["outputs"][0]["data"]["image/png"]
    assert base64.b64decode(png_data).startswith(b"\x89PNG\r\n\x1a\n")


def test_unknown_metadata_and_mime_are_present_in_lossless_fixture() -> None:
    path = FIXTURES / "notebooks" / "07_unknown_metadata.ipynb"
    node = nbformat.read(path, as_version=nbformat.NO_CONVERT)

    assert node.metadata["vendor.example/notebook"]["version"] == 9
    assert node.cells[0].metadata["vendor.example/cell"]["enabled"] is True
    assert (
        node.cells[1]
        .outputs[0]
        .data["application/vnd.example.widget+json"]["state"]["value"]
        == 7
    )


def test_cell_ids_are_unique_within_each_notebook() -> None:
    for path in sorted((FIXTURES / "notebooks").glob("*.ipynb")):
        node = nbformat.read(path, as_version=nbformat.NO_CONVERT)
        ids = [cell.id for cell in node.cells if "id" in cell]
        assert len(ids) == len(set(ids)), path

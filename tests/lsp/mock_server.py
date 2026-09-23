#!/usr/bin/env python3
"""Small deterministic LSP server used by nvjup's hermetic integration tests."""

from __future__ import annotations

import json
import re
import sys
from typing import Any

DOCUMENTS: dict[str, str] = {}


def read_message() -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in {b"\r\n", b"\n"}:
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    return json.loads(sys.stdin.buffer.read(length))


def send(payload: dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def response(message_id: int | str, result: Any) -> None:
    send({"jsonrpc": "2.0", "id": message_id, "result": result})


def utf16_length(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def position_for_offset(text: str, offset: int) -> dict[str, int]:
    before = text[:offset]
    line = before.count("\n")
    line_text = before.rsplit("\n", 1)[-1]
    return {"line": line, "character": utf16_length(line_text)}


def ranges_for(uri: str, name: str) -> list[dict[str, Any]]:
    text = DOCUMENTS.get(uri, "")
    result = []
    for match in re.finditer(rf"\b{re.escape(name)}\b", text):
        start = position_for_offset(text, match.start())
        end = position_for_offset(text, match.end())
        result.append({"uri": uri, "range": {"start": start, "end": end}})
    return result


def publish_diagnostics(uri: str) -> None:
    text = DOCUMENTS.get(uri, "")
    diagnostics = []
    for location in ranges_for(uri, "missing_name"):
        diagnostics.append(
            {
                "range": location["range"],
                "severity": 1,
                "code": "mock-undefined",
                "source": "nvjup-mock",
                "message": "missing_name is undefined",
            }
        )
    send(
        {
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": {"uri": uri, "diagnostics": diagnostics},
        }
    )


def definition(uri: str) -> list[dict[str, Any]]:
    locations = ranges_for(uri, "length")
    text = DOCUMENTS.get(uri, "")
    for location in locations:
        line = location["range"]["start"]["line"]
        source_line = text.splitlines()[line] if line < len(text.splitlines()) else ""
        if "def length" in source_line:
            return [location]
    return locations[:1]


def semantic_tokens(uri: str) -> dict[str, list[int]]:
    locations = ranges_for(uri, "length")
    data: list[int] = []
    previous_line = 0
    previous_character = 0
    for location in locations:
        start = location["range"]["start"]
        delta_line = start["line"] - previous_line
        delta_start = (
            start["character"] - previous_character
            if delta_line == 0
            else start["character"]
        )
        data.extend([delta_line, delta_start, len("length"), 0, 0])
        previous_line = start["line"]
        previous_character = start["character"]
    return {"data": data}


def handle_request(message: dict[str, Any]) -> bool:
    method = message.get("method")
    params = message.get("params") or {}
    message_id = message.get("id")

    if method == "initialize":
        response(
            message_id,
            {
                "capabilities": {
                    "positionEncoding": "utf-16",
                    "textDocumentSync": 1,
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "declarationProvider": True,
                    "implementationProvider": True,
                    "typeDefinitionProvider": True,
                    "referencesProvider": True,
                    "completionProvider": {"triggerCharacters": ["."]},
                    "signatureHelpProvider": {"triggerCharacters": ["(", ","]},
                    "renameProvider": True,
                    "codeActionProvider": True,
                    "documentSymbolProvider": True,
                    "semanticTokensProvider": {
                        "legend": {"tokenTypes": ["function"], "tokenModifiers": []},
                        "full": True,
                    },
                },
                "serverInfo": {"name": "nvjup-mock", "version": "1"},
            },
        )
    elif method == "shutdown":
        response(message_id, None)
    elif method == "textDocument/hover":
        response(
            message_id,
            {"contents": {"kind": "markdown", "value": "**nvjup mock hover**"}},
        )
    elif method == "textDocument/signatureHelp":
        response(
            message_id,
            {
                "signatures": [
                    {
                        "label": "length(point: Точка) -> float",
                        "documentation": "Mock signature mapped from the shadow document.",
                    }
                ],
                "activeSignature": 0,
                "activeParameter": 0,
            },
        )
    elif method in {
        "textDocument/definition",
        "textDocument/declaration",
        "textDocument/implementation",
        "textDocument/typeDefinition",
    }:
        response(message_id, definition(params["textDocument"]["uri"]))
    elif method == "textDocument/references":
        response(message_id, ranges_for(params["textDocument"]["uri"], "length"))
    elif method == "textDocument/completion":
        response(
            message_id,
            {
                "isIncomplete": False,
                "items": [
                    {
                        "label": "length",
                        "kind": 3,
                        "detail": "nvjup mock completion",
                        "documentation": "Cross-cell completion from one shadow document.",
                    }
                ],
            },
        )
    elif method == "textDocument/rename":
        uri = params["textDocument"]["uri"]
        edits = [
            {"range": location["range"], "newText": params["newName"]}
            for location in ranges_for(uri, "length")
        ]
        response(message_id, {"changes": {uri: edits}})
    elif method == "textDocument/codeAction":
        uri = params["textDocument"]["uri"]
        locations = ranges_for(uri, "point")
        edit = None
        if locations:
            edit = {
                "changes": {
                    uri: [{"range": locations[-1]["range"], "newText": "renamed_point"}]
                }
            }
        response(
            message_id,
            (
                [
                    {
                        "title": "Rename final point reference",
                        "kind": "quickfix",
                        "edit": edit,
                    }
                ]
                if edit
                else []
            ),
        )
    elif method == "textDocument/documentSymbol":
        uri = params["textDocument"]["uri"]
        locations = definition(uri)
        result = []
        if locations:
            result.append(
                {
                    "name": "length",
                    "kind": 12,
                    "range": locations[0]["range"],
                    "selectionRange": locations[0]["range"],
                }
            )
        response(message_id, result)
    elif method == "textDocument/semanticTokens/full":
        response(message_id, semantic_tokens(params["textDocument"]["uri"]))
    elif message_id is not None:
        response(message_id, None)

    if method == "exit":
        return False
    return True


def main() -> None:
    running = True
    while running:
        message = read_message()
        if message is None:
            return
        method = message.get("method")
        params = message.get("params") or {}
        if method == "textDocument/didOpen":
            document = params["textDocument"]
            DOCUMENTS[document["uri"]] = document["text"]
            publish_diagnostics(document["uri"])
        elif method == "textDocument/didChange":
            uri = params["textDocument"]["uri"]
            changes = params.get("contentChanges") or []
            if changes:
                DOCUMENTS[uri] = changes[-1].get("text", DOCUMENTS.get(uri, ""))
            publish_diagnostics(uri)
        elif method == "textDocument/didClose":
            DOCUMENTS.pop(params["textDocument"]["uri"], None)
        running = handle_request(message)


if __name__ == "__main__":
    main()

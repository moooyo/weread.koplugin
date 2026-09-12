"""Generate offline shard fixtures using the repository's Python reference."""

import base64
import json
from pathlib import Path
import runpy
import sys


repo = Path(__file__).resolve().parents[2]
reference = runpy.run_path(str(repo / "scripts" / "fetch_weread_epub.py"))
fixtures = [
    ("empty", ""),
    ("one_byte", "a"),
    ("two_bytes", "ab"),
    ("three_bytes", "abc"),
    ("short_overlap", "abcdef"),
    ("plain_xhtml", "<html><body><p>Offline content fixture.</p></body></html>"),
    ("multiple_bodies", "<html><body>First</body></html><html><body>Second</body></html>"),
    ("unicode", "<p>\u4e2d\u6587 \u304b\u306a \ud55c\uae00 \U0001f600 e\u0301 \U00020000</p>"),
    ("css", "body { line-height: 1.7; } .note { font-size: 0.85em; }"),
]
lines = ["-- Generated offline by spec/helpers/generate_content_decoder_fixtures.py.", "return {"]
for index, (name, plain) in enumerate(fixtures):
    encoded = base64.b64encode(plain.encode("utf-8")).decode("ascii")
    if index % 2:
        encoded = encoded.rstrip("=").replace("+", "-").replace("/", "_")
    positions = reference["swap_positions"](encoded)
    characters = list(encoded)
    for pair in range(1, len(positions), 2):
        for delta in (0, 1):
            left, right = positions[pair] + delta, positions[pair - 1] + delta
            characters[left], characters[right] = characters[right], characters[left]
    body = "0" + "".join(characters)
    first, second = len(body) // 3, 2 * len(body) // 3
    pieces = (body[:first], body[first:second], body[second:])
    shards = [reference["md5_hex"](piece).upper() + piece for piece in pieces]
    single = reference["md5_hex"](body).upper() + body
    assert reference["decode_content_shards"](*shards) == plain
    assert reference["decode_style_shard"](single) == plain
    values = {"name": name, "expected_hex": plain.encode("utf-8").hex(),
              "e0": shards[0], "e1": shards[1], "e3": shards[2], "single": single}
    lines.append("    {")
    for key, value in values.items():
        lines.append(f"        {key} = {json.dumps(value, ensure_ascii=True)},")
    lines.append("    },")
lines.append("}")
destination = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "spec" / "fixtures" / "content_decoder_cases.lua"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Generated {len(fixtures)} offline shard fixtures")

#!/usr/bin/env python3
"""Export WeRead cookies from a browser Cookie header or copied LuaSettings file.

Lua input is parsed as literal data and is never executed.
The destination must not already exist. POSIX files are created with mode 0600;
on Windows, access is governed by the destination directory's existing ACL.
"""

from __future__ import annotations

import argparse
from http.cookies import CookieError, SimpleCookie
import json
import math
import os
from pathlib import Path
import re
import stat
import sys


MAX_SETTINGS_BYTES = 16 * 1024 * 1024
MAX_TABLE_DEPTH = 64
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z_0-9]*")
NUMBER = re.compile(
    r"(?:0[xX](?:[0-9A-Fa-f]+(?:\.[0-9A-Fa-f]*)?|\.[0-9A-Fa-f]+)"
    r"(?:[pP][+-]?[0-9]+)?|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)"
    r"(?:[eE][+-]?[0-9]+)?)"
)
COOKIE_NAME = re.compile(r"[!#$%&'*+\-.^_`|~0-9A-Za-z]+")
COOKIE_VALUE = re.compile(r"[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]*")
KEYWORDS = frozenset(
    "and break do else elseif end false for function if in local nil not or "
    "repeat return then true until while goto".split()
)


class ExportError(ValueError):
    """An error whose message is safe to display without source contents."""


class LuaTable:
    def __init__(self) -> None:
        # Typed keys keep Lua's boolean keys distinct from numeric keys.
        self.fields: dict[tuple[str, object], object] = {}


class LiteralParser:
    """Accept a return statement containing only literal tables and scalars."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.position = 0

    def fail(self, message: str) -> None:
        # Never include an unexpected token, string, or source excerpt.
        raise ExportError(f"{message} (offset {self.position}).")

    def long_open(self, position: int) -> tuple[int, str] | None:
        if not self.text.startswith("[", position):
            return None
        end = position + 1
        while end < len(self.text) and self.text[end] == "=":
            end += 1
        if end < len(self.text) and self.text[end] == "[":
            return end + 1, "]" + "=" * (end - position - 1) + "]"
        return None

    def long_string(self, *, comment: bool = False) -> str:
        opening = self.long_open(self.position)
        if opening is None:
            self.fail("Invalid long string")
        start, closing = opening
        end = self.text.find(closing, start)
        if end < 0:
            self.fail("Unterminated long string or comment")
        self.position = end + len(closing)
        if comment:
            return ""
        value = re.sub(r"\r\n|\n\r|\r", "\n", self.text[start:end])
        return value[1:] if value.startswith("\n") else value

    def skip(self) -> None:
        while self.position < len(self.text):
            if self.text[self.position] in " \t\r\n\v\f":
                self.position += 1
            elif self.text.startswith("--", self.position):
                self.position += 2
                if self.long_open(self.position):
                    self.long_string(comment=True)
                else:
                    while self.position < len(self.text) and self.text[self.position] not in "\r\n":
                        self.position += 1
            else:
                break

    def expect(self, character: str) -> None:
        self.skip()
        if not self.text.startswith(character, self.position):
            self.fail("Invalid literal table syntax")
        self.position += len(character)

    def quoted_string(self) -> str:
        quote = self.text[self.position]
        self.position += 1
        start = self.position
        parts: list[str] = []
        escapes = {
            "a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r",
            "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"',
        }
        while self.position < len(self.text):
            character = self.text[self.position]
            if character == quote:
                parts.append(self.text[start:self.position])
                self.position += 1
                return "".join(parts)
            if character in "\r\n":
                self.fail("Unescaped newline in quoted string")
            if character != "\\":
                self.position += 1
                continue
            parts.append(self.text[start:self.position])
            self.position += 1
            if self.position >= len(self.text):
                self.fail("Unterminated string escape")
            character = self.text[self.position]
            self.position += 1
            if character in escapes:
                parts.append(escapes[character])
            elif "0" <= character <= "9":
                digits = character
                while len(digits) < 3 and self.position < len(self.text):
                    character = self.text[self.position]
                    if not "0" <= character <= "9":
                        break
                    digits += character
                    self.position += 1
                number = int(digits)
                if number > 255:
                    self.fail("Decimal string escape is out of range")
                parts.append(chr(number))
            elif character == "x":
                digits = self.text[self.position:self.position + 2]
                if len(digits) != 2 or any(digit not in "0123456789abcdefABCDEF" for digit in digits):
                    self.fail("Invalid hexadecimal string escape")
                parts.append(chr(int(digits, 16)))
                self.position += 2
            elif character in "\r\n":
                if self.position < len(self.text) and self.text[self.position] in "\r\n" \
                        and self.text[self.position] != character:
                    self.position += 1
                parts.append("\n")
            elif character == "z":
                while self.position < len(self.text) and self.text[self.position] in " \t\r\n\v\f":
                    self.position += 1
            else:
                self.fail("Unsupported string escape")
            start = self.position
        self.fail("Unterminated quoted string")

    def value(self, depth: int) -> object:
        self.skip()
        if self.position >= len(self.text):
            self.fail("Missing literal value")
        character = self.text[self.position]
        if character == "{":
            return self.table(depth + 1)
        if character in "\"'":
            return self.quoted_string()
        if self.long_open(self.position):
            return self.long_string()
        identifier = IDENTIFIER.match(self.text, self.position)
        if identifier:
            self.position = identifier.end()
            name = identifier.group()
            if name in {"true", "false", "nil"}:
                return {"true": True, "false": False, "nil": None}[name]
            self.fail("Executable Lua and variable references are not supported")
        negative = character == "-"
        if negative:
            self.position += 1
            self.skip()
        number = NUMBER.match(self.text, self.position)
        if not number:
            self.fail("Expected a literal value")
        self.position = number.end()
        try:
            raw = number.group()
            result = float.fromhex(raw) if raw.lower().startswith("0x") else float(raw)
        except (ValueError, OverflowError):
            self.fail("Invalid numeric literal")
        if not math.isfinite(result):
            self.fail("Non-finite numeric literals are not supported")
        return -result if negative else result

    def table(self, depth: int) -> LuaTable:
        if depth > MAX_TABLE_DEPTH:
            self.fail("Settings exceed the maximum table nesting depth")
        self.expect("{")
        result = LuaTable()
        seen: set[tuple[str, object]] = set()
        array_index = 1
        while True:
            self.skip()
            if self.text.startswith("}", self.position):
                self.position += 1
                return result
            if self.text.startswith("[", self.position) and not self.long_open(self.position):
                self.position += 1
                key = self.value(depth)
                self.expect("]")
                self.expect("=")
                item = self.value(depth)
            else:
                saved = self.position
                identifier = IDENTIFIER.match(self.text, self.position)
                if identifier:
                    self.position = identifier.end()
                    self.skip()
                if identifier and self.text.startswith("=", self.position):
                    key = identifier.group()
                    if key in KEYWORDS:
                        self.fail("Invalid literal field name")
                    self.position += 1
                    item = self.value(depth)
                else:
                    self.position = saved
                    key, item = array_index, self.value(depth)
                    array_index += 1
            if isinstance(key, str):
                typed_key = ("string", key)
            elif isinstance(key, bool):
                typed_key = ("boolean", key)
            elif isinstance(key, (int, float)):
                typed_key = ("number", key)
            else:
                self.fail("Unsupported literal table key")
            if typed_key in seen:
                self.fail("Duplicate literal table keys are not supported")
            seen.add(typed_key)
            if item is not None:
                result.fields[typed_key] = item
            self.skip()
            if self.position < len(self.text) and self.text[self.position] in ",;":
                self.position += 1
            elif not self.text.startswith("}", self.position):
                self.fail("Missing literal field separator")

    def parse(self) -> LuaTable:
        self.skip()
        statement = IDENTIFIER.match(self.text, self.position)
        if not statement or statement.group() != "return":
            self.fail("Settings must contain a return table")
        self.position = statement.end()
        result = self.value(0)
        self.skip()
        if self.text.startswith(";", self.position):
            self.position += 1
            self.skip()
        if self.position != len(self.text) or not isinstance(result, LuaTable):
            self.fail("Only one returned literal table is supported")
        return result


def read_input(input_path: Path) -> str:
    try:
        if not input_path.is_file():
            raise ExportError("Input must be a regular file")
        with input_path.open("rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ExportError("Input must be a regular file")
            data = source.read(MAX_SETTINGS_BYTES + 1)
    except OSError:
        raise ExportError("Could not read the input file") from None
    if len(data) > MAX_SETTINGS_BYTES:
        raise ExportError("Input file exceeds the 16 MiB limit")
    try:
        return data.decode("utf-8-sig")
    except UnicodeError:
        raise ExportError("Input file must be UTF-8 text") from None


def validate_cookies(cookies: dict[str, str]) -> dict[str, str]:
    for name, value in cookies.items():
        if not isinstance(name, str) or not COOKIE_NAME.fullmatch(name):
            raise ExportError("Cookie names must be valid HTTP cookie names")
        # Cookie octets are ASCII. This also avoids platform text-encoding
        # changes when MozillaCookieJar moves between Windows and Linux.
        if not isinstance(value, str) or not COOKIE_VALUE.fullmatch(value):
            raise ExportError("Cookie values contain unsupported characters")
    if any(not cookies.get(name, "") for name in ("wr_skey", "wr_vid")):
        raise ExportError("Required wr_skey and wr_vid cookies must be present and nonempty")
    return cookies


def read_cookies(settings_path: Path) -> dict[str, str]:
    root = LiteralParser(read_input(settings_path)).parse()
    table = root.fields.get(("string", "cookies"))
    if not isinstance(table, LuaTable):
        raise ExportError("No top-level cookies table was found")
    cookies: dict[str, str] = {}
    for (kind, name), value in table.fields.items():
        if kind != "string":
            raise ExportError("Cookie names must be valid HTTP cookie names")
        cookies[name] = value
    return validate_cookies(cookies)


def read_cookie_header(input_path: Path) -> dict[str, str]:
    text = read_input(input_path)
    if text.endswith("\r\n"):
        text = text[:-2]
    elif text.endswith("\n"):
        text = text[:-1]
    if any(character in text for character in "\r\n\t\x00"):
        raise ExportError("Cookie input must contain one line without control characters")
    text = text.strip(" ")
    if text[:7].lower() == "cookie:":
        text = text[7:].strip(" ")
    # SimpleCookie may silently ignore malformed trailing input or treat fields
    # as Set-Cookie attributes. Validate full fields before trusting its result.
    names: set[str] = set()
    for field in text.split(";"):
        name, separator, raw_value = field.strip(" ").partition("=")
        if not separator or not COOKIE_NAME.fullmatch(name):
            raise ExportError("Invalid Cookie header syntax")
        if raw_value.startswith('"') and raw_value.endswith('"') and len(raw_value) >= 2:
            raw_value = raw_value[1:-1]
        if not COOKIE_VALUE.fullmatch(raw_value):
            raise ExportError("Invalid Cookie header value")
        if name in names:
            raise ExportError("Duplicate cookie names are not supported")
        names.add(name)
    parsed = SimpleCookie()
    try:
        parsed.load(text)
    except CookieError:
        raise ExportError("Invalid Cookie header syntax") from None
    if set(parsed) != names:
        raise ExportError("Invalid Cookie header syntax")
    return validate_cookies({name: morsel.value for name, morsel in parsed.items()})


def export_credentials(settings_path: Path | None, output_path: Path, *, cookie_header_path: Path | None = None) -> int:
    if (settings_path is None) == (cookie_header_path is None):
        raise ExportError("Choose exactly one credential input file")
    cookies = read_cookies(settings_path) if settings_path is not None else read_cookie_header(cookie_header_path)
    lines = ["# Netscape HTTP Cookie File", "# Exported WeRead cookies. Keep this file private.", ""]
    for name in sorted(cookies):
        lines.append("\t".join((".weread.qq.com", "TRUE", "/", "TRUE", "", name, cookies[name])))
    descriptor = None
    created = False
    written = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
        descriptor = os.open(output_path, flags, 0o600)
        created = True
        with os.fdopen(descriptor, "w", encoding="ascii", newline="\n") as target:
            descriptor = None
            target.write("\n".join(lines) + "\n")
        written = True
    except FileExistsError:
        raise ExportError("Output already exists; choose a new file") from None
    except OSError:
        raise ExportError("Could not create or write the output file") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if created and not written:
            try:
                output_path.unlink()
            except OSError:
                pass
    return len(cookies)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise ExportError("Invalid command-line arguments; use --help")


def main(argv: list[str] | None = None) -> int:
    parser = SafeArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--settings", type=Path, help="Path to a copied weread.lua settings file")
    source.add_argument("--cookie-header-file", type=Path, help="UTF-8 file containing one browser Cookie header value")
    parser.add_argument("--output", type=Path, required=True, help="New private Netscape cookie file to create")
    try:
        args = parser.parse_args(argv)
        count = export_credentials(args.settings, args.output, cookie_header_path=args.cookie_header_file)
    except ExportError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    except Exception:
        # Do not expose unexpected exception messages: they may contain input.
        print("Error: Credential export failed.", file=sys.stderr)
        return 1
    print(json.dumps({"output": os.path.abspath(args.output), "cookies": count}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

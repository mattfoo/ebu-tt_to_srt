#!/usr/bin/env python3
"""EBU-TT / TTML -> SRT converter, version 2.0.0."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Iterable, Optional

from lxml import etree

VERSION = "2.0.0"
TT_NS = "http://www.w3.org/ns/ttml"
TTP_NS = "http://www.w3.org/ns/ttml#parameter"

_CLOCK_RE = re.compile(r"^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$")
_CLOCK_FRAME_RE = re.compile(r"^(\d+):(\d{2}):(\d{2}):(\d+)$")
_OFFSET_RE = re.compile(r"^(\d+(?:\.\d+)?)(ms|h|m|s|f)$")
_FPS_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)(?:\s*/\s*(\d+(?:\.\d+)?))?\s*$")


class EbuTTError(Exception):
    """Base converter error."""


class TimestampError(EbuTTError):
    """Invalid timestamp."""


@dataclass(frozen=True)
class Cue:
    number: int
    begin: Decimal
    end: Decimal
    text: str


@dataclass(frozen=True)
class ConversionResult:
    output: Path
    written: int
    skipped: int
    offset: Decimal
    frame_rate: Decimal
    time_base: str


def parse_frame_rate(value) -> Decimal:
    if isinstance(value, Decimal):
        fps = value
    else:
        m = _FPS_RE.match(str(value))
        if not m:
            raise EbuTTError(f"invalid frame rate: {value!r}")
        try:
            fps = Decimal(m.group(1)) / Decimal(m.group(2) or "1")
        except (InvalidOperation, ZeroDivisionError) as exc:
            raise EbuTTError(f"invalid frame rate: {value!r}") from exc
    if fps <= 0:
        raise EbuTTError("frame rate must be greater than zero")
    return fps


def detect_frame_rate(root: etree._Element) -> Decimal:
    raw = root.get(f"{{{TTP_NS}}}frameRate")
    if not raw:
        return Decimal("25")
    fps = parse_frame_rate(raw)
    mult = root.get(f"{{{TTP_NS}}}frameRateMultiplier")
    if mult:
        parts = mult.split()
        if len(parts) != 2:
            raise EbuTTError(f"invalid frameRateMultiplier: {mult!r}")
        try:
            fps *= Decimal(parts[0]) / Decimal(parts[1])
        except (InvalidOperation, ZeroDivisionError) as exc:
            raise EbuTTError(f"invalid frameRateMultiplier: {mult!r}") from exc
    return fps


def parse_timestamp(value: str, *, frame_rate: Decimal,
                    time_base: str = "media") -> Decimal:
    if value is None:
        raise TimestampError("timestamp is missing")
    value = value.strip()
    if not value:
        raise TimestampError("timestamp is empty")

    m = _CLOCK_RE.match(value)
    if m:
        h, mi, s = map(int, m.group(1, 2, 3))
        if mi > 59 or s > 59:
            raise TimestampError(f"invalid timestamp: {value!r}")
        frac = Decimal("0." + m.group(4)) if m.group(4) else Decimal(0)
        return Decimal(h * 3600 + mi * 60 + s) + frac

    m = _CLOCK_FRAME_RE.match(value)
    if m:
        h, mi, s, frames = map(int, m.groups())
        if mi > 59 or s > 59:
            raise TimestampError(f"invalid timestamp: {value!r}")
        if Decimal(frames) >= frame_rate:
            raise TimestampError(f"frame {frames} outside frame rate {frame_rate}")
        return Decimal(h * 3600 + mi * 60 + s) + Decimal(frames) / frame_rate

    m = _OFFSET_RE.match(value)
    if m:
        n, unit = Decimal(m.group(1)), m.group(2)
        return {
            "h": n * 3600, "m": n * 60, "s": n,
            "ms": n / 1000, "f": n / frame_rate,
        }[unit]

    # Real-world media feeds sometimes use plain seconds.
    if time_base == "media" and re.fullmatch(r"\d+(?:\.\d+)?", value):
        return Decimal(value)

    raise TimestampError(f"unsupported timestamp: {value!r}")


def format_srt_time(seconds: Decimal) -> str:
    seconds = max(Decimal(0), seconds)
    ms = int((seconds * 1000).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    h, rem = divmod(ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _local_name(node: etree._Element) -> str:
    return etree.QName(node).localname


def _document_start(root: etree._Element) -> Optional[str]:
    names = {"documentStartOfProgramme", "documentStartOfProgram"}
    for node in root.iter():
        if _local_name(node) in names:
            value = (node.text or "").strip()
            if value:
                return value
            for attr in ("value", "time"):
                value = (node.get(attr) or "").strip()
                if value:
                    return value
    for node in root.iter():
        for attr, value in node.attrib.items():
            if etree.QName(attr).localname in names and value.strip():
                return value.strip()
    return None


def _timing_value(value: str, fps: Decimal, time_base: str) -> Decimal:
    return parse_timestamp(value, frame_rate=fps, time_base=time_base)


def _resolve_timing(p: etree._Element, fps: Decimal,
                    time_base: str) -> tuple[Decimal, Decimal]:
    # EBU-TT permits timing on body/div/p and child expressions can be
    # relative to the nearest timed ancestor. Accumulate ancestor begins.
    ancestors = list(p.iterancestors())
    ancestors.reverse()
    chain = ancestors + [p]

    current_begin = Decimal(0)
    parent_end: Optional[Decimal] = None

    for node in chain:
        b = node.get("begin")
        e = node.get("end")
        d = node.get("dur")

        node_start = current_begin
        if b:
            current_begin += _timing_value(b, fps, time_base)

        if e:
            parent_end = node_start + _timing_value(e, fps, time_base)
        elif d:
            parent_end = current_begin + _timing_value(d, fps, time_base)

    p_begin = current_begin
    b = p.get("begin")
    p_parent_begin = Decimal(0)
    for node in chain[:-1]:
        if node.get("begin"):
            p_parent_begin += _timing_value(node.get("begin"), fps, time_base)

    if p.get("end"):
        p_end = p_parent_begin + _timing_value(p.get("end"), fps, time_base)
    elif p.get("dur"):
        p_end = p_begin + _timing_value(p.get("dur"), fps, time_base)
    elif parent_end is not None:
        p_end = parent_end
    else:
        raise TimestampError("subtitle has neither end nor dur")

    if p_end < p_begin:
        raise TimestampError("subtitle end precedes begin")
    return p_begin, p_end


def _text(node: etree._Element) -> str:
    parts = []
    if node.text:
        parts.append(node.text)
    for child in node:
        if _local_name(child) == "br":
            parts.append("\n")
        else:
            parts.append(_text(child))
        if child.tail:
            parts.append(child.tail)
    return "".join(parts)


def extract_text(p: etree._Element) -> str:
    text = _text(p)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def _parse_xml(path: Path) -> etree._ElementTree:
    parser = etree.XMLParser(
        resolve_entities=False,
        no_network=True,
        load_dtd=False,
        recover=False,
    )
    try:
        return etree.parse(str(path), parser)
    except (OSError, etree.XMLSyntaxError) as exc:
        raise EbuTTError(f"unable to parse XML '{path}': {exc}") from exc


def convert(input_path, output_path=None, *, offset=None, fps=None,
            no_auto_offset=False, strict=False, verbose=False,
            keep_empty=False) -> ConversionResult:
    source = Path(input_path)
    if not source.is_file():
        raise EbuTTError(f"input file does not exist: {source}")

    destination = Path(output_path) if output_path else source.with_suffix(".srt")
    tree = _parse_xml(source)
    root = tree.getroot()

    time_base = root.get(f"{{{TTP_NS}}}timeBase", "media").lower()
    if time_base not in {"media", "clock", "smpte"}:
        if strict:
            raise EbuTTError(f"unsupported timeBase: {time_base!r}")
        if verbose:
            print(f"Warning: unsupported timeBase {time_base!r}; using media",
                  file=sys.stderr)
        time_base = "media"

    frame_rate = parse_frame_rate(fps) if fps is not None else detect_frame_rate(root)

    offset_seconds = Decimal(0)
    if offset is not None:
        offset_seconds = (offset if isinstance(offset, Decimal)
                          else parse_timestamp(str(offset), frame_rate=frame_rate,
                                               time_base=time_base))
    elif not no_auto_offset:
        start = _document_start(root)
        if start:
            try:
                offset_seconds = parse_timestamp(start, frame_rate=frame_rate,
                                                 time_base=time_base)
            except TimestampError as exc:
                if strict:
                    raise
                if verbose:
                    print(f"Warning: invalid documentStartOfProgramme: {exc}",
                          file=sys.stderr)

    paragraphs = root.xpath(
        ".//*[local-name()='p' and namespace-uri()=$ns]", ns=TT_NS
    )
    if not paragraphs:
        raise EbuTTError("no TTML <p> subtitle elements found")

    cues = []
    skipped = 0

    for p in paragraphs:
        try:
            begin, end = _resolve_timing(p, frame_rate, time_base)
            text = extract_text(p)
            if not text and not keep_empty:
                skipped += 1
                continue

            begin -= offset_seconds
            end -= offset_seconds
            if end < 0:
                skipped += 1
                continue
            begin = max(Decimal(0), begin)
            end = max(Decimal(0), end)
            if end < begin:
                raise TimestampError("timestamp invalid after offset")

            cues.append(Cue(len(cues) + 1, begin, end, text))
        except (TimestampError, EbuTTError) as exc:
            if strict:
                raise
            skipped += 1
            print(f"Warning: skipping subtitle: {exc}", file=sys.stderr)

    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8", newline="\n") as fh:
        for cue in cues:
            fh.write(f"{cue.number}\n")
            fh.write(f"{format_srt_time(cue.begin)} --> "
                     f"{format_srt_time(cue.end)}\n")
            fh.write(cue.text + "\n\n")

    if verbose:
        print(f"[ebu-tt_to_srt] written={len(cues)} skipped={skipped}",
              file=sys.stderr)

    return ConversionResult(destination, len(cues), skipped,
                            offset_seconds, frame_rate, time_base)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Convert EBU-TT/TTML to SRT.")
    p.add_argument("input", type=Path)
    p.add_argument("output", type=Path, nargs="?")
    p.add_argument("-o", "--output", dest="output_option", type=Path)
    p.add_argument("--offset")
    p.add_argument("--fps")
    p.add_argument("--no-auto-offset", action="store_true")
    p.add_argument("--keep-empty", action="store_true")
    p.add_argument("--strict", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--version", action="version", version=VERSION)
    return p


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.output and args.output_option:
        print("Error: specify output positionally or with --output, not both",
              file=sys.stderr)
        return 2
    output = args.output_option or args.output
    try:
        result = convert(
            args.input, output,
            offset=args.offset, fps=args.fps,
            no_auto_offset=args.no_auto_offset,
            strict=args.strict, verbose=args.verbose,
            keep_empty=args.keep_empty,
        )
    except (EbuTTError, OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Written {result.written} subtitle(s) to {result.output}"
          + (f"; skipped {result.skipped}" if result.skipped else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

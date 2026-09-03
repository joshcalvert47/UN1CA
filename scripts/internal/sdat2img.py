#!/usr/bin/env python3
# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

import re
import sys

BLOCK_SIZE = 4096


def parse_ranges(value):
    values = [int(item) for item in value.split(",") if item]
    if not values:
        return []
    count = values[0]
    if len(values) != 1 + count * 2:
        raise ValueError(f"invalid range list: {value}")
    ranges = []
    for index in range(count):
        start = values[1 + index * 2]
        end = values[2 + index * 2]
        if start < 0 or end < start:
            raise ValueError(f"invalid range: {start},{end}")
        ranges.append((start, end))
    return ranges


def range_blocks(ranges):
    return sum(end - start for start, end in ranges)


def copy_ranges(output, ranges, payload_file):
    remaining = range_blocks(ranges) * BLOCK_SIZE
    chunk_size = 4 * 1024 * 1024

    for start, end in ranges:
        output.seek(start * BLOCK_SIZE)
        range_remaining = (end - start) * BLOCK_SIZE
        while range_remaining:
            chunk = payload_file.read(min(chunk_size, range_remaining))
            if not chunk:
                raise ValueError("new.dat is shorter than the transfer list")
            output.write(chunk)
            range_remaining -= len(chunk)
            remaining -= len(chunk)

    if remaining:
        raise ValueError("internal transfer-list range accounting error")


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <transfer.list> <new.dat> <output.img>", file=sys.stderr)
        return 2

    transfer_path, payload_path, output_path = sys.argv[1:]
    with open(transfer_path, "r", encoding="ascii") as transfer_file:
        lines = [line.strip() for line in transfer_file if line.strip() and not line.lstrip().startswith("#")]

    if not lines or not re.fullmatch(r"[0-9]+", lines[0]):
        raise ValueError("transfer list has no valid version")

    version = int(lines[0])
    if version not in (1, 2, 3, 4):
        raise ValueError(f"unsupported transfer list version: {version}")
    if len(lines) < 2 or not re.fullmatch(r"[0-9]+", lines[1]):
        raise ValueError("transfer list has no valid total block count")
    total_blocks = int(lines[1])

    # Header length differs across transfer-list versions/build tools. Find the first command
    # rather than relying on a fixed number of header lines.
    commands = {"new", "zero", "erase", "free", "stash", "move", "bsdiff", "imgdiff", "newfs"}
    command_start = next(
        (index for index, line in enumerate(lines[1:], 1) if line.split(" ", 1)[0] in commands),
        None,
    )
    if command_start is None:
        raise ValueError("transfer list has no supported commands")

    command_lines = lines[command_start:]
    operations = []
    for line in command_lines:
        parts = line.split(" ", 1)
        operation = parts[0]
        ranges = parse_ranges(parts[1]) if len(parts) == 2 else []
        operations.append((operation, ranges))
        for _, end in ranges:
            if end > total_blocks:
                raise ValueError(f"range exceeds transfer-list block count: {end} > {total_blocks}")

    zero_chunk = b"\0" * (4 * 1024 * 1024)
    with open(payload_path, "rb") as payload_file, open(output_path, "wb") as output:
        output.truncate(total_blocks * BLOCK_SIZE)
        for operation, ranges in operations:
            if operation == "new":
                copy_ranges(output, ranges, payload_file)
            elif operation in ("zero", "erase"):
                for start, end in ranges:
                    output.seek(start * BLOCK_SIZE)
                    remaining = (end - start) * BLOCK_SIZE
                    while remaining:
                        chunk = zero_chunk[: min(len(zero_chunk), remaining)]
                        output.write(chunk)
                        remaining -= len(chunk)
            elif operation in ("free", "stash", "move", "bsdiff", "imgdiff", "newfs"):
                raise ValueError(f"unsupported operation in full image: {operation}")
            else:
                raise ValueError(f"unknown transfer operation: {operation}")

        if payload_file.read(1):
            raise ValueError("new.dat has unused bytes")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"sdat2img: {error}", file=sys.stderr)
        raise SystemExit(1)

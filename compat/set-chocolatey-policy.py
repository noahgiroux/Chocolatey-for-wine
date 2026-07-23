#!/usr/bin/env python3
"""Apply CFW's canonical Chocolatey feature policy to a prepared prefix."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import tempfile
import xml.etree.ElementTree as ET


class PolicyError(RuntimeError):
    """Raised when policy cannot be applied without weakening prefix integrity."""


def _open_regular_nofollow(path: Path) -> tuple[int, os.stat_result]:
    flags = (
        os.O_RDONLY
        | os.O_NONBLOCK
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        raise PolicyError(f"cannot open regular file without following links: {path}: {exc}") from exc
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode):
        os.close(descriptor)
        raise PolicyError(f"path is not a regular file: {path}")
    return descriptor, info


def _assert_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise PolicyError(f"cannot inspect directory: {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise PolicyError(f"directory must be real and non-symlinked: {path}")


def _assert_optional_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise PolicyError(f"cannot inspect directory: {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise PolicyError(f"directory must be absent or real and non-symlinked: {path}")


def _assert_no_symlink_components(path: Path) -> None:
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        try:
            info = current.lstat()
        except OSError as exc:
            raise PolicyError(f"cannot inspect path component: {current}: {exc}") from exc
        if stat.S_ISLNK(info.st_mode):
            raise PolicyError(f"path component must not be a symlink: {current}")


def _assert_optional_regular(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise PolicyError(f"cannot inspect path: {path}: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise PolicyError(f"path must be absent or a regular file: {path}")


def _write_atomic(path: Path, payload: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.{os.getpid()}.", suffix=".update", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            info = temporary.lstat()
        except FileNotFoundError:
            pass
        else:
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                raise PolicyError(f"refusing to remove unsafe update path: {temporary}")
            temporary.unlink()


def _serialize(root: ET.Element) -> bytes:
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True, short_empty_elements=True) + b"\n"


def _feature(root: ET.Element) -> ET.Element:
    matches = root.findall("./features/feature[@name='powershellHost']")
    if len(matches) != 1:
        raise PolicyError(
            f"expected exactly one Chocolatey powershellHost feature, found {len(matches)}"
        )
    return matches[0]


def _assert_same_inode(path: Path, expected: os.stat_result) -> None:
    current = path.lstat()
    if stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode):
        raise PolicyError(f"Chocolatey config changed to an unsafe path: {path}")
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        raise PolicyError(f"Chocolatey config changed while policy was prepared: {path}")


def verify_status(status_path: Path) -> None:
    lines = status_path.read_text(encoding="utf-8").replace("\r", "").splitlines()
    observations = [
        line.strip().casefold()
        for line in lines
        if line.partition("|")[0].strip().casefold() == "powershellhost"
    ]
    if len(observations) != 1 or observations[0] not in {
        "powershellhost|disabled",
        "powershellhost|false",
    }:
        raise PolicyError(
            "expected exactly one disabled Chocolatey powershellHost observation, "
            f"found {observations}"
        )


def seed_policy(template_path: Path, config_path: Path) -> None:
    template_path = template_path.absolute()
    config_path = config_path.absolute()
    chocolatey_root = config_path.parent.parent
    parent = config_path.parent

    _assert_no_symlink_components(template_path)
    template_descriptor, _ = _open_regular_nofollow(template_path)
    with os.fdopen(template_descriptor, "rb") as stream:
        template = stream.read()
    try:
        root = ET.fromstring(template)
    except ET.ParseError as exc:
        raise PolicyError(f"malformed Chocolatey config template: {exc}") from exc
    if root.tag != "chocolatey":
        raise PolicyError(f"unexpected Chocolatey config template root: {root.tag}")
    feature = _feature(root)
    if feature.get("enabled") != "false" or feature.get("setExplicitly") != "true":
        raise PolicyError("Chocolatey config template does not disable powershellHost explicitly")

    _assert_no_symlink_components(chocolatey_root)
    _assert_directory(chocolatey_root)
    _assert_optional_directory(parent)
    parent.mkdir(mode=0o755, exist_ok=True)
    _assert_directory(parent)
    _assert_optional_regular(config_path)
    if config_path.exists():
        apply_policy(config_path)
        return

    _write_atomic(config_path, template)
    verify_descriptor, _ = _open_regular_nofollow(config_path)
    with os.fdopen(verify_descriptor, "rb") as stream:
        verified_root = ET.fromstring(stream.read())
    verified = _feature(verified_root)
    if verified.get("enabled") != "false" or verified.get("setExplicitly") != "true":
        raise PolicyError("seeded Chocolatey powershellHost policy is not canonical")

    directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def apply_policy(config_path: Path) -> None:
    config_path = config_path.absolute()
    parent = config_path.parent
    backup_path = Path(f"{config_path}.backup")
    _assert_no_symlink_components(config_path)
    _assert_directory(parent)
    _assert_optional_regular(backup_path)

    descriptor, original_info = _open_regular_nofollow(config_path)
    with os.fdopen(descriptor, "rb") as stream:
        original = stream.read()

    try:
        root = ET.fromstring(original)
    except ET.ParseError as exc:
        raise PolicyError(f"malformed Chocolatey config: {exc}") from exc
    if root.tag != "chocolatey":
        raise PolicyError(f"unexpected Chocolatey config root: {root.tag}")

    feature = _feature(root)
    feature.set("enabled", "false")
    feature.set("setExplicitly", "true")
    updated = _serialize(root)

    _assert_same_inode(config_path, original_info)
    _write_atomic(backup_path, original)
    _assert_same_inode(config_path, original_info)
    _write_atomic(config_path, updated)

    verify_descriptor, _ = _open_regular_nofollow(config_path)
    with os.fdopen(verify_descriptor, "rb") as stream:
        verified_root = ET.fromstring(stream.read())
    verified = _feature(verified_root)
    if verified.get("enabled") != "false" or verified.get("setExplicitly") != "true":
        raise PolicyError("persisted Chocolatey powershellHost policy is not canonical")

    directory_descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("config", type=Path)
    seed_parser = subparsers.add_parser("seed")
    seed_parser.add_argument("template", type=Path)
    seed_parser.add_argument("config", type=Path)
    verify_parser = subparsers.add_parser("verify-status")
    verify_parser.add_argument("status", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "apply":
            apply_policy(args.config)
        elif args.command == "seed":
            seed_policy(args.template, args.config)
        else:
            verify_status(args.status)
    except (OSError, PolicyError) as exc:
        parser.exit(70, f"[cfw] Chocolatey policy failed: {exc}\n")
    print(f"[cfw] chocolatey policy {args.command} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

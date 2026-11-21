#!/usr/bin/env python3
"""Bundle extra plugin packages into the composed iOS runtime archive.

The phone runs a *pre-installed* node_modules tree (dsh-runtime/runtime.zip);
there is no npm on device, so anything that should be available in 本机 mode has
to be baked in at build time.

    bundle-plugins.py <runtime-tree> <addons-node_modules> [plugin ...]

<runtime-tree>  unpacked runtime.zip: manifest.json + files/
<addons-node_modules>  a node_modules tree produced elsewhere by `npm install`
[plugin ...]    package names to add to the shipped `web` profile template

Steps: merge the addons into files/node_modules (never overwriting what is
already there), extend PROFILE_TEMPLATES.web.bundles in
@deepseek-ai/dsh-official-bundles, rebuild manifest.json, rewrite runtime.zip.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

TEMPLATE_PACKAGE = "@deepseek-ai/dsh-official-bundles"
TEMPLATE_FILE = "lib/index.js"


def log(message: str) -> None:
    print(f"bundle-plugins: {message}", file=sys.stderr)


def merge_tree(src: Path, dst: Path) -> None:
    """Copy entries missing from dst; recurse into scope directories (@scope/x).

    pnpm links every package to its content-addressable store, so the real
    directory is resolved before copying; a link is never recreated.
    """
    for entry in sorted(src.iterdir()):
        if entry.name in {".bin", ".package-lock.json"} or entry.name.startswith("."):
            continue
        try:
            real = entry.resolve(strict=True)
        except OSError:
            continue
        if not real.is_dir():
            continue
        target = dst / entry.name
        if entry.name.startswith("@"):
            target.mkdir(exist_ok=True)
            merge_tree(real, target)
            continue
        if target.exists():
            continue
        shutil.copytree(real, target, symlinks=False)


def installed_packages(node_modules: Path) -> set[str]:
    names: set[str] = set()
    for entry in node_modules.iterdir():
        if entry.is_symlink() or not entry.is_dir():
            continue
        if entry.name.startswith("@"):
            for inner in entry.iterdir():
                if inner.is_dir() and not inner.is_symlink():
                    names.add(f"{entry.name}/{inner.name}")
        elif not entry.name.startswith("."):
            names.add(entry.name)
    return names


def patch_web_template(node_modules: Path, plugins: list[str]) -> list[str]:
    template = node_modules / TEMPLATE_PACKAGE / TEMPLATE_FILE
    if not template.is_file():
        log(f"template package missing: {template}")
        return []
    available = installed_packages(node_modules)
    usable = [name for name in plugins if name in available]
    dropped = [name for name in plugins if name not in available]
    if dropped:
        log(f"not installed, left out: {', '.join(dropped)}")
    if not usable:
        log("no plugin to add to the web template")
        return []

    text = template.read_text(encoding="utf-8")
    match = re.search(r'web:\s*\{\s*bundles:\s*\[(?P<body>[^\]]*)\]\s*\}', text)
    if match is None:
        log("web template not found; leaving the bundle list alone")
        return []
    body = match.group("body")
    present = set(re.findall(r'"([^"]+)"', body))
    additions = [f'"{name}"' for name in usable if name not in present]
    if not additions:
        log("web template already lists every plugin")
        return usable
    rewritten = f"web: {{ bundles: [{body.rstrip()}{'' if body.rstrip().endswith(',') or not body.strip() else ','} {', '.join(additions)}] }}"
    template.write_text(text[: match.start()] + rewritten + text[match.end() :], encoding="utf-8")
    log(f"web template bundles += {', '.join(usable)}")
    return usable


def rebuild_manifest(tree: Path, previous: dict) -> dict:
    files = tree / "files"
    entries = []
    for path in sorted(files.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        rel = path.relative_to(files).as_posix()
        payload = path.read_bytes()
        entries.append(
            {"path": rel, "sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)}
        )
    manifest = {
        "dshVersion": previous.get("dshVersion"),
        "files": entries,
        "nodeVersion": previous.get("nodeVersion"),
        "runtimeVersion": previous.get("runtimeVersion"),
        "schema": previous.get("schema"),
    }
    log(f"manifest: {len(previous.get('files', []))} -> {len(entries)} files")
    return manifest


def write_archive(tree: Path, manifest: dict, destination: Path) -> None:
    temporary = destination.with_suffix(".zip.partial")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False, separators=(",", ":")))
        files = tree / "files"
        for path in sorted(files.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            archive.write(path, "files/" + path.relative_to(files).as_posix())
    temporary.replace(destination)
    log(f"archive: {destination} ({destination.stat().st_size} bytes)")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    tree = Path(argv[1]).resolve()
    addons = Path(argv[2]).resolve()
    plugins = argv[3:]

    manifest_path = tree / "manifest.json"
    if not manifest_path.is_file():
        log(f"no manifest.json in {tree}")
        return 1
    previous = json.loads(manifest_path.read_text(encoding="utf-8"))

    node_modules = tree / "files" / "node_modules"
    if not node_modules.is_dir():
        log(f"no node_modules in {tree}")
        return 1
    if addons.is_dir():
        merge_tree(addons, node_modules)
    added = patch_web_template(node_modules, plugins)

    manifest = rebuild_manifest(tree, previous)
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    write_archive(tree, manifest, Path(os.environ.get("RUNTIME_ZIP_OUT", tree.parent / "runtime.zip")))

    summary = Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None
    if summary is not None:
        with summary.open("a", encoding="utf-8") as handle:
            handle.write("\n### On-device plugins\n\n")
            handle.write(f"- added to the `web` profile template: {', '.join(added) if added else '(none)'}\n")
            handle.write(f"- runtime files: {len(manifest['files'])}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

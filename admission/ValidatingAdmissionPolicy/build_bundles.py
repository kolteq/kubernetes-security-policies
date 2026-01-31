#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import shutil
import tarfile
import tempfile
import zipfile
from pathlib import Path
import yaml

ID_RE = re.compile(
    r"policies\.kolteq\.com/validatingAdmissionPolicy:\s*([0-9a-f\-]+)",
    re.IGNORECASE,
)
LABEL_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9_.-]{0,61}[A-Za-z0-9])?$")
DNS_LABEL_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
BUNDLES_INDEX_NAME = "bundles.json"


def index_policy_files(root: Path):
    id_to_paths = {}
    for path in list(root.glob("policies/**/policy.yaml")) + list(
        root.glob("policies/**/binding.yaml")
    ):
        text = path.read_text()
        for policy_id in ID_RE.findall(text):
            id_to_paths.setdefault(policy_id, set()).add(path)
    return id_to_paths


def read_bundle(bundle_path: Path):
    data = json.loads(bundle_path.read_text())
    if isinstance(data, dict):
        name = data.get("name") or bundle_path.stem
        description = (data.get("description") or "").strip()
        policy_ids = data.get("policies", [])
    else:
        name = bundle_path.stem
        description = ""
        policy_ids = data
    return name, description, policy_ids


def collect_bundle_paths(bundles_dir: Path) -> list[Path]:
    return [
        path
        for path in sorted(bundles_dir.glob("*.json"))
        if path.name != BUNDLES_INDEX_NAME
    ]


def write_bundles_index(bundles_dir: Path, bundle_paths: list[Path]):
    names = [path.stem for path in bundle_paths]
    names = sorted(set(names), key=str.casefold)
    index_path = bundles_dir / BUNDLES_INDEX_NAME
    index_path.write_text(json.dumps(names, indent=4) + "\n")


def is_valid_label_key(label: str) -> bool:
    if "/" in label:
        prefix, name = label.split("/", 1)
        if not prefix or not name:
            return False
        if len(prefix) > 253 or len(name) > 63:
            return False
        for part in prefix.split("."):
            if not part or len(part) > 63 or not DNS_LABEL_RE.match(part):
                return False
    else:
        name = label
        if len(name) > 63:
            return False
    return bool(LABEL_RE.match(name))


def sanitize_label(label: str) -> str:
    slug = label.replace("/", "-")
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "-", slug)
    return slug.strip("-") or "bundle"


def write_readme(bundle_dir: Path, name: str, description: str, bundle_slug: str):
    lines = [f"# {name}", ""]
    if description:
        lines.append(description)
        lines.append("")
    lines.extend(
        [
            "Apply:",
            "```bash",
            "kubectl apply -f policies/ --recursive",
            "```",
            "",
            "View online:",
            f"https://kolteq.com/policies/bundles/{bundle_slug.lower()}",
            "",
            "Contact us:",
            "https://kolteq.com",
            "",
        ]
    )
    (bundle_dir / "README.md").write_text("\n".join(lines))


def write_checksum(archive_path: Path):
    hasher = hashlib.sha256()
    with archive_path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    checksum_path = archive_path.with_suffix(archive_path.suffix + ".sha256")
    checksum_path.write_text(f"{hasher.hexdigest()}  {archive_path.name}\n")


def build_bundle(root: Path, bundle_path: Path, id_to_paths, out_dir: Path):
    name, description, policy_ids = read_bundle(bundle_path)
    bundle_slug = bundle_path.stem

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_root = Path(tmpdir)
        bundle_dir = tmp_root / bundle_slug
        bundle_dir.mkdir(parents=True, exist_ok=True)

        files = set()
        for policy_id in policy_ids:
            for path in id_to_paths.get(policy_id, []):
                files.add(path)

        policies_root = root / "policies"
        policies_dir = bundle_dir / "policies"
        for path in sorted(files):
            rel = path.relative_to(policies_root)
            dest = policies_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)

        write_readme(bundle_dir, name, description, bundle_slug)

        tar_path = out_dir / f"{bundle_slug}.tar.gz"
        with tarfile.open(tar_path, "w:gz") as tar:
            tar.add(bundle_dir, arcname=bundle_slug)
        write_checksum(tar_path)

        zip_path = out_dir / f"{bundle_slug}.zip"
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for file_path in bundle_dir.rglob("*"):
                if file_path.is_file():
                    zf.write(file_path, file_path.relative_to(tmp_root))
        write_checksum(zip_path)


def build_bundle_json_from_labels(
    root: Path,
    bundles_dir: Path,
    labels: list[str],
    output: Path | None,
    name: str | None,
    description: str | None,
    deployment: str | None,
):
    for label in labels:
        if not is_valid_label_key(label):
            raise SystemExit(f"invalid Kubernetes label key: {label}")

    policy_ids = set()
    label_set = set(labels)
    for path in root.glob("policies/**/policy.yaml"):
        text = path.read_text()
        doc = yaml.safe_load(text)
        if not isinstance(doc, dict):
            continue
        labels_map = doc.get("metadata", {}).get("labels", {})
        if not isinstance(labels_map, dict):
            continue
        if set(labels_map.keys()) & label_set:
            policy_ids.update(ID_RE.findall(text))

    if not policy_ids:
        raise SystemExit(f"no policies found for labels: {', '.join(labels)}")

    bundle_slug = sanitize_label("+".join(labels))
    bundle_path = output or (bundles_dir / f"{bundle_slug}.json")

    default_deployment = (
        "mkdir -p /tmp/kolteq && curl -L https://github.com/kolteq/kubernetes-security-policies/releases/latest/download/"
        f"{bundle_slug}.tar.gz | tar -xz -C /tmp/kolteq && kubectl apply -f /tmp/kolteq/{bundle_slug} --recursive"
    )
    sources = [
        f"https://github.com/kolteq/kubernetes-security-policies/releases/latest/download/{bundle_slug}.tar.gz",
        f"https://github.com/kolteq/kubernetes-security-policies/releases/latest/download/{bundle_slug}.zip",
    ]
    data = {
        "name": name or ", ".join(labels),
        "description": description or f"Bundle generated for labels: {', '.join(labels)}.",
        "deployment": deployment or default_deployment,
        "sources": sources,
        "policies": sorted(policy_ids),
    }
    bundle_path.write_text(json.dumps(data, indent=4) + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Build bundle archives or generate bundle JSON from a label."
    )
    parser.add_argument(
        "--labels",
        nargs="+",
        help="Kubernetes label keys to generate a bundle JSON from policy metadata.labels.",
    )
    parser.add_argument(
        "--build",
        action="store_true",
        help="Build zip/tar.gz for all bundles/*.json.",
    )
    parser.add_argument(
        "--output",
        help="Output bundle JSON path when using --label.",
    )
    parser.add_argument("--name", help="Bundle name when using --label.")
    parser.add_argument("--description", help="Bundle description when using --label.")
    parser.add_argument("--deployment", help="Deployment command when using --label.")
    args = parser.parse_args()

    if not args.labels and not args.build:
        parser.error("one of --labels or --build is required")

    root = Path(__file__).resolve().parent
    bundles_dir = root / "bundles"

    if args.labels:
        output = Path(args.output) if args.output else None
        build_bundle_json_from_labels(
            root,
            bundles_dir,
            args.labels,
            output,
            args.name,
            args.description,
            args.deployment,
        )

    if args.build:
        out_dir = bundles_dir
        id_to_paths = index_policy_files(root)
        bundle_paths = collect_bundle_paths(bundles_dir)
        write_bundles_index(bundles_dir, bundle_paths)
        for bundle_path in bundle_paths:
            build_bundle(root, bundle_path, id_to_paths, out_dir)


if __name__ == "__main__":
    main()

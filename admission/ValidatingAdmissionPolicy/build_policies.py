#!/usr/bin/env python3
import hashlib
import tarfile
import zipfile
from pathlib import Path


def write_checksum(archive_path: Path):
    hasher = hashlib.sha256()
    with archive_path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    checksum_path = archive_path.with_suffix(archive_path.suffix + ".sha256")
    checksum_path.write_text(f"{hasher.hexdigest()}  {archive_path.name}\n")


def build_archives(root: Path):
    policies_dir = root / "policies"
    if not policies_dir.exists():
        raise SystemExit(f"policies directory not found: {policies_dir}")

    tar_path = policies_dir / "policies.tar.gz"
    def tar_filter(tarinfo: tarfile.TarInfo) -> tarfile.TarInfo | None:
        if Path(tarinfo.name) == Path("policies/policies.json"):
            return None
        return tarinfo

    with tarfile.open(tar_path, "w:gz") as tar:
        tar.add(policies_dir, arcname="policies", filter=tar_filter)
    write_checksum(tar_path)

    zip_path = policies_dir / "policies.zip"
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for file_path in policies_dir.rglob("*"):
            if file_path.is_file():
                if file_path == policies_dir / "policies.json":
                    continue
                zf.write(file_path, file_path.relative_to(policies_dir))
    write_checksum(zip_path)


def main():
    root = Path(__file__).resolve().parent
    build_archives(root)


if __name__ == "__main__":
    main()

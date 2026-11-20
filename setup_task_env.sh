#!/usr/bin/env bash
# Prepare a reproducible Docling 1.20.0 task environment.
#
# Run this once with network access:
#
#   ./setup_task_env.sh
#
# For the full OCR test suite, install Tesseract and its language packs too:
#
#   ./setup_task_env.sh --with-tesseract
#
# The script creates .venv/ and uses the normal Hugging Face and EasyOCR
# caches in the user's home directory. After it completes, the fixture PDFs and
# the test suite can run without downloading packages or models.
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-$SCRIPT_DIR/.cache/poetry-bootstrap}"
WITH_TESSERACT=0
FORCE_MODELS=0
SKIP_WARMUP=0
SKIP_OFFLINE_CHECK=0

# Interpreter and system-tool versions are deliberately locked. Do not loosen
# these to "3.11.x" or "5.x": the point is that every rebuild uses the same
# system-level versions.
PYTHON_VERSION="3.11.9"
TESSERACT_VERSION="5.3.0"

usage() {
    cat <<'EOF'
Usage: ./setup_task_env.sh [options]

Options:
  --with-tesseract       Install Tesseract, the eng/fra/deu/spa language packs,
                         and the optional tesserocr package for full OCR tests.
  --force-models         Re-download the pinned model files even if cached.
  --skip-warmup          Do not run the one-document conversion check.
  --skip-offline-check   Do not repeat the conversion with offline env vars set.
  -h, --help             Show this help.

Environment overrides:
  PYTHON_BIN             Python executable (default: python3.11, then python3)
  VENV_DIR               Task virtualenv directory (default: <repo>/.venv)
  BOOTSTRAP_DIR          Poetry bootstrap directory (default: <repo>/.cache/poetry-bootstrap)
EOF
}

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --with-tesseract)
            WITH_TESSERACT=1
            ;;
        --force-models)
            FORCE_MODELS=1
            ;;
        --skip-warmup)
            SKIP_WARMUP=1
            ;;
        --skip-offline-check)
            SKIP_OFFLINE_CHECK=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cd "$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-python3.11}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN="python3"
fi
command -v "$PYTHON_BIN" >/dev/null 2>&1 \
    || die "No Python interpreter found. Set PYTHON_BIN to a Python 3.10+ executable."

PYTHON_VERSION="$PYTHON_VERSION" "$PYTHON_BIN" - <<'PY' || die "The selected interpreter does not match the locked Python version."
import os
import sys

wanted = tuple(int(part) for part in os.environ["PYTHON_VERSION"].split("."))
got = sys.version_info[:3]
if got != wanted:
    raise SystemExit(
        f"Python is locked to {os.environ['PYTHON_VERSION']}, "
        f"but {sys.version.split()[0]} was selected"
    )
print(f"Using Python {sys.version.split()[0]}")
PY

SYSTEM_PYTHON_VERSION="$("$PYTHON_BIN" --version 2>&1)"
log "System Python: $SYSTEM_PYTHON_VERSION ($(command -v "$PYTHON_BIN"))"
log "Locked Python: $PYTHON_VERSION"

tesseract_version() {
    tesseract --version 2>&1 | awk '/^tesseract / {print $2; exit}' || true
}

if command -v tesseract >/dev/null 2>&1; then
    INSTALLED_TESSERACT_VERSION="$(tesseract_version)"
    log "System Tesseract: $INSTALLED_TESSERACT_VERSION (locked: $TESSERACT_VERSION)"
    if [ "$WITH_TESSERACT" -eq 1 ] && [ "$INSTALLED_TESSERACT_VERSION" != "$TESSERACT_VERSION" ]; then
        die "Tesseract is locked to $TESSERACT_VERSION, but $INSTALLED_TESSERACT_VERSION is installed. Install the locked version or use a matching Debian bookworm environment."
    fi
else
    log "System Tesseract: not installed (locked: $TESSERACT_VERSION)"
fi

log "Creating the task virtualenv at $VENV_DIR"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi
TASK_PY="$VENV_DIR/bin/python"
TASK_PY_VERSION="$("$TASK_PY" -c 'import platform; print(platform.python_version())')"
if [ "$TASK_PY_VERSION" != "$PYTHON_VERSION" ]; then
    die "Task Python is $TASK_PY_VERSION, but the lock requires $PYTHON_VERSION"
fi
log "Task Python: Python $TASK_PY_VERSION (locked)"
"$TASK_PY" -m pip install --upgrade pip

log "Preparing Poetry 1.8.3 from the lock file"
if [ ! -x "$BOOTSTRAP_DIR/bin/python" ]; then
    "$PYTHON_BIN" -m venv "$BOOTSTRAP_DIR"
fi
BOOTSTRAP_PY="$BOOTSTRAP_DIR/bin/python"
POETRY="$BOOTSTRAP_DIR/bin/poetry"
if ! "$POETRY" --version >/dev/null 2>&1; then
    "$BOOTSTRAP_PY" -m pip install --upgrade pip
    "$BOOTSTRAP_PY" -m pip install "poetry==1.8.3"
fi
"$POETRY" --version
"$POETRY" check --lock

install_tesseract() {
    if command -v tesseract >/dev/null 2>&1; then
        INSTALLED_TESSERACT_VERSION="$(tesseract_version)"
        if [ "$INSTALLED_TESSERACT_VERSION" = "$TESSERACT_VERSION" ] \
            && tesseract --list-langs 2>/dev/null | grep -qx 'eng' \
            && tesseract --list-langs 2>/dev/null | grep -qx 'fra' \
            && tesseract --list-langs 2>/dev/null | grep -qx 'deu' \
            && tesseract --list-langs 2>/dev/null | grep -qx 'spa'; then
            log "Tesseract $TESSERACT_VERSION and lang packs are already installed"
            return
        fi
    fi

    log "Installing Tesseract and language packs"
    if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
        brew install tesseract tesseract-lang
    elif command -v apt-get >/dev/null 2>&1; then
        SUDO=()
        if [ "$(id -u)" -ne 0 ]; then
            command -v sudo >/dev/null 2>&1 \
                || die "Root privileges are required to install Tesseract."
            SUDO=(sudo)
        fi
        "${SUDO[@]}" apt-get update
        "${SUDO[@]}" apt-get install -y \
            tesseract-ocr \
            tesseract-ocr-eng \
            tesseract-ocr-fra \
            tesseract-ocr-deu \
            tesseract-ocr-spa \
            libtesseract-dev \
            libleptonica-dev \
            pkg-config
    else
        die "Tesseract needs Homebrew (macOS) or apt-get (Debian/Ubuntu). Install it manually, then rerun with --with-tesseract."
    fi

    command -v tesseract >/dev/null 2>&1 \
        || die "Tesseract installation did not produce the tesseract command."
    INSTALLED_TESSERACT_VERSION="$(tesseract_version)"
    log "System Tesseract: $INSTALLED_TESSERACT_VERSION (locked: $TESSERACT_VERSION)"
    if [ "$INSTALLED_TESSERACT_VERSION" != "$TESSERACT_VERSION" ]; then
        die "Tesseract is locked to $TESSERACT_VERSION, but the package manager installed $INSTALLED_TESSERACT_VERSION. Install the locked version or use a matching Debian bookworm environment."
    fi
    for lang in eng fra deu spa; do
        tesseract --list-langs 2>/dev/null | grep -qx "$lang" \
            || die "Tesseract language pack '$lang' is missing."
    done
}

if [ "$WITH_TESSERACT" -eq 1 ]; then
    install_tesseract
fi

log "Installing locked Python dependencies into $VENV_DIR"
export VIRTUAL_ENV="$VENV_DIR"
export POETRY_VIRTUALENVS_CREATE=false
export POETRY_VIRTUALENVS_IN_PROJECT=false
export POETRY_NO_INTERACTION=1

"$POETRY" install --no-interaction --no-ansi --without examples

if [ "$WITH_TESSERACT" -eq 1 ]; then
    log "Installing the tesserocr extra"
    "$POETRY" install --no-interaction --no-ansi --without examples -E tesserocr
fi

# The task agent edits the checkout, not a site-packages copy. Verify that the
# import resolves to this checkout; if Poetry installed a non-editable copy,
# replace it with an editable install that does not touch the locked deps.
if ! "$TASK_PY" - <<'PY'
from pathlib import Path
import docling

source = Path(docling.__file__).resolve()
root = Path.cwd().resolve()
if root not in source.parents:
    raise SystemExit(f"docling imported from {source}, expected {root}")
print(f"docling source: {source}")
PY
then
    log "Installing the checkout in editable mode"
    "$TASK_PY" -m pip install --no-deps -e "$SCRIPT_DIR"
fi

"$TASK_PY" - <<'PY'
from importlib.metadata import version

expected = {
    "docling": "1.20.0",
    "docling-core": "1.7.2",
    "docling-ibm-models": "2.0.0",
    "deepsearch-glm": "0.22.0",
    "easyocr": "1.7.2",
    "click": "8.1.7",
    "typer": "0.12.5",
}
for name, wanted in expected.items():
    got = version(name)
    if got != wanted:
        raise SystemExit(f"{name}: expected {wanted}, got {got}")
    print(f"{name}: {got}")
PY

log "Downloading and verifying pinned Docling, DeepSearch, and EasyOCR models"
CERT_BUNDLE="$("$TASK_PY" -c 'import certifi; print(certifi.where())')"
export SSL_CERT_FILE="$CERT_BUNDLE"
export REQUESTS_CA_BUNDLE="$CERT_BUNDLE"
export CURL_CA_BUNDLE="$CERT_BUNDLE"
FORCE_MODELS="$FORCE_MODELS" "$TASK_PY" - <<'PY'
import hashlib
import os
from pathlib import Path

DOCLING_REVISION = "v2.0.0"
DOCLING_COMMIT = "2bdc831fd1edeb61e6d0dfc8ae7596b0c30bdff4"

DOCLING_SHA256 = {
    "model_artifacts/layout/beehive_v0.0.5_pt/model.pt":
        "87449b75a37de440eb95a7453fe0c8a83bcd9257a041355fd5fbfbb4f32fc160",
    "model_artifacts/tableformer/otslp_all_fast.check":
        "3299cbfd5071aa8414e1fdc5d2703f1061f557d28c741ae28c0a9098a5f67872",
    "model_artifacts/tableformer/fat/otslp_all_standard_094_clean.check":
        "eb5ee88f5e411e2a7925837c05de5236bee1934569433b4ab58371ffba3f1da6",
}

DEEPSEARCH_SHA256 = {
    "crf/part-of-speech/crf_pos_model_en.bin":
        "d74db5e360dea976e8a88221f7607822ea4178bfa6907f634962bbaa6b5049a7",
    "crf/reference/crf_reference.bin":
        "1c5d33eb9cea9cd0574429d444f414392b7f6d441629074aa5c0dbbf1586f75e",
    "crf/ucmi/crf_material.bin":
        "a70a3d4a1cf490ecf8ecf75c1dc91ed0cde0180fa56b036d14a762309d388c11",
    "fasttext/language/fst_language.bin":
        "7e69ec5451bc261cc7844e49e4792a85d7f09c06789ec800fc4a44aec362764e",
    "fasttext/metadata/fst_author.bin":
        "fc4fed0154f9b7c1294ad5eab725b13e4ee18095048e8128aa3d547624d29fa3",
    "fasttext/person-name/fst_person_name.bin":
        "998cffe47670d2534ff49f217609f8750649c1fab2143c58da304e4f6388871c",
    "fasttext/semantic/fst_semantic.bin":
        "2edabe277798e3d2445920237699de81ecd00e5270b7b337faf0e844f4378515",
    "rgx/geoloc/rgx_geoloc.json":
        "9792868b6f7d7b558beeaf36a97b501972d78892cfa29b1c38a768ac8bd7a8a8",
}

EASYOCR_MD5 = {
    "craft_mlt_25k.pth": "2f8227d2def4037cdb3b34389dcf9ec1",
    "english_g2.pth": "5864788e1821be9e454ec108d61b887d",
    "latin_g2.pth": "469869130aad1a34e8f9086f4262bc59",
}

force = os.environ.get("FORCE_MODELS") == "1"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_hashes(root: Path, expected: dict[str, str]) -> None:
    for relative, wanted in expected.items():
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"Missing model file: {path}")
        actual = sha256(path)
        if actual != wanted:
            raise SystemExit(
                f"Model checksum mismatch for {path}: expected {wanted}, got {actual}"
            )
        print(f"verified {relative}")


from huggingface_hub import snapshot_download

docling_root = Path(
    snapshot_download(
        repo_id="ds4sd/docling-models",
        revision=DOCLING_REVISION,
        force_download=force,
    )
).resolve()
if docling_root.name != DOCLING_COMMIT:
    raise SystemExit(
        f"Docling model revision {DOCLING_REVISION} resolved to "
        f"{docling_root.name}, expected {DOCLING_COMMIT}"
    )
check_hashes(docling_root, DOCLING_SHA256)

from deepsearch_glm.utils.load_pretrained_models import (
    get_resources_dir,
    load_pretrained_nlp_models,
)

load_pretrained_nlp_models(force=force, verbose=True)
deepsearch_root = Path(get_resources_dir()) / "models"
check_hashes(deepsearch_root, DEEPSEARCH_SHA256)

import easyocr
from easyocr.config import MODULE_PATH
from easyocr.utils import calculate_md5

easyocr_root = Path(MODULE_PATH) / "model"
easyocr.Reader(
    ["en"],
    gpu=False,
    model_storage_directory=str(easyocr_root),
    download_enabled=True,
    verbose=False,
)
easyocr.Reader(
    ["fr", "de", "es", "en"],
    gpu=False,
    model_storage_directory=str(easyocr_root),
    download_enabled=True,
    verbose=False,
)
for filename, wanted in EASYOCR_MD5.items():
    path = easyocr_root / filename
    if not path.is_file():
        raise SystemExit(f"Missing EasyOCR model: {path}")
    actual = calculate_md5(str(path))
    if actual != wanted:
        raise SystemExit(
            f"EasyOCR checksum mismatch for {path}: expected {wanted}, got {actual}"
        )
    print(f"verified EasyOCR {filename}")

print("All pinned models are present.")
PY

if [ "$SKIP_WARMUP" -eq 0 ]; then
    log "Running a one-document conversion warm-up"
    mkdir -p "$SCRIPT_DIR/.cache/warmup"
    "$TASK_PY" -m docling.cli.main \
        "$SCRIPT_DIR/tests/quotes/quote-01-northwind.pdf" \
        --output "$SCRIPT_DIR/.cache/warmup" \
        --no-json --no-txt --no-doctags
fi

if [ "$SKIP_WARMUP" -eq 0 ] && [ "$SKIP_OFFLINE_CHECK" -eq 0 ]; then
    log "Checking that the same conversion works with network access disabled"
    mkdir -p "$SCRIPT_DIR/.cache/warmup-offline"
    HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
        "$TASK_PY" -m docling.cli.main \
        "$SCRIPT_DIR/tests/quotes/quote-01-northwind.pdf" \
        --output "$SCRIPT_DIR/.cache/warmup-offline" \
        --no-json --no-txt --no-doctags
fi

log "Environment ready"
cat <<EOF

Task Python:  $VENV_DIR/bin/python (locked to $PYTHON_VERSION)
Docling CLI:  $VENV_DIR/bin/docling <source> ...
Locked Tesseract: $TESSERACT_VERSION (only required with --with-tesseract)

For an offline test run:
  export HF_HUB_OFFLINE=1
  export TRANSFORMERS_OFFLINE=1
  $VENV_DIR/bin/python -m pytest ...

With --with-tesseract, the tesseract command and tesserocr are installed too.
EOF

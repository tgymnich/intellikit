#!/usr/bin/env bash
# IntelliKit Tools Installer
# Installs tools from Git via pipx (git+https...#subdirectory=<tool>).
# Each tool is installed into its own isolated pipx environment.
# Usage: curl -sSL <install script URL> | bash -s -- [OPTIONS]
#    or: ./install/tools/install.sh [OPTIONS]  (from repo root)
# Pass options after bash -s -- when piping from curl so they reach this script.

set -e

ALL_TOOLS=(accordo kerncap linex metrix nexus rocm_mcp uprof_mcp)
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/AMDResearch/intellikit/main/install/tools/install.sh"
REPO_URL="https://github.com/AMDResearch/intellikit.git"
REF="main"
PIPX_CMD="pipx"
PYTHON_BIN=""
FORCE=false
DRY_RUN=false
# Set only via --tools; empty = install all
TOOL_SELECTION=""

print_usage() {
  echo "IntelliKit Tools Installer"
  echo ""
  echo "Default: install all tools from Git: ${ALL_TOOLS[*]}"
  echo ""
  echo "Usage:"
  echo "  curl -sSL ${INSTALL_SCRIPT_URL} | bash -s -- [OPTIONS]"
  echo "  ./install/tools/install.sh [OPTIONS]   # from repo root"
  echo ""
  echo "Options:"
  echo "  --tools <list>    Comma-separated tools to install only (default: all)."
  echo "                    Example: --tools metrix,linex"
  echo "  --pipx-cmd <cmd>  pipx command (default: pipx). Example: --pipx-cmd 'python3.12 -m pipx'"
  echo "  --python <path>   Python interpreter pipx should build the venvs with."
  echo "                    Example: --python python3.12"
  echo "  --force           Reinstall tools even if already installed (pipx --force)."
  echo "  --repo-url <url>  Git repo URL (default: https://github.com/AMDResearch/intellikit.git)"
  echo "  --ref <ref>       Git branch/tag/commit (default: main)"
  echo "  --dry-run         Print pipx commands without running them"
  echo "  --help, -h        Show this help message and exit"
  echo ""
  echo "Valid tool names: ${ALL_TOOLS[*]}"
  echo ""
  echo "Example (works with pipe; use args so overrides reach bash):"
  echo "  curl -sSL ${INSTALL_SCRIPT_URL} | bash -s -- --tools metrix,nexus --python python3.12 --dry-run"
}

require_arg() {
  local opt="$1"
  local val="$2"
  if [[ -z "${val}" || "${val}" == -* ]]; then
    echo "Missing or invalid value for ${opt}" >&2
    exit 1
  fi
}

tool_is_known() {
  local name="$1"
  local t
  for t in "${ALL_TOOLS[@]}"; do
    [[ "$t" == "$name" ]] && return 0
  done
  return 1
}

# Trim POSIX whitespace from string (parameter expansion).
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Require pipx to be available.
require_pipx() {
  if ! eval "${PIPX_CMD} --version" >/dev/null 2>&1; then
    echo "Error: cannot run: ${PIPX_CMD} --version" >&2
    echo "pipx is required. Install it with one of:" >&2
    echo "  python3 -m pip install --user pipx && python3 -m pipx ensurepath" >&2
    echo "  sudo apt-get install -y pipx        # Debian/Ubuntu" >&2
    echo "  brew install pipx                   # macOS" >&2
    echo "Or pass an alternate launcher with --pipx-cmd 'python3.12 -m pipx'." >&2
    exit 1
  fi
}

# Require Python >= 3.10 for the interpreter pipx will use to build venvs.
# When --python is given we check that interpreter; otherwise we check python3.
require_python_ge_310() {
  local py_exe="${PYTHON_BIN}"

  if [[ -z "$py_exe" ]]; then
    py_exe="python3"
  fi

  if ! command -v "$py_exe" >/dev/null 2>&1; then
    echo "Error: Python interpreter not found: ${py_exe}" >&2
    echo "Pass a valid interpreter with --python (e.g. --python python3.12)." >&2
    exit 1
  fi

  if ! "$py_exe" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
    local ver
    ver="$("$py_exe" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "unknown")"
    echo "Error: ${py_exe} is Python ${ver}, but IntelliKit requires Python 3.10 or newer." >&2
    echo "Pass a newer interpreter with --python (e.g. --python python3.12)." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --help|-h) print_usage; exit 0 ;;
    --tools)
      require_arg "$1" "${2:-}"
      TOOL_SELECTION="$2"
      shift 2
      ;;
    --pipx-cmd)
      require_arg "$1" "${2:-}"
      PIPX_CMD="$2"; shift 2
      ;;
    --python)
      require_arg "$1" "${2:-}"
      PYTHON_BIN="$2"; shift 2
      ;;
    --repo-url)
      require_arg "$1" "${2:-}"
      REPO_URL="$2"; shift 2
      ;;
    --ref)
      require_arg "$1" "${2:-}"
      REF="$2"; shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "" >&2
      print_usage >&2
      exit 1
      ;;
  esac
done

require_pipx
require_python_ge_310

# --- System dependency check for tools with C++ builds ---
# accordo and nexus depend on KernelDB which requires cmake, libdwarf-dev,
# and libzstd-dev to compile. Without these, the install will fail during
# the C++ build step.
needs_native_deps() {
  local t
  for t in "$@"; do
    [[ "$t" == "accordo" || "$t" == "nexus" ]] && return 0
  done
  return 1
}

check_system_deps() {
  local missing=()
  if ! command -v cmake >/dev/null 2>&1; then
    missing+=(cmake)
  fi
  # Check for libdwarf and libzstd headers (dpkg on Debian/Ubuntu, rpm on Fedora/RHEL)
  if command -v dpkg >/dev/null 2>&1; then
    if ! dpkg -s libdwarf-dev >/dev/null 2>&1; then
      missing+=(libdwarf-dev)
    fi
    if ! dpkg -s libzstd-dev >/dev/null 2>&1; then
      missing+=(libzstd-dev)
    fi
  elif command -v rpm >/dev/null 2>&1; then
    if ! rpm -q libdwarf-devel >/dev/null 2>&1; then
      missing+=(libdwarf-devel)
    fi
    if ! rpm -q libzstd-devel >/dev/null 2>&1; then
      missing+=(libzstd-devel)
    fi
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Error: Missing system packages required by accordo/nexus: ${missing[*]}" >&2
    echo "Install them first:" >&2
    if command -v apt-get >/dev/null 2>&1; then
      echo "  sudo apt-get update && sudo apt-get install -y ${missing[*]}" >&2
    elif command -v dnf >/dev/null 2>&1; then
      echo "  sudo dnf install -y ${missing[*]}" >&2
    elif command -v yum >/dev/null 2>&1; then
      echo "  sudo yum install -y ${missing[*]}" >&2
    else
      echo "  (use your system package manager to install: ${missing[*]})" >&2
    fi
    echo "" >&2
    echo "Without these, the C++ build step for accordo/nexus (via KernelDB) will fail." >&2
    echo "" >&2
    if [[ "$DRY_RUN" == true ]]; then
      echo "Dry run: continuing despite missing system dependencies." >&2
      return 0
    fi
    exit 1
  fi
}

INSTALL_TOOLS=()
if [[ -z "${TOOL_SELECTION}" ]]; then
  INSTALL_TOOLS=("${ALL_TOOLS[@]}")
else
  IFS=',' read -r -a _raw <<< "${TOOL_SELECTION}"
  already_in_install_list() {
    local needle="$1"
    local e
    for e in "${INSTALL_TOOLS[@]}"; do
      [[ "$e" == "$needle" ]] && return 0
    done
    return 1
  }
  for _part in "${_raw[@]}"; do
    _t="$(trim "${_part}")"
    [[ -z "${_t}" ]] && continue
    if ! tool_is_known "${_t}"; then
      echo "Unknown tool: ${_t}" >&2
      echo "Valid tools: ${ALL_TOOLS[*]}" >&2
      exit 1
    fi
    if already_in_install_list "${_t}"; then
      continue
    fi
    INSTALL_TOOLS+=("${_t}")
  done
  unset -f already_in_install_list
  if [[ ${#INSTALL_TOOLS[@]} -eq 0 ]]; then
    echo "No tools to install after parsing --tools." >&2
    exit 1
  fi
fi

# pipx requires the git+ prefix for VCS installs
[[ "$REPO_URL" != git+* ]] && REPO_URL="git+${REPO_URL}"

# Assemble optional pipx install flags
PIPX_FLAGS=""
[[ -n "$PYTHON_BIN" ]] && PIPX_FLAGS+=" --python \"${PYTHON_BIN}\""
[[ "$FORCE" == true ]] && PIPX_FLAGS+=" --force"

# Warn about missing system deps if installing tools that need C++ builds
if needs_native_deps "${INSTALL_TOOLS[@]}"; then
  check_system_deps
fi

for tool in "${INSTALL_TOOLS[@]}"; do
  url="${REPO_URL}@${REF}#subdirectory=${tool}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "Would run: ${PIPX_CMD} install${PIPX_FLAGS} \"${url}\""
  else
    echo "Installing $tool..."
    eval "${PIPX_CMD} install${PIPX_FLAGS} \"${url}\""
  fi
done

if [[ "$DRY_RUN" != true ]]; then
  echo ""
  echo "Done. Installed: ${INSTALL_TOOLS[*]}"
fi

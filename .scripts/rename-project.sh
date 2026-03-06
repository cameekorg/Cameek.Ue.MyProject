#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_OLD_NAME="Cameek.Ue.MyProject"

usage() {
  cat <<'EOF'
Usage:
  .scripts/rename-project.sh <new-name> [--old-name <old-name>] [--dry-run]

Examples:
  .scripts/rename-project.sh Acme.Ue.RenamedProject
  .scripts/rename-project.sh Acme.Ue.RenamedProject --old-name Cameek.Ue.MyProject
  .scripts/rename-project.sh Acme.Ue.RenamedProject --dry-run
EOF
}

error() {
  echo "Error: $*" >&2
  exit 1
}

is_valid_project_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]
}

is_text_file() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    return 0
  fi

  LC_ALL=C grep -Iq . "$file"
}

is_excluded_path() {
  local path="$1"
  case "$path" in
    ./.git|./.git/*|./bin|./bin/*|./obj|./obj/*|./.vs|./.vs/*|./.idea|./.idea/*|./node_modules|./node_modules/*|./.scripts|./.scripts/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

new_name=""
old_name="$DEFAULT_OLD_NAME"
dry_run=0

while (($# > 0)); do
  case "$1" in
    -o|--old-name)
      (($# >= 2)) || error "Missing value for $1"
      old_name="$2"
      shift 2
      ;;
    -n|--dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      error "Unknown option: $1"
      ;;
    *)
      if [[ -z "$new_name" ]]; then
        new_name="$1"
        shift
      else
        error "Unexpected argument: $1"
      fi
      ;;
  esac
done

if [[ -z "$new_name" ]]; then
  usage
  exit 1
fi

if [[ -z "$old_name" ]]; then
  error "--old-name cannot be empty"
fi

if [[ "$new_name" == "$old_name" ]]; then
  error "New name and old name are identical. Nothing to do."
fi

if [[ "$new_name" == *"/"* || "$new_name" == *"\\"* ]]; then
  error "New name cannot contain path separators."
fi

if ! is_valid_project_name "$new_name"; then
  error "New name must be a valid dotted C# identifier (for example: Acme.Ue.MyProject)."
fi

command -v perl >/dev/null 2>&1 || error "perl is required but not found in PATH."

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_root"

content_updates=0

while IFS= read -r -d '' file; do
  if ! is_text_file "$file"; then
    continue
  fi

  if ! LC_ALL=C grep -Fq "$old_name" "$file"; then
    continue
  fi

  ((content_updates += 1))

  if ((dry_run)); then
    echo "[DRY-RUN] update ${file#./}"
    continue
  fi

  OLD_NAME="$old_name" NEW_NAME="$new_name" perl -0777 -i -pe 's/\Q$ENV{OLD_NAME}\E/$ENV{NEW_NAME}/g' "$file"
done < <(find . \
  -type d \( -name .git -o -name bin -o -name obj -o -name .vs -o -name .idea -o -name node_modules -o -name .scripts \) -prune \
  -o -type f -print0)

declare -a paths_to_rename=()

while IFS= read -r -d '' path; do
  if is_excluded_path "$path"; then
    continue
  fi

  base_name="${path##*/}"
  if [[ "$base_name" == *"$old_name"* ]]; then
    paths_to_rename+=("$path")
  fi
done < <(find . -depth -print0)

path_renames=0
for path in "${paths_to_rename[@]}"; do
  base_name="${path##*/}"
  new_base_name="${base_name//$old_name/$new_name}"
  if [[ "$new_base_name" == "$base_name" ]]; then
    continue
  fi

  parent_dir="${path%/*}"
  target_path="${parent_dir}/${new_base_name}"

  if [[ -e "$target_path" ]]; then
    error "Cannot rename ${path#./} to ${target_path#./}: target already exists."
  fi

  ((path_renames += 1))
  if ((dry_run)); then
    echo "[DRY-RUN] rename ${path#./} -> ${target_path#./}"
    continue
  fi

  mv -- "$path" "$target_path"
done

mapfile -t root_projects < <(find . -maxdepth 1 -type f -name '*.csproj' -printf '%P\n' | sort)
mapfile -t root_solutions < <(find . -maxdepth 1 -type f \( -name '*.sln' -o -name '*.slnx' \) -printf '%P\n' | sort)

alignment_renames=0
if (( ${#root_projects[@]} == 1 && ${#root_solutions[@]} > 0 )); then
  project_base_name="${root_projects[0]%.csproj}"

  for solution_file in "${root_solutions[@]}"; do
    solution_ext="${solution_file##*.}"
    expected_solution_name="${project_base_name}.${solution_ext}"
    if [[ "$solution_file" == "$expected_solution_name" ]]; then
      continue
    fi

    if [[ -e "./$expected_solution_name" ]]; then
      error "Cannot align solution name to $expected_solution_name because it already exists."
    fi

    ((alignment_renames += 1))
    if ((dry_run)); then
      echo "[DRY-RUN] align ${solution_file} -> ${expected_solution_name}"
      continue
    fi

    mv -- "./$solution_file" "./$expected_solution_name"
  done
fi

if (( ! dry_run )); then
  declare -a remaining_content=()
  while IFS= read -r -d '' file; do
    if ! is_text_file "$file"; then
      continue
    fi

    if LC_ALL=C grep -Fq "$old_name" "$file"; then
      remaining_content+=("${file#./}")
    fi
  done < <(find . \
    -type d \( -name .git -o -name bin -o -name obj -o -name .vs -o -name .idea -o -name node_modules -o -name .scripts \) -prune \
    -o -type f -print0)

  declare -a remaining_paths=()
  while IFS= read -r -d '' path; do
    if is_excluded_path "$path"; then
      continue
    fi

    base_name="${path##*/}"
    if [[ "$base_name" == *"$old_name"* ]]; then
      remaining_paths+=("${path#./}")
    fi
  done < <(find . -print0)

  if (( ${#remaining_content[@]} > 0 || ${#remaining_paths[@]} > 0 )); then
    echo "Validation failed. Old name is still present."

    if (( ${#remaining_content[@]} > 0 )); then
      echo "Files with remaining content references:"
      for file in "${remaining_content[@]}"; do
        echo "  - $file"
      done
    fi

    if (( ${#remaining_paths[@]} > 0 )); then
      echo "Paths that still contain old name:"
      for path in "${remaining_paths[@]}"; do
        echo "  - $path"
      done
    fi

    exit 2
  fi
fi

if ((dry_run)); then
  echo "Dry-run complete. Files to update: $content_updates, paths to rename: $path_renames, aligned solution names: $alignment_renames."
else
  echo "Rename complete. Updated files: $content_updates, renamed paths: $path_renames, aligned solution names: $alignment_renames."
fi

repo_dir_name="$(basename -- "$repo_root")"
if [[ "$repo_dir_name" == *"$old_name"* ]]; then
  echo "Note: repository directory still contains '$old_name'. Rename the folder manually if needed."
fi

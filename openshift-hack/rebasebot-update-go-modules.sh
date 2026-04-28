#!/usr/bin/env bash

# Rebasebot lifecycle hook that updates Go modules and vendors dependencies.
# Combines the rebasebot builtin update_go_modules hook with the repo-specific
# go.work reconstruction logic from openshift-hack/update-vendor.sh.

set -e
set -o pipefail
set -o nounset

stage_and_commit() {
    if [[ -z "${REBASEBOT_GIT_USERNAME:-}" || -z "${REBASEBOT_GIT_EMAIL:-}" ]]; then
        author_flag=()
    else
        author_flag=(--author="$REBASEBOT_GIT_USERNAME <$REBASEBOT_GIT_EMAIL>")
    fi

    if [[ -n $(git status --porcelain) ]]; then
        git add -A
        git commit "${author_flag[@]}" -q -m "UPSTREAM: <drop>: Updating and vendoring go modules after an upstream rebase"
    fi
}

reset_go_mod_files() {
    while IFS= read -r -d '' go_mod_file; do
        local module_base_path
        module_base_path=$(dirname "$go_mod_file")

        for filename in "go.mod" "go.sum"; do
            local full_path="$module_base_path/$filename"
            if [[ ! -f "$full_path" ]]; then
                continue
            fi
            if ! git checkout "source/$REBASEBOT_SOURCE" -- "$full_path"; then
                echo "go module at $module_base_path is downstream only, skip its resetting"
                break
            fi
        done
    done < <(find . -name 'go.mod' -print0)
}

rebuild_go_work() {
    echo "Rebuilding go.work from go.mod"
    # Reconstruct go.work using the pattern from openshift-hack/update-vendor.sh:
    # - Take the go directive from go.mod as the header
    # - Add workspace entries for . and providers
    # - Append replace directives from go.mod (excluding internal providers replace)
    grep '^go' go.mod > go.work
    go work use .
    go work use providers
    echo -e "\nreplace (" >> go.work
    grep '=>' go.mod | sort | uniq | \
        grep -v "k8s.io/cloud-provider-gcp/providers" | \
        sed 's/replace /\t/' \
        >> go.work
    echo -e ")" >> go.work
}

process_go_workspace_updates() {
    echo "Performing go workspace modules update"

    reset_go_mod_files

    # Rebuild go.work from the updated go.mod rather than resetting it from
    # upstream, because this repo maintains a downstream go.work that differs
    # structurally from upstream (it adds the providers workspace and custom
    # replace directives).
    rebuild_go_work

    echo "Running go work sync"
    if ! go work sync; then
        echo "Unable to run 'go work sync'" >&2
        exit 1
    fi

    echo "Running go work vendor"
    if ! go work vendor; then
        echo "Unable to run 'go work vendor'" >&2
        exit 1
    fi

    echo "Running go mod tidy for providers"
    pushd providers > /dev/null
    go mod tidy
    popd > /dev/null

    echo "Running go mod tidy"
    go mod tidy

    stage_and_commit
}

process_go_mod_updates() {
    echo "Performing go modules update"

    reset_go_mod_files

    while IFS= read -r -d '' go_mod_file; do
        local module_base_path
        module_base_path=$(dirname "$go_mod_file")

        pushd "$module_base_path" > /dev/null || { echo "Failed to cd to $module_base_path" >&2; exit 1; }

        echo "Running go mod tidy for $module_base_path"
        if ! go mod tidy; then
            echo "Unable to run 'go mod tidy' in $module_base_path" >&2
            exit 1
        fi

        echo "Running go mod vendor for $module_base_path"
        if ! go mod vendor; then
            echo "Unable to run 'go mod vendor' in $module_base_path" >&2
            exit 1
        fi

        popd > /dev/null
    done < <(find . -name 'go.mod' -print0)

    stage_and_commit
}

if [[ -z "${REBASEBOT_SOURCE:-}" ]]; then
    echo "The environment variable REBASEBOT_SOURCE is not set." >&2
    exit 1
fi

if [[ -f "go.work" ]]; then
    process_go_workspace_updates
else
    process_go_mod_updates
fi

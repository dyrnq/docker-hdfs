#!/usr/bin/env bash
set -Eeo pipefail

push="${push:-false}"
repo="${repo:-dyrnq}"
dockerfile="${dockerfile:-Dockerfile.debian}"
platforms="${platforms:-linux/amd64,linux/arm64}"
tags=()

while [ $# -gt 0 ]; do
    case "$1" in
        --push)        push="$2"; shift ;;
        --repo)        repo="$2"; shift ;;
        --dockerfile)  dockerfile="$2"; shift ;;
        --platforms)   platforms="$2"; shift ;;
        --tag)         tags+=("$2"); shift ;;
        --*) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

if [ ${#tags[@]} -eq 0 ]; then
    echo "ERROR: at least one --tag required"
    exit 1
fi

tag_args=()
for t in "${tags[@]}"; do
    tag_args+=(--tag "$repo/$t")
done

echo "=== buildx: dockerfile=$dockerfile platforms=$platforms push=$push ==="
printf '  tag: %s\n' "${tags[@]}"

if [ "$push" = "true" ]; then
    docker buildx build \
        --platform "$platforms" \
        --output "type=image,push=true" \
        --file "$dockerfile" \
        "${tag_args[@]}" \
        .
else
    # No push — multi-arch build validation only
    docker buildx build \
        --platform "$platforms" \
        --output "type=image,push=false" \
        --file "$dockerfile" \
        "${tag_args[@]}" \
        .
fi

echo "=== buildx done ==="

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# bundle-s3.sh push <store> <bundle>... <s3://bucket/prefix>: bundles made with
# `determinismo bundle <run> <timeline> <bundle> --store <store>` to S3: the store's blobs
# (sha256/<hex>, content-addressed: a name is its bytes, so one already there is never sent
# again, whichever bundle or run put it) and each bundle's own files (kilobytes) under
# bundles/<its name>/.
# bundle-s3.sh pull <s3://bucket/prefix> <bundle name> <store> <out>: one bundle back: its own
# files into <out>, the blobs its STORED lists into <store> (those missing only), then
# `determinismo bundle fetch <out> <store>` puts each where the bundle names it, checked against
# its digest. Then: cd <out> && determinismo explore --run . --branch <timeline> (on x86-64 with
# KVM and determinismo's module: infra/aws/inspect.sh makes such a machine).
# Needs the AWS CLI with credentials for the bucket; or, for a public bundle (publish-public.sh),
# its HTTPS address as the remote (CloudFront's): curl alone, the bundle's FILES listing its own.
#   infra/host/bundle-s3.sh push ~/bundles/store ~/bundles/nats-1647-64 s3://my-bucket/determinismo
#   infra/host/bundle-s3.sh pull s3://my-bucket/determinismo nats-1647-64 ~/store ~/nats-1647-64
set -euo pipefail
usage() {
  sed -n '3,15p' "$0" >&2
  exit 2
}
[ $# -ge 1 ] || usage
# The bundle publisher's own credentials when this machine has them (an IAM user limited to the
# bundles bucket, profile determinismo-bundles: no login that expires), else the default ones.
if [ -z "${AWS_PROFILE:-}" ] && aws configure list-profiles 2>/dev/null | grep -qx determinismo-bundles; then
  export AWS_PROFILE=determinismo-bundles
fi
command -v aws >/dev/null || { echo "bundle-s3.sh: the AWS CLI (aws) is not installed" >&2; exit 1; }
case $1 in
  push)
    [ $# -ge 4 ] || usage
    store=$2
    remote=${*: -1}
    remote=${remote%/}
    bundles=("${@:3:$#-3}")
    # Blobs: a name present remotely is the same bytes (its digest), so its size is enough.
    aws s3 sync --size-only --exclude '*.part' "$store/sha256" "$remote/sha256"
    for bundle in "${bundles[@]}"; do
      [ -f "$bundle/STORED" ] || { echo "bundle-s3.sh: $bundle has no STORED (made without --store)" >&2; exit 1; }
      aws s3 cp --recursive --quiet "$bundle" "$remote/bundles/$(basename "$bundle")"
      echo "bundle-s3.sh: $bundle -> $remote/bundles/$(basename "$bundle")"
    done
    ;;
  pull)
    [ $# -eq 5 ] || usage
    remote=${2%/}
    name=$3
    store=$4
    out=$5
    [ ! -e "$out" ] || { echo "bundle-s3.sh: $out exists" >&2; exit 1; }
    # From the bucket, or a public bundle's HTTPS address (no listing there: its FILES).
    get() { case $remote in https://*) curl -fsS --retry 5 --create-dirs -o "$2" "$remote/$1" ;; *) aws s3 cp --quiet "$remote/$1" "$2" ;; esac; }
    case $remote in
      https://*)
        get "bundles/$name/FILES" "$out/FILES"
        while read -r file; do get "bundles/$name/$file" "$out/$file"; done < "$out/FILES"
        rm "$out/FILES"
        ;;
      *) aws s3 cp --recursive --quiet "$remote/bundles/$name" "$out" ;;
    esac
    # S3 keeps no file modes: the bundle's one script (bundle-moment.sh's) runnable again.
    [ ! -f "$out/INSPECT.sh" ] || chmod +x "$out/INSPECT.sh"
    mkdir -p "$store/sha256"
    while read -r hex _size path; do
      [ -f "$store/sha256/$hex" ] && continue
      get "sha256/$hex" "$store/sha256/$hex.part"
      mv "$store/sha256/$hex.part" "$store/sha256/$hex"
      echo "bundle-s3.sh: $path ($hex) fetched"
    done < "$out/STORED"
    # The bundle's own explorer (the run's build, which it carries) puts the blobs in place: an
    # inspection machine needs nothing of determinismo installed but its KVM module.
    explorer=$(awk '$3 ~ /^artifacts\/[0-9a-f]+-determinismo$/ { print $1 }' "$out/STORED")
    [ -n "$explorer" ] || { echo "bundle-s3.sh: $name carries no explorer" >&2; exit 1; }
    tool=$(mktemp)
    cp "$store/sha256/$explorer" "$tool"
    chmod +x "$tool"
    "$tool" bundle fetch "$out" "$store"
    rm -f "$tool"
    # S3 keeps no file modes: the programs among the inputs (ELF files: the explorer, the test
    # program its host checks run, as on the recording host) executable again (a NATS host check
    # exited 127 on an inspection machine, its program not executable).
    for file in "$out"/artifacts/*; do
      [ "$(head -c 4 "$file" | od -An -c | tr -d ' ')" = '177ELF' ] && chmod +x "$file"
    done
    ;;
  *) usage ;;
esac

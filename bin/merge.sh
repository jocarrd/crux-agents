#!/usr/bin/env bash
# crux merge — merges a proposal after checking it is the one you think it is.
#
#   crux merge <number> [--admin]
#
# `gh pr merge` resolves the repository from the directory you are in, so a
# correct number in the wrong place merges another project's proposal without
# asking anything. Here it is said out loud what is about to be merged, and
# where, and it stops if something does not add up.

set -uo pipefail

CRUX_HOME="${CRUX_HOME:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export CRUX_HOME
source "$CRUX_HOME/lib/common.sh"

NUM="${1:-}"
[[ -n "$NUM" ]] || die "usage: crux merge <proposal number>"
[[ "$NUM" =~ ^[0-9]+$ ]] || die "the proposal number is an integer, not '$NUM'"

command -v gh >/dev/null || die "gh is needed to talk to the remote"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_DIR" ]] || die "this is not a git repository"

origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
[[ -n "$origin" ]] || die "the repository has no origin: I do not know where to look"
slug="$(echo "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"

data="$(gh pr view "$NUM" --repo "$slug" --json title,state,headRefName,baseRefName,isDraft,mergeable 2>/dev/null || true)"
[[ -n "$data" ]] || die "proposal #$NUM does not exist in $slug — are you in the right repo?"

title="$(echo "$data" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).title))')"
status="$(echo "$data" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).state))')"
branch="$(echo "$data" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).headRefName))')"
base="$(echo "$data" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).baseRefName))')"
draft="$(echo "$data" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.parse(d).isDraft))')"

echo "$slug#$NUM · $title"
echo "  $branch → $base"
echo

[[ "$status" == "OPEN" ]] || die "the proposal is $status, not open"
[[ "$draft" != "true" ]] || die "the proposal is a draft"

dirty="$(git -C "$REPO_DIR" status --porcelain | wc -l)"
[[ "$dirty" -eq 0 ]] || warn "$(count "$dirty" "uncommitted file" "uncommitted files") in the repo (it does not prevent the merge)"

gh pr merge "$NUM" --repo "$slug" --merge --delete-branch "${@:2}"

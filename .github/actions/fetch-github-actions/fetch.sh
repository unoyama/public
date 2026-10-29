#!/usr/bin/env bash
# Fetches @cloudstashhq/github-actions from CodeArtifact and unpacks it at _ci/github-actions, and
# the toolchain manifest (pnpm.json of @cloudstashhq/toolchain, latest) at
# $RUNNER_TEMP/cloudstash-toolchain/pnpm.json, last, unless TOOLCHAIN is false.
# Canonical copy: cloudstashhq/packages-shared packages/github-actions/bootstrap/fetch-github-actions,
# copied verbatim into each consumer. Tests: tests/test_bootstrap_fetch.py there. The action.yml description has the why.
#
# Always writes ready=true|false and toolchain-ready=true|false (the manifest's own outcome, which
# never changes ready, the alarm or the exit), and exits 0 unless REQUIRED is true: a registry outage must never
# turn a deploy red, but a job that cannot work without the package (registry-login before an
# install) fails here, naming the cause, instead of at a later step that only says "not found". On any failure it posts one plain-text line to the alarms channel, when it was given one
# and a token, because the actions that would otherwise report the run are the ones missing. An
# outage fails every workflow a commit triggers at once, so only one run per commit posts: see
# is_leader. TOOLCHAIN (the toolchain input) is true or false, anything else fails the step before
# the package, the manifest or the alarm.
set -uo pipefail

dest="${GITHUB_WORKSPACE}/_ci/github-actions"
tgz="${RUNNER_TEMP}/ga.tgz"
version="${VERSION_INPUT:-}"
[ -n "$version" ] || version="$(tr -d '[:space:]' < "$(dirname "$0")/VERSION" 2>/dev/null)"

# Every GitHub API call is bounded: the fallback must post well inside the caller's
# timeout-minutes. GNU timeout is on ubuntu runners; without it the call runs unbounded.
bounded() { if command -v timeout > /dev/null 2>&1; then timeout 15 "$@"; else "$@"; fi; }

# Whether this run posts the fallback for its commit. The leader is the lowest run id among this
# run's WAVE, the commit's runs whose workflow file, at that commit, references
# fetch-github-actions; this run always counts. A wave is the runs one trigger fired: the same
# event, started within WAVE_SECONDS of this one. A release, prod or cut run lands on a commit
# whose dev push runs finished long before, with lower ids: without the wave they would lead and
# nobody would post. A rerun starts again (run_started_at), so it is its own wave too. Runs of workflows that never fetch (lint, CodeQL, Dependabot's dynamic ones) are
# left out, or one of them could hold the lowest id and nobody would post. Any lookup failure
# makes this run post: a duplicate alarm beats a missing one. A rerun of the leader keeps its run
# id, so it posts again. A workflow that fetches only through a reusable workflow does not name
# this action in its own file, so each such run counts only itself and posts.
is_leader() {
  local runs paths file lowest="${GITHUB_RUN_ID}" id run_path out event started
  local self_event="" self_started="" wave="${WAVE_SECONDS:-600}"
  local self_path="${GITHUB_WORKFLOW_REF:-}"
  self_path="${self_path#"${GITHUB_REPOSITORY}/"}"
  self_path="${self_path%%@*}"
  runs=$(bounded gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$HEAD_SHA&per_page=100" \
    --paginate --jq '.workflow_runs[]
      | "\(.id) \(.event) \((.run_started_at // .created_at) | fromdateiso8601) \(.path)"' 2>&1) || {
    echo "::warning::Could not list this commit's runs ($(printf '%s' "$runs" | head -n 1)); posting"
    return 0
  }
  # This run's own event and start, from the same listing.
  while read -r id event started run_path; do
    if [ "$id" = "$GITHUB_RUN_ID" ]; then self_event=$event; self_started=$started; fi
  done <<< "$runs"
  case "$self_started" in
    ""|*[!0-9]*) echo "::warning::This run is not in its commit's run listing; posting"; return 0 ;;
  esac
  paths=" "
  while read -r id event started run_path; do
    case "$id" in ""|*[!0-9]*) continue ;; esac
    case "$started" in ""|*[!0-9]*) continue ;; esac
    run_path="${run_path%%@*}"
    [ "$id" -lt "$lowest" ] || continue
    # Another wave: another trigger, or the same one long before (or after) this run.
    [ "$event" = "$self_event" ] || continue
    [ $(( started > self_started ? started - self_started : self_started - started )) -le "$wave" ] || continue
    case "$run_path" in .github/workflows/*) ;; *) continue ;; esac
    if [ "$run_path" != "$self_path" ]; then
      case "$paths" in
        *" +$run_path "*) ;;
        *" -$run_path "*) continue ;;
        *)
          if out=$(bounded gh api "repos/$GITHUB_REPOSITORY/contents/$run_path?ref=$HEAD_SHA" \
            -H "Accept: application/vnd.github.raw" 2>&1); then
            file="$out"
          elif printf '%s' "$out" | grep -q "HTTP 404"; then
            file=""
          else
            echo "::warning::Could not read $run_path ($(printf '%s' "$out" | head -n 1)); posting"
            return 0
          fi
          if printf '%s' "$file" | grep -q "fetch-github-actions"; then
            paths="$paths+$run_path "
          else
            paths="$paths-$run_path "
            continue
          fi
          ;;
      esac
    fi
    lowest="$id"
  done <<< "$runs"
  if [ "$lowest" != "$GITHUB_RUN_ID" ]; then
    echo "Run $lowest posts this commit's fallback alarm; staying silent"
    return 1
  fi
  return 0
}

# The toolchain manifest: pnpm.json of @cloudstashhq/toolchain's latest release, at
# $RUNNER_TEMP/cloudstash-toolchain/pnpm.json, outside the workspace so no checkout can ever supply
# it, for setup-node-pnpm in a later step of this job in a repo that pins no pnpm (setup-node-pnpm
# holds no credential, so it is read here, with the read role this step already holds). It is read
# last, after the package and its alarm, so a hung registry never delays the alarm, and every call
# is bounded without GNU timeout too: one attempt for the token, no npm retries, 20 s per request. From npm-shared only,
# never the public registry, where a package of that name would be someone else's: npm packs it from
# a scratch directory with the default and the scope's registry both set to npm-shared, reading only
# a user config of its own that holds the token and is deleted straight after. The package must be
# @cloudstashhq/toolchain at an X.Y.Z, and only package/pnpm.json, exactly one JSON object, is taken
# from it (to stdout, so no path in the tarball is ever written), with package/pnpm-cooldown.json
# beside it when the release ships one (the minimum release age setup-node-pnpm holds the manifest
# to; it falls back without one), and package/bootstrap.json beside them when the release ships one
# (every bootstrap release by its bytes, which infra-checks reads there in a later step of this job
# in place of its bundled copy, so it sees releases newer than itself). Writes toolchain-ready, and when
# true toolchain-manifest (that object, one line) and toolchain-version. Its failure is a warning
# and toolchain-ready=false, never a change to ready or the exit: setup-node-pnpm then fails closed
# in an unpinned repo, naming the cause. Without the read role it is not attempted, nor with
# toolchain: false (skip_toolchain).
TOOLCHAIN_PACKAGE="@cloudstashhq/toolchain"
TOOLCHAIN_DIR="${RUNNER_TEMP}/cloudstash-toolchain"
TOOLCHAIN_REGISTRY="https://cloudstash-168824206675.d.codeartifact.us-east-2.amazonaws.com/npm/npm-shared/"

# A call bounded to $1 seconds: GNU timeout is on ubuntu runners; without it the call runs unbounded.
within() { local s="$1"; shift; if command -v timeout > /dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }

toolchain_unavailable() {
  echo "::warning::Toolchain manifest unavailable: $1; setup-node-pnpm fails in a repo that pins no packageManager"
  echo "toolchain-ready=false" >> "$GITHUB_OUTPUT"
}

fetch_toolchain() {
  local work token tgz meta name tversion compact one_object has_cooldown cooldown cooldown_line has_bootstrap bootstrap
  command -v npm > /dev/null 2>&1 || { toolchain_unavailable "npm is not on PATH"; return; }
  work="$(mktemp -d "${RUNNER_TEMP}/toolchain.XXXXXX")" || { toolchain_unavailable "could not create a scratch directory"; return; }
  token="$(AWS_MAX_ATTEMPTS=1 aws codeartifact get-authorization-token --cli-connect-timeout 5 --cli-read-timeout 30 \
    --domain cloudstash --domain-owner 168824206675 --region us-east-2 --duration-seconds 900 \
    --query authorizationToken --output text 2> /dev/null)"
  if [ -z "$token" ] || [ "$token" = None ]; then
    rm -rf "$work"; toolchain_unavailable "the registry gave no token"; return
  fi
  echo "::add-mask::$token"
  # Written by the shell, never on npm's argv, which any process on the runner can read.
  if ! (umask 077 && printf '%s:_authToken=%s\n' "${TOOLCHAIN_REGISTRY#https:}" "$token" > "$work/npmrc"); then
    rm -rf "$work"; toolchain_unavailable "could not write the token to the scratch npm config"; return
  fi
  mkdir "$work/pack"
  (cd "$work" && within 60 env NPM_CONFIG_USERCONFIG="$work/npmrc" npm_config_userconfig="$work/npmrc" \
    NPM_CONFIG_GLOBALCONFIG=/dev/null npm pack "$TOOLCHAIN_PACKAGE@latest" --pack-destination "$work/pack" \
    --silent --fetch-retries=0 --fetch-timeout=20000 "--registry=$TOOLCHAIN_REGISTRY" "--@cloudstashhq:registry=$TOOLCHAIN_REGISTRY" > /dev/null 2>&1)
  rm -f "$work/npmrc"
  tgz="$(find "$work/pack" -maxdepth 1 -type f -name '*.tgz' | head -n 1)"
  if [ -z "$tgz" ]; then
    rm -rf "$work"; toolchain_unavailable "npm could not download $TOOLCHAIN_PACKAGE@latest from npm-shared"; return
  fi
  one_object='if length == 1 and (.[0] | type) == "object" then .[0] else error("not one object") end'
  meta="$(tar -xzOf "$tgz" package/package.json 2> /dev/null | jq -cs "$one_object" 2> /dev/null)"
  name="$(jq -r '.name | strings' <<< "$meta" 2> /dev/null)"
  tversion="$(jq -r '.version | strings' <<< "$meta" 2> /dev/null)"
  if [ "$name" != "$TOOLCHAIN_PACKAGE" ] || ! [[ "$tversion" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    rm -rf "$work"; toolchain_unavailable "npm-shared answered $TOOLCHAIN_PACKAGE@latest with a package that is not it at an X.Y.Z"; return
  fi
  compact="$(tar -xzOf "$tgz" package/pnpm.json 2> /dev/null | jq -cs "$one_object" 2> /dev/null)"
  # The cooldown, when the release ships one, as it is: setup-node-pnpm reads it strictly and fails
  # on a malformed one, so it is never checked, compacted or dropped here.
  # One it cannot extract is written empty, which setup-node-pnpm refuses too.
  has_cooldown=false cooldown=""
  if tar -tzf "$tgz" package/pnpm-cooldown.json > /dev/null 2>&1; then
    has_cooldown=true
    cooldown="$(tar -xzOf "$tgz" package/pnpm-cooldown.json 2> /dev/null)" || cooldown=""
  fi
  # The bootstrap releases, when the release ships them (an older toolchain does not), as they are:
  # infra-checks reads them strictly and refuses a malformed file rather than fall back to its own
  # copy, so they are never checked or dropped here either. One it cannot extract is written empty,
  # which infra-checks refuses too. No output carries them: infra-checks reads them by this path in
  # this job, and a path means nothing in another job.
  has_bootstrap=false bootstrap=""
  if tar -tzf "$tgz" package/bootstrap.json > /dev/null 2>&1; then
    has_bootstrap=true
    bootstrap="$(tar -xzOf "$tgz" package/bootstrap.json 2> /dev/null)" || bootstrap=""
  fi
  rm -rf "$work"
  [ -n "$compact" ] || { toolchain_unavailable "$TOOLCHAIN_PACKAGE@$tversion has no pnpm.json that is one JSON object"; return; }
  { mkdir -p "$TOOLCHAIN_DIR" && printf '%s\n' "$compact" > "$TOOLCHAIN_DIR/pnpm.json"; } \
    || { toolchain_unavailable "could not write $TOOLCHAIN_DIR/pnpm.json"; return; }
  cooldown_line=""
  if [ "$has_cooldown" = true ]; then
    printf '%s\n' "$cooldown" > "$TOOLCHAIN_DIR/pnpm-cooldown.json" \
      || { rm -rf "$TOOLCHAIN_DIR"; toolchain_unavailable "could not write $TOOLCHAIN_DIR/pnpm-cooldown.json"; return; }
    echo "Unpacked $TOOLCHAIN_PACKAGE $tversion's pnpm-cooldown.json at \$RUNNER_TEMP/cloudstash-toolchain/pnpm-cooldown.json"
    # One line for another job: the object compacted, or, when it is not one object, the text as a
    # JSON string, which setup-node-pnpm refuses as it refuses the file. Never dropped.
    cooldown_line="$(printf '%s' "$cooldown" | jq -cs "$one_object" 2> /dev/null)" \
      || cooldown_line="$(printf '%s' "$cooldown" | jq -Rsc . 2> /dev/null)" || cooldown_line='"unreadable"'
  fi
  if [ "$has_bootstrap" = true ]; then
    printf '%s\n' "$bootstrap" > "$TOOLCHAIN_DIR/bootstrap.json" \
      || { rm -rf "$TOOLCHAIN_DIR"; toolchain_unavailable "could not write $TOOLCHAIN_DIR/bootstrap.json"; return; }
    echo "Unpacked $TOOLCHAIN_PACKAGE $tversion's bootstrap.json at \$RUNNER_TEMP/cloudstash-toolchain/bootstrap.json"
  fi
  echo "Unpacked $TOOLCHAIN_PACKAGE $tversion's pnpm.json at \$RUNNER_TEMP/cloudstash-toolchain/pnpm.json"
  { echo "toolchain-ready=true"; echo "toolchain-manifest=$compact"; echo "toolchain-version=$tversion"
    [ -z "$cooldown_line" ] || echo "toolchain-cooldown=$cooldown_line"; } >> "$GITHUB_OUTPUT"
}

# toolchain: false, for a job that never runs pnpm: no token, no npm, no manifest, and
# toolchain-ready=false. A marker stands where the manifest would be, so setup-node-pnpm, failing in
# a later step of this job for want of one, can name this cause; it words that error and nothing
# else, so it is never trusted for more. Writing it is best effort.
skip_toolchain() {
  echo "Toolchain manifest not read: this step ran with toolchain: false"
  echo "toolchain-ready=false" >> "$GITHUB_OUTPUT"
  { mkdir -p "$TOOLCHAIN_DIR" && echo "fetch-github-actions ran with toolchain: false" > "$TOOLCHAIN_DIR/skipped"; } 2> /dev/null || true
}

# The manifest's own outcome, last: only with the read role, and only when the job asked for it.
finish_toolchain() {
  if [ "$toolchain" = false ]; then
    skip_toolchain
  elif [ "${CREDS_OUTCOME:-}" = success ]; then
    fetch_toolchain
  else
    toolchain_unavailable "could not assume the registry read role"
  fi
}

# Replace, never keep: whatever the role's outcome, a manifest from an earlier fetch in this job must
# not outlive this one.
rm -rf "$TOOLCHAIN_DIR"

# Unset is the action's default, true. Anything but true or false is the caller's mistake: it fails
# the step, naming it (printably: the value is never echoed as it is), before the package, the
# manifest or the alarm, whatever REQUIRED says.
toolchain="${TOOLCHAIN-true}"
case "$toolchain" in
  true|false) ;;
  *)
    echo "::error::fetch-github-actions: the toolchain input must be true or false, not '$(printf '%s' "$toolchain" | tr -c '[:alnum:]._-' '?')'"
    { echo "ready=false"; echo "toolchain-ready=false"; } >> "$GITHUB_OUTPUT"
    exit 1
    ;;
esac

fail() {
  echo "::warning::Shared GitHub actions unavailable: $1"
  echo "ready=false" >> "$GITHUB_OUTPUT"
  # A token with no channel is an org variable the repo cannot see, which resolves to empty.
  if [ -n "${SLACK_TOKEN:-}" ] && [ -z "${ALARMS_CHANNEL:-}" ]; then
    echo "::warning::fetch-github-actions: the alarms-channel input is empty; the fallback alarm was not posted"
  fi
  if [ -n "${SLACK_TOKEN:-}" ] && [ -n "${ALARMS_CHANNEL:-}" ] && is_leader; then
    text="Deployment notifications unavailable: could not fetch @cloudstashhq/github-actions"
    text="$text ${version:-?} for ${CONTEXT:-${GITHUB_WORKFLOW:-this workflow}} · ${RUN_URL:-}"
    body=$(jq -n --arg c "$ALARMS_CHANNEL" --arg t "$text" '{channel: $c, text: $t}')
    # The token reaches curl on stdin (-H @-), never its argv.
    printf 'Authorization: Bearer %s\n' "$SLACK_TOKEN" |
      curl -sS --connect-timeout 5 --max-time 10 -X POST https://slack.com/api/chat.postMessage \
        -H @- -H "Content-Type: application/json; charset=utf-8" \
        --data-binary "$body" > /dev/null ||
      echo "::warning::Could not post the fallback alarm either"
  fi
  # After the alarm, never before it.
  finish_toolchain
  if [ "${REQUIRED:-false}" = true ]; then
    echo "::error::Shared GitHub actions unavailable and this job requires them: $1"
    exit 1
  fi
  exit 0
}

# Published versions are immutable, so an exact X.Y.Z is the whole pin; anything else (a tag such
# as latest, a range) would float.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version '$version' is not an exact X.Y.Z"
[ "${CREDS_OUTCOME:-}" = success ] || fail "could not assume the registry read role"

# Bounded: the announce and report jobs time out at 5 minutes, and a hung call must not reach it.
aws codeartifact get-package-version-asset --cli-connect-timeout 5 --cli-read-timeout 30 \
  --domain cloudstash --domain-owner 168824206675 --region us-east-2 --repository npm-shared \
  --format npm --namespace cloudstashhq --package github-actions --package-version "$version" --asset package.tgz "$tgz" > /dev/null ||
  fail "could not fetch version $version from the registry"

# Replace, never merge: an action a newer version removed must not linger from an older unpack.
{ rm -rf "$dest" && mkdir -p "$dest"; } || fail "could not prepare $dest"
# npm tarballs hold everything under a top-level package/ directory.
tar -xzf "$tgz" --strip-components=1 -C "$dest" || fail "could not unpack version $version"
# The unpack is the package it asked for, whichever of its actions this job uses.
unpacked="$(jq -r '"\(.name)@\(.version)"' "$dest/package.json" 2>/dev/null)"
[ "$unpacked" = "@cloudstashhq/github-actions@$version" ] && [ -d "$dest/actions" ] ||
  fail "version $version unpacked as '${unpacked:-no package.json}', not @cloudstashhq/github-actions@$version with actions/"

echo "Unpacked @cloudstashhq/github-actions $version at _ci/github-actions"
echo "ready=true" >> "$GITHUB_OUTPUT"
finish_toolchain

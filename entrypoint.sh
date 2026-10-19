#!/bin/bash
# Varun Chopra <vchopra@eightfold.ai>
#
# This action runs every time a review is approved.

set -e

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

if [[ -z "$GITHUB_REPOSITORY" ]]; then
  echo "Set the GITHUB_REPOSITORY env variable."
  exit 1
fi

if [[ -z "$GITHUB_EVENT_PATH" ]]; then
  echo "Set the GITHUB_EVENT_PATH env variable."
  exit 1
fi

add_label(){
  curl -sSL \
    -H "${AUTH_HEADER}" \
    -H "${API_HEADER}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"labels\":[\"${1}\"]}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/issues/${number}/labels"
}

cat $GITHUB_EVENT_PATH

URI="https://api.github.com"
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

# --- Which CI to request ---------------------------------------------------------------
# Two switches, "true" or "false", passed in by the calling workflow from repository
# variables:
#   CI_FLEET_TRIGGER  the fleet CI: its labels, needs_ci and needs_ci:lite. Unset = true.
#   CI_K8S_TRIGGER    CI k8s: its workflows, started with workflow_dispatch.  Unset = false.
fleet_on() { [[ "${CI_FLEET_TRIGGER:-true}" == "true" ]]; }
k8s_on() { [[ "${CI_K8S_TRIGGER:-false}" == "true" ]]; }

has_label() {  # has_label <name>: on the PR as this script read it
  local l
  for l in $labels; do [[ "$l" == "$1" ]] && return 0; done
  return 1
}

# A label added with GITHUB_TOKEN starts no workflow, so CI k8s is started with
# workflow_dispatch, which GITHUB_TOKEN may trigger (needs `actions: write`). Same-repo
# PRs only: a fork's code must not run on the CI cluster. Never fails the action.
same_repo_pr() {
  local head
  head=$(curl -sSL -H "${AUTH_HEADER}" -H "${API_HEADER}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/pulls/${number}" | jq -r '.head.repo.full_name // ""') || return 1
  [[ "$head" == "$GITHUB_REPOSITORY" ]]
}

dispatch() {  # dispatch <workflow file> <inputs json>
  local ref
  ref=$(jq -r '.repository.default_branch // "master"' "$GITHUB_EVENT_PATH")
  curl -sSL -o /dev/null -w "dispatch $1: HTTP %{http_code}\n" \
    -H "${AUTH_HEADER}" -H "${API_HEADER}" -X POST -H "Content-Type: application/json" \
    -d "{\"ref\":\"${ref}\",\"inputs\":${2}}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/actions/workflows/${1}/dispatches" || true
}

# k8s_request <workflow file>: start a CI k8s run of this PR. CI k8s is requested exactly
# when the fleet's needs_ci label would be, and adds no label of its own.
k8s_request() {
  k8s_on || return 0
  same_repo_pr || { echo "CI k8s: not a same-repo PR, skipping $1"; return 0; }
  dispatch "$1" "{\"pr\":\"${number}\"}"
}
# ----------------------------------------------------------------------------------------

number=$(jq --raw-output .pull_request.number "$GITHUB_EVENT_PATH")
labels=$(jq --raw-output .pull_request.labels[].name "$GITHUB_EVENT_PATH")
sha=$(jq --raw-output .pull_request.head.sha "$GITHUB_EVENT_PATH")

already_needs_ci_lite=false
already_needs_ci=false
already_needs_alt_ci=false
curr_python_version="3.13"
alt_python_version="3.13"

# Check for both needs_ci:lite and needs_ci labels
for label in $labels; do
  case $label in
    needs_ci:lite)
      already_needs_ci_lite=true
      ;;
    needs_ci)
      already_needs_ci=true
      ;;
    "needs_ci:${alt_python_version}")
      already_needs_alt_ci=true
      ;;
    *)
      echo "Unknown label $label"
      ;;
  esac
done

statuses=$(curl -sSL -H "${AUTH_HEADER}" -H "${API_HEADER}" -H "Content-Type: application/json" "${URI}/repos/${GITHUB_REPOSITORY}/statuses/${sha}")

# Handle needs_ci:lite label (and CI k8s lite, by the same rule)
status_lite=$(echo "$statuses" | jq -r '.[] | select(.context=="Requisites (Python '"${curr_python_version}"') lite") | .state' | head -1)
if [[ $status_lite != "success" && "$already_needs_ci_lite" == false ]]; then
  if fleet_on; then
    echo "Adding label needs_ci:lite"
    add_label "needs_ci:lite"
  fi
  k8s_request "ci_k8s_lite.yml"
fi

# Handle needs_ci label (and CI k8s full, by the same rule)
status_ci=$(echo "$statuses" | jq -r '.[] | select(.context=="Requisites (Python '"${curr_python_version}"')") | .state' | head -1)
if [[ $status_ci != "success" && "$already_needs_ci" == false ]]; then
  if fleet_on; then
    echo "Adding label needs_ci"
    add_label "needs_ci"
  fi
  k8s_request "ci_k8s_full.yml"
fi

# Handle needs_ci:alt label
if [[ "$already_needs_alt_ci" == false && "$curr_python_version" != "$alt_python_version" ]]; then
  status_alt_ci=$(echo "$statuses" | jq -r '.[] | select(.context=="Requisites (Python '"${alt_python_version}"')") | .state' | head -1)
  if [[ $status_alt_ci != "success" ]]; then
    echo "Adding label needs_ci:${alt_python_version}"
    add_label "needs_ci:${alt_python_version}"
  fi
fi

# TODO: Handle needs_ci:alt:lite label
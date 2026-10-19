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

# --- CI k8s --------------------------------------------------------------------------
# When the repository variable CI_K8S_TRIGGER (passed in by the calling workflow) is
# "true", every needs_ci / needs_ci:lite this action adds also starts the matching CI k8s
# workflow. A label added with GITHUB_TOKEN starts no workflow, so it is started with
# workflow_dispatch, which GITHUB_TOKEN may trigger (needs `actions: write`). Never fails
# the action.
ci_k8s_request() {  # ci_k8s_request <workflow file>: start a CI k8s run of this PR
  [[ "${CI_K8S_TRIGGER:-false}" == "true" ]] || return 0
  local ref
  ref=$(jq -r '.repository.default_branch // "master"' "$GITHUB_EVENT_PATH")
  curl -sSL -o /dev/null -w "dispatch $1: HTTP %{http_code}\n" \
    -H "${AUTH_HEADER}" -H "${API_HEADER}" -X POST -H "Content-Type: application/json" \
    -d "{\"ref\":\"${ref}\",\"inputs\":{\"pr\":\"${number}\"}}" \
    "${URI}/repos/${GITHUB_REPOSITORY}/actions/workflows/${1}/dispatches" || true
}
# --------------------------------------------------------------------------------------

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

# Handle needs_ci:lite label
if [[ "$already_needs_ci_lite" == false ]]; then
  status_lite=$(echo "$statuses" | jq -r '.[] | select(.context=="Requisites (Python '"${curr_python_version}"') lite") | .state' | head -1)
  if [[ $status_lite != "success" ]]; then
    echo "Adding label needs_ci:lite"
    add_label "needs_ci:lite"
    ci_k8s_request "ci_k8s_lite.yml"
  fi
fi

# Handle needs_ci label
if [[ "$already_needs_ci" == false ]]; then
  status_ci=$(echo "$statuses" | jq -r '.[] | select(.context=="Requisites (Python '"${curr_python_version}"')") | .state' | head -1)
  if [[ $status_ci != "success" ]]; then
    echo "Adding label needs_ci"
    add_label "needs_ci"
    ci_k8s_request "ci_k8s_full.yml"
  fi
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
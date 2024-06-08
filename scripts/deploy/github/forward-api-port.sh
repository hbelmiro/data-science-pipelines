#!/usr/bin/env bash

usage() {
    echo "Usage: $0 [-q] <KUBEFLOW_NS>"
    exit 1
}

QUIET=0
while getopts "q" opt; do
    case $opt in
        q) QUIET=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND -1))

if [ $# -ne 1 ]; then
    usage
fi

KUBEFLOW_NS=$1
POD_NAME=$(kubectl get pod -n "$KUBEFLOW_NS" -l app=ml-pipeline -o json | jq -r '.items[] | .metadata.name')

if [ $QUIET -eq 1 ]; then
    kubectl port-forward -n "$KUBEFLOW_NS" "$POD_NAME" 8888:8888 > /dev/null 2>&1 &
else
    kubectl port-forward -n "$KUBEFLOW_NS" "$POD_NAME" 8888:8888 &
fi

# wait for the port-forward
sleep 5

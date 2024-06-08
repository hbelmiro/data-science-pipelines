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
POD_NAME=$(kubectl get pods -n kubeflow -l app=ml-pipeline-ui -o jsonpath='{.items[0].metadata.name}')

if [ $QUIET -eq 1 ]; then
    kubectl port-forward -n "$KUBEFLOW_NS" "$POD_NAME" 3000:3000 > /dev/null 2>&1 &
else
    kubectl port-forward -n "$KUBEFLOW_NS" "$POD_NAME" 3000:3000 &
fi

# wait for the port-forward
sleep 5

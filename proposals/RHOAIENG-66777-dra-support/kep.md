# KEP: Dynamic Resource Allocation (DRA) Support for Kubeflow Pipelines

<!-- toc -->
- [Summary](#summary)
- [Motivation](#motivation)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [User Stories](#user-stories)
- [Proposal](#proposal)
  - [SDK API](#sdk-api)
  - [Risks and Mitigations](#risks-and-mitigations)
- [Design Details](#design-details)
  - [Proto Schema](#proto-schema)
  - [Python SDK](#python-sdk)
  - [Backend Driver](#backend-driver)
  - [Runtime Behavior](#runtime-behavior)
- [Test Plan](#test-plan)
<!-- /toc -->

## Summary

Add Kubernetes Dynamic Resource Allocation (DRA) support to Kubeflow Pipelines through the `kfp-kubernetes` SDK package, enabling pipeline authors to request hardware resources (GPUs, accelerators) via the DRA claim-based model. This follows the same pattern as existing Kubernetes-specific features like tolerations, node selectors, and node affinity.

## Motivation

Kubernetes [Dynamic Resource Allocation (DRA)](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/) is the successor to the device-plugin model for accelerator scheduling. DRA enables:

- Fine-grained GPU partitioning
- Multi-instance GPU (MIG)
- Vendor-specific resource allocation strategies
- Claim-based resource management with proper lifecycle semantics

As DRA adoption grows across Kubernetes distributions, KFP pipeline authors need a way to request DRA-managed resources for their pipeline tasks. Today, KFP supports requesting accelerators via `set_accelerator_limit()` / `set_accelerator_type()`, which maps to the legacy device-plugin model. There is no way to use DRA claims.

### Goals

- Provide SDK functions in `kfp-kubernetes` for pipeline authors to attach DRA resource claims to pipeline tasks.
- Support both static claims (known at compile time) and parameterized claims (resolved at pipeline runtime).
- Propagate resource claims to the pipeline task pod spec at runtime.
- Maintain full backward compatibility — existing pipelines without DRA claims continue to work unchanged.

### Non-Goals

- Providing DRA resource lifecycle management (creating `ResourceClaim` or `ResourceClaimTemplate` objects). These are managed outside KFP by cluster administrators or external tooling.

## User Stories

### Pipeline author: request a GPU via DRA

As a pipeline author, I want to attach a DRA resource claim to my pipeline task so that the task pod gets a GPU allocated through the DRA framework.

```python
from kfp import dsl
from kfp import kubernetes

@dsl.component
def train_model():
    import torch
    device = torch.device("cuda")
    # ... training logic ...

@dsl.pipeline
def training_pipeline():
    task = train_model()
    kubernetes.add_resource_claim(
        task,
        resource_claim_template_name="gpu-claim-template",
    )
```

The cluster administrator has pre-created a `ResourceClaimTemplate` named `gpu-claim-template` that describes the GPU allocation requirements. At runtime, the pod gets a `resourceClaims` entry and the container references it, resulting in a GPU allocated via DRA.

### Pipeline author: parameterized claims for multi-environment pipelines

As a pipeline author, I want to pass DRA claim configuration as a pipeline parameter so the same compiled pipeline can run with different resource configurations across environments.

```python
from kfp import dsl
from kfp import kubernetes

@dsl.component
def train_model():
    ...

@dsl.pipeline
def training_pipeline(resource_claim: dict):
    task = train_model()
    kubernetes.add_resource_claim_json(task, resource_claim_json=resource_claim)
```

The caller provides the claim configuration at pipeline submission time:

```python
client.create_run_from_pipeline_func(
    training_pipeline,
    arguments={
        "resource_claim": {
            "name": "gpu",
            "resourceClaimTemplateName": "gpu-claim-template",
        }
    },
)
```

### Cluster administrator: enable DRA for KFP workloads

As a cluster administrator, I configure `DeviceClass` and `ResourceClaimTemplate` objects on the cluster. Pipeline authors reference these templates in their pipelines via `add_resource_claim()`. No changes to the KFP installation are required — DRA support works out of the box once the cluster has DRA enabled and drivers installed.

## Proposal

### SDK API

Two new functions in the `kfp-kubernetes` package:

**Static variant** — claim configuration known at compile time:

```python
kubernetes.add_resource_claim(
    task: PipelineTask,
    resource_claim_template_name: Optional[str] = None,
    existing_claim_name: Optional[str] = None,
    local_name: Optional[str] = None,
) -> PipelineTask
```

- `resource_claim_template_name`: name of a `ResourceClaimTemplate` in the same namespace. A new `ResourceClaim` is created per pod and deleted with the pod.
- `existing_claim_name`: name of an existing `ResourceClaim` in the same namespace.
- Exactly one of `resource_claim_template_name` or `existing_claim_name` must be provided.
- `local_name`: optional pod-local identifier for this claim, used by containers to reference it. When omitted, defaults to the value of `resource_claim_template_name` or `existing_claim_name`.
- Can be called multiple times on the same task to attach multiple claims.
- When an auto-generated `local_name` collides with an existing one on the same task (e.g., an explicit `local_name="abc"` followed by `resource_claim_template_name="abc"`), a random suffix is appended to ensure uniqueness.

**JSON variant** — claim configuration resolved at runtime:

```python
kubernetes.add_resource_claim_json(
    task: PipelineTask,
    resource_claim_json: Union[PipelineParameterChannel, dict, list],
) -> PipelineTask
```

- Accepts a pipeline parameter, a static dict, or a static list.
- Each claim dict uses Kubernetes API field names: `name` (required), and one of `resourceClaimTemplateName` or `resourceClaimName`. Note: `local_name` auto-generation is only available in the static variant; for the JSON variant, `name` must be provided explicitly since the Go backend unmarshals JSON directly into `corev1.PodResourceClaim`.
- When a list is provided, each item is treated as a separate claim.

**Resulting pod spec:**

```yaml
spec:
  resourceClaims:
    - name: gpu-claim-template        # auto-generated from resource_claim_template_name
      resourceClaimTemplateName: gpu-claim-template
  containers:
    - name: main
      resources:
        claims:
          - name: gpu-claim-template   # references pod-level claim
```

### Risks and Mitigations

| Risk                                                       | Mitigation                                                                                                                                                                                             |
|------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Cluster does not have DRA enabled                          | The `resourceClaims` field is silently ignored by the Kubernetes API server when the `DynamicResourceAllocation` feature gate is disabled. Pods still schedule normally without the claimed resources. |
| No DRA driver installed for requested resource             | Pod stays in `Pending` state. This is standard Kubernetes behavior, identical to requesting a non-existent resource via device plugins.                                                                |
| Pipeline compiled with DRA claims runs on older Kubernetes | The `resourceClaims` field is part of `PodSpec` since Kubernetes 1.26. Older API servers reject unknown fields, causing pod creation to fail.                                                          |

## Design Details

### Proto Schema

New messages and fields added to `kubernetes_executor_config.proto`:

```protobuf
// Pod-level resource claim for Dynamic Resource Allocation.
// Maps to corev1.PodResourceClaim.
message PodResourceClaim {
  // Unique name for this claim within the pod.
  string local_name = 1;

  // Name of a ResourceClaimTemplate in the same namespace.
  // Mutually exclusive with existing_claim_name.
  string resource_claim_template_name = 2;

  // Name of an existing ResourceClaim in the same namespace.
  // Mutually exclusive with resource_claim_template_name.
  string existing_claim_name = 3;

  // JSON parameter for runtime-resolved claims.
  // When set, takes precedence over the static fields above.
  ml_pipelines.TaskInputsSpec.InputParameterSpec resource_claim_json = 4;
}

message KubernetesExecutorConfig {
  // ... existing fields 1-19 ...
  repeated PodResourceClaim pod_resource_claims = 20;
}
```

### Python SDK

New module `kubernetes_platform/python/kfp/kubernetes/pod_resource_claim.py` with `add_resource_claim()` and `add_resource_claim_json()` functions, following the `add_toleration()` / `add_toleration_json()` pattern.

Both functions use `common.get_existing_kubernetes_config_as_message()` to retrieve the current config and append claims to the `pod_resource_claims` repeated field.

When `local_name` is omitted, the SDK auto-generates it from `resource_claim_template_name` or `existing_claim_name`, appending a random suffix on collision.

Container-level claim references (`resources.claims`) are automatically derived from pod-level claims by the backend driver. Each claim's `local_name` is added as a container claim reference on the `main` container so it can consume the allocated resource. KFP task pods contain a single user container (`main`), plus Argo-managed containers (init containers, wait sidecar) and optional modelcar sidecars. DRA claim references are only added to the `main` container, as it is the only container executing user workloads that require access to DRA-managed resources.

### Backend Driver

In `backend/src/v2/driver/k8s.go`, `extendPodSpecPatch()` is extended to:

1. Read `pod_resource_claims` from `KubernetesExecutorConfig`.
2. For JSON variants, resolve parameters via `resolveK8sJsonParameter()`.
3. Convert proto messages to `corev1.PodResourceClaim` structs and set `podSpec.ResourceClaims`.
4. Add corresponding `corev1.ResourceClaim` entries to `podSpec.Containers[0].Resources.Claims`.

This follows the existing pattern used for tolerations and node selectors.

### Runtime Behavior

1. Pipeline author calls `kubernetes.add_resource_claim()` in pipeline definition.
2. SDK compiler stores claim configuration in the platform spec under `kubernetes.deploymentSpec.executors`.
3. At runtime, the KFP driver reads the platform spec and injects `resourceClaims` into the pod spec patch.
4. Argo Workflows applies the patch via strategic merge when creating the task pod.
5. Kubernetes scheduler allocates the DRA resource before starting the pod.
6. Container accesses the allocated resource.

## Test Plan

### Python SDK unit tests

**Static variant (`add_resource_claim`):**
- Single claim with `resource_claim_template_name`
- Single claim with `existing_claim_name`
- Explicit `local_name` override
- Multiple claims on one task
- Auto-generated `local_name` defaults to template/claim name
- Auto-generated `local_name` appends random suffix on collision
- Coexistence with other `kfp-kubernetes` features (tolerations, node selectors, etc.)
- Coexistence with `set_accelerator_limit()` on same task (DRA and device-plugin are alternative GPU approaches — both on same task should not break)
- Validation: error when neither `resource_claim_template_name` nor `existing_claim_name` is provided
- Validation: error when both are provided

**JSON variant (`add_resource_claim_json`):**
- Pipeline input parameter (single dict)
- Pipeline input parameter (list of dicts)
- Static dict (single claim)
- Static list (multiple claims)
- Upstream task output parameter

### Go backend tests

- No claims configured — pod spec unchanged
- Static variant: field mapping from proto (`local_name`, `existing_claim_name`, `resource_claim_template_name`) to K8s struct (`Name`, `ResourceClaimName`, `ResourceClaimTemplateName`)
- Container-level claim references auto-generated for each pod-level claim
- Claims added when `Containers[0].Resources` has no prior limits/requests (zero-value struct)
- Multiple claims propagated to pod spec
- JSON parameter resolution via `resolveK8sJsonParameter()`
- JSON variant with missing `name` field — verify clear error from K8s struct validation
- Null/optional parameter handling (skip claim when parameter resolves to null)

### KFP Local

DRA fields are Kubernetes-specific. When running pipelines locally via `SubprocessRunner` or `DockerRunner`, DRA claims in the platform spec are ignored (no pod spec is generated). No changes needed in local runners — verify DRA claims in platform spec do not cause errors in local execution.


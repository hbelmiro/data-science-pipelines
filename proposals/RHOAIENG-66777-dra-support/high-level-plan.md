# RHOAIENG-66777: Dynamic Resource Allocation (DRA) Support for Data Science Pipelines

## Summary

Add Kubernetes [Dynamic Resource Allocation (DRA)](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/) support to the Data Science Pipelines stack, enabling pipeline tasks and operator-managed components to request and consume hardware resources (GPUs, accelerators) through the DRA claim-based model.

## Motivation

DRA is the successor to the device-plugin model for accelerator scheduling in Kubernetes. It is required for:

- Fine-grained GPU partitioning
- Multi-instance GPU (MIG)
- Vendor-specific resource allocation strategies on OpenShift
- GPUaaS support

DRA introduces pod-level `resourceClaims` (`[]corev1.PodResourceClaim`) that define which `ResourceClaim` objects must be allocated and reserved before a pod starts. Containers reference these claims by name to consume the allocated resources.

DRA is stable in Kubernetes v1.35+ and gated by the `DynamicResourceAllocation` feature gate on older versions.

## Scope

### In scope

1. **KFP (Kubeflow Pipelines)** — upstream SDK + backend changes (`kubeflow/master` branch)
2. **DSP (Data Science Pipelines)** — cherry-pick KFP changes (`opendatahub-io/master` branch)
3. **DSPO (Data Science Pipelines Operator)** — DSPA CRD + controller changes (`upstream/main` branch)

### Out of scope

- **ODH Argo Workflows fork** — KFP uses `PodSpecPatch` (strategic merge patch on `corev1.PodSpec`) to inject all resource configuration into pods. Argo's own `WorkflowSpec`/`Template` types are bypassed entirely. This works identically on Argo v3 and v4. No Argo fork changes are needed.
- **Argo v4 migration** — separate effort, not required for DRA.
- Raw `Workflow` CR submission bypassing KFP — not a supported use case.

## Background: How Resources Flow in KFP

KFP has two paths for injecting configuration into pipeline task pods:

### Path 1: Generic container resources (`pipeline_spec.proto`)
- CPU, memory, accelerator limits/requests
- Handled in `../../backend/src/v2/driver/driver.go` → `initPodSpecPatch()`
- Platform-agnostic

### Path 2: Kubernetes-specific configuration (`kubernetes_executor_config.proto`)
- Tolerations, nodeSelector, nodeAffinity, podAffinity, secrets, configMaps, etc.
- Handled in `../../backend/src/v2/driver/k8s.go` → `extendPodSpecPatch()`
- K8s-specific

Both paths build/modify the same `k8score.PodSpec` struct, which is serialized to JSON and stored as `PodSpecPatch` on the Argo Workflow template. Argo applies this patch via `strategicpatch.StrategicMergePatch()` when creating pods.

**DRA belongs in Path 2** — it is a Kubernetes-specific pod-level feature, analogous to tolerations and nodeAffinity. It does not belong in `pipeline_spec.proto` or the generic `ResourceSpec`.

## Implementation Plan

### 1. KFP (`kubeflow/master` branch)

#### 1.1 Proto definition

**File:** `../../kubernetes_platform/proto/kubernetes_executor_config.proto`

Add a new `ResourceClaim` message and field to `KubernetesExecutorConfig`:

```protobuf
// ResourceClaim for Dynamic Resource Allocation (DRA).
// Maps to corev1.PodResourceClaim in the pod spec.
message ResourceClaim {
  // Name for this resource claim. Must be unique within the pod.
  // Used by containers to reference the claim in their resources.claims list.
  string name = 1;

  // Name of a ResourceClaimTemplate in the same namespace.
  // Mutually exclusive with resource_claim_name.
  string resource_claim_template_name = 2;

  // Name of an existing ResourceClaim in the same namespace.
  // Mutually exclusive with resource_claim_template_name.
  string resource_claim_name = 3;
}

message KubernetesExecutorConfig {
  // ... existing fields 1-19 ...
  repeated ResourceClaim resource_claims = 20;
}
```

Additionally, container-level claim references need to be supported. A container references pod-level claims via `resources.claims` (`[]corev1.ResourceClaim`). Add a field to `KubernetesExecutorConfig` for this:

```protobuf
// ContainerResourceClaim references a pod-level resource claim by name,
// allowing a container to consume the allocated resource.
// Maps to corev1.ResourceClaim in container resources.claims.
message ContainerResourceClaim {
  // Must match a pod-level ResourceClaim name.
  string name = 1;
  // Request identifies a named request within the claim for device selection.
  string request = 2;
}

message KubernetesExecutorConfig {
  // ... existing fields 1-20 ...
  repeated ContainerResourceClaim container_resource_claims = 21;
}
```

In the backend, container-level claims are set on `podSpec.Containers[0].Resources.Claims` in `extendPodSpecPatch()`, after the pod-level `ResourceClaims` are set.

#### 1.2 Python SDK (`kfp-kubernetes` package)

**Directory:** `../../kubernetes_platform/python/kfp/kubernetes`

Add DRA helper functions following the existing pattern (e.g., how `add_toleration()`, `add_node_selector()` work):

```python
def add_resource_claim(
    task: PipelineTask,
    claim_name: str,
    resource_claim_template_name: Optional[str] = None,
    resource_claim_name: Optional[str] = None,
) -> PipelineTask:
    """Add a DRA resource claim to a pipeline task."""
```

#### 1.3 Backend driver

**File:** `../../backend/src/v2/driver/k8s.go`

Add DRA handling in `extendPodSpecPatch()`, following the tolerations/nodeSelector pattern:

```go
// Pod-level resource claims
if resourceClaims := kubernetesExecutorConfig.GetResourceClaims(); len(resourceClaims) > 0 {
    var k8sClaims []k8score.PodResourceClaim
    for _, claim := range resourceClaims {
        k8sClaim := k8score.PodResourceClaim{
            Name: claim.GetName(),
        }
        // ResourceClaimTemplateName and ResourceClaimName are *string in corev1.PodResourceClaim
        if tplName := claim.GetResourceClaimTemplateName(); tplName != "" {
            k8sClaim.ResourceClaimTemplateName = &tplName
        }
        if claimName := claim.GetResourceClaimName(); claimName != "" {
            k8sClaim.ResourceClaimName = &claimName
        }
        k8sClaims = append(k8sClaims, k8sClaim)
    }
    podSpec.ResourceClaims = k8sClaims
}

// Container-level claim references
if containerClaims := kubernetesExecutorConfig.GetContainerResourceClaims(); len(containerClaims) > 0 {
    var k8sContainerClaims []k8score.ResourceClaim
    for _, claim := range containerClaims {
        k8sContainerClaims = append(k8sContainerClaims, k8score.ResourceClaim{
            Name:    claim.GetName(),
            Request: claim.GetRequest(),
        })
    }
    podSpec.Containers[0].Resources.Claims = k8sContainerClaims
}
```

#### 1.4 Tests

- Proto serialization tests
- Python SDK unit tests for `add_resource_claim()`
- Backend driver tests in `k8s_test.go` — verify `extendPodSpecPatch()` sets `podSpec.ResourceClaims`
- Compiler tests

#### 1.5 Regenerate

```bash
# Go proto bindings (backend driver)
make -C api generate
make -C kubernetes_platform generate

# Python proto bindings (SDK)
make -C api python
make -C kubernetes_platform python
```

### 2. DSP (`opendatahub-io/master` branch)

Cherry-pick all KFP changes from step 1 into the DSP fork.

### 3. DSPO (`upstream/main` branch)

DSPO manages infrastructure component Deployments (APIServer, WorkflowController, PersistenceAgent, ScheduledWorkflow, MariaDB, Minio, MLMD). These are not ML workload pods, but the Jira requests DRA support for completeness.

Note: Pipeline execution pods (the actual ML workloads) get DRA through KFP's `PodSpecPatch` mechanism (steps 1-2 above). DSPO changes only affect the operator's own infrastructure pods.

#### 3.1 CRD types

**File:** `api/v1/dspipeline_types.go`

Add pod-level `ResourceClaims` field to each component spec that creates a Deployment. `resourceClaims` is a pod-level field (`spec.template.spec.resourceClaims`), NOT a container-level resource field, so it does not belong in the existing custom `ResourceRequirements` struct.

```go
// Add to APIServer, WorkflowController, PersistenceAgent, ScheduledWorkflow,
// MariaDB, Minio, Envoy, GRPC structs:

// ResourceClaims defines which ResourceClaims must be allocated
// and reserved before the Pod is allowed to start.
// +optional
ResourceClaims []corev1.PodResourceClaim `json:"resourceClaims,omitempty"`
```

#### 3.2 Deployment templates

Add `resourceClaims` blocks at the pod spec level (`spec.template.spec`) in all 8 deployment templates under `config/internal/`:

| Template           | File                                              |
|--------------------|---------------------------------------------------|
| APIServer          | `apiserver/default/deployment.yaml.tmpl`          |
| WorkflowController | `workflow-controller/deployment.yaml.tmpl`        |
| PersistenceAgent   | `persistence-agent/deployment.yaml.tmpl`          |
| ScheduledWorkflow  | `scheduled-workflow/deployment.yaml.tmpl`         |
| MariaDB            | `mariadb/default/deployment.yaml.tmpl`            |
| Minio              | `minio/default/deployment.yaml.tmpl`              |
| MLMD Envoy         | `ml-metadata/metadata-envoy.deployment.yaml.tmpl` |
| MLMD GRPC          | `ml-metadata/metadata-grpc.deployment.yaml.tmpl`  |

Template pattern (example for APIServer — replace `.APIServer` with the component's template variable):

```yaml
spec:
  template:
    spec:
      {{ if .APIServer.ResourceClaims }}
      resourceClaims:
        {{- range .APIServer.ResourceClaims }}
        - name: {{ .Name }}
          {{- if .ResourceClaimTemplateName }}
          resourceClaimTemplateName: {{ .ResourceClaimTemplateName }}
          {{- end }}
          {{- if .ResourceClaimName }}
          resourceClaimName: {{ .ResourceClaimName }}
          {{- end }}
        {{- end }}
      {{ end }}
      containers:
        ...
```

Each template uses its own component variable: `.APIServer`, `.WorkflowController`, `.PersistenceAgent`, `.ScheduledWorkflow`, `.MariaDB`, `.Minio`, `.MLMD.Envoy`, `.MLMD.GRPC`.

#### 3.3 Regenerate

```bash
make manifests  # Regenerate CRDs via controller-gen
make generate   # Regenerate DeepCopy methods
```

#### 3.4 Tests

- Unit tests for CRD serialization/deserialization with `resourceClaims`
- Controller tests verifying `resourceClaims` propagates from DSPA CR to rendered Deployment pod template

## Acceptance Criteria

1. KFP SDK users can specify `resourceClaims` on pipeline tasks via `kfp-kubernetes` helpers.
2. KFP backend propagates `resourceClaims` to pipeline execution pod specs via `PodSpecPatch`.
3. DSPO users can specify `resourceClaims` in DSPA CR for operator-managed components.
4. DSPO controller propagates `resourceClaims` to component Deployment pod templates.
5. All changes are backward compatible — existing CRs/pipelines without `resourceClaims` work without modification.
6. Unit tests cover serialization, compilation, and propagation of DRA fields.
7. Changes pass lint, generate, and manifests checks without errors or drift.

## Dependencies

- Kubernetes cluster with `DynamicResourceAllocation` feature gate enabled (stable in v1.35+)
- Appropriate DRA drivers installed on the cluster (e.g., NVIDIA DRA driver for GPU allocation)

## References

- [Kubernetes DRA documentation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [KEP-3063: Dynamic Resource Allocation](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/3063-dynamic-resource-allocation)
- [DSPO source](https://github.com/opendatahub-io/data-science-pipelines-operator)
- [KFP source](https://github.com/kubeflow/pipelines)
- [RHOAIENG-66777](https://redhat.atlassian.net/browse/RHOAIENG-66777)

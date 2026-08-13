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

1. **KFP (Kubeflow Pipelines)** — upstream SDK + backend changes (`kubeflow/master` branch). See [KEP](kep.md) for details.
2. **DSP (Data Science Pipelines)** — cherry-pick KFP changes (`opendatahub-io/master` branch)
3. **DSPO (Data Science Pipelines Operator)** — DSPA CRD + controller changes (`upstream/main` branch)

### Out of scope

- **ODH Argo Workflows fork** — KFP uses `PodSpecPatch` (strategic merge patch on `corev1.PodSpec`) to inject resource configuration into pods, bypassing Argo's `WorkflowSpec`/`Template` types. No Argo fork changes are needed. Note: Argo 4.1 added native DRA support (`resourceClaims` field on `WorkflowSpec`/`Template`), but KFP is currently on Argo 4.0.8 and the PodSpecPatch approach works across all versions.
- **Argo v4 migration** — separate effort.
- Raw `Workflow` CR submission bypassing KFP — not a supported use case.

## Implementation Plan

### 1. KFP (`kubeflow/master` branch)

Detailed in the [KEP](kep.md). Summary:

- **Proto**: New `PodResourceClaim` message (fields: `local_name`, `resource_claim_template_name`, `existing_claim_name`, `resource_claim_json`) + field 20 on `KubernetesExecutorConfig`
- **Python SDK**: New `add_resource_claim()` and `add_resource_claim_json()` functions in `kubernetes_platform/python/kfp/kubernetes/pod_resource_claim.py`
  - `local_name` optional, auto-generated from template/claim name with random suffix on collision
  - JSON variant uses K8s API field names (`name`, `resourceClaimTemplateName`, `resourceClaimName`)
- **Backend driver**: `extendPodSpecPatch()` in `k8s.go` maps proto fields to `corev1.PodResourceClaim` structs on `podSpec.ResourceClaims`
- **Container-level claims**: Auto-derived from pod-level claims by the backend driver (single `main` container per task pod)

### 2. DSP (`opendatahub-io/master` branch)

Cherry-pick all KFP changes from step 1 into the DSP fork.

### 3. DSPO (`upstream/main` branch)

DSPO manages infrastructure component Deployments (APIServer, WorkflowController, PersistenceAgent, ScheduledWorkflow, MariaDB, Minio, MLMD). These are not ML workload pods, but the Jira requests DRA support for these components.

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
make lint       # Verify no lint errors
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

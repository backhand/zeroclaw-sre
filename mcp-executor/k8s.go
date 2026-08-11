package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"time"
)

// prune_replicaset deletes one superseded ReplicaSet.
//
// The safety is not the approval prompt — a prompt can be talked past, and was.
// It is the re-read below: the object is fetched immediately before deletion and
// refused unless it is *still* owned by a Deployment and *still* scaled to zero
// with nothing terminating. A ReplicaSet that went live again between the
// operator seeing the proposal and approving it will not be deleted.
//
// Deliberately one object per call. A `prune_all` would move the decision about
// what is stale back into the model, which is the thing this component exists to
// prevent.
func pruneReplicaSetTool() *tool {
	return &tool{
		name: "prune_replicaset",
		description: "Delete ONE superseded ReplicaSet. Refuses unless it is owned by a Deployment " +
			"and already scaled to zero with no pods still terminating, so it can never take down " +
			"running workload. Use the k3s-admin skill's prune-rs.sh to choose candidates.",
		schema: map[string]any{
			"type":     "object",
			"required": []string{"namespace", "name"},
			"properties": map[string]any{
				"namespace": map[string]any{
					"type":        "string",
					"description": "Namespace of the ReplicaSet. Must be in ALLOWED_NAMESPACES.",
				},
				"name": map[string]any{
					"type":        "string",
					"description": "Exact ReplicaSet name, e.g. api-gateway-7c9f4b6d8.",
				},
			},
			"additionalProperties": false,
		},
		run: runPruneReplicaSet,
	}
}

type replicaSet struct {
	Metadata struct {
		Name            string `json:"name"`
		OwnerReferences []struct {
			Kind string `json:"kind"`
			Name string `json:"name"`
		} `json:"ownerReferences"`
	} `json:"metadata"`
	Spec struct {
		Replicas *int `json:"replicas"`
	} `json:"spec"`
	Status struct {
		Replicas int `json:"replicas"`
	} `json:"status"`
}

func runPruneReplicaSet(raw json.RawMessage) toolResult {
	var args struct {
		Namespace string `json:"namespace"`
		Name      string `json:"name"`
	}
	if err := json.Unmarshal(raw, &args); err != nil {
		return fail("could not parse arguments: %v", err)
	}
	if err := validName("namespace", args.Namespace); err != nil {
		return fail("%v", err)
	}
	if err := validName("name", args.Name); err != nil {
		return fail("%v", err)
	}
	if err := allowedNamespace(args.Namespace); err != nil {
		return fail("refused: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "kubectl",
		"-n", args.Namespace, "get", "replicaset", args.Name, "-o", "json").Output()
	if err != nil {
		return fail("refused: cannot read %s/%s: %v", args.Namespace, args.Name, cleanExecErr(err))
	}

	var rs replicaSet
	if err := json.Unmarshal(out, &rs); err != nil {
		return fail("refused: unreadable ReplicaSet json: %v", err)
	}

	owner := ""
	for _, o := range rs.Metadata.OwnerReferences {
		if o.Kind == "Deployment" {
			owner = o.Name
			break
		}
	}
	if owner == "" {
		return fail("refused: %s/%s is not owned by a Deployment", args.Namespace, args.Name)
	}
	if rs.Spec.Replicas == nil {
		return fail("refused: %s/%s has no spec.replicas", args.Namespace, args.Name)
	}
	if *rs.Spec.Replicas != 0 {
		return fail("refused: %s/%s has spec.replicas=%d — it is serving traffic",
			args.Namespace, args.Name, *rs.Spec.Replicas)
	}
	if rs.Status.Replicas != 0 {
		return fail("refused: %s/%s still has %d running pod(s)",
			args.Namespace, args.Name, rs.Status.Replicas)
	}

	if _, err := exec.CommandContext(ctx, "kubectl",
		"-n", args.Namespace, "delete", "replicaset", args.Name, "--wait=false").Output(); err != nil {
		return fail("delete failed for %s/%s: %v — is the zeroclaw-sre-prune RoleBinding applied to %s?",
			args.Namespace, args.Name, cleanExecErr(err), args.Namespace)
	}

	return ok("deleted %s/%s (deployment %s)", args.Namespace, args.Name, owner)
}

// cleanExecErr surfaces the stderr of a failed command; kubectl puts the useful
// part ("Error from server (Forbidden): ...") there, and ExitError alone says
// only "exit status 1".
func cleanExecErr(err error) string {
	var ee *exec.ExitError
	if errorsAs(err, &ee) && len(ee.Stderr) > 0 {
		return trimTo(string(ee.Stderr), 400)
	}
	return err.Error()
}

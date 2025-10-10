PROFILE ?= ootb        # ootb | strict
FAMILY  ?= v5          # v5 | v6
SUITE   ?= aro-$(PROFILE)-d96s-$(FAMILY).yaml
KUBECONFIG ?= $$KUBECONFIG

.PHONY: run ns-prepare strict ootb seller-pack prep test-prep


run: ns-prepare
	# Run benchmark-runner workloads against a live OpenShift/ARO cluster
	podman run --rm \
	  -v $(PWD)/suites:/suites \
	  -v $(PWD)/results:/results \
	  -v $(KUBECONFIG):/root/.kube/config:ro \
	  quay.io/benchmark-runner/benchmark-runner:latest \
	  --config /suites/aro-$(PROFILE)-d96s-$(FAMILY).yaml \
	  --kubeconfig /root/.kube/config

ns-prepare:
	./scripts/prepare-namespace.sh

strict:
	./scripts/prepare-strict.sh

ootb:
	./scripts/prepare-ootb.sh

seller-pack:
	./scripts/seller-pack.sh results

prep:
	@echo "Preparing fresh cluster for perf tests... This can take up to 30 minutes. Go have a sandwich."
	./scripts/prep-cluster.sh

test-prep:
	@echo "Running local-only tests for prep-cluster.sh..."
	./tests/local-prep/run-tests.sh

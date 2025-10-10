PROFILE ?= ootb        # ootb | strict
FAMILY  ?= v5          # v5 | v6
SUITE   ?= aro-$(PROFILE)-d96s-$(FAMILY).yaml

.PHONY: run prepare strict ootb seller-pack

run: prepare
	@echo "Running suite $(SUITE)"
	podman run --rm \
	  -v $(PWD)/suites:/suites \
	  -v $(PWD)/results:/results \
	  quay.io/redhat-performance/benchmark-runner:latest \
	  --config /suites/$(SUITE)

prepare:
	./scripts/prepare-namespace.sh
	oc apply -f https://raw.githubusercontent.com/cloud-bulldozer/benchmark-operator/master/deploy/operator.yaml

strict:
	./scripts/prepare-strict.sh

ootb:
	./scripts/prepare-ootb.sh

seller-pack:
	./scripts/seller-pack.sh results

prep:
	@echo "Preparing fresh cluster for perf tests... This can take up to 30 minutes. Go have a sandwich."
	./scripts/prep-cluster.sh

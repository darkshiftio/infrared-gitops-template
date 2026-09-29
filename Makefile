CLUSTER ?= demo
FLAVOR  ?= k3s
REGION  ?= us-east-1
OUT     ?= out
# BUILD_REGISTRY: the registry prefix product images are built into (defaults to
# $INFRARED_BUILD_REGISTRY); empty leaves the builds component out. E.g.
# make render BUILD_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com/acme
BUILD_REGISTRY ?= $(INFRARED_BUILD_REGISTRY)

.PHONY: render verify test vendor-argocd vendor-kpack clean

## render: render template/ into $(OUT)/ (make render CLUSTER=demo FLAVOR=k3s)
render:
	rm -rf $(OUT)
	go run ./hack/render -template template -out $(OUT) -cluster $(CLUSTER) -flavor $(FLAVOR) -region $(REGION) -build-registry "$(BUILD_REGISTRY)"

## verify: the gate CI runs
verify:
	scripts/verify.sh

test:
	go test ./...

vendor-argocd:
	scripts/vendor-argocd.sh

vendor-kpack:
	scripts/vendor-kpack.sh

clean:
	rm -rf $(OUT)

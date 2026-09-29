CLUSTER ?= demo
FLAVOR  ?= k3s
REGION  ?= us-east-1
OUT     ?= out

.PHONY: render verify test vendor-argocd vendor-kpack clean

## render: render template/ into $(OUT)/ (make render CLUSTER=demo FLAVOR=k3s)
render:
	rm -rf $(OUT)
	go run ./hack/render -template template -out $(OUT) -cluster $(CLUSTER) -flavor $(FLAVOR) -region $(REGION)

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

.PHONY: help fmt validate plan apply destroy smoke bundle-workers

REGION ?= us-east-1

help:
	@echo "make fmt              - terraform fmt -recursive"
	@echo "make validate         - terraform validate"
	@echo "make plan             - terraform plan"
	@echo "make apply            - terraform apply"
	@echo "make destroy          - terraform destroy"
	@echo "make smoke            - curl /healthz on the API endpoint"
	@echo "make bundle-workers   - build local tarballs for both workers"

fmt:
	terraform -chdir=terraform fmt -recursive

validate:
	terraform -chdir=terraform fmt -check -recursive
	terraform -chdir=terraform init -backend=false
	terraform -chdir=terraform validate

plan:
	terraform -chdir=terraform plan

apply:
	terraform -chdir=terraform apply

destroy:
	terraform -chdir=terraform destroy

smoke:
	@API=$$(terraform -chdir=terraform output -raw api_endpoint); \
	echo "GET $$API/healthz"; curl -sS "$$API/healthz" && echo

bundle-workers:
	cd workers/caller-worker && npm ci && npm run build && \
	  tar -czf /tmp/caller-worker.tar.gz dist package.json package-lock.json
	cd workers/inference-worker && \
	  tar -czf /tmp/inference-worker.tar.gz src requirements.txt pyproject.toml
	@ls -lh /tmp/caller-worker.tar.gz /tmp/inference-worker.tar.gz

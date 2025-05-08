.PHONY: help all init deploy clean test

help:
	@echo "Available targets:"
	@echo "  all       Run init and deploy targets"
	@echo "  init      Install and start the Kubernetes cluster with required addons"
	@echo "  deploy    Deploy the application using deploy.sh"
	@echo "  clean     Remove the cluster (minikube delete)"
	@echo "  test      Run integration tests using test.sh"

all: init deploy

init:
	@if [ ! -f ./init.sh ]; then \
		echo "init.sh not found!"; exit 1; \
	fi
	bash ./init.sh

deploy:
	@if [ ! -f ./deploy.sh ]; then \
		echo "deploy.sh not found!"; exit 1; \
	fi
	bash ./deploy.sh

test:
	@if [ ! -f ./test.sh ]; then \
		echo "test.sh not found!"; exit 1; \
	fi
	bash ./test.sh

clean:
	@echo "Deleting minikube cluster..."
	@minikube delete || echo "minikube not found or already deleted."

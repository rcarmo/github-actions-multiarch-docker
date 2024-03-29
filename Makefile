export IMAGE_NAME?=rcarmo/sample-multiarch-zsh
export VCS_REF=`git rev-parse --short HEAD`
export VCS_URL=https://github.com/rcarmo/azure-pipelines-multiarch-docker
export BUILD_DATE=`date -u +"%Y-%m-%dT%H:%M:%SZ"`
export TAG_DATE=`date -u +"%Y%m%d"`
export UBUNTU_VERSION=ubuntu:20.04
export QEMU_VERSION=5.2.0-2
export BUILD_IMAGE_NAME=local/ubuntu-base
export TARGET_ARCHITECTURES=amd64 arm64v8 arm32v7
export QEMU_ARCHITECTURES=arm aarch64
export DOCKER_CLI_EXPERIMENTAL=enabled
export SHELL=/bin/bash

# Permanent local overrides
-include .env

.PHONY: build qemu wrap push manifest clean

qemu:
	@echo "==> Setting up QEMU"
	-docker run --rm --privileged multiarch/qemu-user-static:register --reset
	-mkdir tmp
	$(foreach ARCH, $(QEMU_ARCHITECTURES), make fetch-qemu-$(ARCH);)
	@echo "==> Done setting up QEMU"

fetch-qemu-%:
	$(eval ARCH := $*)
	@echo "--> Fetching QEMU binary for $(ARCH)"
	cd tmp && \
	curl -L -o qemu-$(ARCH)-static.tar.gz \
		https://github.com/multiarch/qemu-user-static/releases/download/v$(QEMU_VERSION)/qemu-$(ARCH)-static.tar.gz && \
	tar xzf qemu-$(ARCH)-static.tar.gz && \
	cp qemu-$(ARCH)-static ../qemu/
	@echo "--> Done."

wrap:
	@echo "==> Building local base containers"
	$(foreach ARCH, $(TARGET_ARCHITECTURES), make wrap-$(ARCH);)
	@echo "==> Done."

wrap-amd64:
	docker pull amd64/$(UBUNTU_VERSION)
	docker tag amd64/$(UBUNTU_VERSION) $(BUILD_IMAGE_NAME):amd64

wrap-translate-%: 
	@if [[ "$*" == "arm64v8" ]] ; then \
	   echo "aarch64"; \
	else \
		echo "arm"; \
	fi 

wrap-%:
	$(eval ARCH := $*)
	@echo "--> Building local base container for $(ARCH)"
	docker build --build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg ARCH=$(shell make wrap-translate-$(ARCH)) \
		--build-arg BASE=$(ARCH)/$(UBUNTU_VERSION) \
		--build-arg VCS_REF=$(VCS_REF) \
		--build-arg VCS_URL=$(VCS_URL) \
		-t $(BUILD_IMAGE_NAME):$(ARCH) qemu
	@echo "--> Done building local base container for $(ARCH)"

build:
	@echo "==> Building all containers"
	$(foreach ARCH, $(TARGET_ARCHITECTURES), make build-$(ARCH);)
	@echo "==> Done."

build-%:
	$(eval ARCH := $*)
	@echo "--> Building $(ARCH)"
	docker build --build-arg BUILD_DATE=$(BUILD_DATE) \
		--build-arg ARCH=$(ARCH) \
		--build-arg BASE=$(BUILD_IMAGE_NAME):$(ARCH) \
		--build-arg VCS_REF=$(VCS_REF) \
		--build-arg VCS_URL=$(VCS_URL) \
		-t $(IMAGE_NAME):$(ARCH) src
	@echo "--> Done building $(ARCH)"

push:
	@echo "==> Pushing $(IMAGE_NAME)"
	docker push $(IMAGE_NAME)
	@echo "==> Done."

push-%:
	$(eval ARCH := $*)
	docker push $(IMAGE_NAME):$(ARCH)

expand-%: # expand architecture variants for manifest
	@if [ "$*" == "amd64" ] ; then \
	   echo '--arch $*'; \
	elif [[ "$*" == *"arm"* ]] ; then \
	   echo '--arch arm --variant $*' | cut -c 1-21,27-; \
	fi

manifest:
	@echo "==> Building multi-architecture manifest"
	$(foreach STEP, build push, make $(STEP)-manifest;)
	@echo "==> Done."	

build-manifest:
	@echo "--> Creating manifest"
	docker manifest create --amend \
		$(IMAGE_NAME):latest \
		$(foreach arch, $(TARGET_ARCHITECTURES), $(IMAGE_NAME):$(arch) )
	$(foreach arch, $(TARGET_ARCHITECTURES), \
		docker manifest annotate \
			$(IMAGE_NAME):latest \
			$(IMAGE_NAME):$(arch) $(shell make expand-$(arch));)

push-manifest:
	@echo "--> Pushing manifest"
	docker manifest push $(IMAGE_NAME):latest

clean:
	@echo "==> Cleaning up old images..."
	-docker rm -fv $$(docker ps -a -q -f status=exited)
	-docker rmi -f $$(docker images -q -f dangling=true)
	-docker rmi -f $(BUILD_IMAGE_NAME)
	-docker rmi -f $$(docker images --format '{{.Repository}}:{{.Tag}}' | grep $(IMAGE_NAME))
	@echo "==> Done."

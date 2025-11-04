SHELL := /bin/bash
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: install config run stop restart

install:
	@bash "$(PROJECT_ROOT)/scripts/install.sh"

config:
	@python3 "$(PROJECT_ROOT)/scripts/config.py"

run:
	@bash "$(PROJECT_ROOT)/scripts/run.sh"

stop:
	@bash "$(PROJECT_ROOT)/scripts/stop.sh"

restart:
	@bash "$(PROJECT_ROOT)/scripts/restart.sh"

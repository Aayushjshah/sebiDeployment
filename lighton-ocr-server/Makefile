.PHONY: lint lint-fix test benchmark-lightonocr

PYTHON ?= python

lint:
	$(PYTHON) -m ruff format --check .
	$(PYTHON) -m ruff check .

lint-fix:
	$(PYTHON) -m ruff format .
	$(PYTHON) -m ruff check --fix .

test:
	PYTHONPATH=src $(PYTHON) -m unittest discover -s tests -v

benchmark-lightonocr:
	PYTHONPATH=src $(PYTHON) scripts/benchmark_lightonocr.py $(ARGS)

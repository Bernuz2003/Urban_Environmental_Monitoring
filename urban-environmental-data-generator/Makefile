PYTHON := .venv/bin/python

.PHONY: venv test generate verify clean
venv:
	python3 -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -e .

test:
	$(PYTHON) -m unittest discover -s tests -v

generate:
	$(PYTHON) -m uem_data_generator.cli

verify:
	./scripts/verify_dataset.sh

clean:
	rm -rf work output/urban-environmental-dataset

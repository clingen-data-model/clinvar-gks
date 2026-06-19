.SECONDARY:
.DELETE_ON_ERROR:

BUILD_DIR := build
DEF_DIR := def
JSON_DIR := json
MD_DIR := md
IMPORT_DIR := import

vpath %tag $(BUILD_DIR)
vpath %.classes $(BUILD_DIR)

SOURCES := $(wildcard *-source.yaml)
TAGS := $(SOURCES:-source.yaml=.tag)
IMPORTS := $(wildcard $(IMPORT_DIR)/*-source.yaml)

all: build-ordered ${TAGS} prune-tag

build-ordered: | $(BUILD_DIR)

$(BUILD_DIR):
	mkdir $(BUILD_DIR)

%.tag: %.classes %.json-tag %.defs-tag %.md-tag
	touch $(BUILD_DIR)/$@

%.classes: %-source.yaml
	source2classes $< >${BUILD_DIR}/$@

%.json-tag: %-source.yaml ${IMPORTS}
	source2splitjs $<
	touch $(BUILD_DIR)/$@

%.defs-tag: %-source.yaml ${IMPORTS}
	y2t $<
	touch $(BUILD_DIR)/$@

PYTHON := $(shell pyenv which python3 2>/dev/null || which python3)

%.md-tag: %-source.yaml ${IMPORTS}
	$(PYTHON) y2md.py $<
	touch $(BUILD_DIR)/$@

prune-tag: ${TAGS}
	$(MAKE) -f prune.mk
	touch $(BUILD_DIR)/$@

clean:
	rm $(BUILD_DIR)/*
	rm $(DEF_DIR)/*
	rm $(JSON_DIR)/*
	rm $(MD_DIR)/*

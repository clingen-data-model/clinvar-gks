BUILD_DIR := build
SOURCES := $(wildcard *-source.yaml)
CLASS_FILTER_FILES = $(SOURCES:%-source.yaml=${BUILD_DIR}/%.classes)
FILTER_CLASSES := $(shell cat ${CLASS_FILTER_FILES})
FILTER_JSONS = $(FILTER_CLASSES:%=json/%)
FILTER_DEFS = $(FILTER_CLASSES:%=def/%.rst)
FILTER_MDS = $(FILTER_CLASSES:%=md/%.md)

.DEFAULT: prune

prune: $(filter-out ${FILTER_JSONS} ${FILTER_DEFS} ${FILTER_MDS},$(wildcard def/* json/* md/*))
	$(if $^,rm $^)
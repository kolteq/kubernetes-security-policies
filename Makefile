.PHONY: test test-vap build build-vap-bundles clean clean-vap-bundles

test: test-vap

test-vap:
	./admission/ValidatingAdmissionPolicy/test_ValidatingAdmissionPolicy.sh

build: build-vap-bundles

build-vap-bundles:
	./admission/ValidatingAdmissionPolicy/build_bundles.py --build

clean: clean-vap-bundles

clean-vap-bundles:
	rm ./admission/ValidatingAdmissionPolicy/bundles/*.zip ./admission/ValidatingAdmissionPolicy/bundles/*.tar.gz

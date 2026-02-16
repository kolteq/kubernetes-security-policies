.PHONY: test test-vap test-istio build build-vap-bundles clean clean-vap-bundles

test: test-vap test-istio

test-vap:
	./admission/ValidatingAdmissionPolicy/test_ValidatingAdmissionPolicy.sh

test-istio:
	./istio/test_all.sh

build: build-vap-bundles

build-vap-bundles:
	./admission/ValidatingAdmissionPolicy/build_bundles.py

clean: clean-vap-bundles

clean-vap-bundles:
	rm ./admission/ValidatingAdmissionPolicy/bundles/*/*.zip* ./admission/ValidatingAdmissionPolicy/bundles/*/*.tar.gz*

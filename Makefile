.PHONY: test test-vap test-istio build build-vap-bundles clean clean-vap-bundles

test: test-vap test-istio

test-vap:
	./admission/validatingAdmissionPolicies/policy_tests.sh

test-istio:
	./istio/test_all.sh

build: build-vap-bundles

build-vap-bundles:
	./admission/validatingAdmissionPolicies/build_bundles.py --build

clean: clean-vap-bundles

clean-vap-bundles:
	rm ./admission/validatingAdmissionPolicies/bundles/*.zip ./admission/validatingAdmissionPolicies/bundles/*.tar.gz

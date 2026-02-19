.PHONY: test test-vap test-istio build build-vap-bundles clean clean-vap-bundles

test: test-vap test-istio

test-vap:
	./admission/ValidatingAdmissionPolicy/test_ValidatingAdmissionPolicy.sh

test-istio:
	./istio/test_all.sh

build: build-vap-bundles build-vap-policies

build-vap-bundles:
	./admission/ValidatingAdmissionPolicy/build_bundles.py

build-vap-policies:
	./admission/ValidatingAdmissionPolicy/build_policies.py

clean: clean-vap-bundles clean-vap-policies

clean-vap-bundles:
	rm ./admission/ValidatingAdmissionPolicy/bundles/*/*.zip* ./admission/ValidatingAdmissionPolicy/bundles/*/*.tar.gz*

clean-vap-policies:
	rm ./admission/ValidatingAdmissionPolicy/policies/*.zip* ./admission/ValidatingAdmissionPolicy/policies/*.tar.gz*

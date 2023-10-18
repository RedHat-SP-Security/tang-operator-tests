# tang-operator test suite
Upstream repository for tang-operator-tests. Based on the previous work developed on common repository:
https://github.com/RedHat-SP-Security/tests

This test suite is supposed to be executed and maintained via Test Managament Tool (`tmt`).
The data are structured in flexible metadata format (`fmf`).

For more information about `tmt` and `fmf`, please visit:
* https://github.com/teemtee/tmt
* https://github.com/teemtee/fmf

In order to execute tang-operator test suite, you will need some software installed in your machine:
- A K8S/OpenShift/minikube cluster
- kubectl/oc
- helm (for DAST test execution)
- podman (for Malware Detection test execution)
- clamav (for Malware Detection test execution)

In case `helm`, `podman` or `clamav` does not exist, tests requiring its installation won't be executed.

To execute the test suite, next steps must be followed:

Clone Security Special Projects Test repository:
```bash
$ git clone https://github.com/RedHat-SP-Security/tang-operator-tests
```

Access tang-operator Test Suite directory:
```bash
$ cd tang-operator/Sanity
```

Execute Test suite (through make command):
```bash
$ make
```

Previous command will install the latest version of the upstream project, that corresponds to version "quay.io/sec-eng-special/tang-operator-bundle:latest".
In case a specific version wants to be executed instead, it can be done through next command:
```bash
$ IMAGE_VERSION="quay.io/sec-eng-special/tang-operator-bundle:v0.0.26" make
```

It is also possible to run the Test Suite without installing any tang-operator version, by just keeping the existing installed version. To do so, next must be executed:
```bash
$ DISABLE_BUNDLE_INSTALL_TESTS=1 make
```

Finally, it is also possible to run the Test Suite installing the latest tang-operator test suite, without uninstalling it at the end of the test execution and keep the existing installed version. To do so, next must be executed:
```bash
$ DISABLE_BUNDLE_UNINSTALL_TESTS=1 make
```

The output of the execution should dump something similar to this output:
```bash
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::   /CoreOS/tang-operator/Sanity
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

:: [ 19:09:41 ] :: [   LOG    ] :: Phases fingerprint:  vIfocsyN
:: [ 19:09:41 ] :: [   LOG    ] :: Asserts fingerprint: VyWiusp0
:: [ 19:09:41 ] :: [   LOG    ] :: JOURNAL XML: /var/tmp/beakerlib-ufKrQJe/journal.xml
:: [ 19:09:41 ] :: [   LOG    ] :: JOURNAL TXT: /var/tmp/beakerlib-ufKrQJe/journal.txt
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
::   Duration: 1458s
::   Phases: 18 good, 0 bad
::   OVERALL RESULT: PASS (/CoreOS/tang-operator/Sanity)
```

Please, take into account previous output could change (for example, a higher number of Phases could exist in the Test suite).

In case it is necessary, a more verbose output of the test execution can be indicated, through `V=1` option:
```bash
$ V=1 make
```

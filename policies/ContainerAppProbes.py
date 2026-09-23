"""Both probes, or neither is trustworthy.

This exists because of a measured finding on the AWS side: the EKS pod-failure
drill lost 3 of 400 requests during deregistration because readiness and liveness
were the same endpoint, so a pod that was merely busy got killed instead of
drained. No built-in checkov policy asserts a Container App declares both, so
this one does — the lesson travels with the code rather than living in a
postmortem nobody reads.
"""
from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


def _unwrap(value):
    """checkov wraps nested blocks in single-element lists, sometimes twice."""
    for _ in range(5):
        if isinstance(value, list) and len(value) == 1:
            value = value[0]
        else:
            break
    return value


class ContainerAppProbes(BaseResourceCheck):
    def __init__(self):
        super().__init__(
            name="Container App containers must declare both liveness and readiness probes",
            id="CKV_ACP_1",
            categories=[CheckCategories.GENERAL_SECURITY],
            supported_resources=["azurerm_container_app"],
        )

    def scan_resource_conf(self, conf):
        template = _unwrap(conf.get("template"))
        if not isinstance(template, dict):
            # Never silently pass something we could not read.
            return CheckResult.FAILED

        containers = template.get("container")
        containers = containers if isinstance(containers, list) else [containers]
        # A template with no container is malformed, not compliant.
        if not containers or containers == [None]:
            return CheckResult.FAILED

        for raw in containers:
            c = _unwrap(raw)
            if not isinstance(c, dict):
                return CheckResult.FAILED
            if not c.get("liveness_probe") or not c.get("readiness_probe"):
                return CheckResult.FAILED
        return CheckResult.PASSED


check = ContainerAppProbes()

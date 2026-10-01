# Changelog

## [1.0.0](https://github.com/superlinked/terraform-azure-sie/compare/v0.7.3...v1.0.0) (2026-10-01)


### ⚠ BREAKING CHANGES

* the system subnet NSG no longer allows inbound traffic from the Internet by default; the plan removes the AllowPublicLoadBalancerInbound rule in place. Set public_load_balancer_ports with public_load_balancer_allowed_ip_ranges, or set public_load_balancer_ports = ["80", "443", "8080"] and allow_public_load_balancer = true to keep the previous rule with no plan change. api_server_authorized_ip_ranges entries broader than /8 or /16 now require allow_public_api_server = true.

### Bug Fixes

* close the AKS system subnet and reject open API allowlists ([#5](https://github.com/superlinked/terraform-azure-sie/issues/5)) ([2cb24f0](https://github.com/superlinked/terraform-azure-sie/commit/2cb24f078aadb4de56c5d09ddadd8a2f9d8066b8))
* use SIE 0.9.0 in AKS deployment examples ([#6](https://github.com/superlinked/terraform-azure-sie/issues/6)) ([de3339c](https://github.com/superlinked/terraform-azure-sie/commit/de3339cc1b060a964c096e04a7ba906c97ff434c))

## [0.7.3](https://github.com/superlinked/terraform-azure-sie/compare/v0.7.2...v0.7.3) (2026-09-28)


### Bug Fixes

* pin Azure SIE deployment examples to 0.8.2 ([#2](https://github.com/superlinked/terraform-azure-sie/issues/2)) ([6f54653](https://github.com/superlinked/terraform-azure-sie/commit/6f54653b54c4edeee1789b576769b36ce08da44d))
* use SIE 0.8.3 in AKS deployment examples ([#4](https://github.com/superlinked/terraform-azure-sie/issues/4)) ([5173d74](https://github.com/superlinked/terraform-azure-sie/commit/5173d741454f8975607d882a819692b65f7547ab))

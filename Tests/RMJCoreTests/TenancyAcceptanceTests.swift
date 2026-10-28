import Foundation
import Testing
import RMJCore

struct TenancyAcceptanceTests {
    @Test func declaredCompaniesDenyEachOtherAndSharedTenantsAreDeniedNowhere() throws {
        let tenants = try JSONDecoder().decode([String: TenantConfig].self, from: Data(#"{"acme":{},"globex":{},"personal":{"shared":true}}"#.utf8))
        for (repo, destination) in [("acme", "globex"), ("globex", "acme")] {
            #expect(Tenancy.denies(repoTenant: repo, destinationTenant: destination, tenants: tenants))
        }
        for tenant in tenants.keys {
            #expect(!Tenancy.denies(repoTenant: tenant, destinationTenant: tenant, tenants: tenants))
            #expect(!Tenancy.denies(repoTenant: "personal", destinationTenant: tenant, tenants: tenants))
            #expect(!Tenancy.denies(repoTenant: tenant, destinationTenant: "personal", tenants: tenants))
            #expect(!Tenancy.denies(repoTenant: "undeclared", destinationTenant: tenant, tenants: tenants))
            #expect(!Tenancy.denies(repoTenant: tenant, destinationTenant: "undeclared", tenants: tenants))
        }
        #expect(!Tenancy.denies(repoTenant: "unknown-one", destinationTenant: "unknown-two", tenants: tenants))
    }

    @Test func rulesValidationAcceptsSharedTenantField() throws {
        let rules = try RulesValidation.parse(Data(#"{"destinations":{},"tenants":{"personal":{"shared":true}},"rules":[]}"#.utf8))
        #expect(rules.tenants["personal"]?.shared == true)
    }
}

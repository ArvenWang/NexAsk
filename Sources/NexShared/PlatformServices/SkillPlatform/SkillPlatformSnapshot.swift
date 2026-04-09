import Foundation

struct SkillPlatformVerificationState {
    let invalidPackageCount: Int
    let lastErrorMessage: String?
}

struct SkillPlatformSnapshot {
    let catalogSnapshot: SkillCatalogSnapshot?
    let installedSkillIDs: [String]
    let catalogSkillIDs: [String]
    let skillsWithUpdates: [String]
    let verification: SkillPlatformVerificationState
    let entitlementSnapshot: CommerceEntitlementSnapshot
    let entitlementIsReady: Bool
    let runtimeSnapshot: GatewayRuntimeSnapshot
}

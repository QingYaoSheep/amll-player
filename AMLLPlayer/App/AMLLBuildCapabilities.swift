import Foundation

/// Central compile-time gate isolating self-signed / sideload capabilities
/// from a future App Store compliant build (`-DAMLL_APP_STORE_COMPLIANT`).
enum AMLLBuildCapabilities {
    static var supportsPrivateVariableBlur: Bool {
        #if AMLL_APP_STORE_COMPLIANT
        false
        #else
        true
        #endif
    }

    static var supportsSilentBackgroundKeepAlive: Bool {
        #if AMLL_APP_STORE_COMPLIANT
        false
        #else
        true
        #endif
    }
}

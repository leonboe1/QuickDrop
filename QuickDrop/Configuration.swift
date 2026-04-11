//
//  Configuration.swift
//  QuickDrop
//
//  Created by Leon Böttger on 15.08.25.
//

import LUI
import SwiftUI

let configuration = LUIConfiguration(
    appName: "QuickDrop",
    
    plusVersionInfo: GetPlusViewInformation(
        lifetimeID: "plusversion",
        monthlyID: "quickdrop.monthly",
        yearlyID: "quickdrop.yearly",
        plusViewHeader: isMac() ? "plusview_title" : nil,
        description: isMac() ? "plusview_description" : "plusview_description_phone",
        onBoughtPlusVersionAlertMessage: "plusview_success_description",
        plusVersionFeatures: [],
        settingsLabelColor: .orange,
        settingsFooter: "plusview_footer_phone"
    ),
    
    hasRoundedFont: false,
    
    switchedToInAppPurchaseWithBundleVersion: AppVersionBundle(appVersion: "1.2", buildVersion: 0, legacyUserDefaultsKey: Settings.UserDefaultsKeys.plusVersionLegacy.rawValue),
    
    copyrightInformation: licenseText,
    
    logUploadDisclaimerMessage: "log_upload_disclaimer_message",
    
    loggingUrl: AppGroup.appGroupDirectory,
    
    introductionViewInformation: "QuickDropWelcomeDescription",
    
    introductionViewImage: Image(.quickDropMockup),
    
    usesAutomaticReviewPromptAndShareSheet: false,
    
    usesPagedIntroduction: true,
    
    supportsSplitView: false,
    
    supportsLiquidGlass: true,
    
    supportsPortraitSplitView: false,
    
    supportsDarkModeShadow: true,
    
    privacyPolicyURL: .privacyPolicyURL
)


extension String {
    static let privacyPolicyURL = "https://leonboettger.com/quickdrop-privacy"
}

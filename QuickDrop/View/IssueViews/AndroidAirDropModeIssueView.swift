//
//  AndroidAirDropModeIssueView.swift
//  QuickDrop
//
//  Created by Leon Böttger on 10.06.26.
//

import Foundation
import SwiftUI

struct AndroidAirDropModeIssueView: View {
    var body: some View {
        IssueView(
            image: .smartphone,
            header: "AndroidAirDropModeHeader".localized(),
            description: "AndroidAirDropModeDescription".localized()
        )
    }
}

#Preview {
    AndroidAirDropModeIssueView()
        .frame(width: issueViewWidth, height: issueViewHeight)
}

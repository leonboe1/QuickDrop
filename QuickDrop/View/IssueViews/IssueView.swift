//
//  IssueView.swift
//  QuickDrop
//
//  Created by Leon Böttger on 15.05.25.
//

import SwiftUI
import Foundation

let issueViewWidth = 600.0
let issueViewHeight = 400.0

struct IssueView: View {
    
    @Environment(\.colorScheme) var colorScheme
    
    let image: ImageResource
    let header: String
    let description: String
    
    var actionLabel: String? = nil
    var action: (() async -> Void)? = nil
    
    @State var isLoading = false
    
    var body: some View {
        ZStack {
            
            if colorScheme == .light {
                Color.white
            }
            
            let imageSize = 120.0
            ScrollView {
                
                ZStack {
                    
                    if colorScheme == .light {
                        Color.gray.opacity(0.1)
                    }
                    else {
                        Color.black.opacity(0.2)
                    }
                    
                    Image(image)
                        .resizable()
                        .frame(width: imageSize, height: imageSize)
                        .overlay(
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: imageSize * 0.2))
                                .background(Circle().foregroundColor(.white))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .foregroundColor(.red)
                            
                                .padding(imageSize * 0.09)
                                .padding(.trailing, image == .filter ? 15 : 0)
                                .padding(.bottom, imageSize * 0.03)
                        )
                        .padding(.vertical)
                    
                }
                .padding(.bottom, 20)
                
                Text(header)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(description)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(0.7)
                    .padding()
                
                if let actionLabel = actionLabel, let action = action {
                    Button(actionLabel) {
                        
                        withAnimation {
                            isLoading = true
                        }
                        
                        Task {
                            await action()
                            
                            withAnimation {
                                isLoading = false
                            }
                        }
                    }
                    .opacity(isLoading ? 0 : 1)
                    .overlay(
                        ProgressView()
                            .opacity(isLoading ? 1 : 0)
                            .scaleEffect(0.7)
                    )
                    .padding(.bottom, 30)
                }
            }
        }
    }
}


#Preview {
    IssueView(image: .smartphone, header: "Header", description: "Description")
        .frame(width: 600, height: 400)
}

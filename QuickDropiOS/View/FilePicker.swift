//
//  FilePicker.swift
//  QuickDrop
//
//  Created by Leon Böttger on 15.08.25.
//

import SwiftUI
import PhotosUI
import LUI
import UniformTypeIdentifiers

struct SendPickerButton<Label: View>: View {
    var label: () -> Label
    var onResult: (_ urls: [URL]?, _ text: String?) -> Void
    var onPrepare: (() -> Void)? = nil
    
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    
    @State private var showFilePicker = false
    
    var body: some View {
        Menu {
            Button("SendImages", systemImage: "photo") {
                showPhotoPicker = true
            }
            Button("SendFiles", systemImage: "folder") {
                showFilePicker = true
            }
            Button("SendClipboard", systemImage: "doc.on.clipboard") {
                if let clipboardText = UIPasteboard.general.string, !clipboardText.isEmpty {
                    onResult(nil, clipboardText)
                } else {
                    showAlert(title: "ClipboardEmpty", message: "ClipboardEmptyMessage")
                }
            }
        } label: {
            label()
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: nil,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: selectedPhotoItems) { newItems in
            guard !newItems.isEmpty else { return }
            onPrepare?()
            updatedPhotoSelection(content: newItems)
        }
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.item, .folder], // any file
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                onResult(urls, nil)
            case .failure:
                onResult(nil, nil)
            }
        }
    }
    
    
    func updatedPhotoSelection(content: [PhotosPickerItem]) {
        Task {
            do {
                let urls = try await fetchContentUrls(content: content)
                onResult(urls, nil)
                selectedPhotoItems = []
            } catch {
                log("Could not fetch photo URLs: \(error)")
                onResult(nil, nil)   // let the caller dismiss the "preparing" it opened on `onPrepare`
                selectedPhotoItems = []
            }
        }
    }
    
    
    func fetchContentUrls(content: [PhotosPickerItem]) async throws -> [URL] {
        try await withThrowingTaskGroup(of: URL?.self, returning: [URL].self) { group in
            let fileManager = FileManager.default
            
            for item in content {
                group.addTask {
                    if let dataUrl = try await item.loadTransferable(type: Data.self) {
                        
                        if let contentType = item.supportedContentTypes.first {
                            // Step 2: make the URL file name and a get a file extention.
                            let url = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(contentType.preferredFilenameExtension ?? "")")
                            
                            do {
                                // Step 3: write to temp App file directory and return in completionHandler
                                try dataUrl.write(to: url)
                                return url
                            } catch {
                                log("Failed to write data to file: \(error)")
                                throw error
                            }
                            
                        }
                        
                        //                        let destination = fileManager.temporaryDirectory.appendingPathComponent(dataUrl.url.lastPathComponent)
                        //
                        //                        // overwrite if file exists
                        //                        if fileManager.fileExists(atPath: destination.path) {
                        //                            try fileManager.removeItem(at: destination)
                        //                        }
                        //
                        //                        log("Copying photo at \(dataUrl.url) to \(destination)")
                        //
                        //                        do {
                        //                            try fileManager.copyItem(at: dataUrl.url, to: destination)
                        //                        }
                        //                        catch {
                        //                            log("Failed to copy photo: \(error)")
                        //                            throw error
                        //                        }
                        //                        return destination
                    }
                    return nil
                }
            }
            
            var finalUrls = [URL]()
            for try await result in group {
                if let url = result {
                    finalUrls.append(url)
                }
            }
            
            return finalUrls
        }
    }
}


/// File representation
fileprivate struct DataUrl: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { data in
            
            log("Received data: \(data.url)")
            return SentTransferredFile(data.url)
        } importing: { received in
            
            log("Importing file: \(received.file)")
            return Self(url: received.file)
        }
    }
}


#Preview {
    SendPickerButton {
        Text("Send Files")
            .font(.headline)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
    } onResult: { urls, text in
        if let urls = urls {
            log("Selected URLs: \(urls)")
        }
        if let text = text {
            log("Clipboard text: \(text)")
        }
    }
}

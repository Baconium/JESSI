//
//  Logger.swift
//  mobilegewalt
//
//  Created by roooot on 15.11.25.
//

import Foundation
import Combine
import SwiftUI

let modlogger = Logger()
let tunnelinglogger = Logger()

class Logger: ObservableObject {
    @Published var logs: [String] = []
    private var lastwasdivider = false
    private var pendingdivider = false

    init() {}

    func log(_ message: String) {
        DispatchQueue.main.async {
            if self.pendingdivider {
                self.divider()
                self.pendingdivider = false
            }
            
            if self.lastwasdivider || self.logs.isEmpty {
                self.logs.append(message)
                print("")
            } else {
                self.logs[self.logs.count - 1] += "\n" + message
            }

            self.lastwasdivider = false
        }

        print(message)
    }

    func divider() {
        DispatchQueue.main.async {
            self.lastwasdivider = true
        }
    }
    
    func enclosedlog(_ message: String) {
        DispatchQueue.main.async {
            if !self.lastwasdivider && !self.logs.isEmpty {
                self.divider()
            }
            
            if self.lastwasdivider || self.logs.isEmpty {
                self.logs.append(message)
            } else {
                self.logs[self.logs.count - 1] += "\n" + message
            }
            
            self.lastwasdivider = false
            self.pendingdivider = true
        }
        
        print(message)
    }
    
    func flushdivider() {
        DispatchQueue.main.async {
            if self.pendingdivider {
                self.divider()
                self.pendingdivider = false
            }
        }
    }
}

struct LogsViewSheet: View {
    @ObservedObject var logger: Logger
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                ForEach(logger.logs, id: \.self) { log in
                    Text(log)
                        .font(.system(size: 15, design: .monospaced))
                        .onTapGesture {
                            UIPasteboard.general.string = log
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                    .foregroundColor(.green)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { logger.logs.removeAll() }
                        .foregroundColor(.red)
                }
            }
        }
    }
}



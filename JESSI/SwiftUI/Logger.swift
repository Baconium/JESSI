//
//  Logger.swift
//  mobilegewalt
//
//  Created by roooot on 15.11.25.
//

import Foundation
import Combine

let runtimelogger = Logger()

class Logger: ObservableObject {
    @Published var logs: [String] = []
    private var lastwasdivider = false

    init() {}

    func log(_ message: String) {
        DispatchQueue.main.async {
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
}

//
//  CustomBuild.swift
//  Ice
//

import Foundation

/// Local integrations use their own update channel so upstream releases cannot
/// silently replace the additional menu bar behavior.
enum CustomBuild {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "IceCustomBuild") as? Bool ?? false
    }

    static let updatesURL = URL(string: "https://github.com/northpixelworks/Ice/commits/main")!

    static var description: String {
        Bundle.main.object(forInfoDictionaryKey: "IceCustomBuildDescription") as? String
            ?? "Custom build with Portworth integration and macOS 27 support"
    }
}

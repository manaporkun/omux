import SwiftUI

// The macOS 27 SDK exports a State macro alongside the existing property wrapper.
// Use the wrapper explicitly so building with Command Line Tools doesn't require
// Xcode's SwiftUIMacros plugin. This is the same SwiftUI.State storage on older SDKs.
typealias ViewState<Value> = SwiftUI.State<Value>

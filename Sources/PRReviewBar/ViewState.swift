import SwiftUI

// The macOS 26 SDK resolves `@State` to a macro whose plugin ships only with Xcode, so the Command Line Tools cannot expand it.
typealias ViewState<Value> = SwiftUI.State<Value>

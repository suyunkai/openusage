import SwiftUI

extension EnvironmentValues {
    /// On while Privacy Mode sees a capture, and on a copied card while it's on.
    // Spelled out instead of `@Entry`: the Command Line Tools ship without the SwiftUI macro plugin.
    var concealsAccountNames: Bool {
        get { self[ConcealsAccountNamesKey.self] }
        set { self[ConcealsAccountNamesKey.self] = newValue }
    }
}

private struct ConcealsAccountNamesKey: EnvironmentKey {
    static let defaultValue = false
}

extension View {
    /// Blurs the account's own name in place while \`concealsAccountNames\` is on. The provider's name,
    /// shown for an account without one, stays readable.
    func concealingAccountName(of provider: Provider) -> some View {
        modifier(AccountNameConcealment(isNamed: provider.labelBesideName != nil))
    }
}

private struct AccountNameConcealment: ViewModifier {
    let isNamed: Bool
    @Environment(\.concealsAccountNames) private var concealsAccountNames

    func body(content: Content) -> some View {
        content.blur(radius: isNamed && concealsAccountNames ? 4 : 0)
    }
}

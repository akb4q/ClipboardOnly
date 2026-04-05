// AppMenuView.swift — menu contents

import SwiftUI

struct AppMenuView: View {
    @EnvironmentObject var controller: MenuBarController

    var body: some View {
        Toggle(L10n.str(.toggle), isOn: $controller.clipboardMode)

        Divider()

        Text(String(format: L10n.str(.saveLocation), controller.saveDirectory.path))
            .foregroundStyle(.secondary)

        Divider()

        Button(L10n.str(.quit)) { controller.quit() }
    }
}

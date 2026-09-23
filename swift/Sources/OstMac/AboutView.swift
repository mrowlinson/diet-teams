// AboutView.swift — om-package lane: About Diet Teams window content.
//
// om-reskin-chrome: Diet tokens only.
import AppKit
import DietDesign
import OstMacCore
import SwiftUI

struct AboutView: View {

    public var body: some View {
        VStack(spacing: DietSpace.sm) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: DietSize.avatarLG + DietSpace.md, height: DietSize.avatarLG + DietSpace.md)
                    .padding(.bottom, DietSpace.xs)
            }
            Text(AppIdentity.name)
                .font(DietType.title1).bold()
                .foregroundStyle(DietColor.textPrimaryColor)
            Text("Version \(AppIdentity.version)")
                .font(DietType.body)
                .foregroundStyle(DietColor.textSecondaryColor)
            Text(AppIdentity.bundleID)
                .font(DietType.captionMono)
                .foregroundStyle(DietColor.textSecondaryColor)
                .textSelection(.enabled)
            Text("\(AppIdentity.tagline) — chat list, conversation, live updates.")
                .font(DietType.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(DietColor.textSecondaryColor)
                .padding(.top, DietSpace.xs)
        }
        .padding(DietSpace.lg)
        .frame(width: 340)
        .background(DietColor.windowColor)
    }
}
